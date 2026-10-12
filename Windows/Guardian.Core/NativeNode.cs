using System.Text.RegularExpressions;
namespace Guardian.Core;

public sealed record NativeNode(string Name, int? Delay);

public static class NativeLabels
{
    private static readonly Regex Suffix = new(@"^(?<name>.+?)\s+(?:(?<delay>-?\d+)\s*ms|超时|timeout|测试中|测速中|测量中|--\s*ms)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
    public static NativeNode? Parse(string label)
    {
        var normalized = Regex.Replace(label, @"\s+", " ").Trim();
        var match = Suffix.Match(normalized);
        if (!match.Success) return null;
        var name = match.Groups["name"].Value.Trim();
        if (!Policy.IsAllowed(name) || name is "不使用节点" or "直连" or "自动选择" || name.StartsWith("🔰") || name.StartsWith("🛑")) return null;
        int? delay = int.TryParse(match.Groups["delay"].Value, out var parsed) && parsed > 0 ? parsed : null;
        return new(name, delay);
    }
}
