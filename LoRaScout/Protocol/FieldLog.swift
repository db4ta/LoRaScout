import Foundation

enum LogEvent: Equatable {
    case appended
    case ignored
    case gap
    case finished
    case malformed
}

/// Rebuilds fieldlog.csv from `[u32 offset][bytes]` packets. `data.count` is the resume offset.
struct LogAssembler {
    var data = Data()

    mutating func accept(_ packet: Data) -> LogEvent {
        let b = [UInt8](packet)
        guard b.count >= 4 else { return .malformed }
        let offset = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        let payload = b[4...]
        if offset > data.count { return .gap }
        if payload.isEmpty { return offset == data.count ? .finished : .gap }
        let overlap = data.count - offset
        guard overlap < payload.count else { return .ignored }
        data.append(contentsOf: payload.dropFirst(overlap))
        return .appended
    }
}

enum LogStatus: Equatable {
    case sent, ok, noAnswer, txFail, test
    case other(String)

    init(_ text: String) {
        switch text {
        case "SENT": self = .sent
        case "OK": self = .ok
        case "NO_ANSWER": self = .noAnswer
        case "TX_FAIL": self = .txFail
        case "TEST": self = .test
        default: self = .other(text)
        }
    }
}

struct FieldLogRow: Identifiable, Equatable {
    var id: Int
    var time: String
    var lat: Double?
    var lng: Double?
    var alt: Double?
    var rssi: Int?
    var snr: Int?
    var status: LogStatus

    var hasPosition: Bool { lat != nil && lng != nil }
}

enum FieldLog {
    /// Cuts off a line left open by an interrupted download.
    static func completeLines(_ data: Data) -> Data {
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data[...end]
    }

    /// Lines without a closing newline are ignored: they belong to an interrupted download.
    /// A swapped card can repeat the header in the middle of the file.
    static func parse(_ data: Data) -> [FieldLogRow] {
        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        lines.removeLast()
        var rows: [FieldLogRow] = []
        for (index, line) in lines.enumerated() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7, f[0] != "Time_UTC" else { continue }
            rows.append(FieldLogRow(id: index, time: f[0], lat: Double(f[1]), lng: Double(f[2]), alt: Double(f[3]),
                                    rssi: Int(f[4]), snr: Int(f[5]), status: LogStatus(f[6])))
        }
        return rows
    }
}
