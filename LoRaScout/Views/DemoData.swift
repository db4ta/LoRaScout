#if DEBUG
import Foundation

/// Sample data for screenshots. Start with `-demo`, plus `-demoTab n`, `-demoPairing`, `-demoEmpty`, `-demoDevices`
/// or `-demoSingle` (one tester instead of two in parallel).
enum DemoData {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let isActive = arguments.contains("-demo")
    static let showResult = arguments.contains("-demoToast")
    static let showEvents = arguments.contains("-demoEvents")
    static let scrollToBottom = arguments.contains("-demoBottom")
    static let showList = arguments.contains("-demoList")
    static let writeImage = arguments.contains("-demoJPG")
    static let showDevices = arguments.contains("-demoDevices")
    static let single = arguments.contains("-demoSingle")
    static var scrollTarget: String? { arguments.firstIndex(of: "-demoScroll").map { arguments[$0 + 1] } }

    /// Fourteen months of made-up drives in a public park, `-demoPeriod day|month|year`.
    static func archive() -> Archive {
        guard !arguments.contains("-demoEmpty") else { return Archive() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var archive = Archive()
        var rows: [MergedRow] = []
        for dayIndex in stride(from: 430, to: 0, by: -7) {
            let start = Date.now.addingTimeInterval(-Double(dayIndex) * 86400)
            for i in 0..<(12 + dayIndex % 7) {
                let received: Received = (i + dayIndex) % (4 + dayIndex % 5) == 0 ? .no : (i == 3 ? .unknown : .yes)
                var row = MergedRow(id: 0, time: formatter.string(from: start.addingTimeInterval(Double(i) * 120)),
                                    lat: String(52.505 + Double(i + dayIndex % 9) * 0.0008),
                                    lng: String(13.350 + 0.004 * sin(Double(i + dayIndex) / 4)), alt: "35",
                                    status: "SENT", received: received)
                // Every other drive both testers ran in parallel, the tracker a little further east.
                if dayIndex % 2 == 0, i % 2 == 1 {
                    row.device = devices[1].name
                    row.lng = String(13.353 + 0.004 * sin(Double(i + dayIndex) / 4))
                } else {
                    row.device = devices[0].name
                }
                if received == .yes {
                    row.gw = String(1 + i % 3)
                    row.rssi = String(-70 - i * 3)
                    row.snr = String(9 - i)
                    row.sf = String(7 + i % 3)
                }
                rows.append(row)
            }
        }
        _ = archive.ingest(rows, timeZone: .current)
        return archive
    }

    static func period(latest: DayKey?) -> Period? {
        guard let index = arguments.firstIndex(of: "-demoPeriod"), let latest,
              let kind = PeriodKind(rawValue: arguments[index + 1]) else { return nil }
        return Period(kind: kind, anchor: latest)
    }

    static var tab: Int {
        arguments.firstIndex(of: "-demoTab").flatMap { Int(arguments[$0 + 1]) } ?? 0
    }

    static var link: TesterSession.Link {
        if arguments.contains("-demoPairing") { return .pairing }
        if arguments.contains("-demoBondLost") { return .bondLost }
        return arguments.contains("-demoEmpty") ? .searching : .ready
    }

    struct Tester {
        var device: KnownDevice
        var status: DeviceStatus
        var config: DeviceConfig
        var csv: String
        var events: [(TimeInterval, EventKind)]
        var uplinkAge: TimeInterval
    }

    static let devices = [
        KnownDevice(id: UUID(uuidString: "6F1C2A3B-0000-4000-8000-00000000A1B2") ?? UUID(), name: "FieldTester-A1B2",
                    devEUI: "70B3D57ED0000001"),
        KnownDevice(id: UUID(uuidString: "6F1C2A3B-0000-4000-8000-00000000C3D4") ?? UUID(), name: "FieldTracker-C3D4",
                    devEUI: "70B3D57ED0000002"),
        KnownDevice(id: UUID(uuidString: "6F1C2A3B-0000-4000-8000-00000000E5F6") ?? UUID(), name: "FieldTester-E5F6"),
    ]

    /// Two testers in parallel, or the Core2 alone with `-demoSingle`.
    static var testers: [Tester] { single ? [core2] : [core2, tracker] }

    static var nearby: [UUID: NearbyDevice] {
        let other = single ? devices[1] : devices[2]
        return [other.id: NearbyDevice(id: other.id, name: other.name, rssi: -64, seen: .distantFuture)]
    }

    static let core2 = Tester(
        device: devices[0],
        status: DeviceStatus(
            flags: [.gnssData, .fix, .sdReady], join: .joined, tx: .sent, screen: 0, profile: 2,
            rssi: -71, snr: 8, dataRate: 5, gwCount: 2, gwRssi: -72, gwSnr: 7, feedbackAge: 34,
            sent: 128, lost: 6, per: 4, sats: 11, hdop: 1.2, lat: 52.5145, lng: 13.3501, alt: 35),
        config: DeviceConfig(
            devEUI: "70B3D57ED0000001", joinEUI: "0000000000000000", appKeySet: true, interval: 120, profile: 2,
            uploadOnBoot: true, wifiName: "Heimnetz", wifiPasswordSet: true, server: "http://192.168.10.20:8099/fieldlog",
            uploadTokenSet: true),
        csv: deviceCSV(lngOffset: 0, second: 0),
        events: [
            (34, .networkAnswer(gateways: 2, rssi: -72, snr: 7)),
            (36, .sendStarted(.app)),
            (154, .autoUplink),
            (280, .noAnswer),
            (295, .sendStarted(.device)),
            (420, .fixGained),
            (600, .joined),
        ],
        uplinkAge: 34)

    static let tracker = Tester(
        device: devices[1],
        status: DeviceStatus(
            flags: [.gnssData, .fix, .sdReady], join: .joined, tx: .sent, screen: 0, profile: 1,
            rssi: -97, snr: -3, dataRate: 3, gwCount: 1, gwRssi: -104, gwSnr: -4, feedbackAge: 81,
            sent: 57, lost: nil, per: 0, sats: 8, hdop: 1.6, lat: 52.5141, lng: 13.3532, alt: 36),
        config: DeviceConfig(devEUI: "70B3D57ED0000002", joinEUI: "0000000000000000", appKeySet: true, interval: 180,
                             profile: 1),
        csv: deviceCSV(lngOffset: 0.003, second: 30),
        events: [
            (81, .networkAnswer(gateways: 1, rssi: -104, snr: -4)),
            (84, .sendStarted(.app)),
            (230, .autoUplink),
            (500, .fixGained),
            (700, .joined),
        ],
        uplinkAge: 81)

    private static func time(_ minute: Int, _ second: Int = 0) -> String { String(format: "2026-10-30 12:%02d:%02d", minute, second) }

    private static func deviceCSV(lngOffset: Double, second: Int) -> String {
        (0..<40).reduce("Time_UTC,Lat,Lng,Alt,RSSI,SNR,Status\n") { text, i in
            let lat = 52.505 + Double(i) * 0.0006, lng = 13.350 + lngOffset + 0.004 * sin(Double(i) / 4)
            return text + "\(time(i, second)),\(lat),\(lng),510.0,,,\(i % 6 == 0 ? "OK" : "SENT")\n"
        }
    }

    /// Server rows name the device in a tenth column, like the new server may. The tracker loses more.
    static let coverageCSV: String = (0..<40).reduce("") { text, i in
        var rows = text
        if i % 5 != 2 {
            rows += "\(time(i)),\(i),52.5,13.3,35,\(1 + i % 3),\(-70 - i),\(9 - i / 5),\(7 + i % 2),70B3D57ED0000001\n"
        }
        if i % 3 != 1 {
            rows += "\(time(i, 31)),\(i),52.5,13.3,35,1,\(-90 - i),\(-2 - i / 8),9,70B3D57ED0000002\n"
        }
        return rows
    }
}
#endif
