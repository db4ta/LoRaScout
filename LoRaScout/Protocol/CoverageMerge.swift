import Foundation

enum Received: String {
    case yes, no, unknown
}

struct MergedRow: Identifiable, Equatable {
    var id: Int
    var time: String
    var lat: String
    var lng: String
    var alt: String
    var status: String
    var received: Received
    var gw = ""
    var rssi = ""
    var snr = ""
    var sf = ""
    /// Advertised name of the tester, empty for rows from before device tags.
    var device = ""

    var latitude: Double? { Double(lat) }
    var longitude: Double? { Double(lng) }
}

struct MergeResult: Equatable {
    var rows: [MergedRow]
    /// Last server entry. Newer device rows show up as lost until fresh coverage data is loaded.
    var lastServerTime: String
    var rowsAfterCoverage: Int

    func count(_ received: Received) -> Int { rows.count { $0.received == received } }

    /// The Device column only appears once a row has one, so merged.csv stays like merge_coverage.py.
    var csv: Data {
        let tagged = rows.contains { !$0.device.isEmpty }
        let header = ["Time_UTC", "Lat", "Lng", "Alt", "Status", "Received", "GW", "RSSI", "SNR", "SF"] + (tagged ? ["Device"] : [])
        let lines = [header] + rows.map {
            [$0.time, $0.lat, $0.lng, $0.alt, $0.status, $0.received.rawValue, $0.gw, $0.rssi, $0.snr, $0.sf]
                + (tagged ? [$0.device] : [])
        }
        return Data(lines.map { $0.map { CoverageMerge.quoted($0) }.joined(separator: ",") + "\r\n" }.joined().utf8)
    }
}

struct Distribution: Equatable {
    var value: String
    var count: Int
}

struct CoverageStats: Equatable {
    var received: Int
    var lost: Int
    var unknown: Int
    var lossRate: Double?
    var meanRSSI: Double?
    var meanSNR: Double?
    var gateways: [Distribution]
    var spreadingFactors: [Distribution]

    init(_ result: MergeResult) {
        received = result.count(.yes)
        lost = result.count(.no)
        unknown = result.count(.unknown)
        lossRate = received + lost > 0 ? Double(lost) / Double(received + lost) : nil
        let hits = result.rows.filter { $0.received == .yes }
        meanRSSI = Self.mean(hits.compactMap { Double($0.rssi) })
        meanSNR = Self.mean(hits.compactMap { Double($0.snr) })
        gateways = Self.distribution(hits.map(\.gw))
        spreadingFactors = Self.distribution(hits.map(\.sf))
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func distribution(_ values: [String]) -> [Distribution] {
        Dictionary(grouping: values.filter { !$0.isEmpty }) { $0 }
            .map { Distribution(value: $0.key, count: $0.value.count) }
            .sorted { (number($0.value), $0.value) < (number($1.value), $1.value) }
    }

    private static func number(_ text: String) -> Double {
        Double(text.drop { !$0.isNumber }) ?? .infinity
    }
}

/// One tester's log for the merge. `tag` is its name for the archive, `devEUI` picks its rows in the server log.
struct DeviceLog: Equatable {
    var tag: String
    var data: Data
    var devEUI: String?
}

/// The server's coverage log, sorted by time. The legacy file has no header:
/// `Time_UTC,FCnt,Lat,Lng,Alt,GW,RSSI,SNR,SF`, a tenth column is taken as DevEUI.
/// With a header row, columns are found by name, the device in `Device`, `DevEUI` or `dev_eui`.
struct ServerLog {
    struct Row {
        var time: Int
        var text: String
        var gw: String
        var rssi: String
        var snr: String
        var sf: String
        /// Normalized DevEUI, empty if the server doesn't name the device.
        var device: String
    }

    private(set) var rows: [Row]

    var isEmpty: Bool { rows.isEmpty }
    var hasDevices: Bool { rows.contains { !$0.device.isEmpty } }

