import CoreBluetooth
import Foundation
import Observation

private func uuid(_ n: Int) -> CBUUID { CBUUID(string: String(format: "4654%04X-7B1C-4E2A-9D3F-6C0A5E8F1A10", n)) }

private enum Gatt {
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

@Observable
final class FieldTester: NSObject {
    enum Link: Equatable {
        case starting, bluetoothOff, unauthorized, unsupported
        case searching, connecting, pairing, pairingFailed, ready
        case bondLost
    }

    enum LogState: Equatable {
        case idle, loading, done
        case failed(String)
    }

    let network: any LoRaNetwork = TTNNetwork()

    private(set) var link = Link.starting
    private(set) var deviceName: String?
    private(set) var status: DeviceStatus?
    private(set) var config: DeviceConfig?
    private(set) var sendMessage: String?
    private(set) var events: [TesterEvent] = []
    private(set) var toast: TesterEvent?
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

    private(set) var clearingDeviceLog = false
    private(set) var clearMessage: String?

    let logURL = URL.documentsDirectory.appending(path: "fieldlog.csv")
    var logData: Data { FieldLog.completeLines(assembler.data) }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
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

    private static let knownDeviceKey = "knownDevice"
    private static let pairingTimeout: TimeInterval = 120
    private static let attemptInterval: TimeInterval = 5
    private static let configTimeout: TimeInterval = 5
    private static let logTimeout: TimeInterval = 10
    private static let sendRequestTimeout: TimeInterval = 60
    private static let profileEchoTimeout: TimeInterval = 10
    private static let toastDuration: TimeInterval = 6
    private static let resultDuration: TimeInterval = 20
    private static let maxEvents = 200

    override init() {
        super.init()
        assembler.data = (try? Data(contentsOf: logURL)) ?? Data()
        logRows = FieldLog.parse(assembler.data)
        logReceived = assembler.data.count
        #if DEBUG
        if DemoData.isActive {
            loadDemo()
            return
        }
        #endif
        central = CBCentralManager(delegate: self, queue: nil)
        Task { [weak self] in
            while let self {
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
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

    func dismissToast() { toast = nil }

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

    /// The local copy goes too: its length would be a wrong resume offset for the new log.
    /// Fetches what is new on the card, false if that didn't work out.
    func downloadLogAndWait() async -> Bool {
        downloadLog()
        while logState == .loading { try? await Task.sleep(for: .milliseconds(200)) }
        return logState == .done
    }

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
        try? FileManager.default.removeItem(at: logURL)
    }

    func retryPairing() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: Connection

    private func startConnecting() {
        if peripheral == nil, let text = UserDefaults.standard.string(forKey: Self.knownDeviceKey),
           let id = UUID(uuidString: text), let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            use(known)
        }
        // iOS can hold the link on its own, e.g. after a reinstall. The device doesn't advertise then.
        if peripheral == nil, let held = central.retrieveConnectedPeripherals(withServices: [Gatt.service]).first {
            use(held)
        }
        // A pending connect has no timeout, it completes as soon as the device is back in range.
        if let peripheral {
            central.connect(peripheral)
            link = .connecting
        } else {
            link = .searching
        }
        central.scanForPeripherals(withServices: [Gatt.service])
    }

    private func use(_ found: CBPeripheral) {
        peripheral = found
        found.delegate = self
        deviceName = found.name
    }

    private func resetSession() {
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
        link = .ready
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

    private func record(_ kinds: [EventKind], profile: UInt8, at date: Date) {
        for kind in kinds {
            let event = TesterEvent(date: date, kind: kind, profile: profile)
            events.insert(event, at: 0)
            guard kind.isDeviceSignal else { continue }
            toast = event
            lastSendResult = event
        }
        if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
    }

    private func tick() {
        let now = Date.now
        if let toast, now.timeIntervalSince(toast.date) > Self.toastDuration { self.toast = nil }
        if sendRequested, now.timeIntervalSince(sendRequestedAt) > Self.sendRequestTimeout { sendRequested = false }
        if link == .pairing {
            if now.timeIntervalSince(pairingStarted) > Self.pairingTimeout {
                link = .pairingFailed
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
        case .displayAlways: "Sparmodus ohne Bluetooth"
        case .displayOffSeconds: "Display aus nach"
        case .brightness: "Helligkeit"
        case .cpuMHz: "Prozessortakt"
        case .gnssStandby: "GNSS-Standby"
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
        case .noCard: finishLog(.failed("Keine SD-Karte oder kein Zugriff."))
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
        case .noCard: clearMessage = "Keine SD-Karte oder kein Zugriff."
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

extension FieldTester: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startConnecting()
        case .poweredOff:
            resetSession()
            link = .bluetoothOff
        case .unauthorized: link = .unauthorized
        case .unsupported: link = .unsupported
        default: link = .starting
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if found.identifier == peripheral?.identifier { return }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        use(found)
        deviceName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? found.name
        link = .connecting
        central.connect(found)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        central.stopScan()
        UserDefaults.standard.set(connected.identifier.uuidString, forKey: Self.knownDeviceKey)
        link = .pairing
        pairingStarted = .now
        connected.discoverServices([Gatt.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        handleLoss(of: failed, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleLoss(of: lost, error: error)
    }

    private func handleLoss(of lost: CBPeripheral, error: Error?) {
        // A disconnect of the previous device arrives after use() picked a new one.
        guard lost.identifier == peripheral?.identifier else { return }
        resetSession()
        guard central.state == .poweredOn else { return }
        if (error as? CBError)?.code == .peerRemovedPairingInformation {
            link = .bondLost
            return
        }
        startConnecting()
    }
}

extension FieldTester: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Gatt.service }) else { return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] { chars[char.uuid] = char }
        pendingSubscriptions = [Gatt.reply, Gatt.log, Gatt.status]
        subscribeNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor char: CBCharacteristic, error: Error?) {
        guard error == nil else { return }  // tick() repeats it, the pairing may still be open
        pendingSubscriptions.removeAll { $0 == char.uuid }
        subscribeNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor char: CBCharacteristic, error: Error?) {
        guard error == nil, let value = char.value else { return }
        switch char.uuid {
        case Gatt.status:
            guard let parsed = DeviceStatus.parse(value) else { return }
            ingest(parsed)
            if link == .pairing || link == .pairingFailed { becomeReady() }
        case Gatt.config:
            if let parsed = DeviceConfig.parse(value) { config = parsed }
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
        guard error != nil else { return }
        if char.uuid == Gatt.config, savingConfig {
            failConfig("Schreiben fehlgeschlagen.")
        } else if char.uuid == Gatt.control {
            sendMessage = "Der Befehl konnte nicht gesendet werden."
            sendRequested = false
        }
    }
}

#if DEBUG
extension FieldTester {
    fileprivate func loadDemo() {
        link = DemoData.link
        deviceName = "FieldTester-A1B2"
        guard link == .ready else { return }
        status = DemoData.status
        config = DemoData.config
        lastUplink = Date.now.addingTimeInterval(-34)
        assembler.data = Data(DemoData.deviceCSV.utf8)
        logRows = FieldLog.parse(assembler.data)
        logReceived = assembler.data.count
        logState = .done
        for (age, kind) in DemoData.events.reversed() {
            record([kind], profile: 2, at: Date.now.addingTimeInterval(-age))
        }
        if !DemoData.showResult {
            toast = nil
            lastSendResult = nil
        }
    }
}
#endif
