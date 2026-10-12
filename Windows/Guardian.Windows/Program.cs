using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Guardian.Core;
using Forms = System.Windows.Forms;

namespace Guardian.Windows;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Length == 3 && args[0] == "--native-ui") { NativeUI.Run(args[1], args[2]); return; }
        if (args.Contains("--diagnose")) { Diagnostics.Write(); return; }
        using var mutex = new Mutex(true, @"Local\IKuuuGuardian.Windows", out var created);
        if (!created) { Forms.MessageBox.Show("Guardian 已在运行，请查看右下角托盘（含隐藏图标）。"); return; }
        ApplicationConfiguration.Initialize();
        Forms.Application.ThreadException += (_, e) => { Storage.Log("UI 错误：" + e.Exception.GetType().Name); Forms.MessageBox.Show("操作失败，请查看日志。"); };
        try { using var app = new TrayApp(); Forms.Application.Run(app); }
        catch (Exception ex) { Storage.Log("启动失败：" + ex.GetType().Name); Forms.MessageBox.Show("Guardian 无法启动：" + ex.GetType().Name + "\n请检查 " + Storage.ConfigPath); }
    }
}

internal sealed class TrayApp : Forms.ApplicationContext
{
    private readonly Forms.NotifyIcon tray = new();
    private readonly Forms.Timer timer = new() { Interval = 1000 };
    private readonly Forms.ToolStripMenuItem stateItem = new("启动中…") { Enabled = false };
    private readonly Forms.ToolStripMenuItem startItem = new("开启检测");
    private readonly Forms.ToolStripMenuItem pauseItem = new("暂停检测");
    private readonly Forms.ToolStripMenuItem recoverItem = new("立即测速并恢复");
    private readonly Forms.ToolStripMenuItem[] eventItems = Enumerable.Range(0, 3).Select(_ => new Forms.ToolStripMenuItem { Enabled = false }).ToArray();
    private readonly RecentEvents recentEvents = Storage.LoadRecentEvents();
    private readonly Forms.Form dispatcher = new();
    private readonly NetworkProbe probe = new();
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly FailureWindow failure = new();
    private readonly CancellationTokenSource lifetime = new();
    private Task? diagnosticTask;
    private readonly Dictionary<string, Icon> icons = new();
    private Settings settings;
    private CancellationTokenSource? operation;
    private Task? currentTask;
    private bool enabled = true, busy, exiting;
    private TimeSpan nextCheck, nextRecovery;
    private string route = "", message = "正在启动", detail = "", lastLogged = "", lastProbeLogged = "";

    public TrayApp()
    {
        settings = Storage.Load();
        _ = dispatcher.Handle;
        foreach (var (key, color) in new[] { ("green", Color.FromArgb(83, 162, 125)), ("amber", Color.FromArgb(210, 162, 70)),
            ("red", Color.FromArgb(196, 91, 91)), ("gray", Color.FromArgb(140, 146, 153)) }) icons[key] = Shield(color);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(stateItem);
        menu.Items.Add("查看详细状态", null, (_, _) => ShowStatus());
        menu.Items.Add(new Forms.ToolStripSeparator());
        startItem.Click += (_, _) => { enabled = true; failure.Reset(); nextCheck = TimeSpan.Zero; nextRecovery = TimeSpan.Zero; Update("amber", "检测已开启"); };
        pauseItem.Click += (_, _) => { enabled = false; operation?.Cancel(); failure.Reset(); Update("gray", "已暂停，正在结束当前操作"); };
        recoverItem.Click += (_, _) => BeginCheck(true);
        menu.Items.Add(startItem); menu.Items.Add(pauseItem);
        menu.Items.Add("立即检测", null, (_, _) => BeginCheck(false));
        menu.Items.Add(recoverItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("配置自动切换（可选）", null, async (_, _) => await ConfigureAsync());
        menu.Items.Add("导出 iKuuu 兼容性诊断", null, async (_, _) =>
        {
            if (exiting || diagnosticTask is { IsCompleted: false }) return;
            diagnosticTask = DiagnoseAsync();
            await diagnosticTask;
        });
        menu.Items.Add("打开日志目录", null, (_, _) => OpenFolder());
        menu.Items.Add("使用说明", null, (_, _) => ShowHelp());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("最近事件") { Enabled = false });
        menu.Items.AddRange(eventItems);
        menu.Opening += (_, _) => RenderEvents();
        RenderEvents();
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("停止检测并退出", null, async (_, _) => await QuitAsync());
        tray.ContextMenuStrip = menu;
        tray.Icon = icons["amber"];
        tray.Text = "iKuuu Guardian：启动中";
        tray.DoubleClick += (_, _) => ShowStatus();
        tray.Visible = true;
        timer.Tick += (_, _) => { if (enabled && !busy && clock.Elapsed >= nextCheck) BeginCheck(false); };
        timer.Start();
        Update("amber", "已开启，等待检测");
        Storage.Log("Guardian 0.1.4 启动；不自动启动 iKuuu，不设置开机自启");
        if (!File.Exists(Storage.ConfigPath))
        {
            tray.ShowBalloonTip(7000, "Guardian 已开始检测", "盾牌在右下角托盘，可能位于隐藏图标内。已启用官方界面恢复（0.17.5），双击查看详情。", Forms.ToolTipIcon.Info);
            // 首次使用明确展示能力边界，而不是把检测模式伪装为完整自动保护。
            dispatcher.BeginInvoke((Action)ShowHelp);
        }
    }

