import Foundation

// Pure encoders and decoders for the protocol in docs/ble-protocol.md (firmware repo). No CoreBluetooth here.

private func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
private func i16(_ b: [UInt8], _ o: Int) -> Int16 { Int16(bitPattern: u16(b, o)) }
private func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}
private func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }
private func i8(_ b: [UInt8], _ o: Int) -> Int8 { Int8(bitPattern: b[o]) }

private func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
}

struct StatusFlags: OptionSet, Equatable {
    let rawValue: UInt8
    static let gnssData = StatusFlags(rawValue: 1 << 0)
    static let fix = StatusFlags(rawValue: 1 << 1)
    static let sdReady = StatusFlags(rawValue: 1 << 2)
    static let sendPending = StatusFlags(rawValue: 1 << 3)
    static let loraBusy = StatusFlags(rawValue: 1 << 4)
    static let awaitingNetwork = StatusFlags(rawValue: 1 << 5)
    static let noNetworkAnswer = StatusFlags(rawValue: 1 << 6)
    static let gnssStandby = StatusFlags(rawValue: 1 << 7)
}

enum JoinState: UInt8 { case idle, joining, joined, failed }
enum TxState: UInt8 { case idle, busy, sent, acked, lost }

struct DeviceStatus: Equatable {
    static let size = 39

    var flags: StatusFlags
    var join: JoinState
    var tx: TxState
    var screen: UInt8
    var profile: UInt8
    var rssi: Int?
    var snr: Int
    var dataRate: UInt8
    var gwCount: Int?
    var gwRssi: Int
    var gwSnr: Int
    var feedbackAge: Int?
    var sent: UInt32
    var lost: Int?
    var per: UInt8
    var sats: UInt8
    var hdop: Double
    var lat: Double?
    var lng: Double?
    var alt: Int?

    var spreadingFactor: Int? { dataRate <= 5 ? 12 - Int(dataRate) : nil }

    static func parse(_ data: Data) -> DeviceStatus? {
        let b = [UInt8](data)
        guard b.count >= size, b[0] == 1 else { return nil }
        let flags = StatusFlags(rawValue: b[1])
        let fix = flags.contains(.fix)
        let rssi = i16(b, 6), gwCount = i16(b, 10), age = u16(b, 15), lost = i32(b, 21), alt = i16(b, 37)
        return DeviceStatus(
            flags: flags,
            join: JoinState(rawValue: b[2]) ?? .idle,
            tx: TxState(rawValue: b[3]) ?? .idle,
            screen: b[4],
            profile: b[5],
            rssi: rssi == 0 ? nil : Int(rssi),
            snr: Int(i8(b, 8)),
            dataRate: b[9],
            gwCount: gwCount < 0 ? nil : Int(gwCount),
            gwRssi: Int(i16(b, 12)),
            gwSnr: Int(i8(b, 14)),
            feedbackAge: age == 0xFFFF ? nil : Int(age),
            sent: u32(b, 17),
            lost: lost < 0 ? nil : Int(lost),
            per: b[25],
            sats: b[26],
            hdop: Double(u16(b, 27)) / 10,
            lat: fix ? Double(i32(b, 29)) / 1e7 : nil,
            lng: fix ? Double(i32(b, 33)) / 1e7 : nil,
            alt: alt == Int16.min ? nil : Int(alt))
    }
}

enum ControlCommand: Equatable {
    case sendNow
    case screen(UInt8)
    case restart
    case logStart(offset: UInt32)
    case logStop
    case logClear

    static let sendNowOp: UInt8 = 0x01
    static let logStartOp: UInt8 = 0x10
    static let logClearOp: UInt8 = 0x12

    var bytes: Data {
        switch self {
        case .sendNow: Data([Self.sendNowOp])
        case .screen(let n): Data([0x02, n])
        case .restart: Data([0x03])
        case .logStart(let offset): Data([Self.logStartOp] + littleEndian(offset))
        case .logStop: Data([0x11])
        case .logClear: Data([Self.logClearOp])
        }
    }
}

enum ReplyStatus: UInt8 { case ok, invalid, busy, noCard, savedNeedsRestart }

struct Reply: Equatable {
    var op: UInt8
    var status: ReplyStatus
    var logSize: UInt32?

    var configID: ConfigID? { op & 0x80 != 0 ? ConfigID(rawValue: op & 0x7F) : nil }

