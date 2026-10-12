using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Automation;
using Guardian.Core;

namespace Guardian.Windows;

internal sealed record NativeRequest(string Action, string Name = "", string Expected = "");
internal sealed record NativeReply(string Selected, NativeNode[] Nodes, string Error = "", bool WindowMinimized = false);

// Every cross-process UIA operation runs in a disposable child, so a stalled
// accessibility provider cannot block the tray, pause, or exit.
internal sealed class NativeController : IController
{
    private string observed = "";
    public async Task<Snapshot> SnapshotAsync(string group, CancellationToken token)
    {
        var reply = await CallAsync(new("snapshot"), token);
        observed = reply.Selected;
        return new("iKuuu 官方选择节点", reply.Selected, reply.Nodes.Select(n => n.Name).Distinct().ToArray());
    }
    public async Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names, CancellationToken token)
    {
        var allowed = names.ToHashSet(StringComparer.Ordinal);
        var reply = await CallAsync(new("benchmark", Expected: observed), token);
        var scores = reply.Nodes.Where(n => allowed.Contains(n.Name) && n.Delay > 0)
            .Select(n => new DelayResult(n.Name, n.Delay!.Value)).OrderBy(n => n.Milliseconds).ToArray();
        if (scores.Length > 0) return scores;
        Storage.Log("官方测速未返回成功延迟；最多逐个复检三个候选节点，不把测速超时直接等同于节点不可用");
        return reply.Nodes.Where(n => allowed.Contains(n.Name)).DistinctBy(n => n.Name)
            .Select(n => new DelayResult(n.Name, int.MaxValue)).ToArray();
    }
    public async Task SelectAsync(string group, string name, CancellationToken token)
    {
        if (!Policy.IsAllowed(name)) throw new InvalidOperationException("不能选择排除节点");
        var reply = await CallAsync(new("select", name, observed), token);
        if (reply.Selected != name) throw new InvalidOperationException("客户端未确认目标节点");
        observed = reply.Selected;
    }
    private static async Task<NativeReply> CallAsync(NativeRequest request, CancellationToken token)
    {
        var directory = Path.Combine(Path.GetTempPath(), "IKuuuGuardian-ui-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var input = Path.Combine(directory, "request.json"); var output = Path.Combine(directory, "response.json");
        try
        {
            await File.WriteAllTextAsync(input, JsonSerializer.Serialize(request), token);
            var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
            if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "IKuuuGuardian.dll"));
            start.ArgumentList.Add("--native-ui"); start.ArgumentList.Add(input); start.ArgumentList.Add(output);
            using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动客户端适配进程");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(35));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException)
            {
                if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
                token.ThrowIfCancellationRequested();
                throw new InvalidOperationException("客户端控件响应超时，请展开 iKuuu 窗口后重试");
            }
            if (process.ExitCode != 0 || !File.Exists(output)) throw new InvalidOperationException("客户端适配进程失败");
            var reply = JsonSerializer.Deserialize<NativeReply>(await File.ReadAllTextAsync(output, token))
                ?? throw new InvalidOperationException("客户端没有返回状态");
            if (reply.Error.Length > 0) throw new InvalidOperationException(reply.Error);
            return reply;
        }
        finally { try { Directory.Delete(directory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }
}

internal static class NativeUI
{
    private sealed record Control(AutomationElement Element, string Name, ControlType Type, int Parent);
    private sealed record Frame(IntPtr Window, List<Control> Controls, int Group, string Selected, NativeNode[] Nodes);
    public static void Run(string input, string output)
    {
        SetThreadDpiAwarenessContext((IntPtr)(-4));
        NativeReply reply;
        try
        {
            if (GetForegroundWindow() == IntPtr.Zero || !GetPhysicalCursorPos(out _))
                throw new InvalidOperationException("Windows 桌面不可交互（锁屏或远程会话断开），暂停节点恢复");
            var request = JsonSerializer.Deserialize<NativeRequest>(File.ReadAllText(input)) ?? throw new InvalidOperationException("缺少操作");
            var frame = ServerFrame();
            if (request.Expected.Length > 0 && frame.Selected != request.Expected)
                throw new InvalidOperationException("检测到用户或客户端修改节点，停止自动操作");
            if (request.Action == "select")
            {
                if (!Policy.IsAllowed(request.Name) || !frame.Nodes.Any(n => n.Name == request.Name))
                    throw new InvalidOperationException("目标不是当前列表中的允许节点");
                var button = SelectionButtons(frame.Controls, frame.Group).Single(c => NativeLabels.Parse(c.Name)?.Name == request.Name);
                Invoke(button, frame.Window, request.Expected);
                var deadline = Stopwatch.StartNew();
                do { Thread.Sleep(150); frame = ServerFrame(); } while (frame.Selected != request.Name && frame.Selected == request.Expected && deadline.ElapsedMilliseconds < 5000);
                if (frame.Selected != request.Name) throw new InvalidOperationException("客户端未完成节点切换或已被手动修改");
            }
            else if (request.Action == "benchmark")
            {
                // Verified on iKuuu 0.17.5: the single floating 49px button is
                // a direct sibling of the pinned, named selection-group header.
                var parent = frame.Controls[frame.Group].Parent;
                var buttons = frame.Controls.Where(c => c.Parent == parent && c.Type == ControlType.Button && c.Name.Length == 0)
                    .Where(c => { var r = c.Element.Current.BoundingRectangle; return r.Width is >= 40 and <= 90 && r.Height is >= 40 and <= 90; }).ToArray();
                if (buttons.Length != 1) throw new InvalidOperationException("无法唯一识别官方测速按钮，停止操作");
                var before = Signature(frame.Nodes); Invoke(buttons[0], frame.Window, request.Expected);
                var clock = Stopwatch.StartNew(); var previous = ""; var stable = 0; var changed = false;
                while (clock.Elapsed < TimeSpan.FromSeconds(16))
                {
                    Thread.Sleep(500); frame = ServerFrame();
                    if (frame.Selected != request.Expected) throw new InvalidOperationException("测速期间节点被手动修改，停止操作");
                    var signature = Signature(frame.Nodes); changed |= signature != before;
                    stable = signature == previous ? stable + 1 : 0; previous = signature;
                    if (changed && stable >= 3 && clock.Elapsed > TimeSpan.FromSeconds(3)) break;
                }
                // Do not use old cached measurements when no new result appeared.
                if (!changed) frame = frame with { Nodes = frame.Nodes.Select(n => n with { Delay = null }).ToArray() };
            }
            else if (request.Action != "snapshot") throw new InvalidOperationException("未知操作");
            reply = new(frame.Selected, frame.Nodes, WindowMinimized: IsIconic(frame.Window));
        }
        catch (Exception ex)
        {
            Storage.Log("官方界面操作错误：" + ex);
            reply = new("", Array.Empty<NativeNode>(), ex is InvalidOperationException ? ex.Message : "客户端控件错误：" + ex.GetType().Name + " " + ex.Message);
        }
        File.WriteAllText(output, JsonSerializer.Serialize(reply));
    }
    private static string Signature(NativeNode[] nodes) => string.Join("\n", nodes.Select(n => n.Name + ":" + n.Delay));
    private static Frame ServerFrame()
    {
        using var process = Process.GetProcesses().FirstOrDefault(p => ClientProcess.IsIKuuu(p.ProcessName))
            ?? throw new InvalidOperationException("iKuuu 未运行");
        var version = process.MainModule?.FileVersionInfo.FileVersion ?? "";
        if (!version.StartsWith("0.17.5", StringComparison.Ordinal)) throw new InvalidOperationException("官方界面适配已验证版本为 0.17.5；此版本请使用 Controller 模式或导出诊断");
        var handle = process.MainWindowHandle;
        if (handle == IntPtr.Zero)
        {
            EnumWindows((h, _) => { GetWindowThreadProcessId(h, out var pid); if (pid == process.Id && WindowTitle(h) == "iKuuuVPN") { handle = h; return false; } return true; }, IntPtr.Zero);
        }
        if (handle == IntPtr.Zero) throw new InvalidOperationException("请打开 iKuuu 客户端窗口");
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var controls = Read(handle);
            var group = PinnedGroup(controls);
            if (group >= 0)
            {
                var selected = controls.FirstOrDefault(c => c.Parent == group && c.Type == ControlType.Text)?.Name.Trim();
                var nodes = SelectionButtons(controls, group).Select(c => NativeLabels.Parse(c.Name)).OfType<NativeNode>().DistinctBy(n => n.Name).ToArray();
                if (!string.IsNullOrEmpty(selected) && nodes.Length > 0) return new(handle, controls, group, selected, nodes);
                Invoke(controls[group], handle); Thread.Sleep(400); continue;
            }
            throw new InvalidOperationException("请在 iKuuu 客户端打开服务器页面，再执行恢复");
        }
        throw new InvalidOperationException("未读到节点列表，请展开“选择节点”组后重试");
    }
    private static List<Control> Read(IntPtr handle)
    {
        var result = new List<Control>(); var queue = new Queue<(AutomationElement Node, int Parent, int Depth)>();
        queue.Enqueue((AutomationElement.FromHandle(handle), -1, 0));
        while (queue.Count > 0 && result.Count < 1500)
        {
            var (node, parent, depth) = queue.Dequeue(); var current = node.Current; var index = result.Count;
            result.Add(new(node, current.Name ?? "", current.ControlType, parent));
            if (depth >= 32) continue;
            var child = TreeWalker.ControlViewWalker.GetFirstChild(node);
            for (var i = 0; child != null && i < 200; i++) { queue.Enqueue((child, index, depth + 1)); child = TreeWalker.ControlViewWalker.GetNextSibling(child); }
        }
        return result;
    }
    private static int PinnedGroup(List<Control> controls)
    {
        var headers = controls.Select((c, i) => (c, i)).Where(x => x.c.Type == ControlType.Button && x.c.Name.Trim() == "🔰 选择节点")
            .Where(x => controls.Any(c => c.Parent == x.c.Parent && c.Type == ControlType.Button && c.Name.Length == 0 &&
                c.Element.Current.BoundingRectangle.Width is >= 40 and <= 90 && c.Element.Current.BoundingRectangle.Height is >= 40 and <= 90)).ToArray();
        if (headers.Length > 1) throw new InvalidOperationException("无法唯一识别固定选择节点标题");
        return headers.Length == 1 ? headers[0].i : -1;
    }
    private static Control[] SelectionButtons(List<Control> controls, int pinned)
    {
        var headers = controls.Select((c, i) => (c, i)).Where(x => x.c.Type == ControlType.Button && x.c.Name.Trim() == "🔰 选择节点" && x.c.Parent != controls[pinned].Parent)
            .Where(x => controls.Any(c => c.Parent == x.i && c.Type == ControlType.Text)).Select(x => x.c).ToArray();
        if (headers.Length == 0) return Array.Empty<Control>();
        if (headers.Length != 1 || headers[0].Parent < 0) throw new InvalidOperationException("无法唯一识别选择节点分组");
        var headerContainer = headers[0].Parent;
        var siblings = controls.Select((c, i) => (c, i)).Where(x => x.c.Parent == controls[headerContainer].Parent && x.i > headerContainer).ToArray();
        if (siblings.Length == 0) return Array.Empty<Control>();
        var nodeContainer = siblings[0].i;
        return controls.Where(c => c.Parent == nodeContainer && c.Type == ControlType.Button && NativeLabels.Parse(c.Name) != null).ToArray();
    }
    private static void Invoke(Control control, IntPtr window, string expected = "")
    {
        // Flutter's accessibility bounds can omit the current scroll offset.
        // Invoke the identified semantic control; never synthesize coordinate clicks.
        var fresh = Read(window);
        var header = PinnedGroup(fresh);
        if (header < 0) throw new InvalidOperationException("节点界面已变化，停止恢复");
        if (expected.Length > 0)
        {
            if (fresh.FirstOrDefault(c => c.Parent == header && c.Type == ControlType.Text)?.Name.Trim() != expected)
                throw new InvalidOperationException("操作前节点已变化，停止操作");
        }
        var node = NativeLabels.Parse(control.Name);
        Control target;
        if (node != null)
            target = SelectionButtons(fresh, header).Single(c => NativeLabels.Parse(c.Name)?.Name == node.Name);
        else if (control.Name.Trim() == "🔰 选择节点") target = fresh[header];
        else if (control.Name.Length == 0)
            target = fresh.Where(c => c.Parent == fresh[header].Parent && c.Type == ControlType.Button && c.Name.Length == 0)
                .Single(c => c.Element.Current.BoundingRectangle.Width is >= 40 and <= 90 && c.Element.Current.BoundingRectangle.Height is >= 40 and <= 90);
        else throw new InvalidOperationException("无法识别目标操作");
        if (!target.Element.TryGetCurrentPattern(InvokePattern.Pattern, out var invoke))
            throw new InvalidOperationException("目标控件已变化或不支持原生操作，停止恢复");
        ((InvokePattern)invoke).Invoke();
    }
    private static string WindowTitle(IntPtr window) { var text = new System.Text.StringBuilder(128); GetWindowText(window, text, text.Capacity); return text.ToString(); }
    private delegate bool WindowCallback(IntPtr window, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetPhysicalCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
