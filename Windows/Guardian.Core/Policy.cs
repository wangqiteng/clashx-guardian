using System.Net;
using System.Text.RegularExpressions;

namespace Guardian.Core;

public sealed record Settings
{
    public int CheckSeconds { get; init; } = 5;
    public int FailureSeconds { get; init; } = 20;
    public int SuccessCooldownSeconds { get; init; } = 120;
    public int RetrySeconds { get; init; } = 30;
    public string ControllerUrl { get; init; } = "http://127.0.0.1:9090";
    public string Group { get; init; } = "";
    public bool AllowSwitch { get; init; }

    public void Validate()
    {
        if (CheckSeconds is < 3 or > 300 || FailureSeconds is < 10 or > 600 ||
            SuccessCooldownSeconds is < 30 or > 3600 || RetrySeconds is < 10 or > 600)
            throw new ArgumentException("检测间隔或冷却时间超出安全范围");
        Policy.ControllerUri(ControllerUrl);
        if (AllowSwitch && string.IsNullOrWhiteSpace(Group))
            throw new ArgumentException("请先选择需要切换的策略组");
    }
}

public static class Policy
{
    // 排除标记、地区别名和特殊路由，不能仅依赖中文节点名称。
    private static readonly Regex Excluded = new(
        @"台湾|台灣|台北|臺灣|臺北|Taiwan|Taipei|🇹🇼|\bTW\b|^(DIRECT|REJECT|PASS|COMPATIBLE)$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

    public static bool IsAllowed(string name) => !string.IsNullOrWhiteSpace(name) && !Excluded.IsMatch(name);

    public static Uri ControllerUri(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "http" ||
            !IPAddress.TryParse(uri.Host.Trim('[', ']'), out var ip) || !IPAddress.IsLoopback(ip) ||
            uri.UserInfo.Length != 0 || uri.AbsolutePath != "/" || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            throw new ArgumentException("Controller 只允许 http://127.0.0.1:端口 或 http://[::1]:端口");
        return uri;
    }

    // 未登录的 API 常返回 401/404/405；403/429 不代表 Codex 可用，不能涂绿。
    public static bool PrimaryStatus(int code) => code is >= 200 and < 300 or 401 or 404 or 405;
    public static bool PublicStatus(int code) => code is >= 200 and < 300;
}

public sealed record ProbeResult(bool Primary, bool Public, string Detail)
{
    public bool Healthy => Primary && Public;
}
public sealed record ProxyNode(string Name, string Type, string? Now, string[]? All);
public sealed record Snapshot(string Group, string Selected, IReadOnlyList<string> Candidates);
public sealed record DelayResult(string Name, int Milliseconds);
public sealed record RecoveryResult(bool Recovered, bool Changed, string Message);

public interface IController
{
    Task<Snapshot> SnapshotAsync(string group, CancellationToken token);
    Task<IReadOnlyList<DelayResult>> BenchmarkAsync(IEnumerable<string> names, CancellationToken token);
    Task SelectAsync(string group, string name, CancellationToken token);
}

public sealed class FailureWindow
{
    private TimeSpan? failedAt;
    private TimeSpan? lastSample;
    public void Reset() { failedAt = null; lastSample = null; }

    // 使用单调时钟；休眠或长时间没有样本后重新累计，不把睡眠算成断网。
    public bool Observe(bool healthy, TimeSpan now, int threshold)
    {
        if (lastSample is { } last && now - last > TimeSpan.FromSeconds(45)) failedAt = null;
        lastSample = now;
        if (healthy) { failedAt = null; return false; }
        failedAt ??= now;
        return now - failedAt >= TimeSpan.FromSeconds(threshold);
    }
}
