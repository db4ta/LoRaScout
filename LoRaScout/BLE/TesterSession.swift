import CoreBluetooth
import Foundation
import Observation

private func uuid(_ n: Int) -> CBUUID { CBUUID(string: String(format: "4654%04X-7B1C-4E2A-9D3F-6C0A5E8F1A10", n)) }

enum Gatt {
    static let service = uuid(1)
    static let status = uuid(2)
    static let control = uuid(3)
    static let reply = uuid(4)
    static let config = uuid(5)
    static let log = uuid(6)
}

struct TesterEvent: Identifiable, Equatable {
    let id = UUID()
    var date: Date
    var kind: EventKind
    var profile: UInt8
}

/// One tester: its link, live data, config, events and log. TesterCentral owns the CBCentralManager and hands
/// connection callbacks to the session of that peripheral. A session without id stands in while none is active.
@Observable
final class TesterSession: NSObject, Identifiable {
    enum Link: Equatable {
        case starting, bluetoothOff, unauthorized, unsupported
        case searching, connecting, pairing, pairingFailed, ready
        case bondLost
        /// No tester chosen yet.
        case choosing
    }

    enum LogState: Equatable {
        case idle, loading, done
        case failed(String)
    }

    let id: UUID?
    @ObservationIgnored private unowned let central: TesterCentral

    /// Own connection state. Bluetooth itself being off or not allowed wins, see `link`.
    private(set) var state = Link.searching
    private(set) var deviceName: String?
    private(set) var status: DeviceStatus?
    private(set) var config: DeviceConfig?
    private(set) var sendMessage: String?
    private(set) var events: [TesterEvent] = []
    private(set) var lastUplink: Date?
    private(set) var sendRequested = false
    private(set) var lastSendResult: TesterEvent?
    private(set) var savingConfig = false
    private(set) var configMessage: String?
    private(set) var configFailed = false
    private(set) var restartNeeded = false
    private(set) var logState = LogState.idle
    private(set) var logReceived = 0
    private(set) var logTotal: Int?
    private(set) var logRows: [FieldLogRow] = []
    /// Counts changes of the local log, cheaper to watch than the log itself.
    private(set) var logRevision = 0

    private(set) var clearingDeviceLog = false
    private(set) var clearMessage: String?

    var network: any LoRaNetwork { central.network }
    var link: Link { central.radio ?? (id == nil ? .choosing : state) }
    var known: KnownDevice? { central.known.first { $0.id == id } }
    var kind: DeviceKind { DeviceKind(name: deviceName ?? known?.name) }
    /// Tags archive rows. The name only, never the id: a later name would duplicate rows tagged with the id.
    var deviceTag: String { known?.name ?? "" }
    /// For lists, toasts and buttons.
    var title: String { deviceName ?? known?.title ?? "Tester" }
    var shortTitle: String { KnownDevice.shortTitle(title) }

    /// One local log per tester, so a resume offset never belongs to the other device.
    var logURL: URL { Self.logURL(for: id) }
    var logData: Data { FieldLog.completeLines(assembler.data) }

    @ObservationIgnored private(set) var peripheral: CBPeripheral?
    @ObservationIgnored private var chars: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingSubscriptions: [CBUUID] = []
    @ObservationIgnored private var pairingStarted = Date.distantPast
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var configQueue: [ConfigWrite] = []
    @ObservationIgnored private var configSentAt = Date.distantPast
    @ObservationIgnored private var assembler = LogAssembler()
    @ObservationIgnored private var lastLogActivity = Date.distantPast
    @ObservationIgnored private var logResyncing = false
    @ObservationIgnored private var lastStatus: DeviceStatus?
    @ObservationIgnored private var linkWasDown = false
    @ObservationIgnored private var sendRequestedAt = Date.distantPast
    @ObservationIgnored private var profileWrittenAt = Date.distantPast
    @ObservationIgnored private var logRetriedFromStart = false
    @ObservationIgnored private var resumeLogOnConnect = false

    static let legacyLogURL = URL.documentsDirectory.appending(path: "fieldlog.csv")
    private static let pairingTimeout: TimeInterval = 120
    private static let attemptInterval: TimeInterval = 5
    private static let configTimeout: TimeInterval = 5
    private static let logTimeout: TimeInterval = 10
    private static let sendRequestTimeout: TimeInterval = 60
    private static let profileEchoTimeout: TimeInterval = 10
    static let resultDuration: TimeInterval = 20
    private static let maxEvents = 200

    static func logURL(for id: UUID?) -> URL {
        id.map { URL.documentsDirectory.appending(path: "fieldlog-\($0.uuidString).csv") } ?? legacyLogURL
    }

    init(id: UUID?, central: TesterCentral) {
        self.id = id
        self.central = central
        super.init()
        deviceName = central.known.first { $0.id == id }?.name.nonEmpty
        loadLog()
    }