    private void Update(string color, string text)
    {
        message = text;
        tray.Icon = icons[color];
        var tooltip = "iKuuu Guardian：" + text;
        tray.Text = tooltip.Length > 63 ? tooltip[..63] : tooltip;
        stateItem.Text = text.Length > 65 ? text[..65] + "…" : text;
        startItem.Enabled = !enabled && !busy;
        pauseItem.Enabled = enabled;
        recoverItem.Enabled = enabled && !busy && (settings.AllowSwitch || settings.AllowUISwitch);
        var eventText = text == "需要处理 · 请查看详细状态" ? "恢复暂停：" + detail : text;
        if (text != "正在检测" && lastLogged != eventText)
        {
            RecordEvent(eventText);
            lastLogged = eventText;
        }
    }

    private void RecordEvent(string text)
    {
        Storage.Log(text);
        if (recentEvents.Record(text, DateTimeOffset.Now)) Storage.SaveRecentEvents(recentEvents);
        RenderEvents();
    }

    private void RenderEvents()
    {
        var events = recentEvents.NewestFirst;
        for (var i = 0; i < eventItems.Length; i++)
        {
            var item = eventItems[i];
            item.Visible = i < events.Count || i == 0;
            if (i >= events.Count) { item.Text = i == 0 ? "暂无事件" : ""; continue; }
            var info = new System.Globalization.StringInfo(events[i].Message);
            var summary = info.LengthInTextElements > 48 ? info.SubstringByTextElements(0, 48) + "…" : events[i].Message;
            item.Text = RecentEvents.RelativeTime(events[i].Timestamp, DateTimeOffset.Now) + " · " + summary;
            item.ToolTipText = events[i].Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") + " · " + events[i].Message;
        }
    }

    private void BeginCheck(bool manualRecovery)
    {
        if (busy || exiting || !enabled) return;
        busy = true;
        operation = new CancellationTokenSource();
        recoverItem.Enabled = false;
        if (manualRecovery) Update("amber", "正在测速和验证");
        currentTask = CheckAsync(manualRecovery, operation.Token);
    }

