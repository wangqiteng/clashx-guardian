using Microsoft.Win32;
using System.Diagnostics;
using System.Net;
using Guardian.Core;

namespace Guardian.Windows;

internal static class ClientProcess
{
    public static bool IsIKuuu(string name) => name.Equals("ikuuu", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("ikuuuvpn", StringComparison.OrdinalIgnoreCase) || name.Equals("ikuuu vpn", StringComparison.OrdinalIgnoreCase);

    public static bool Running()
    {
        var processes = Process.GetProcesses();
        try
        {
            foreach (var p in processes)
                try { if (IsIKuuu(p.ProcessName)) return true; } catch (InvalidOperationException) { }
            return false;
        }
        finally { foreach (var p in processes) p.Dispose(); }
    }
}

internal sealed class NetworkProbe : IDisposable
{
    private HttpClient? client;
    public string Route { get; private set; } = "";

    public void RefreshRoute()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings");
        if (!string.IsNullOrEmpty(key?.GetValue("AutoConfigURL") as string))
            throw new InvalidOperationException("检测到 PAC 自动配置，首版不支持此路径，请使用 iKuuu 系统代理或 TUN 模式");
        var enabled = key?.GetValue("ProxyEnable") is int n && n != 0;
        var server = enabled ? key?.GetValue("ProxyServer") as string ?? "" : "";
        string? proxy = null;
        if (enabled)
        {
            if (server.Contains('='))
            {
                var entries = server.Split(';').Select(v => v.Split('=', 2)).Where(v => v.Length == 2)
                    .ToDictionary(v => v[0].Trim(), v => v[1].Trim(), StringComparer.OrdinalIgnoreCase);
                if (entries.TryGetValue("https", out var https)) proxy = "http://" + https;
                else if (entries.TryGetValue("socks", out var socks)) proxy = "socks5://" + socks;
                else throw new InvalidOperationException("系统代理未配置 HTTPS 或 SOCKS 路径");
            }
            else proxy = server.Contains("://") ? server : "http://" + server;
            if (!Uri.TryCreate(proxy, UriKind.Absolute, out var uri) ||
                uri.Scheme is not ("http" or "socks5") || !IPAddress.TryParse(uri.Host.Trim('[', ']'), out var ip) || !IPAddress.IsLoopback(ip))
                throw new InvalidOperationException("首版只检测本机代理；当前系统代理不是回环地址");
        }
        var route = proxy ?? "系统路由（TUN 或直连，无法仅靠探针区分）";
        if (route == Route && client != null) return;
        client?.Dispose();
        client = new HttpClient(new HttpClientHandler { UseProxy = proxy != null, Proxy = proxy != null ? new WebProxy(proxy) : null,
            AllowAutoRedirect = false, MaxConnectionsPerServer = 4 }) { Timeout = TimeSpan.FromSeconds(6) };
        Route = route;
    }

    public async Task<ProbeResult> RunAsync(CancellationToken token)
    {
        if (client == null) throw new InvalidOperationException("检测路径尚未初始化");
        var primary = GetAsync("https://chatgpt.com/backend-api/codex", token);
        var google = GetAsync("https://www.gstatic.com/generate_204", token);
        var cloudflare = GetAsync("https://www.cloudflare.com/cdn-cgi/trace", token);
        await Task.WhenAll(primary, google, cloudflare);
        token.ThrowIfCancellationRequested();
        return new(Policy.PrimaryStatus(primary.Result), Policy.PublicStatus(google.Result) || Policy.PublicStatus(cloudflare.Result),
            $"OpenAI HTTP {primary.Result}；外网 HTTP {google.Result}/{cloudflare.Result}（0 表示连接失败）");
    }

    private async Task<int> GetAsync(string url, CancellationToken token)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            using var response = await client!.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            return (int)response.StatusCode;
        }
        catch (Exception ex) when (!token.IsCancellationRequested && ex is HttpRequestException or TaskCanceledException) { return 0; }
    }

    public void Dispose() => client?.Dispose();
}
