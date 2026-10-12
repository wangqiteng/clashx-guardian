using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace Guardian.Core;

public sealed class ClashController : IController, IDisposable
{
    private readonly HttpClient http;

    public ClashController(string address, string secret, HttpMessageHandler? handler = null)
    {
        http = new HttpClient(handler ?? new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        { BaseAddress = Policy.ControllerUri(address), Timeout = TimeSpan.FromSeconds(5), MaxResponseContentBufferSize = 2 * 1024 * 1024 };
        if (!string.IsNullOrEmpty(secret)) http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", secret);
    }

    public async Task<Dictionary<string, ProxyNode>> ReadAsync(CancellationToken token)
    {
        using var response = await http.GetAsync("proxies", token);
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
        var result = new Dictionary<string, ProxyNode>(StringComparer.Ordinal);
        foreach (var p in json.RootElement.GetProperty("proxies").EnumerateObject())
        {
            var n = p.Value;
            result.Add(p.Name, new ProxyNode(p.Name, n.GetProperty("type").GetString() ?? "",
                n.TryGetProperty("now", out var now) ? now.GetString() : null,
                n.TryGetProperty("all", out var all) ? all.EnumerateArray().Select(v => v.GetString()!).ToArray() : null));
        }
        return result;
    }

    public async Task<Snapshot> SnapshotAsync(string group, CancellationToken token)
    {
        var nodes = await ReadAsync(token);
        if (!nodes.TryGetValue(group, out var selected) || selected.Type != "Selector" || selected.All == null || selected.Now == null)
            throw new InvalidOperationException("策略组不存在或不是手动选择组，请重新配置");
        // 只选择本组直接成员中的实际节点，不改动嵌套策略组或特殊路由。
        var candidates = selected.All.Where(n => Policy.IsAllowed(n) && nodes.TryGetValue(n, out var node) &&
            node.All == null && node.Type is not ("Direct" or "Reject" or "Pass" or "Compatible")).Distinct().ToArray();
        return new Snapshot(group, selected.Now, candidates);
    }

    public async Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names, CancellationToken token)
    {
        using var gate = new SemaphoreSlim(16);
        var tasks = names.Where(Policy.IsAllowed).Distinct().Select(async name =>
        {
            await gate.WaitAsync(token);
            try
            {
                var path = $"proxies/{Uri.EscapeDataString(name)}/delay?timeout=2500&url={Uri.EscapeDataString("https://www.gstatic.com/generate_204")}";
                using var response = await http.GetAsync(path, token);
                response.EnsureSuccessStatusCode();
                using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
                var delay = json.RootElement.GetProperty("delay").GetInt32();
                return delay > 0 ? new DelayResult(name, delay) : null;
            }
            catch (Exception ex) when (!token.IsCancellationRequested && ex is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
            { return null; }
            finally { gate.Release(); }
        });
        return (await Task.WhenAll(tasks)).OfType<DelayResult>().OrderBy(n => n.Milliseconds).ThenBy(n => n.Name, StringComparer.Ordinal).ToArray();
    }

    public async Task SelectAsync(string group, string name, CancellationToken token)
    {
        if (!Policy.IsAllowed(name)) throw new InvalidOperationException("禁止切换到排除节点");
        using var response = await http.PutAsJsonAsync($"proxies/{Uri.EscapeDataString(group)}", new { name }, token);
        response.EnsureSuccessStatusCode();
    }

    public void Dispose() => http.Dispose();
}
