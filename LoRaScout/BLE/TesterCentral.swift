import CoreBluetooth
import Foundation
import Observation

/// A tester's success or failure signal, shown on every tab with the device name.
struct DeviceToast: Identifiable, Equatable {
    var event: TesterEvent
    var device: String
    var id: UUID { event.id }
}

/// Owns the CBCentralManager, the remembered testers and one TesterSession per active tester.
/// Each tester accepts one link, CoreBluetooth holds several peripherals at once, so up to `maxActive` run in parallel.
@Observable
final class TesterCentral: NSObject {
    static let maxActive = 4

    let network: any LoRaNetwork = TTNNetwork()

    /// Bluetooth itself, nil while it is on. Every session shows this instead of its own state then.
    private(set) var radio: TesterSession.Link? = .starting
    private(set) var known: [KnownDevice] = []
    private(set) var nearby: [UUID: NearbyDevice] = [:]
    /// Active testers in the order they were activated.
    private(set) var sessions: [TesterSession] = []
    /// The tester Konfig edits and single views show.
    private(set) var focusedID: UUID?
    private(set) var toast: DeviceToast?

    /// The focused tester, else the first active, else a stand-in without device.
    var focused: TesterSession { sessions.first { $0.id == focusedID } ?? sessions.first ?? placeholder }
    var isMulti: Bool { sessions.count > 1 }
    var canActivateMore: Bool { sessions.count < Self.maxActive }

    func session(_ id: UUID) -> TesterSession? { sessions.first { $0.id == id } }

    /// Logs of the active testers for the merge. Without any, the old single log, if there still is one.
    var deviceLogs: [DeviceLog] {
        logSources.map { DeviceLog(tag: $0.deviceTag, data: $0.logData, devEUI: $0.known?.devEUI) }
    }

    /// Changes whenever one of the logs, names or DevEUIs does.
    var logsKey: [String] {
        logSources.map { "\($0.id?.uuidString ?? "")|\($0.logRevision)|\($0.deviceTag)|\($0.known?.devEUI ?? "")" }
    }

    private var logSources: [TesterSession] {
        sessions.isEmpty ? (placeholder.logRows.isEmpty ? [] : [placeholder]) : sessions
    }

    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var placeholder: TesterSession!
    @ObservationIgnored private let signals = SignalPlayer()
    @ObservationIgnored private var browsing = false
    @ObservationIgnored private var scanMode = ScanMode.off
    /// Only right after launch, a forgotten tester must not come straight back.
    @ObservationIgnored private var adoptHeld = true
    @ObservationIgnored private var seen: [UUID: CBPeripheral] = [:]

    private enum ScanMode { case off, normal, browse }