    private static let legacyColumns = ["time_utc": 0, "gw": 5, "rssi": 6, "snr": 7, "sf": 8, "device": 9]
    private static let aliases = ["time": "time_utc", "deveui": "device", "dev_eui": "device", "device_eui": "device",
                                  "gateways": "gw", "gwcount": "gw"]

    init(_ data: Data) {
        var lines = CoverageMerge.parseCSV(data)
        var columns = Self.legacyColumns
        if let first = lines.first, let head = first.first, CoverageMerge.parseTime(head) == nil,
           first.contains(where: { ["time_utc", "time"].contains($0.lowercased()) }) {
            columns = [:]
            for (index, name) in first.enumerated() {
                let key = name.trimmingCharacters(in: .whitespaces).lowercased()
                columns[Self.aliases[key] ?? key] = columns[Self.aliases[key] ?? key] ?? index
            }
            lines.removeFirst()
        }
        func value(_ fields: [String], _ name: String) -> String {
            guard let index = columns[name], index < fields.count else { return "" }
            return fields[index]
        }
        let parsed = lines.enumerated().compactMap { index, fields -> (Int, Row)? in
            let text = value(fields, "time_utc")
            guard let time = CoverageMerge.parseTime(text) else { return nil }
            return (index, Row(time: time, text: text, gw: value(fields, "gw"), rssi: value(fields, "rssi"),
                               snr: value(fields, "snr"), sf: value(fields, "sf"),
                               device: DevEUI.normalized(value(fields, "device"))))
        }
        rows = parsed.sorted { ($0.1.time, $0.0) < ($1.1.time, $1.0) }.map(\.1)
    }
}

/// Same behavior as tools/merge_coverage.py in the firmware repo. Keep both in step.
/// Additionally: if the server names the device, a tester only takes rows with its own DevEUI.
enum CoverageMerge {
    private static let windowBefore = 5
    static let windowAfter = 15

    /// nil if the coverage log has no usable rows or the device CSV lacks the Time_UTC or Status column.
    static func merge(device: Data, server: Data, devEUI: String? = nil) -> MergeResult? {
        var used = Set<Int>()
        return merge(device: device, server: ServerLog(server), devEUI: devEUI, used: &used)
    }

    /// `used` holds the server rows already given to a tester, so with several testers none is counted twice.
    /// Rows without device match every tester. A tester without known DevEUI matches all rows, like before,
    /// but only the untagged ones once the server names devices, so rows of two testers never mix.
    /// If the server names devices but none of its rows is this tester's, its rows stay unknown.
    static func merge(device: Data, server: ServerLog, devEUI: String?, used: inout Set<Int>) -> MergeResult? {
        guard let globalLast = server.rows.last else { return nil }
        let own = devEUI.flatMap { DevEUI.normalized($0).nonEmpty }
        let candidates = server.rows.indices.filter { index in
            let device = server.rows[index].device
            return device.isEmpty || device == own
        }
        let first = candidates.first.map { server.rows[$0] }, last = candidates.last.map { server.rows[$0] }

        var deviceRows = parseCSV(device)
        guard !deviceRows.isEmpty else {
            return MergeResult(rows: [], lastServerTime: (last ?? globalLast).text, rowsAfterCoverage: 0)
        }
        let columns = Dictionary(deviceRows.removeFirst().enumerated().map { ($1, $0) }) { _, later in later }
        func value(_ row: [String], _ name: String) -> String {
            guard let index = columns[name], index < row.count else { return "" }
            return row[index]
        }
        if !deviceRows.isEmpty, columns["Time_UTC"] == nil || columns["Status"] == nil { return nil }

        var rows: [MergedRow] = []
        var afterCoverage = 0
        for row in deviceRows where value(row, "Status") != "TEST" {
            let text = value(row, "Time_UTC")
            var merged = MergedRow(id: rows.count, time: text, lat: value(row, "Lat"), lng: value(row, "Lng"),
                                   alt: value(row, "Alt"), status: value(row, "Status"), received: .unknown)
            if let first, let last, let time = parseTime(text), time + windowAfter >= first.time {
                if let index = match(time, server.rows, candidates, used) {
                    used.insert(index)
                    let hit = server.rows[index]
                    merged.received = .yes
                    merged.gw = hit.gw
                    merged.rssi = hit.rssi
                    merged.snr = hit.snr
                    merged.sf = hit.sf
                } else {
                    merged.received = .no
                    if time > last.time + windowAfter { afterCoverage += 1 }
                }
            }
            rows.append(merged)
        }
        return MergeResult(rows: rows, lastServerTime: (last ?? globalLast).text, rowsAfterCoverage: afterCoverage)
    }