    static func parse(_ data: Data) -> Reply? {
        let b = [UInt8](data)
        guard b.count >= 2, let status = ReplyStatus(rawValue: b[1]) else { return nil }
        return Reply(op: b[0], status: status, logSize: b.count >= 6 ? u32(b, 2) : nil)
    }
}

enum ConfigID: UInt8 {
    case devEUI = 1, joinEUI, appKey, interval, profile, uploadOnBoot, wifiName, wifiPassword, server, uploadToken, displaySave,
         displayAlways, displayOffSeconds, brightness, cpuMHz, gnssStandby, signalTones
}

struct DeviceConfig: Equatable {
    var devEUI = ""
    var joinEUI = ""
    var appKeySet = false
    var interval: UInt16 = 0
    var profile: UInt8 = 0
    var uploadOnBoot = false
    var wifiName = ""
    var wifiPasswordSet = false
    var server = ""
    var uploadTokenSet = false
    var displaySave = true
    var displayAlways = false
    var displayOffSeconds: UInt8 = 30
    var brightness: UInt8 = 50
    var cpuMHz: UInt8 = 80
    var gnssStandby = false
    var signalTones = false

    func text(_ id: ConfigID) -> String {
        switch id {
        case .devEUI: devEUI
        case .joinEUI: joinEUI
        default: ""
        }
    }

    func isSet(_ id: ConfigID) -> Bool { id == .appKey && appKeySet }

    /// Parses the `[id][len][value]` list. Unknown ids are skipped, a cut-off entry fails the whole read.
    static func parse(_ data: Data) -> DeviceConfig? {
        let b = [UInt8](data)
        var config = DeviceConfig()
        var i = 0
        while i < b.count {
            guard i + 2 <= b.count else { return nil }
            let rawID = b[i], len = Int(b[i + 1])
            let start = i + 2
            guard start + len <= b.count else { return nil }
            let value = Array(b[start..<(start + len)])
            i = start + len
            guard let id = ConfigID(rawValue: rawID) else { continue }
            let text = String(decoding: value, as: UTF8.self)
            let flag = value.first.map { $0 != 0 } ?? false
            switch id {
            case .devEUI: config.devEUI = text
            case .joinEUI: config.joinEUI = text
            case .appKey: config.appKeySet = flag
            case .interval:
                guard len == 2 else { return nil }
                config.interval = u16(value, 0)
            case .profile: config.profile = value.first ?? 0
            case .uploadOnBoot: config.uploadOnBoot = flag
            case .wifiName: config.wifiName = text
            case .wifiPassword: config.wifiPasswordSet = flag
            case .server: config.server = text
            case .uploadToken: config.uploadTokenSet = flag
            case .displaySave: config.displaySave = flag
            case .displayAlways: config.displayAlways = flag
            case .displayOffSeconds: config.displayOffSeconds = value.first ?? 30
            case .brightness: config.brightness = value.first ?? 50
            case .cpuMHz: config.cpuMHz = value.first ?? 80
            case .gnssStandby: config.gnssStandby = flag
            case .signalTones: config.signalTones = flag
            }
        }
        return config
    }
}

struct ConfigWrite: Equatable {
    static let maxValueSize = 99

    var id: ConfigID
    var value: Data

    var bytes: Data { Data([id.rawValue]) + value }

    static func text(_ id: ConfigID, _ text: String) -> ConfigWrite { ConfigWrite(id: id, value: Data(text.utf8)) }
    static func interval(_ seconds: UInt16) -> ConfigWrite {
        ConfigWrite(id: .interval, value: Data([UInt8(seconds & 0xFF), UInt8(seconds >> 8)]))
    }
    static func profile(_ profile: UInt8) -> ConfigWrite { ConfigWrite(id: .profile, value: Data([profile])) }
    static func byte(_ id: ConfigID, _ value: UInt8) -> ConfigWrite { ConfigWrite(id: id, value: Data([value])) }
    static func flag(_ id: ConfigID, _ on: Bool) -> ConfigWrite { byte(id, on ? 1 : 0) }
    static func uploadOnBoot(_ on: Bool) -> ConfigWrite { ConfigWrite(id: .uploadOnBoot, value: Data([on ? 1 : 0])) }

    /// Upload "on" needs WiFi name, server and token stored first, so it always goes last.
    static func ordered(_ writes: [ConfigWrite]) -> [ConfigWrite] {
        writes.filter { $0.id != .uploadOnBoot } + writes.filter { $0.id == .uploadOnBoot }
    }
}
