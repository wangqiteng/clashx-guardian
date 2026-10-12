namespace Guardian.Core;

public sealed record RecentEvent(DateTimeOffset Timestamp, string Message);

public sealed class RecentEvents(IEnumerable<RecentEvent>? saved = null)
{
    private readonly List<RecentEvent> items = (saved ?? Array.Empty<RecentEvent>())
        .Where(e => e != null && !string.IsNullOrWhiteSpace(e.Message))
        .OrderByDescending(e => e.Timestamp).Take(3)
        .Select(e => e with { Message = Normalize(e.Message) }).ToList();
    public IReadOnlyList<RecentEvent> NewestFirst => items.ToArray();
    public bool Record(string message, DateTimeOffset timestamp)
    {
        message = Normalize(message);
        if (message.Length == 0 || items.FirstOrDefault()?.Message == message) return false;
        items.Insert(0, new(timestamp, message));
        if (items.Count > 3) items.RemoveRange(3, items.Count - 3);
        return true;
    }
    public static string RelativeTime(DateTimeOffset timestamp, DateTimeOffset now)
    {
        var elapsed = now - timestamp;
        if (elapsed.TotalMinutes < 1) return "刚刚";
        if (elapsed.TotalHours < 1) return (int)elapsed.TotalMinutes + " 分钟前";
        if (elapsed.TotalDays < 1) return (int)elapsed.TotalHours + " 小时前";
        return (int)elapsed.TotalDays + " 天前";
    }
    private static string Normalize(string message) => message.Replace('\r', ' ').Replace('\n', ' ').Trim();
}