    /// True if the data contains at least one coverage row with a valid time.
    static func isCoverage(_ data: Data) -> Bool { !ServerLog(data).isEmpty }

    /// Lowest free candidate row inside the window. Rows are sorted, so the search can start at the window.
    private static func match(_ time: Int, _ server: [ServerLog.Row], _ candidates: [Int], _ used: Set<Int>) -> Int? {
        let start = time - windowBefore, end = time + windowAfter
        var low = 0, high = candidates.count
        while low < high {
            let middle = (low + high) / 2
            if server[candidates[middle]].time < start { low = middle + 1 } else { high = middle }
        }
        var position = low
        while position < candidates.count, server[candidates[position]].time <= end {
            if !used.contains(candidates[position]) { return candidates[position] }
            position += 1
        }
        return nil
    }

    // MARK: Python-compatible CSV and time

    /// csv.reader with the default dialect, blank lines dropped.
    static func parseCSV(_ data: Data) -> [[String]] {
        enum State { case fieldStart, field, quoted, quoteInQuoted }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var state = State.fieldStart
        var lineHasContent = false

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endLine() {
            if lineHasContent {
                endField()
                rows.append(row)
            }
            row = []
            lineHasContent = false
            state = .fieldStart
        }

        var previousCR = false
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            let isCRLFTail = previousCR && scalar == "\n"
            previousCR = scalar == "\r"
            if isCRLFTail, state != .quoted { continue }
            switch state {
            case .quoted:
                if scalar == "\"" { state = .quoteInQuoted } else { field.append(scalar) }
            case .quoteInQuoted where scalar == "\"":
                field.append(scalar)
                state = .quoted
            case .fieldStart where scalar == "\"":
                lineHasContent = true
                state = .quoted
            default:
                if scalar == "\n" || scalar == "\r" {
                    endLine()
                } else if scalar == "," {
                    lineHasContent = true
                    endField()
                    state = .fieldStart
                } else {
                    lineHasContent = true
                    field.append(scalar)
                    state = .field
                }
            }
        }
        endLine()
        return rows
    }

    /// csv.writer quoting, QUOTE_MINIMAL.
    static func quoted(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static let timePattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(1[0-2]|0[1-9]|[1-9])-(3[0-1]|[1-2]\d|0[1-9]|[1-9]| [1-9])\s+(2[0-3]|[0-1]\d|\d):([0-5]\d|\d):(6[0-1]|[0-5]\d|\d)\z"#)

    /// Seconds since 1970, strptime("%Y-%m-%d %H:%M:%S") rules. No time zone: both logs are UTC.
    static func parseTime(_ text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = timePattern?.firstMatch(in: text, range: range) else { return nil }
        let parts = (1...6).compactMap { group in
            Range(match.range(at: group), in: text).flatMap { Int(text[$0].trimmingCharacters(in: .whitespaces)) }
        }
        guard parts.count == 6 else { return nil }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard year >= 1, day <= monthDays[month - 1], parts[5] <= 59 else { return nil }
        // days_from_civil
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146097 + dayOfEra - 719468
        return days * 86400 + parts[3] * 3600 + parts[4] * 60 + parts[5]
    }
}
