import Foundation

struct IngestSummary: Equatable {
    var added = 0
    var upgraded = 0
    var skippedNoTime = 0
    var changedDays = Set<DayKey>()
}

struct PeriodEntry: Identifiable, Equatable {
    var period: Period
    var count: Int
    var received: Int
    var lost: Int

    var id: Period { period }
    var lossRate: Double? { received + lost > 0 ? Double(lost) / Double(received + lost) : nil }
}

enum ArchiveError: LocalizedError, Equatable {
    case unreadable
    case write
    case logDownload

    var errorDescription: String? {
        switch self {
        case .unreadable: "Das Archiv konnte nicht gelesen werden. Es wird nichts geschrieben und nichts gelöscht."
        case .write: "Das Archiv konnte nicht geschrieben werden. Es wurde nichts gelöscht."
        case .logDownload: "Das Tester-Log konnte nicht geladen werden. Es wurde nichts gelöscht."
        }
    }
}

/// History of all uplinks by local day. Pure data, ArchiveFiles keeps it on disk.
struct Archive: Equatable {
    var days: [DayKey: [MergedRow]] = [:]
    /// Keys of deleted rows, so the log still on the iPhone doesn't bring them back.
    var deleted = Set<String>()

    static func key(_ row: MergedRow) -> String { row.time + "|" + row.status }

    private static func rank(_ received: Received) -> Int {
        switch received {
        case .unknown: 0
        case .no: 1
        case .yes: 2
        }
    }

    /// The better result wins, equal results keep the row on file. Fields only ever get filled, never emptied.
    static func combine(_ old: MergedRow, _ new: MergedRow) -> MergedRow {
        var best = rank(new.received) > rank(old.received) ? new : old
        let other = rank(new.received) > rank(old.received) ? old : new
        let fields: [WritableKeyPath<MergedRow, String>] = [\.lat, \.lng, \.alt, \.gw, \.rssi, \.snr, \.sf]
        for field in fields where best[keyPath: field].isEmpty { best[keyPath: field] = other[keyPath: field] }
        best.id = 0
        return best
    }

    /// Rows without a usable time are counted, not stored. Safe to repeat with the same rows.
    mutating func ingest(_ rows: [MergedRow], timeZone: TimeZone) -> IngestSummary {
        var summary = IngestSummary()
        var known: [String: (day: DayKey, index: Int)] = [:]
        for (day, list) in days {
            for (index, row) in list.enumerated() { known[Self.key(row)] = (day, index) }
        }
        for var row in rows where row.status != "TEST" {
            guard let time = CoverageMerge.parseTime(row.time) else {
                summary.skippedNoTime += 1
                continue
            }
            let key = Self.key(row)
            if deleted.contains(key) { continue }
            row.id = 0
            if let place = known[key] {
                let old = days[place.day]?[place.index] ?? row
                let merged = Self.combine(old, row)
                if merged != old {
                    days[place.day]?[place.index] = merged
                    summary.upgraded += 1
                    summary.changedDays.insert(place.day)
                }
            } else {
                let day = DayKey(date: Date(timeIntervalSince1970: TimeInterval(time)), timeZone: timeZone)
                days[day, default: []].append(row)
                known[key] = (day, (days[day]?.count ?? 1) - 1)
                summary.added += 1
                summary.changedDays.insert(day)
            }
        }
        for day in summary.changedDays {
            days[day]?.sort { (CoverageMerge.parseTime($0.time) ?? 0) < (CoverageMerge.parseTime($1.time) ?? 0) }
        }
        return summary
    }

    func result(for period: Period) -> MergeResult {
        let rows = days.keys.filter(period.contains).sorted().flatMap { days[$0] ?? [] }
        return MergeResult(rows: rows.enumerated().map { index, row in
            var copy = row
            copy.id = index
            return copy
        }, lastServerTime: "", rowsAfterCoverage: 0)
    }

    private func entry(_ period: Period) -> PeriodEntry {
        var entry = PeriodEntry(period: period, count: 0, received: 0, lost: 0)
        for day in days.keys where period.contains(day) {
            for row in days[day] ?? [] {
                entry.count += 1
                if row.received == .yes { entry.received += 1 }
                if row.received == .no { entry.lost += 1 }
            }
        }
        return entry
    }

    /// One entry per day, month or year that has data, oldest first.
    func entries(_ kind: PeriodKind) -> [PeriodEntry] {
        var seen = Set<DayKey>()
        var periods: [Period] = []
        for day in days.keys.sorted() where days[day]?.isEmpty == false {
            let period = Period(kind: kind, anchor: day)
            if seen.insert(period.first ?? day).inserted { periods.append(period) }
        }
        return periods.map(entry)
    }

    /// Points for the loss chart: the next finer steps of the period, nil for a single day.
    func trend(for period: Period) -> [PeriodEntry] {
        switch period.kind {
        case .day: return []
        case .month: return entries(.day).filter { period.contains($0.period.anchor) }
        case .year: return entries(.month).filter { period.contains($0.period.anchor) }
        case .all:
            let years = entries(.year), months = entries(.month)
            if years.count >= 3 { return years }
            return months.count >= 2 ? months : entries(.day)
        }
    }

    var latestDay: DayKey? { days.keys.filter { days[$0]?.isEmpty == false }.max() }
    var rowCount: Int { days.values.reduce(0) { $0 + $1.count } }
}

