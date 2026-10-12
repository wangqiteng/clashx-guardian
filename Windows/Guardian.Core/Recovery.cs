namespace Guardian.Core;

public sealed class Recovery(IController controller, Func<CancellationToken, Task<ProbeResult>> probe,
    Action<string> log, Func<CancellationToken, Task>? settle = null)
{
    private readonly Func<CancellationToken, Task> wait = settle ?? (t => Task.Delay(2000, t));

    public async Task<RecoveryResult> RunAsync(string group, CancellationToken token)
    {
        var initial = await controller.SnapshotAsync(group, token);
        var candidates = await controller.BenchmarkAsync(initial.Candidates.Where(n => n != initial.Selected && Policy.IsAllowed(n)), token);
        if ((await probe(token)).Healthy) return new(true, false, "线路自行恢复，无需切换");
        if (candidates.Count == 0) return new(false, false, "没有测速成功的非台湾节点");
        string expected = initial.Selected;
        string lastOwned = initial.Selected;
        bool changed = false, success = false, externalChangeObserved = false;
        try
        {
            foreach (var candidate in candidates.Where(n => Policy.IsAllowed(n.Name)).OrderBy(n => n.Milliseconds).Take(3))
            {
                token.ThrowIfCancellationRequested();
                var current = await controller.SnapshotAsync(group, token);
                if (current.Selected != expected)
                {
                    externalChangeObserved = true;
                    return new(false, false, "检测到用户或客户端修改节点，停止自动操作");
                }
                if (!current.Candidates.Contains(candidate.Name)) continue;
                // 即使请求响应丢失，服务端也可能已切换；finally 会核对实际节点后回退。
                lastOwned = current.Selected;
                expected = candidate.Name;
                changed = true;
                await controller.SelectAsync(group, candidate.Name, token);
                await wait(token);
                if ((await controller.SnapshotAsync(group, token)).Selected != expected)
                {
                    externalChangeObserved = true;
                    return new(false, false, "节点选择被外部修改，停止自动操作");
                }
                var verified = await probe(token);
                token.ThrowIfCancellationRequested();
                if (verified.Healthy)
                {
                    if ((await controller.SnapshotAsync(group, token)).Selected != expected)
                    {
                        externalChangeObserved = true;
                        return new(false, false, "验证期间节点被外部修改，停止自动操作");
                    }
                    success = true;
                    var measurement = candidate.Milliseconds == int.MaxValue ? "实际连通性验证通过；客户端延迟未知" : candidate.Milliseconds + " ms";
                    return new(true, true, $"已切换并验证：{candidate.Name}（{measurement}）");
                }
                log("候选节点验证失败：" + candidate.Name + "；" + verified.Detail + "。尝试下一个候选节点");
            }
            return new(false, false, "候选节点均未通过验证，可能是站点或公共线路故障");
        }
        finally
        {
            // 暂停/退出也需收尾；仅回退我们仍拥有的选择，不覆盖用户手动操作。
            if (changed && !success && !externalChangeObserved)
            {
                if (!Policy.IsAllowed(initial.Selected)) log("原节点属于排除地区，不自动切回；保留最后候选，请手动选择");
                else
                {
                    // Native UI reads and selection acknowledgements span several
                    // child processes; eight seconds can expire after selection
                    // succeeded but before its final acknowledgement is read.
                    using var rollback = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                    try
                    {
                        var current = await controller.SnapshotAsync(group, rollback.Token);
                        if (current.Selected == expected || (lastOwned != initial.Selected && current.Selected == lastOwned))
                        {
                            await controller.SelectAsync(group, initial.Selected, rollback.Token);
                            if ((await controller.SnapshotAsync(group, rollback.Token)).Selected != initial.Selected)
                                throw new InvalidOperationException();
                            log("已回退原节点");
                        }
                    }
                    catch { log("回退未完成，请在客户端确认当前节点"); }
                }
            }
        }
    }
}
