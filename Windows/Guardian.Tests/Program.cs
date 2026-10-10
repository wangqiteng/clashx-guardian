using System.Net;
using System.Text;
using Guardian.Core;

int passed = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
foreach (var name in new[] { "台湾 Y01", "台灣", "臺北", "🇹🇼 Y02", "Taipei 1", "Taiwan", "TW-01", "DIRECT", "REJECT" }) Check(!Policy.IsAllowed(name), "exclude " + name);
Check(Policy.IsAllowed("日本 Y01 | IEPL"), "allow Japan");
foreach (var address in new[] { "http://192.168.1.1:9090", "http://example.com", "http://127.0.0.1:9090/api", "http://a:b@127.0.0.1:9090", "http://127.0.0.1:9090?secret=x" })
{
    bool rejected = false; try { Policy.ControllerUri(address); } catch (ArgumentException) { rejected = true; }
    Check(rejected, "reject unsafe controller " + address);
}
Check(Policy.ControllerUri("http://[::1]:9090").IsLoopback, "IPv6 loopback");
Check(Policy.PrimaryStatus(401) && !Policy.PrimaryStatus(403) && !Policy.PrimaryStatus(429) && !Policy.PrimaryStatus(500), "primary HTTP status semantics");
Check(!Policy.PublicStatus(401) && Policy.PublicStatus(204), "public HTTP status semantics");
var failure = new FailureWindow();
Check(!failure.Observe(false, TimeSpan.Zero, 20), "first failure does not switch");
Check(!failure.Observe(false, TimeSpan.FromSeconds(19), 20), "threshold not yet reached");
Check(failure.Observe(false, TimeSpan.FromSeconds(20), 20), "20-second threshold");
Check(!failure.Observe(true, TimeSpan.FromSeconds(21), 20), "recovery resets threshold");
Check(!failure.Observe(false, TimeSpan.FromSeconds(22), 20), "new failure starts fresh");
Check(!failure.Observe(false, TimeSpan.FromHours(1), 20), "sleep gap resets threshold");

var api = new FakeController();
var recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(api.Current == "Japan", api.Current == "Japan", "")), _ => { }, _ => Task.CompletedTask);
var result = await recovery.RunAsync("Proxy", default);
Check(result.Recovered && api.Selections.SequenceEqual(new[] { "Japan" }), "sort latency and verify selected node");
api = new FakeController();
recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(false, false, "")), _ => { }, _ => Task.CompletedTask);
result = await recovery.RunAsync("Proxy", default);
Check(!result.Recovered && api.Current == "Original" && api.Selections.SequenceEqual(new[] { "Japan", "Singapore", "Original" }), "failed candidates roll back original");
api = new FakeController();
recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(true, true, "")), _ => { }, _ => Task.CompletedTask);
result = await recovery.RunAsync("Proxy", default);
Check(result.Recovered && !result.Changed && api.Selections.Count == 0, "self-recovery avoids switching");
api = new FakeController { AfterBenchmark = c => c.Current = "Manual" };
recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(false, false, "")), _ => { }, _ => Task.CompletedTask);
result = await recovery.RunAsync("Proxy", default);
Check(api.Selections.Count == 0 && api.Current == "Manual", "manual change stops recovery");
api = new FakeController();
using (var cancel = new CancellationTokenSource())
{
    recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(false, false, "")), _ => { }, t => { cancel.Cancel(); t.ThrowIfCancellationRequested(); return Task.CompletedTask; });
    try { await recovery.RunAsync("Proxy", cancel.Token); } catch (OperationCanceledException) { }
    Check(api.Current == "Original", "pause/exit cancellation rolls back");
}
api = new FakeController { Current = "台湾" };
recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(false, false, "")), _ => { }, _ => Task.CompletedTask);
await recovery.RunAsync("Proxy", default);
Check(api.Selections.All(Policy.IsAllowed), "rollback never selects excluded region");
api = new FakeController();
var probeCount = 0;
recovery = new Recovery(api, _ =>
{
    probeCount++;
    if (probeCount > 1) api.Current = "Manual";
    return Task.FromResult(new ProbeResult(probeCount > 1, probeCount > 1, ""));
}, _ => { }, _ => Task.CompletedTask);
result = await recovery.RunAsync("Proxy", default);
Check(!result.Recovered && api.Current == "Manual", "manual change during verification is preserved");
api = new FakeController { RejectSingapore = true };
recovery = new Recovery(api, _ => Task.FromResult(new ProbeResult(false, false, "")), _ => { }, _ => Task.CompletedTask);
try { await recovery.RunAsync("Proxy", default); } catch (HttpRequestException) { }
Check(api.Current == "Original", "rejected second selection rolls back first candidate");
api = new FakeController();
probeCount = 0;
recovery = new Recovery(api, _ =>
{
    probeCount++;
    if (probeCount == 3) api.Current = "Japan";
    return Task.FromResult(new ProbeResult(probeCount == 3, probeCount == 3, ""));
}, _ => { }, _ => Task.CompletedTask);
result = await recovery.RunAsync("Proxy", default);
Check(!result.Recovered && api.Current == "Japan", "observed manual return to earlier candidate is not rolled back");