    // MARK: Commands

    var canSend: Bool {
        guard link == .ready, let status, !sendRequested else { return false }
        return status.join == .joined && !status.flags.contains(.sendPending) && !status.flags.contains(.loraBusy)
            && !status.flags.contains(.awaitingNetwork)
    }

    var sendPhase: SendPhase {
        let recent = lastSendResult.flatMap {
            Date.now.timeIntervalSince($0.date) < Self.resultDuration ? $0.kind : nil
        }
        return SendPhase.derive(connected: link == .ready, status: status, requested: sendRequested, recentResult: recent)
    }

    func sendNow() {
        sendMessage = nil
        sendRequested = true
        sendRequestedAt = .now
        write(.sendNow)
    }

    func showScreen(_ screen: UInt8) { write(.screen(screen)) }

    func restart() {
        restartNeeded = false
        write(.restart)
    }

    /// Writes one value at a time and waits for its reply.
    func save(_ writes: [ConfigWrite]) {
        guard link == .ready, !savingConfig, !writes.isEmpty else { return }
        configQueue = ConfigWrite.ordered(writes)
        if writes.contains(where: { $0.id == .profile }) { profileWrittenAt = .now }
        savingConfig = true
        configFailed = false
        configMessage = nil
        sendNextConfig()
    }

    func downloadLog(fromStart: Bool = false) {
        guard link == .ready, logState != .loading else { return }
        if fromStart {
            assembler.data = Data()
            logReceived = 0
        }
        logRetriedFromStart = false
        beginLog()
    }

    /// Fetches what is new on the card, false if that didn't work out.
    func downloadLogAndWait() async -> Bool {
        downloadLog()
        while logState == .loading { try? await Task.sleep(for: .milliseconds(200)) }
        return logState == .done
    }

    /// The local copy goes too: its length would be a wrong resume offset for the new log.
    func clearDeviceLog() {
        guard link == .ready, logState != .loading, !clearingDeviceLog else { return }
        clearingDeviceLog = true
        clearMessage = nil
        write(.logClear)
    }

    func clearLocalLog() {
        guard logState != .loading else { return }
        assembler.data = Data()
        logReceived = 0
        logTotal = nil
        logRows = []
        logState = .idle
        logRevision += 1
        try? FileManager.default.removeItem(at: logURL)
    }

    func retryPairing() {
        if let peripheral { central.cancel(peripheral) }
    }

    // MARK: Connection, driven by TesterCentral

    func use(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        if let name = found.name, !name.isEmpty { deviceName = name }
    }

    func rename(_ name: String) {
        if !name.isEmpty, name != deviceName { deviceName = name }
    }

    func setState(_ new: Link) {
        if state != new { state = new }
    }

    /// Lets go of the peripheral, before the session goes away.
    func drop() {
        resetSession()
        peripheral?.delegate = nil
        peripheral = nil
        resumeLogOnConnect = false
    }

    func didConnect() {
        state = .pairing
        pairingStarted = .now
        peripheral?.discoverServices([Gatt.service])
    }

    func resetSession() {
        chars = [:]
        pendingSubscriptions = []
        status = nil
        linkWasDown = true
        clearingDeviceLog = false
        sendRequested = false
        config = nil
        if savingConfig {
            configQueue = []
            savingConfig = false
            configFailed = true
            configMessage = "Verbindung getrennt, Speichern abgebrochen."
        }
        if logState == .loading {
            finishLog(.idle)
            resumeLogOnConnect = true
        }
    }

    private func loadLog() {
        assembler.data = (try? Data(contentsOf: logURL)) ?? Data()
        logRows = FieldLog.parse(assembler.data)
        logReceived = assembler.data.count
        logTotal = nil
        logState = .idle
        logRevision += 1
    }

    private func subscribeNext() {
        guard let peripheral else { return }
        if let next = pendingSubscriptions.first, let char = chars[next] {
            lastAttempt = .now
            peripheral.setNotifyValue(true, for: char)
        } else if pendingSubscriptions.isEmpty {
            readStatus()
        }
    }

    private func readStatus() {
        guard let peripheral, let char = chars[Gatt.status] else { return }
        lastAttempt = .now
        peripheral.readValue(for: char)
    }

    private func becomeReady() {
        state = .ready
        central.sessionBecameReady()
        if let char = chars[Gatt.config] { peripheral?.readValue(for: char) }
        if resumeLogOnConnect {
            resumeLogOnConnect = false
            beginLog()
        }
    }

