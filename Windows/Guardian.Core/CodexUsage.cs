using System.Diagnostics;
using System.Text.Json;

namespace Guardian.Core;

// 独立读取 CLI 额度，不访问认证文件，不影响网络恢复任务。
public static class CodexUsage
{
    // 校验窗口并生成本地时间说明，缺失数据不能显示为零额度。
    public static string Parse(JsonElement result)
    {
        JsonElement bucket = result.TryGetProperty("rateLimitsByLimitId", out JsonElement buckets)
            ? buckets.GetProperty("codex") : result.GetProperty("rateLimits");
        if (bucket.TryGetProperty("limitId", out JsonElement id) && id.GetString() != "codex") throw new FormatException();
        List<string> lines = new();
        foreach (string key in new[] { "primary", "secondary" })
        {
            if (!bucket.TryGetProperty(key, out JsonElement window) || window.ValueKind == JsonValueKind.Null) continue;
            double used = window.GetProperty("usedPercent").GetDouble();
            double minutes = window.GetProperty("windowDurationMins").GetDouble();
            DateTimeOffset reset = DateTimeOffset.FromUnixTimeSeconds(window.GetProperty("resetsAt").GetInt64());
            if (!double.IsFinite(used) || used < 0 || used > 100 || !double.IsFinite(minutes) || minutes <= 0 || reset <= DateTimeOffset.UtcNow) throw new FormatException();
            string duration = minutes >= 1440 ? $"{minutes / 1440:g} 天" : minutes >= 60 ? $"{minutes / 60:g} 小时" : $"{minutes:g} 分钟";
            lines.Add($"{duration}：剩余 {Math.Floor(100 - used)}%（已用 {used:g}%）· {reset.LocalDateTime:MM-dd HH:mm} 重置");
        }
        return lines.Count > 0 ? string.Join("\n", lines) : throw new FormatException();
    }

    // 只选桌面安装目录内的资源组件，不能把桌面前端当作命令行启动。
    public static string? FindDesktopComponent(string frontend, Func<string, bool> exists)
    {
        string? directory = Path.GetDirectoryName(frontend);
        if (string.IsNullOrEmpty(directory)) return null;
        string candidate = Path.Combine(directory, "resources", "codex.exe");
        if (exists(candidate)) return candidate;
        // 已运行的后台组件本身就在 resources 中。
        if (string.Equals(Path.GetFileName(directory), "resources", StringComparison.OrdinalIgnoreCase)
            && string.Equals(Path.GetFileName(frontend), "codex.exe", StringComparison.OrdinalIgnoreCase)
            && exists(frontend)) return frontend;
        return null;
    }

    // 从已运行桌面进程定位内置组件，不扫描 PATH，不要求额外安装 CLI。
    private static ProcessStartInfo Locate()
    {
        HashSet<string> candidates = new(StringComparer.OrdinalIgnoreCase);
        foreach (string name in new[] { "Codex", "ChatGPT" })
        foreach (Process desktop in Process.GetProcessesByName(name))
        {
            using (desktop)
            {
                try
                {
                    string? path = desktop.MainModule?.FileName;
                    string? candidate = path == null ? null : FindDesktopComponent(path, File.Exists);
                    if (candidate != null) candidates.Add(candidate);
                }
                catch (Exception) { /* 无权读取或已退出的进程不影响其他候选。 */ }
            }
        }
        if (candidates.Count != 1) throw new FileNotFoundException();
        return new ProcessStartInfo(candidates.Single());
    }

    // 限时读取有界输出，退出时终止子进程树，避免残留 CLI。
    public static async Task<string> ReadAsync(CancellationToken cancellation)
    {
        using CancellationTokenSource deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(20));
        using Process process = new();
        Task? drain = null;
        string accountLabel = "";
        try
        {
            ProcessStartInfo start = Locate(); start.ArgumentList.Add("app-server");
            start.UseShellExecute = false; start.CreateNoWindow = true;
            start.RedirectStandardInput = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            process.StartInfo = start; process.Start();
            drain = DrainAsync(process.StandardError, deadline.Token);
            await process.StandardInput.WriteLineAsync("{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"guardian_usage\",\"version\":\"0.1.6\"}}}");
            char[] buffer = new char[4096]; string pending = ""; int total = 0;
            while (true)
            {
                int count = await process.StandardOutput.ReadAsync(buffer.AsMemory(), deadline.Token);
                if (count == 0 || (total += count) > 1048576) throw new FormatException();
                pending += new string(buffer, 0, count);
                int newline;
                while ((newline = pending.IndexOf('\n')) >= 0)
                {
                    string line = pending[..newline]; pending = pending[(newline + 1)..];
                    using JsonDocument document = JsonDocument.Parse(line);
                    JsonElement root = document.RootElement;
                    if (!root.TryGetProperty("id", out JsonElement id) || !id.TryGetInt32(out int number)) continue;
                    if (root.TryGetProperty("error", out _)) throw new FormatException();
                    if (number == 1)
                    {
                        await process.StandardInput.WriteLineAsync("{\"method\":\"initialized\"}");
                        await process.StandardInput.WriteLineAsync("{\"id\":2,\"method\":\"account/read\",\"params\":{\"refreshToken\":false}}");
                    }
                    if (number == 2)
                    {
                        JsonElement account = root.GetProperty("result").GetProperty("account");
                        if (account.ValueKind != JsonValueKind.Object || account.GetProperty("type").GetString() != "chatgpt")
                            return "桌面内置组件未提供可复用的 ChatGPT 登录态；请在 Codex 内查看额度";
                        accountLabel = account.TryGetProperty("email", out JsonElement email) ? email.GetString() ?? "未知账号" : "未知账号";
                        await process.StandardInput.WriteLineAsync("{\"id\":3,\"method\":\"account/rateLimits/read\"}");
                    }
                    if (number == 3) return "读取账号：" + accountLabel + "（请与桌面端核对）\n" + Parse(root.GetProperty("result"));
                }
            }
        }
        catch (FileNotFoundException) { return "未识别到唯一的桌面内置组件：请打开 Codex 桌面版，再点击刷新额度"; }
        catch (Exception) { return "桌面组件额度暂不可用；请检查 Codex 登录和网络，或在 Codex 内查看"; }
        finally
        {
            deadline.Cancel();
            try { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); } } catch (Exception) { }
            if (drain != null) await drain;
        }
    }

    // 丢弃诊断输出，不保存可能包含账号信息的内容。
    private static async Task DrainAsync(StreamReader reader, CancellationToken token)
    {
        try { char[] buffer = new char[4096]; while (await reader.ReadAsync(buffer.AsMemory(), token) > 0) { } }
        catch (Exception) { }
    }
}