var handler = new MockHandler();
using (var controller = new ClashController("http://127.0.0.1:9090", "test-only-secret", handler))
{
    var snapshot = await controller.SnapshotAsync("Proxy", default);
    Check(snapshot.Candidates.SequenceEqual(new[] { "Japan / 01", "Singapore" }), "filter nested groups and excluded nodes");
    var scores = await controller.BenchmarkAsync(snapshot.Candidates, default);
    Check(scores.Count == 2 && scores[0].Name == "Singapore", "controller delay parsing and sorting");
    await controller.SelectAsync("Proxy", "Japan / 01", default);
    Check(handler.SawPut && handler.SawEscapedName && handler.SawAuth, "controller routes, escaping, authentication and switch body");
}
Console.WriteLine($"{passed} checks passed");

sealed class FakeController : IController
{
    public string Current = "Original";
    public List<string> Selections = new();
    public Action<FakeController>? AfterBenchmark;
    public bool RejectSingapore;
    public Task<Snapshot> SnapshotAsync(string group, CancellationToken token) => Task.FromResult(new Snapshot(group, Current, new[] { "Japan", "Singapore", "台湾" }));
    public Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names, CancellationToken token)
    {
        if (names.Any(n => !Policy.IsAllowed(n))) throw new Exception("excluded node reached benchmark");
        AfterBenchmark?.Invoke(this);
        return Task.FromResult<IReadOnlyList<DelayResult>>(new[] { new DelayResult("Singapore", 200), new DelayResult("Japan", 20), new DelayResult("台湾", 1) });
    }
    public Task SelectAsync(string group, string name, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (RejectSingapore && name == "Singapore") throw new HttpRequestException();
        Selections.Add(name); Current = name; return Task.CompletedTask;
    }
}

sealed class MockHandler : HttpMessageHandler
{
    public bool SawPut, SawEscapedName, SawAuth;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        SawAuth |= request.Headers.Authorization?.ToString() == "Bearer test-only-secret";
        var path = request.RequestUri!.AbsolutePath;
        if (path.Contains("Japan%20%2F%2001", StringComparison.OrdinalIgnoreCase)) SawEscapedName = true;
        if (request.Method == HttpMethod.Put)
        {
            SawPut = (await request.Content!.ReadAsStringAsync(cancellationToken)).Contains("Japan / 01");
            return new(HttpStatusCode.NoContent);
        }
        var json = path.EndsWith("/delay") ? (path.Contains("Singapore") ? "{\"delay\":25}" : "{\"delay\":50}") : """
            {"proxies":{"Proxy":{"type":"Selector","now":"Japan / 01","all":["Japan / 01","Singapore","台湾","Auto","DIRECT"]},
            "Japan / 01":{"type":"Shadowsocks"},"Singapore":{"type":"Vmess"},"台湾":{"type":"Shadowsocks"},
            "Auto":{"type":"URLTest","all":["Singapore"]},"DIRECT":{"type":"Direct"}}}
            """;
        return new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    }
}