    private func ingest(_ parsed: DeviceStatus) {
        let now = Date.now
        let context = EventContext(afterReconnect: linkWasDown, appRequestedSend: sendRequested,
                                   appChangedProfile: now.timeIntervalSince(profileWrittenAt) < Self.profileEchoTimeout)
        let kinds = TesterEvents.derive(previous: lastStatus, current: parsed, context: context)
        if let lastStatus, !linkWasDown, parsed.sent > lastStatus.sent { lastUplink = now }
        if kinds.contains(.deviceRestarted) { lastUplink = nil }
        lastStatus = parsed
        linkWasDown = false
        status = parsed
        record(kinds, profile: parsed.profile, at: now)
        if parsed.flags.contains(.awaitingNetwork) || parsed.flags.contains(.sendPending) { sendRequested = false }
    }

    private func record(_ kinds: [EventKind], profile: UInt8, at date: Date, signal: Bool = true) {
        for kind in kinds {
            let event = TesterEvent(date: date, kind: kind, profile: profile)
            events.insert(event, at: 0)
            guard kind.isDeviceSignal else { continue }
            lastSendResult = event
            if signal { central.post(event, from: self) }
        }
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
        if signal { central.playSignals(kinds, from: self) }
    }

    func tick(_ now: Date) {
        if sendRequested, now.timeIntervalSince(sendRequestedAt) > Self.sendRequestTimeout { sendRequested = false }
        if state == .pairing {
            if now.timeIntervalSince(pairingStarted) > Self.pairingTimeout {
                state = .pairingFailed
            } else if now.timeIntervalSince(lastAttempt) > Self.attemptInterval {
                subscribeNext()
            }
        }
        if link == .ready {
            // Notifications carry at most MTU - 3 bytes, a smaller MTU leaves only Read.
            if let peripheral, peripheral.maximumWriteValueLength(for: .withoutResponse) < DeviceStatus.size {
                readStatus()
            }
            if logState == .loading, now.timeIntervalSince(lastLogActivity) > Self.logTimeout {
                write(.logStop)
                finishLog(.failed("Keine Daten mehr vom Gerät."))
            }
        }
        if savingConfig, now.timeIntervalSince(configSentAt) > Self.configTimeout {
            failConfig("Keine Antwort vom Gerät.")
        }
    }

    private func write(_ command: ControlCommand) {
        guard let peripheral, let char = chars[Gatt.control] else { return }
        peripheral.writeValue(command.bytes, for: char, type: .withResponse)
    }

    // MARK: Config

    private func sendNextConfig() {
        guard let next = configQueue.first, let peripheral, let char = chars[Gatt.config] else { return }
        configSentAt = .now
        peripheral.writeValue(next.bytes, for: char, type: .withResponse)
    }

    private func handleConfigReply(_ reply: Reply) {
        guard savingConfig, let id = reply.configID, id == configQueue.first?.id else { return }
        switch reply.status {
        case .ok, .savedNeedsRestart:
            if reply.status == .savedNeedsRestart { restartNeeded = true }
            configQueue.removeFirst()
            if configQueue.isEmpty {
                savingConfig = false
                configMessage = "Gespeichert."
                reloadConfig()
            } else {
                sendNextConfig()
            }
        case .invalid: failConfig("\(label(id)): ungültiger Wert.")
        case .busy: failConfig("\(label(id)): Gerät beschäftigt.")
        case .noCard: failConfig("\(label(id)): kein Zugriff.")
        case .unknown: failConfig("\(label(id)): vom Gerät abgelehnt.")
        }
    }

    private func failConfig(_ message: String) {
        configQueue = []
        savingConfig = false
        configFailed = true
        configMessage = message
        reloadConfig()
    }

    private func reloadConfig() {
        if let char = chars[Gatt.config] { peripheral?.readValue(for: char) }
    }

    private func adopt(_ parsed: DeviceConfig) {
        config = parsed
        // The DevEUI maps rows of the server's coverage log to this tester.
        if let id { central.remember(id, devEUI: parsed.devEUI) }
    }

    private func label(_ id: ConfigID) -> String {
        if let field = network.credentials.first(where: { $0.id == id }) { return field.label }
        return switch id {
        case .interval: "Intervall"
        case .profile: "Profil"
        case .uploadOnBoot: "Upload beim Start"
        case .wifiName: "WLAN-Name"
        case .wifiPassword: "WLAN-Passwort"
        case .server: "Server"
        case .uploadToken: "Upload-Token"
        case .displaySave: "Display-Sparmodus"
        case .displayAlways: "Display ohne iPhone ausschalten"
        case .displayOffSeconds: "Display aus nach"
        case .brightness: "Helligkeit"
        case .cpuMHz: "Prozessortakt"
        case .gnssStandby: "GNSS-Standby"
        case .signalTones: "Signaltöne"
        default: "Wert"
        }
    }

    // MARK: Log

    private func beginLog() {
        logState = .loading
        logTotal = nil
        lastLogActivity = .now
        write(.logStart(offset: UInt32(assembler.data.count)))
    }

