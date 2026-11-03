import Foundation

/// Hardware behind a tester, taken from the advertised name. All speak the same protocol,
/// the tables below only decide what the app offers. The device still has the last word and may reject a write.
enum DeviceKind: Equatable {
    case core2, tracker, generic

    enum Feature: CaseIterable {
        /// Home WiFi upload of the log to the server.
        case wifiUpload
        /// Signal tones played by the tester itself.
        case deviceTones
        /// Several screens on the device display, switchable from the app.
        case screens
        /// GNSS receiver in standby between uplinks.
        case gnssSleep
    }

    private static let prefixes: [(String, DeviceKind)] = [("FieldTester-", .core2), ("FieldTracker-", .tracker)]

    /// What a kind lacks. Unknown devices get everything, a rejected write shows up as an error.
    private static let missing: [DeviceKind: Set<Feature>] = [
        .tracker: [.wifiUpload, .deviceTones, .screens, .gnssSleep],
    ]

    private static let configIDs: [Feature: Set<ConfigID>] = [
        .wifiUpload: [.uploadOnBoot, .wifiName, .wifiPassword, .server, .uploadToken],
        .deviceTones: [.signalTones],
        .gnssSleep: [.gnssStandby],
    ]

    /// Archive rows from before device tags came from the Core2, the only tester back then.
    static let legacyOwner = DeviceKind.core2

    init(name: String?) {
        self = Self.prefixes.first { name?.hasPrefix($0.0) == true }?.1 ?? .generic
    }

    func supports(_ feature: Feature) -> Bool { !(Self.missing[self]?.contains(feature) ?? false) }

    func supports(_ id: ConfigID) -> Bool {
        !Self.configIDs.contains { feature, ids in ids.contains(id) && !supports(feature) }
    }

    var title: String {
        switch self {
        case .core2: "M5Stack Core2"
        case .tracker: "Heltec Wireless Tracker"
        case .generic: "Tester"
        }
    }

    var shortTitle: String {
        switch self {
        case .core2: "Core2"
        case .tracker: "Tracker"
        case .generic: "Tester"
        }
    }

    var symbol: String {
        switch self {
        case .core2: "rectangle.portrait.fill"
        case .tracker: "location.square.fill"
        case .generic: "antenna.radiowaves.left.and.right"
        }
    }

    /// Where the device keeps its log, for messages.
    var logStorage: String { self == .tracker ? "Log-Speicher" : "SD-Karte" }
}

/// A tester the user picked once. The name can be empty until the first connection.
struct KnownDevice: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// From the tester's config, maps rows of the server's coverage log to it. Nil until the first config read.
    var devEUI: String?

    var kind: DeviceKind { DeviceKind(name: name) }
    var title: String { name.isEmpty ? "Tester" : name }

    /// "Core2 A1B2" for "FieldTester-A1B2", short enough for buttons and spoken signals.
    static func shortTitle(_ name: String) -> String {
        let kind = DeviceKind(name: name)
        guard kind != .generic, let suffix = name.split(separator: "-").last, !suffix.isEmpty else { return name }
        return "\(kind.shortTitle) \(suffix)"
    }
}

enum DevEUI {
    /// Upper-case hex without separators, so "70-b3-d5…" and "70B3D5…" match.
    static func normalized(_ text: String) -> String {
        text.uppercased().filter { !"-: ".contains($0) }
    }
}

/// A tester in range. Without RSSI iOS holds the link itself, so it doesn't advertise.
struct NearbyDevice: Identifiable, Equatable {
    var id: UUID
    var name: String
    var rssi: Int?
    var seen: Date

    var kind: DeviceKind { DeviceKind(name: name) }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
