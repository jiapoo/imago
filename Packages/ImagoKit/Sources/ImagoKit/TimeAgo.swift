import Foundation

extension Date {
    /// How long ago, the way people say it, to follow "Backed up" or "Last backup", in the app's language:
    /// - under a minute: "just now"
    /// - under an hour: "5 minutes ago"
    /// - under a day: "3 hours ago"
    /// - the day before: "yesterday"
    /// - within a week: "4 days ago"
    /// - longer: "Nov 2", with the year once it's another year ("Nov 2, 2025")
    /// "just now" and "yesterday" come from the app's string catalog (Bundle.main); the rest from
    /// the system's relative-date formatter, which speaks every language.
    public func ago(now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(self)
        if seconds < 60 { return String(localized: "just now", bundle: .main) }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        relative.dateTimeStyle = .numeric
        relative.calendar = calendar
        if seconds < 3600 { return relative.localizedString(from: DateComponents(minute: -Int(seconds / 60))) }
        if seconds < 86_400 { return relative.localizedString(from: DateComponents(hour: -Int(seconds / 3600))) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: self), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return String(localized: "yesterday", bundle: .main) }
        if days < 7 { return relative.localizedString(from: DateComponents(day: -days)) }
        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}