    private async Task CheckAsync(bool manualRecovery, CancellationToken token)
    {
        try
        {
            var running = await Task.Run(ClientProcess.Running, token);
            if (!running)
            {
                failure.Reset();
                detail = "未识别到 iKuuu 官方进程（ikuuu / ikuuuvpn）。请自行打开客户端；若已打开，请导出诊断并提供版本号。";
                Update("gray", "等待 iKuuu 启动");
                return;
            }
            probe.RefreshRoute();
            if (route != probe.Route) { route = probe.Route; failure.Reset(); nextRecovery = TimeSpan.Zero; }
            var result = await probe.RunAsync(token);
            detail = result.Detail + "\n检测路径：" + route;
            if (detail != lastProbeLogged) { Storage.Log(detail); lastProbeLogged = detail; }
            var due = failure.Observe(result.Healthy, clock.Elapsed, settings.FailureSeconds);
            if (manualRecovery || (due && clock.Elapsed >= nextRecovery))
            {
                if (!(settings.AllowSwitch || settings.AllowUISwitch))
                {
                    Update(result.Healthy ? "green" : "red", result.Healthy ? "探针可达 · 仅检测" : "线路异常 · 仅检测，未启用自动切换");
                    return;
                }
                if (!manualRecovery)
                {
                    await Task.Delay(3000, token);
                    if ((await probe.RunAsync(token)).Healthy) { failure.Reset(); Update("green", "线路自行恢复"); return; }
                }
                Update("amber", "正在测速并验证候选节点");
                using var api = settings.AllowSwitch ? new ClashController(settings.ControllerUrl, Storage.ReadSecret()) : null;
                IController adapter = api is not null ? api : new NativeController();
                var guard = new GuardedController(adapter, () =>
                {
                    if (!ClientProcess.Running()) throw new InvalidOperationException("iKuuu 已退出，停止切换");
                    probe.RefreshRoute();
                    if (probe.Route != route) throw new InvalidOperationException("系统代理路径已变化，停止切换");
                });
                var recovery = new Recovery(guard, probe.RunAsync, RecordEvent);
                var recovered = await recovery.RunAsync(settings.Group, token);
                nextRecovery = clock.Elapsed + TimeSpan.FromSeconds(recovered.Recovered ? settings.SuccessCooldownSeconds : settings.RetrySeconds);
                if (recovered.Recovered) failure.Reset();
                Update(recovered.Recovered ? "green" : "red", recovered.Message);
                return;
            }
            Update(result.Healthy ? "green" : due ? "red" : "amber", result.Healthy
                ? ((settings.AllowSwitch || settings.AllowUISwitch) ? "探针可达 · 自动切换已启用" : "探针可达 · 仅检测")
                : due ? "线路仍异常 · 等待恢复重试冷却" : "线路异常，正在确认（尚未达到切换条件）");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception ex)
        {
            failure.Reset();
            nextRecovery = clock.Elapsed + TimeSpan.FromSeconds(settings.RetrySeconds);
            detail = ex is InvalidOperationException ? ex.Message : "错误类型：" + ex.GetType().Name + "。请检查客户端与 Controller 配置。";
            Storage.Log("检测/恢复错误：" + ex.GetType().Name + " " + ex.Message);
            Update("amber", "需要处理 · 请查看详细状态");
        }
        finally
        {
            busy = false;
            nextCheck = clock.Elapsed + TimeSpan.FromSeconds(settings.CheckSeconds);
            operation?.Dispose(); operation = null;
            if (!enabled && !exiting) Update("gray", "已暂停检测");
            else if (!exiting) { startItem.Enabled = !enabled; recoverItem.Enabled = enabled && (settings.AllowSwitch || settings.AllowUISwitch); }
        }
    }

    private async Task StopOperationAsync()
    {
        enabled = false;
        operation?.Cancel();
        if (currentTask != null) await currentTask;
    }

    private async Task ConfigureAsync()
    {
        if (exiting) return;
        var wasEnabled = enabled;
        await StopOperationAsync();
        using var dialog = new SettingsDialog(settings);
        if (dialog.ShowDialog() == Forms.DialogResult.OK) settings = dialog.Result;
        enabled = wasEnabled; failure.Reset(); nextCheck = TimeSpan.Zero; nextRecovery = TimeSpan.Zero;
        Update(enabled ? "amber" : "gray", enabled ? "已开启，等待检测" : "已暂停检测");
    }

    private void ShowStatus() => Forms.MessageBox.Show(
        $"{message}\n\n{detail}\n\n连续失败阈值：{settings.FailureSeconds} 秒（另有确认、测速和复检耗时）\n" +
        $"自动切换：{((settings.AllowSwitch || settings.AllowUISwitch) ? settings.AllowSwitch ? "已启用 Controller，组：" + settings.Group : "已启用官方界面适配（0.17.5）" : "未启用")}\n\n" +
        "最近事件：\n" + string.Join("\n", recentEvents.NewestFirst.Select(e => e.Timestamp.ToLocalTime().ToString("HH:mm:ss") + " · " + e.Message)) + "\n\n" +
        "探针只验证未登录 HTTP 线路，不保证 Codex 登录、流式请求和账户权限正常。\n日志：" + Storage.LogPath,
        "iKuuu Guardian 状态");