    /// The focused device. The key is older than the device list, so a single tester carries over.
    private static let focusKey = "knownDevice"
    private static let knownDevicesKey = "knownDevices"
    private static let activeKey = "activeDevices"
    private static let nearbyTimeout: TimeInterval = 15
    private static let toastDuration: TimeInterval = 6

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        let legacyFocus = defaults.string(forKey: Self.focusKey).flatMap(UUID.init(uuidString:))
        if let data = defaults.data(forKey: Self.knownDevicesKey),
           let list = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            known = list
        }
        // Before parallel testers there was only the chosen one.
        let active = defaults.stringArray(forKey: Self.activeKey).map { $0.compactMap(UUID.init(uuidString:)) }
            ?? legacyFocus.map { [$0] } ?? []
        for id in active where !known.contains(where: { $0.id == id }) { known.append(KnownDevice(id: id, name: "")) }
        if let legacyFocus {
            // The single log from before belongs to the tester chosen back then.
            let files = FileManager.default, target = TesterSession.logURL(for: legacyFocus)
            if files.fileExists(atPath: TesterSession.legacyLogURL.path()), !files.fileExists(atPath: target.path()) {
                try? files.moveItem(at: TesterSession.legacyLogURL, to: target)
            }
        }
        placeholder = TesterSession(id: nil, central: self)
        #if DEBUG
        if DemoData.isActive {
            loadDemo()
            return
        }
        #endif
        sessions = active.prefix(Self.maxActive).map { TesterSession(id: $0, central: self) }
        focusedID = legacyFocus.flatMap { id in sessions.contains { $0.id == id } ? id : nil } ?? sessions.first?.id
        manager = CBCentralManager(delegate: self, queue: nil)
        Task { [weak self] in
            while let self {
                self.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Devices

    /// Connects to this tester in addition to the others and shows it. An active one only gets the focus.
    func activate(_ id: UUID) {
        guard let manager else { return }
        adoptHeld = false
        if let active = session(id) {
            focus(id)
            if active.state == .pairingFailed { active.retryPairing() }
            return
        }
        guard canActivateMore else { return }
        let name = nearby[id]?.name ?? known.first { $0.id == id }?.name ?? ""
        remember(id, name: name)
        let added = TesterSession(id: id, central: self)
        sessions.append(added)
        saveActive()
        focus(id)
        if let found = seen[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first {
            added.use(found)
            added.rename(name)
        }
        startConnecting(added)
    }

    /// Ends the link, the tester stays known.
    func deactivate(_ id: UUID) {
        guard let gone = session(id) else { return }
        if let peripheral = gone.peripheral { manager?.cancelPeripheralConnection(peripheral) }
        gone.drop()
        sessions.removeAll { $0 === gone }
        saveActive()
        if focusedID == id { focus(sessions.first?.id) }
        updateScan()
    }

    /// Removes the tester from the list. The iOS pairing stays, iOS settings remove it.
    func forget(_ id: UUID) {
        guard manager != nil else { return }
        adoptHeld = false
        deactivate(id)
        known.removeAll { $0.id == id }
        saveKnown()
    }

    func focus(_ id: UUID?) {
        focusedID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: Self.focusKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.focusKey)
        }
    }

    /// Scans with RSSI updates while the device list is open.
    func startBrowsing() {
        guard manager != nil else { return }
        browsing = true
        addHeld()
        updateScan()
    }

    func stopBrowsing() {
        guard manager != nil else { return }
        browsing = false
        updateScan()
    }

    func dismissToast() { toast = nil }

    func previewSignals() { signals.preview() }

    // MARK: For sessions

    func remember(_ id: UUID, name: String) {
        if let index = known.firstIndex(where: { $0.id == id }) {
            guard !name.isEmpty, known[index].name != name else { return }
            known[index].name = name
        } else {
            known.append(KnownDevice(id: id, name: name))
        }
        saveKnown()
    }

    func remember(_ id: UUID, devEUI: String) {
        let value = DevEUI.normalized(devEUI)
        guard !value.isEmpty, let index = known.firstIndex(where: { $0.id == id }), known[index].devEUI != value else { return }
        known[index].devEUI = value
        saveKnown()
    }

    func post(_ event: TesterEvent, from session: TesterSession) {
        toast = DeviceToast(event: event, device: session.title)
    }

    /// With several testers the tones say which one it was.
    func playSignals(_ kinds: [EventKind], from session: TesterSession) {
        signals.play(kinds, label: isMulti ? session.shortTitle : nil)
    }

    func cancel(_ peripheral: CBPeripheral) { manager?.cancelPeripheralConnection(peripheral) }

    func sessionBecameReady() { updateScan() }

    // MARK: Connection

    private func saveKnown() {
        if let data = try? JSONEncoder().encode(known) {
            UserDefaults.standard.set(data, forKey: Self.knownDevicesKey)
        }
    }

    private func saveActive() {
        UserDefaults.standard.set(sessions.compactMap { $0.id?.uuidString }, forKey: Self.activeKey)
    }

    /// iOS can hold the link on its own, e.g. after a reinstall. The device doesn't advertise then.
    private func addHeld() {
        guard let manager, manager.state == .poweredOn else { return }
        for held in manager.retrieveConnectedPeripherals(withServices: [Gatt.service]) where session(held.identifier) == nil {
            seen[held.identifier] = held
            nearby[held.identifier] = NearbyDevice(id: held.identifier, name: held.name ?? "", rssi: nil, seen: .now)
        }
    }

    private func startAll() {
        guard let manager else { return }
        if sessions.isEmpty {
            // After a reinstall with one tester held by iOS, that one is the obvious choice.
            let held = manager.retrieveConnectedPeripherals(withServices: [Gatt.service])
            if adoptHeld, known.isEmpty, held.count == 1, let only = held.first {
                seen[only.identifier] = only
                activate(only.identifier)
                return
            }
        }
        sessions.forEach(startConnecting)
        updateScan()
    }

    private func startConnecting(_ session: TesterSession) {
        guard let manager, manager.state == .poweredOn, let id = session.id else { return }
        if session.peripheral == nil, let found = seen[id] ?? manager.retrievePeripherals(withIdentifiers: [id]).first {
            session.use(found)
        }
        // A pending connect has no timeout, it completes as soon as the device is back in range.
        if let peripheral = session.peripheral {
            manager.connect(peripheral)
            session.setState(.connecting)
        } else {
            session.setState(.searching)
        }
        updateScan()
    }

    /// Scans while the list is open, nothing is active yet, or a tester still has to be found or named.
    private func updateScan() {
        guard let manager, manager.state == .poweredOn else { return }
        let waiting = sessions.contains { $0.state == .searching || $0.state == .connecting }
        let wanted: ScanMode = browsing ? .browse : (sessions.isEmpty || waiting) ? .normal : .off
        guard wanted != scanMode else { return }
        scanMode = wanted
        switch wanted {
        case .off: manager.stopScan()
        case .normal: manager.scanForPeripherals(withServices: [Gatt.service], options: nil)
        case .browse:
            manager.scanForPeripherals(withServices: [Gatt.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private func tick() {
        let now = Date.now
        if let toast, now.timeIntervalSince(toast.event.date) > Self.toastDuration { self.toast = nil }
        let gone = nearby.values.filter { $0.rssi != nil && now.timeIntervalSince($0.seen) > Self.nearbyTimeout }
        for device in gone { nearby[device.id] = nil }
        for session in sessions { session.tick(now) }
        updateScan()
    }

    private func handleLoss(of lost: CBPeripheral, error: Error?) {
        // A deactivated tester's disconnect arrives after its session is gone.
        guard let session = session(lost.identifier), lost === session.peripheral else { return }
        session.resetSession()
        guard manager?.state == .poweredOn else { return }
        if (error as? CBError)?.code == .peerRemovedPairingInformation {
            session.setState(.bondLost)
            updateScan()
            return
        }
        startConnecting(session)
    }
}

extension TesterCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        scanMode = .off
        switch central.state {
        case .poweredOn:
            radio = nil
            startAll()
        case .poweredOff:
            for session in sessions {
                session.resetSession()
                session.setState(.searching)
            }
            radio = .bluetoothOff
        case .unauthorized: radio = .unauthorized
        case .unsupported: radio = .unsupported
        default: radio = .starting
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let id = found.identifier
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? found.name ?? ""
        seen[id] = found
        // Duplicates come several times a second, the list only needs a fresh value now and then.
        let level = rssi.intValue == 127 ? nil : rssi.intValue
        if nearby[id].map({ $0.name != name || Date.now.timeIntervalSince($0.seen) >= 1 }) ?? true {
            nearby[id] = NearbyDevice(id: id, name: name, rssi: level, seen: .now)
        }
        guard let session = session(id) else { return }
        remember(id, name: name)
        session.rename(name)
        if session.peripheral == nil {
            session.use(found)
            session.rename(name)
            session.setState(.connecting)
            central.connect(found)
            updateScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        guard let session = session(connected.identifier), connected === session.peripheral else { return }
        nearby[connected.identifier] = nil
        remember(connected.identifier, name: session.deviceName ?? connected.name ?? "")
        session.didConnect()
        updateScan()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        handleLoss(of: failed, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral lost: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleLoss(of: lost, error: error)
    }
}

#if DEBUG
extension TesterCentral {
    fileprivate func loadDemo() {
        radio = nil
        known = DemoData.devices
        nearby = DemoData.nearby
        sessions = DemoData.testers.map { demo in
            let session = TesterSession(id: demo.device.id, central: self)
            session.loadDemo(demo, link: DemoData.link)
            return session
        }
        focusedID = sessions.first?.id
        if DemoData.showResult, let first = sessions.first, let event = first.lastSendResult {
            toast = DeviceToast(event: event, device: first.title)
        }
    }
}
#endif