    private func finishLog(_ state: LogState) {
        logState = state
        logResyncing = false
        try? assembler.data.write(to: logURL, options: .atomic)
        logRows = FieldLog.parse(assembler.data)
        logRevision += 1
    }

    private func handleLogReply(_ reply: Reply) {
        guard logState == .loading else { return }
        lastLogActivity = .now
        switch reply.status {
        case .ok:
            logResyncing = false
            logTotal = reply.logSize.map(Int.init)
        case .invalid where !logRetriedFromStart:
            // The log on the device is shorter than the offset: another card.
            logRetriedFromStart = true
            assembler.data = Data()
            logReceived = 0
            beginLog()
        case .noCard: finishLog(.failed("\(kind.logStorage) fehlt oder kein Zugriff."))
        case .busy: finishLog(.failed("Gerät beschäftigt."))
        default: finishLog(.failed("Download abgelehnt."))
        }
    }

    private func handleLogPacket(_ packet: Data) {
        guard logState == .loading, !logResyncing else { return }
        lastLogActivity = .now
        switch assembler.accept(packet) {
        case .appended: logReceived = assembler.data.count
        case .ignored: break
        case .finished: finishLog(.done)
        case .malformed: finishLog(.failed("Ungültiges Log-Paket."))
        case .gap:
            logResyncing = true
            write(.logStop)
            write(.logStart(offset: UInt32(assembler.data.count)))
        }
    }

    private func handleClearReply(_ reply: Reply) {
        clearingDeviceLog = false
        switch reply.status {
        case .ok:
            clearLocalLog()
            clearMessage = "Log auf dem Tester gelöscht."
        case .noCard: clearMessage = "\(kind.logStorage) fehlt oder kein Zugriff."
        default: clearMessage = "Der Tester hat das Löschen abgelehnt."
        }
    }

    private func handleSendReply(_ reply: Reply) {
        switch reply.status {
        case .ok: return
        case .busy: sendMessage = "Der Tester hat abgelehnt: beschäftigt oder nicht im LoRaWAN."
        default: sendMessage = "Der Tester hat den Befehl abgelehnt."
        }
        sendRequested = false
    }
}

extension TesterSession: CBPeripheralDelegate {
    /// Callbacks of a peripheral this session already let go can still arrive.
    private func isOwn(_ other: CBPeripheral) -> Bool { other === peripheral }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isOwn(peripheral), let service = peripheral.services?.first(where: { $0.uuid == Gatt.service }) else { return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isOwn(peripheral) else { return }
        for char in service.characteristics ?? [] { chars[char.uuid] = char }
        pendingSubscriptions = [Gatt.reply, Gatt.log, Gatt.status]
        subscribeNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor char: CBCharacteristic, error: Error?) {
        guard isOwn(peripheral), error == nil else { return }  // tick() repeats it, the pairing may still be open
        pendingSubscriptions.removeAll { $0 == char.uuid }
        subscribeNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor char: CBCharacteristic, error: Error?) {
        guard isOwn(peripheral), error == nil, let value = char.value else { return }
        switch char.uuid {
        case Gatt.status:
            guard let parsed = DeviceStatus.parse(value) else { return }
            ingest(parsed)
            if state == .pairing || state == .pairingFailed { becomeReady() }
        case Gatt.config:
            if let parsed = DeviceConfig.parse(value) { adopt(parsed) }
        case Gatt.reply:
            guard let reply = Reply.parse(value) else { return }
            switch reply.op {
            case ControlCommand.sendNowOp: handleSendReply(reply)
            case ControlCommand.logStartOp: handleLogReply(reply)
            case ControlCommand.logClearOp: handleClearReply(reply)
            default: handleConfigReply(reply)
            }
        case Gatt.log:
            handleLogPacket(value)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor char: CBCharacteristic, error: Error?) {
        guard isOwn(peripheral), error != nil else { return }
        if char.uuid == Gatt.config, savingConfig {
            failConfig("Schreiben fehlgeschlagen.")
        } else if char.uuid == Gatt.control {
            sendMessage = "Der Befehl konnte nicht gesendet werden."
            sendRequested = false
        }
    }
}

#if DEBUG
extension TesterSession {
    func loadDemo(_ demo: DemoData.Tester, link: Link) {
        state = link
        deviceName = demo.device.name
        guard link == .ready else { return }
        status = demo.status
        config = demo.config
        lastUplink = Date.now.addingTimeInterval(-demo.uplinkAge)
        assembler.data = Data(demo.csv.utf8)
        logRows = FieldLog.parse(assembler.data)
        logReceived = assembler.data.count
        logState = .done
        logRevision += 1
        for (age, kind) in demo.events.reversed() {
            record([kind], profile: demo.status.profile, at: Date.now.addingTimeInterval(-age), signal: false)
        }
        if !DemoData.showResult { lastSendResult = nil }
    }
}
#endif