    private static void ShowHelp() => Forms.MessageBox.Show(
        "Windows 修复版 0.1.4\n\n1. 自行启动并连接 iKuuu，再启动 Guardian。\n2. 托盘绿色：探针可达；黄色：确认中/需要配置；红色：持续异常；灰色：暂停/等待客户端。\n" +
        "3. 默认使用 iKuuu 0.17.5 官方界面进行测速与切换；其他版本会提示不兼容。可在配置窗口关闭，或启用 Controller 模式。\n" +
        "4. 恢复通过原生控件操作，不移动鼠标；请让客户端停留在服务器页面，可最小化且不会自动展开。切换后验证 OpenAI API 和公共网络，失败尝试回退原节点。\n" +
        "5. 托盘退出会结束检测和恢复任务；不安装后台服务，不设置开机自启。\n\n" +
        "探针验证未登录 OpenAI API 的连通性，不能保证 ChatGPT 登录或 Codex 会话可用。", "使用说明");

    private async Task DiagnoseAsync()
    {
        if (Forms.MessageBox.Show("请先打开 iKuuu 节点列表。将读取 iKuuu 公开控件的类型、有限导航标签及客户端版本，不执行点击。\n诊断保存到本机，不自动上传。继续吗？", "兼容性诊断", Forms.MessageBoxButtons.OKCancel) != Forms.DialogResult.OK) return;
        using var process = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--diagnose") { UseShellExecute = false });
        if (process == null) return;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
            if (process.ExitCode != 0) throw new InvalidOperationException();
            if (exiting) return;
            OpenFolder();
            Forms.MessageBox.Show("诊断已保存为 compatibility.json。请先查看内容再分享；不会自动上传。");
        }
        catch
        {
            if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(); }
            if (!exiting) Forms.MessageBox.Show("读取控件超时或失败，已结束诊断子进程。请提供 iKuuu 版本号和节点页面截图。");
        }
    }

    private static void OpenFolder()
    {
        Directory.CreateDirectory(Storage.DirectoryPath);
        Process.Start(new ProcessStartInfo(Storage.DirectoryPath) { UseShellExecute = true });
    }

    private async Task QuitAsync()
    {
        if (exiting) return;
        exiting = true; timer.Stop();
        lifetime.Cancel();
        Update("gray", "正在停止并完成回退…");
        await StopOperationAsync();
        if (diagnosticTask != null) await diagnosticTask;
        RecordEvent("Guardian 已停止并退出");
        tray.Visible = false;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            lifetime.Dispose(); timer.Dispose(); tray.Dispose(); probe.Dispose(); dispatcher.Dispose();
            foreach (var icon in icons.Values) icon.Dispose();
        }
        base.Dispose(disposing);
    }

    // 直接绘制对称盾牌，不使用 Wi-Fi 符号，与系统网络图标区分。
    private static Icon Shield(Color color)
    {
        using var bmp = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = new GraphicsPath();
        path.AddPolygon(new PointF[] { new(16, 2), new(28, 7), new(26, 20), new(22, 26), new(16, 30), new(10, 26), new(6, 20), new(4, 7) });
        using var brush = new SolidBrush(color); g.FillPath(brush, path);
        using var pen = new Pen(Color.FromArgb(225, 240, 245, 248), 1.5f); g.DrawPath(pen, path);
        var handle = bmp.GetHicon();
        try { using var borrowed = Icon.FromHandle(handle); return (Icon)borrowed.Clone(); }
        finally { DestroyIcon(handle); }
    }
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);
}

internal sealed class GuardedController(IController inner, Action guard) : IController
{
    public Task<Snapshot> SnapshotAsync(string group, CancellationToken token) { guard(); return inner.SnapshotAsync(group, token); }
    public Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names, CancellationToken token) { guard(); return inner.BenchmarkAsync(names, token); }
    public Task SelectAsync(string group, string name, CancellationToken token) { guard(); return inner.SelectAsync(group, name, token); }
}
