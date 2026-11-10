import Foundation

extension Date {
    /// How long ago, the way people say it, to follow "Backed up" or "Last backup":
    /// - under a minute: "just now"
    /// - under an hour: "5 minutes ago"
    /// - under a day: "3 hours ago"
    /// - the day before: "yesterday"
    /// - within a week: "4 days ago"
    /// - longer: "Nov 2", with the year once it's another year ("Nov 2, 2025")
    public func ago(now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(self)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return Self.count(Int(seconds / 60), "minute") + " ago" }
        if seconds < 86_400 { return Self.count(Int(seconds / 3600), "hour") + " ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    private static func count(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s")"
    }
}
