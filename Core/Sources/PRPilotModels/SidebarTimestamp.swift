import Foundation

/// Newest moment anything happened on this item.
///
/// Three things count: the item arrived, the agent finished a turn, or the PR author acted.
/// The author's timestamp lives in `PRStatus` rather than on the item, so the caller passes
/// it in. `addedAt` is the floor, so the result is never optional.
public func lastActivityAt(_ item: WorkItem, authorUpdatedAt: Date?) -> Date {
    let candidates = [item.addedAt, item.claudeLastCompletedAt, authorUpdatedAt].compactMap { $0 }
    return candidates.max() ?? item.addedAt
}

/// Sidebar date stamp: absolute, and short enough for a narrow row.
///
/// Today and yesterday keep the clock time, because that is the part the user reads. Older
/// dates in this year add the day and month. Another year drops the clock for the year,
/// because at that distance the hour tells the user nothing.
///
/// Month names are fixed English rather than locale-formatted, to match the rest of the
/// sidebar, and so the output is stable to test.
public func sidebarDateLabel(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)

    if calendar.isDate(date, inSameDayAs: now) { return "Today \(clock)" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday \(clock)"
    }

    let day = parts.day ?? 1
    let month = monthAbbreviation(parts.month ?? 1)
    guard parts.year == calendar.component(.year, from: now) else {
        return "\(day) \(month) \(parts.year ?? 0)"
    }
    return "\(day) \(month) \(clock)"
}

/// Full date for the row's tooltip, so the short label never hides the real moment.
public func sidebarDateTooltip(for date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    let weekday = weekdayAbbreviation(parts.weekday ?? 1)
    let month = monthAbbreviation(parts.month ?? 1)
    return "\(weekday) \(parts.day ?? 1) \(month) \(parts.year ?? 0) at \(clock)"
}

/// One-line summary of the current agent run for the detail pane. Nil when the item has
/// never run an agent, so the caller can leave the line out entirely.
public func agentRunLabel(
    startedAt: Date?,
    lastCompletedAt: Date?,
    now: Date = Date(),
    calendar: Calendar = .current
) -> String? {
    var parts: [String] = []
    if let startedAt {
        parts.append("started \(sidebarDateLabel(for: startedAt, now: now, calendar: calendar))")
    }
    if let lastCompletedAt {
        parts.append("last reply \(sidebarDateLabel(for: lastCompletedAt, now: now, calendar: calendar))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

private func monthAbbreviation(_ month: Int) -> String {
    let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    guard (1...12).contains(month) else { return "" }
    return names[month - 1]
}

private func weekdayAbbreviation(_ weekday: Int) -> String {
    let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    guard (1...7).contains(weekday) else { return "" }
    return names[weekday - 1]
}
