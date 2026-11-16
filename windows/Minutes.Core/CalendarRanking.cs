namespace Minutes.Core;

public static class CalendarRanking
{
    private static readonly string[] CallHosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com"];
    public static IReadOnlyList<CalendarEvent> Ranked(IEnumerable<CalendarEvent> events, DateTimeOffset now, string? app, bool voice = false)
    {
        var hosts = Hosts(app);
        return events.Where(e => !e.IsAllDay && !e.IsCancelled && !e.DeclinedByMe && e.Title.Trim().Length > 0 && e.Start <= now.AddMinutes(15) && e.End > now)
            .OrderBy(e => voice ? (HasCallLink(e) ? 1 : 0) : hosts.Any(h => e.Text.Contains(h, StringComparison.OrdinalIgnoreCase)) ? 0 : HasCallLink(e) ? 1 : 2)
            .ThenBy(e => Math.Abs((e.Start - now).TotalSeconds)).DistinctBy(e => (e.Title, e.Start, e.End)).ToArray();
    }
    public static bool HasCallLink(CalendarEvent e) => CallHosts.Any(h => e.Text.Contains(h, StringComparison.OrdinalIgnoreCase));
    public static string[] Hosts(string? app) => app?.ToLowerInvariant() switch
    {
        "ms-teams" or "teams" => ["teams.microsoft.com", "teams.live.com"],
        "zoom" => ["zoom.us"],
        "webex" or "ciscocollabhost" => ["webex.com"],
        "chrome" or "msedge" or "firefox" or "brave" or "arc" => ["meet.google.com"],
        _ => []
    };
}
