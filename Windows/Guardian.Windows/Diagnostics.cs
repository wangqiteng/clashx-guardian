using System.Diagnostics;
using System.Text.Json;
using System.Windows.Automation;

namespace Guardian.Windows;

internal static class Diagnostics
{
    // UIA 是同步跨进程调用，放入独立短命进程，避免异常客户端卡住托盘和退出。
    public static void Write()
    {
        Directory.CreateDirectory(Storage.DirectoryPath);
        var clients = new List<object>();
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                try
                {
                    if (!ClientProcess.IsIKuuu(p.ProcessName)) continue;
                    string version = "unknown";
                    try { version = p.MainModule?.FileVersionInfo.FileVersion ?? "unknown"; } catch { }
                    var controls = new List<object>();
                    if (p.MainWindowHandle != IntPtr.Zero)
                    {
                        var root = AutomationElement.FromHandle(p.MainWindowHandle);
                        var queue = new Queue<(AutomationElement Node, int Depth)>();
                        queue.Enqueue((root, 0));
                        while (queue.Count > 0 && controls.Count < 500)
                        {
                            var (node, depth) = queue.Dequeue();
                            var current = node.Current;
                            // 不导出账户、订阅和节点名称；只保留可安全识别的导航/测速标签。
                            var name = current.Name ?? "";
                            var safe = new[] { "服务器", "节点", "测速", "延迟测速", "开始测速", "Servers", "Speed test", "Latency test", "首页", "Home" };
                            controls.Add(new { depth, type = current.ControlType.ProgrammaticName,
                                name = safe.Contains(name, StringComparer.OrdinalIgnoreCase) ? name : "[redacted]",
                                nameLength = name.Length, patterns = node.GetSupportedPatterns().Select(x => x.ProgrammaticName).ToArray() });
                            if (depth >= 32) continue;
                            var child = TreeWalker.ControlViewWalker.GetFirstChild(node);
                            for (int i = 0; child != null && i < 100 && queue.Count < 500; i++)
                            {
                                queue.Enqueue((child, depth + 1));
                                child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                            }
                        }
                    }
                    clients.Add(new { process = p.ProcessName, version, visibleWindow = p.MainWindowHandle != IntPtr.Zero, controls });
                }
                catch (Exception ex) { clients.Add(new { errorType = ex.GetType().Name }); }
            }
        }
        File.WriteAllText(Path.Combine(Storage.DirectoryPath, "compatibility.json"),
            JsonSerializer.Serialize(new { guardianVersion = "0.1.4", os = Environment.OSVersion.VersionString,
                architecture = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString(), clients }, new JsonSerializerOptions { WriteIndented = true }));
    }
}
