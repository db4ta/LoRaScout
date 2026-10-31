import Foundation

/// A calendar day in local time. All date math runs on plain days, so daylight saving plays no part in it.
struct DayKey: Hashable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private init(_ date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// From `2026-10-25`.
    init?(text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    static func < (a: DayKey, b: DayKey) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var shortText: String { String(format: "%02d.%02d.%04d", day, month, year) }

    func adding(days: Int) -> DayKey { DayKey(Self.calendar.date(byAdding: .day, value: days, to: date) ?? date) }
    func adding(months: Int) -> DayKey {
        DayKey(Self.calendar.date(byAdding: .month, value: months, to: date) ?? date)
    }

    var firstOfMonth: DayKey { DayKey(year: year, month: month, day: 1) }
    var lastOfMonth: DayKey { firstOfMonth.adding(months: 1).adding(days: -1) }
}

enum PeriodKind: String, CaseIterable, Identifiable {
    case day, month, year, all

    var id: Self { self }

    var title: String {
        switch self {
        case .day: "Tag"
        case .month: "Monat"
        case .year: "Jahr"
        case .all: "Alles"
        }
    }
}

struct Period: Equatable, Hashable {
    var kind: PeriodKind
    var anchor: DayKey

    static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
                             "September", "Oktober", "November", "Dezember"]

    var first: DayKey? {
        switch kind {
        case .day: anchor
        case .month: anchor.firstOfMonth
        case .year: DayKey(year: anchor.year, month: 1, day: 1)
        case .all: nil
        }
    }

    var last: DayKey? {
        switch kind {
        case .day: anchor
        case .month: anchor.lastOfMonth
        case .year: DayKey(year: anchor.year, month: 12, day: 31)
        case .all: nil
        }
    }

    func contains(_ day: DayKey) -> Bool {
        guard let first, let last else { return true }
        return first <= day && day <= last
    }

    func moved(by step: Int) -> Period {
        var next = self
        switch kind {
        case .day: next.anchor = anchor.adding(days: step)
        case .month: next.anchor = anchor.firstOfMonth.adding(months: step)
        case .year: next.anchor = DayKey(year: anchor.year + step, month: 1, day: 1)
        case .all: break
        }
        return next
    }

    var title: String {
        switch kind {
        case .day: anchor.shortText
        case .month: "\(Self.monthNames[anchor.month - 1]) \(anchor.year)"
        case .year: String(anchor.year)
        case .all: "Alle Daten"
        }
    }

    /// For file names.
    var slug: String {
        switch kind {
        case .day: anchor.text
        case .month: String(format: "%04d-%02d", anchor.year, anchor.month)
        case .year: String(anchor.year)
        case .all: "Alles"
        }
    }
}
