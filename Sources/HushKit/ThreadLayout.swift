// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One run of messages from the same sender, shown together with a single time under the last one.
public struct ThreadRun: Identifiable, Equatable, Sendable {
    public var lines: [Line]
    public var id: Int64 { lines[0].id }
    public var sender: String { lines[0].sender }
    public var outgoing: Bool { lines[0].outgoing }
    /// When the run ended; this is the time shown under it.
    public var time: Date { lines[lines.count - 1].date }
}

public enum ThreadItem: Identifiable, Equatable, Sendable {
    case day(Date)
    case run(ThreadRun)

    public var id: String {
        switch self {
        case .day(let d): return "day-\(Int(d.timeIntervalSince1970))"
        case .run(let r): return "run-\(r.id)"
        }
    }
}

public enum ThreadLayout {
    /// A pause longer than this starts a new run, and so a new time, even from the same sender.
    public static let runGap: TimeInterval = 5 * 60

    /// Day dividers and runs, oldest first. A run ends when the day changes, the sender changes, or the pause exceeds `runGap`.
    public static func build(_ lines: [Line], calendar: Calendar = .current) -> [ThreadItem] {
        var items: [ThreadItem] = []
        var current: [Line] = []
        var lastDay: Date?
        func flush() { if !current.isEmpty { items.append(.run(ThreadRun(lines: current))); current = [] } }
        for line in lines {
            let day = calendar.startOfDay(for: line.date)
            if day != lastDay { flush(); items.append(.day(day)); lastDay = day }
            if let prev = current.last,
               prev.outgoing != line.outgoing || prev.sender != line.sender || line.date.timeIntervalSince(prev.date) > runGap { flush() }
            current.append(line)
        }
        flush()
        return items
    }

    /// Sender names are only worth showing when more than one other person has written in the thread.
    public static func showsSenders(_ lines: [Line]) -> Bool {
        Set(lines.lazy.filter { !$0.outgoing }.map(\.sender)).count > 1
    }

    /// Today, Yesterday, the weekday for the rest of the past week, then the date; the year only when it is not this one.
    public static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: today).day ?? 0
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar
        if days > 0 && days < 7 { f.setLocalizedDateFormatFromTemplate("EEEE") }
        else if calendar.component(.year, from: day) == calendar.component(.year, from: now) { f.setLocalizedDateFormatFromTemplate("dMMM") }
        else { f.setLocalizedDateFormatFromTemplate("dMMMyyyy") }
        return f.string(from: day)
    }
}
