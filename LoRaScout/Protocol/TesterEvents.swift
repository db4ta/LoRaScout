import Foundation

enum SendSource: Equatable { case app, device }

enum EventKind: Equatable {
    case sendStarted(SendSource)
    case autoUplink
    case networkAnswer(gateways: Int?, rssi: Int, snr: Int)
    case lateAnswer(gateways: Int?, rssi: Int, snr: Int)
    case noAnswer
    case sendFailed
    case joined, joinLost, joinFailed
    case fixGained, fixLost
    case gnssLost, gnssBack
    case sdMissing, sdReady
    case profileChanged(UInt8, byApp: Bool)
    case deviceRestarted
}

enum EventSeverity { case success, failure, warning, info }

extension EventKind {
    /// The events on which the firmware itself plays its success or failure signal.
    var isDeviceSignal: Bool {
        switch self {
        case .networkAnswer, .noAnswer, .sendFailed: true
        default: false
        }
    }

    var severity: EventSeverity {
        switch self {
        case .networkAnswer, .joined, .fixGained, .gnssBack, .sdReady: .success
        case .noAnswer, .sendFailed, .joinFailed: .failure
        case .joinLost, .fixLost, .gnssLost, .sdMissing, .deviceRestarted: .warning
        default: .info
        }
    }

    var title: String {
        switch self {
        case .sendStarted(.app): "SEND NOW aus der App gestartet"
        case .sendStarted(.device): "SEND NOW am Gerät gestartet"
        case .autoUplink: "Automatischer Uplink gestartet"
        case .networkAnswer(let gateways, let rssi, let snr): "Netzantwort: " + Self.measurement(gateways, rssi, snr)
        case .lateAnswer(let gateways, let rssi, let snr): "Späte Netzantwort: " + Self.measurement(gateways, rssi, snr)
        case .noAnswer: "Keine Netzantwort nach 15 s"
        case .sendFailed: "Senden fehlgeschlagen"
        case .joined: "Verbunden mit LoRaWAN"
        case .joinLost: "LoRaWAN-Verbindung verloren"
        case .joinFailed: "LoRaWAN-Join fehlgeschlagen"
        case .fixGained: "GPS-Fix erhalten"
        case .fixLost: "GPS-Fix verloren"
        case .gnssLost: "Keine Daten vom GPS-Modul"
        case .gnssBack: "GPS-Modul liefert wieder Daten"
        case .sdMissing: "SD-Karte fehlt"
        case .sdReady: "SD-Karte bereit"
        case .profileChanged(let profile, true): "Rückmeldung geändert: \(Self.profileName(profile))"
        case .profileChanged(let profile, false): "Rückmeldung am Gerät geändert: \(Self.profileName(profile))"
        case .deviceRestarted: "Gerät wurde neu gestartet, Zähler beginnen neu"
        }
    }

    /// Why the device signals. No sound goes over BLE, so this names the trigger and what the profile would do.
    func deviceHint(profile: UInt8) -> String? {
        switch self {
        case .networkAnswer: Self.signalText(profile, success: true)
        case .noAnswer, .sendFailed: Self.signalText(profile, success: false)
        case .profileChanged(_, false): "Das Umschalten am Gerät wird mit dem OK-Signal bestätigt."
        case .lateAnswer: "Kam erst nach Ablauf der 15 s, dafür gibt es kein OK-Signal."
        default: nil
        }
    }

    static func profileName(_ profile: UInt8) -> String {
        switch profile {
        case 0: "Nur Vibration"
        case 1: "Nur Ton"
        case 2: "Ton und Vibration"
        case 3: "Stumm"
        default: "Unbekannt"
        }
    }

    private static func signalText(_ profile: UInt8, success: Bool) -> String {
        let name = success ? "OK-Signal" : "Fehlersignal"
        return switch profile {
        case 0: "Dafür gibt der Tester sein \(name) als Vibration."
        case 1: "Dafür gibt der Tester sein \(name) als Ton."
        case 2: "Dafür gibt der Tester sein \(name) als Ton und Vibration."
        default: "Der Tester ist auf Stumm gestellt und gibt dafür kein Signal."
        }
    }

    private static func measurement(_ gateways: Int?, _ rssi: Int, _ snr: Int) -> String {
        let count = gateways.map { $0 == 1 ? "1 Gateway" : "\($0) Gateways" } ?? "Gateways unbekannt"
        return "\(count), \(signed(rssi)) dBm, \(signed(snr)) dB"
    }
}

/// A real minus sign, for reading and for VoiceOver.
func signed(_ value: Int) -> String { value < 0 ? "−\(-value)" : "\(value)" }

struct EventContext {
    /// The link was down in between, so changes against `previous` happened unseen.
    var afterReconnect = false
    var appRequestedSend = false
    var appChangedProfile = false
}