extension Archive {
    /// Rows to store. Without a merge everything is unknown so far, the device's own values stay.
    /// Rows newer than the coverage log can't have been matched yet, "lost" would be a guess.
    static func rows(result: MergeResult?, device: Data) -> [MergedRow] {
        guard let result else { return deviceRows(device) }
        let last = CoverageMerge.parseTime(result.lastServerTime)
        return result.rows.map { row in
            guard row.received == .no, let last, let time = CoverageMerge.parseTime(row.time),
                  time > last + CoverageMerge.windowAfter else { return row }
            var copy = row
            copy.received = .unknown
            return copy
        }
    }

    private static func deviceRows(_ device: Data) -> [MergedRow] {
        var rows = CoverageMerge.parseCSV(device)
        guard !rows.isEmpty else { return [] }
        let columns = Dictionary(rows.removeFirst().enumerated().map { ($1, $0) }) { _, later in later }
        guard columns["Time_UTC"] != nil, columns["Status"] != nil else { return [] }
        return rows.enumerated().map { index, row in
            func value(_ name: String) -> String {
                guard let column = columns[name], column < row.count else { return "" }
                return row[column]
            }
            return MergedRow(id: index, time: value("Time_UTC"), lat: value("Lat"), lng: value("Lng"), alt: value("Alt"),
                             status: value("Status"), received: .unknown, rssi: value("RSSI"), snr: value("SNR"))
        }
    }
}

/// Dokumente/Archiv/JJJJ/MM/JJJJ-MM-TT.csv, columns like merged.csv.
struct ArchiveFiles {
    var root: URL
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }

    private var deletedURL: URL { root.appending(path: ".geloescht.txt") }

    func url(_ day: DayKey) -> URL {
        root.appending(path: String(format: "%04d", day.year)).appending(path: String(format: "%02d", day.month))
            .appending(path: day.text + ".csv")
    }

    func load() throws -> Archive {
        var archive = Archive()
        let files = FileManager.default
        guard files.fileExists(atPath: root.path()) else { return archive }
        guard let walker = files.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw ArchiveError.unreadable
        }
        for case let url as URL in walker where url.pathExtension == "csv" {
            guard let day = DayKey(text: url.deletingPathExtension().lastPathComponent) else { continue }
            let rows = Self.parse(try Data(contentsOf: url))
            archive.days[day, default: []] += rows
        }
        if let text = try? String(contentsOf: deletedURL, encoding: .utf8) {
            archive.deleted = Set(text.split(separator: "\n").map(String.init))
        }
        return archive
    }

    static func parse(_ data: Data) -> [MergedRow] {
        var rows = CoverageMerge.parseCSV(data)
        guard !rows.isEmpty else { return [] }
        let columns = Dictionary(rows.removeFirst().enumerated().map { ($1, $0) }) { _, later in later }
        return rows.compactMap { row in
            func value(_ name: String) -> String {
                guard let column = columns[name], column < row.count else { return "" }
                return row[column]
            }
            guard CoverageMerge.parseTime(value("Time_UTC")) != nil else { return nil }
            return MergedRow(id: 0, time: value("Time_UTC"), lat: value("Lat"), lng: value("Lng"), alt: value("Alt"),
                             status: value("Status"), received: Received(rawValue: value("Received")) ?? .unknown,
                             gw: value("GW"), rssi: value("RSSI"), snr: value("SNR"), sf: value("SF"))
        }
    }

    func save(_ archive: Archive, days: Set<DayKey>) throws {
        let files = FileManager.default
        for day in days {
            let file = url(day)
            if let rows = archive.days[day], !rows.isEmpty {
                try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try write(MergeResult(rows: rows, lastServerTime: "", rowsAfterCoverage: 0).csv, file)
            } else {
                if files.fileExists(atPath: file.path()) { try files.removeItem(at: file) }
                removeIfEmpty(file.deletingLastPathComponent())
                removeIfEmpty(file.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
    }

    func saveDeleted(_ keys: Set<String>) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write(Data(keys.sorted().joined(separator: "\n").utf8), deletedURL)
    }

    private func removeIfEmpty(_ folder: URL) {
        let content = (try? FileManager.default.contentsOfDirectory(atPath: folder.path())) ?? ["?"]
        if content.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }
}

/// Archive plus files. Memory only changes once the files are written, so a failed write gets repeated next time.
struct ArchiveBook {
    private(set) var archive: Archive
    let files: ArchiveFiles

    init(files: ArchiveFiles) throws {
        self.files = files
        archive = try files.load()
    }

    #if DEBUG
    init(files: ArchiveFiles, archive: Archive) {
        self.files = files
        self.archive = archive
    }
    #endif

    @discardableResult
    mutating func commit(_ rows: [MergedRow], timeZone: TimeZone) throws -> IngestSummary {
        var next = archive
        let summary = next.ingest(rows, timeZone: timeZone)
        do {
            try files.save(next, days: summary.changedDays)
        } catch {
            throw ArchiveError.write
        }
        archive = next
        return summary
    }

    mutating func remove(_ period: Period) throws {
        var next = archive
        let days = Set(next.days.keys.filter(period.contains))
        for day in days {
            next.deleted.formUnion((next.days[day] ?? []).map { Archive.key($0) })
            next.days[day] = nil
        }
        do {
            try files.saveDeleted(next.deleted)
            try files.save(next, days: days)
        } catch {
            throw ArchiveError.write
        }
        archive = next
    }

    mutating func reload() throws { archive = try files.load() }
}