enum TesterEvents {
    /// Compares two status packets. Without a previous status the current one is only the starting point.
    static func derive(previous: DeviceStatus?, current: DeviceStatus, context: EventContext = EventContext()) -> [EventKind] {
        guard let previous else { return [] }
        if current.sent < previous.sent { return [.deviceRestarted] }
        if context.afterReconnect { return [] }

        func rose(_ flag: StatusFlags) -> Bool { !previous.flags.contains(flag) && current.flags.contains(flag) }
        func fell(_ flag: StatusFlags) -> Bool { previous.flags.contains(flag) && !current.flags.contains(flag) }

        var events: [EventKind] = []

        if previous.join != current.join {
            switch current.join {
            case .joined: events.append(.joined)
            case .failed: events.append(.joinFailed)
            default: if previous.join == .joined { events.append(.joinLost) }
            }
        }

        if rose(.awaitingNetwork) {
            events.append(.sendStarted(context.appRequestedSend ? .app : .device))
        } else if current.sent > previous.sent, !current.flags.contains(.awaitingNetwork) {
            events.append(.autoUplink)
        }

        // The age only ever grows until a new network answer arrives.
        let answered: Bool
        if let age = current.feedbackAge {
            answered = previous.feedbackAge.map { age < $0 } ?? true
        } else {
            answered = false
        }
        let txFailed = current.tx == .lost && previous.tx != .lost

        if answered {
            events.append(previous.flags.contains(.awaitingNetwork)
                ? .networkAnswer(gateways: current.gwCount, rssi: current.gwRssi, snr: current.gwSnr)
                : .lateAnswer(gateways: current.gwCount, rssi: current.gwRssi, snr: current.gwSnr))
        }
        if txFailed {
            events.append(.sendFailed)
        } else if rose(.noNetworkAnswer) {
            events.append(.noAnswer)
        }

        if rose(.fix) { events.append(.fixGained) }
        if fell(.fix) { events.append(.fixLost) }
        if fell(.gnssData) { events.append(.gnssLost) }
        if rose(.gnssData) { events.append(.gnssBack) }
        if fell(.sdReady) { events.append(.sdMissing) }
        if rose(.sdReady) { events.append(.sdReady) }
        if previous.profile != current.profile {
            events.append(.profileChanged(current.profile, byApp: context.appChangedProfile))
        }
        return events
    }
}

enum SendPhase: Equatable {
    case ready
    case blocked(String)
    case requested
    case queued
    case waitingForNetwork
    case result(EventKind)

    var isResult: Bool { if case .result = self { true } else { false } }

    var title: String {
        switch self {
        case .ready, .blocked: "SEND NOW"
        case .requested: "Befehl gesendet …"
        case .queued: "Wartet auf Funkmodul …"
        case .waitingForNetwork: "Gesendet, warte auf Netz …"
        case .result(let event): event.title
        }
    }

    static func derive(connected: Bool, status: DeviceStatus?, requested: Bool, recentResult: EventKind?) -> SendPhase {
        guard connected else { return .blocked("Nicht verbunden mit dem Tester") }
        guard let status else { return .blocked("Warte auf Daten vom Tester") }
        if status.flags.contains(.awaitingNetwork) { return .waitingForNetwork }
        if status.flags.contains(.sendPending) { return .queued }
        if requested { return .requested }
        if let recentResult { return .result(recentResult) }
        switch status.join {
        case .joining: return .blocked("Noch nicht im LoRaWAN, Join läuft")
        case .idle, .failed: return .blocked("Nicht im LoRaWAN angemeldet")
        case .joined: break
        }
        return status.flags.contains(.loraBusy) ? .blocked("Sendung läuft gerade") : .ready
    }
}

enum NextUplink: Equatable {
    case notJoined, noFix, unknown, due
    case inSeconds(Int)

    /// The firmware sends once the interval has passed since the last uplink of any kind, and only with a fix.
    static func derive(status: DeviceStatus, interval: UInt16?, lastUplink: Date?, now: Date) -> NextUplink {
        guard status.join == .joined else { return .notJoined }
        guard status.flags.contains(.fix) else { return .noFix }
        guard let interval, let lastUplink else { return .unknown }
        let left = Int((lastUplink.timeIntervalSince(now) + Double(interval)).rounded(.up))
        return left > 0 ? .inSeconds(left) : .due
    }

    var text: String {
        switch self {
        case .notJoined: "Erst nach dem LoRaWAN-Join"
        case .noFix: "Pausiert, bis das GPS einen Fix hat"
        case .unknown: "Zeitpunkt nach dem nächsten Uplink bekannt"
        case .due: "Jetzt fällig"
        case .inSeconds(let s): s >= 60 ? "In etwa \(s / 60) min \(s % 60) s" : "In etwa \(s) s"
        }
    }
}

enum SignalQuality: Equatable {
    case veryGood, good, weak, critical

    static let explanation = "Sehr gut: ab −90 dBm und ab 5 dB. Gut: ab −105 dBm und ab 0 dB. Schwach: ab −115 dBm und ab −7 dB. Darunter kritisch. Es zählt der schlechtere der beiden Werte."

    static func rate(rssi: Int, snr: Int) -> SignalQuality {
        if rssi >= -90 && snr >= 5 { return .veryGood }
        if rssi >= -105 && snr >= 0 { return .good }
        if rssi >= -115 && snr >= -7 { return .weak }
        return .critical
    }

    var title: String {
        switch self {
        case .veryGood: "Sehr gut"
        case .good: "Gut"
        case .weak: "Schwach"
        case .critical: "Kritisch"
        }
    }
}
