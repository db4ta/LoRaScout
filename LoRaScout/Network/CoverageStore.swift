import Foundation
import Observation

@Observable
final class CoverageStore {
    private(set) var result: MergeResult?
    private(set) var stats: CoverageStats?
    private(set) var hasCoverage = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var tokenSet = false
    private(set) var tokenMessage: String?
    private(set) var loadedAt: Date?
    private(set) var serverMessage: String?
    private(set) var book: ArchiveBook?
    private(set) var archiveError: String?
    private(set) var skippedNoTime = 0
    private(set) var selected = MergeResult(rows: [], lastServerTime: "", rowsAfterCoverage: 0)
    private(set) var selectedStats: CoverageStats?

    /// All views show this period. "Alles" follows new data, so it stays the default.
    var period = Period(kind: .all, anchor: DayKey(date: .now, timeZone: .current)) {
        didSet { refreshSelection() }
    }

    /// Tester whose rows Karte, Auswertung and archive list show, nil for all. "" are rows from before device tags.
    var deviceFilter: String? {
        didSet { refreshSelection() }
    }

    var host: String {
        didSet {
            UserDefaults.standard.set(host, forKey: Self.hostKey)
            if host != oldValue { endpoint = nil }
        }
    }

    /// Empty for automatic: 8090 (LoRaScout Server), then 8099 (ioBroker).
    var port: String {
        didSet {
            UserDefaults.standard.set(port, forKey: Self.portKey)
            if port != oldValue { endpoint = nil }
        }
    }

    /// What the last check found at host and port, kept for Konfig and the delete texts.
    private(set) var endpoint: ServerEndpoint? {
        didSet { UserDefaults.standard.set(endpoint.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.endpointKey) }
    }
    private(set) var checking = false
    private(set) var checkMessage: String?
    private(set) var checkFailed = false
    /// Rows per DevEUI of the last fetch from the new server.
    private(set) var deviceCounts: [String: Int] = [:]
    /// DevEUIs of all remembered testers, also inactive ones, so the cached log covers them.
    var knownDevEUIs: [String] = []

    let mergedURL = URL.documentsDirectory.appending(path: "merged.csv")
    var selectionURL: URL { URL.temporaryDirectory.appending(path: "LoRaScout-\(period.slug).csv") }
    /// File name part for exports, names the tester when filtered.
    var selectionSlug: String {
        guard let deviceFilter else { return period.slug }
        return period.slug + "-" + (deviceFilter.isEmpty ? "ohne-Name" : deviceFilter)
    }
    var deviceTags: [String] { archive.deviceTags }
    var archive: Archive { book?.archive ?? Archive() }

    let coverageURL = URL.documentsDirectory.appending(path: "coverage.csv")
    @ObservationIgnored private var coverage = Data()
    @ObservationIgnored private var logs: [DeviceLog] = []
    /// What the next commit writes to the archive, per tester already merged and tagged.
    @ObservationIgnored private var archiveRows: [MergedRow] = []

    private static let hostKey = "coverageHost"
    private static let portKey = "coveragePort"
    private static let endpointKey = "coverageEndpoint"

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: Self.hostKey) ?? ""
        port = defaults.string(forKey: Self.portKey) ?? ""
        endpoint = defaults.data(forKey: Self.endpointKey).flatMap { try? JSONDecoder().decode(ServerEndpoint.self, from: $0) }
        tokenSet = TokenStore.load() != nil
        let files = ArchiveFiles(root: URL.documentsDirectory.appending(path: "Archiv"))
        #if DEBUG
        if DemoData.isActive {
            host = "192.168.10.20"
            tokenSet = true
            coverage = Data(DemoData.coverageCSV.utf8)
            hasCoverage = true
            loadedAt = .now
            book = ArchiveBook(files: ArchiveFiles(root: URL.temporaryDirectory.appending(path: "DemoArchiv")),
                               archive: DemoData.archive())
            if let period = DemoData.period(latest: archive.latestDay) { self.period = period }
            refreshSelection()
            return
        }
        #endif
        do {
            book = try ArchiveBook(files: files)
        } catch {
            archiveError = ArchiveError.unreadable.errorDescription
        }
        if let cached = try? Data(contentsOf: coverageURL), CoverageMerge.isCoverage(cached) {
            coverage = cached
            hasCoverage = true
            loadedAt = (try? FileManager.default.attributesOfItem(atPath: coverageURL.path()))?[.modificationDate] as? Date
        }
        refreshSelection()
    }

    // MARK: Archive

    /// Stores the current state, for the moment before something gets deleted.
    func archiveNow() throws {
        guard book != nil else { throw ArchiveError.unreadable }
        try commit()
    }

    /// Follows the device filter: with one tester chosen only its rows go.
    func deleteArchive(_ target: Period) {
        do {
            try book?.remove(target, device: deviceFilter)
            archiveError = nil
        } catch {
            archiveError = error.localizedDescription
        }
        refreshSelection()
    }

    /// Files can change from outside through the Files app.
    func reloadArchive() {
        #if DEBUG
        if DemoData.isActive { return }
        #endif
        do {
            try book?.reload()
            refreshSelection()
        } catch {
            archiveError = ArchiveError.unreadable.errorDescription
        }
    }

    /// Leaves "Alles" for the latest data rather than an empty today.
    func selectKind(_ kind: PeriodKind) {
        period = Period(kind: kind, anchor: period.kind == .all ? (archive.latestDay ?? period.anchor) : period.anchor)
    }

    private func commit() throws {
        let summary = try book?.commit(archiveRows, timeZone: .current)
        skippedNoTime = summary?.skippedNoTime ?? 0
        archiveError = nil
    }

    private func refreshSelection() {
        if let deviceFilter, !archive.deviceTags.contains(deviceFilter) { self.deviceFilter = nil }
        selected = archive.result(for: period, device: deviceFilter)
        selectedStats = selected.rows.isEmpty ? nil : CoverageStats(selected)
        try? selected.csv.write(to: selectionURL, options: .atomic)
    }

    /// Fills in the server from the device, an edited value stays.
    func offerHost(_ server: String) {
        guard host.isEmpty else { return }
        host = CoverageClient.hostText(server: server)
        if port.isEmpty, let fixed = CoverageClient.base(server: server)?.port { port = String(fixed) }
    }

    func saveToken(_ token: String) {
        let saved = TokenStore.save(token)
        tokenSet = saved || tokenSet
        tokenMessage = saved ? "Token im Schlüsselbund gespeichert." : "Token konnte nicht gespeichert werden."
    }

    /// One log per active tester. Archived rows carry its name so two testers don't merge.
    func update(logs: [DeviceLog]) {
        self.logs = logs
        recompute()
    }

    /// DevEUIs to ask the new server for: active testers first, then the other remembered ones.
    var fetchDevEUIs: [String] {
        var seen = Set<String>()
        return (logs.compactMap(\.devEUI) + knownDevEUIs).map { DevEUI.normalized($0) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Detects the server type at host and port, then checks the token.
    func checkServer() async {
        checking = true
        checkMessage = nil
        defer { checking = false }
        do {
            let found = try await detect()
            guard let token = TokenStore.load() else { throw CoverageError.noToken }
            try await CoverageClient.checkToken(found, token: token)
            checkFailed = false
            checkMessage = "Verbindung und Token in Ordnung."
        } catch {
            checkFailed = true
            checkMessage = error.localizedDescription
        }
    }

    private func detect() async throws -> ServerEndpoint {
        do {
            let found = try await CoverageClient.detect(server: host, port: port)
            endpoint = found
            return found
        } catch {
            endpoint = nil
            throw error
        }
    }

    func fetch() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            guard CoverageClient.base(server: host) != nil else { throw CoverageError.noServer }
            guard let token = TokenStore.load() else { throw CoverageError.noToken }
            let found = try await detect()
            let answer = try await CoverageClient.fetch(found, token: token, devEUIs: fetchDevEUIs)
            try store(answer.data)
            deviceCounts = answer.counts
        } catch {
            self.error = error.localizedDescription
        }
    }

    func importFile(_ url: URL) {
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try store(try Data(contentsOf: url))
        } catch {
            self.error = error is CoverageError ? error.localizedDescription : "Datei konnte nicht gelesen werden."
        }
    }

    func deleteLocal() {
        let files = FileManager.default
        try? files.removeItem(at: coverageURL)
        try? files.removeItem(at: mergedURL)
        coverage = Data()
        hasCoverage = false
        loadedAt = nil
        error = nil
        recompute()
    }

    /// ioBroker: deletes both logs. LoRaScout Server: hides only this tester's rows from the app, its database keeps them.
    func deleteOnServer(devEUI: String?, name: String) async {
        error = nil
        serverMessage = nil
        loading = true
        defer { loading = false }
        do {
            guard CoverageClient.base(server: host) != nil else { throw CoverageError.noServer }
            guard let token = TokenStore.load() else { throw CoverageError.noToken }
            let found = try await detect()
            if found.kind.perDevice {
                guard let devEUI = devEUI.flatMap({ DevEUI.normalized($0).nonEmpty }) else { throw CoverageError.noDevEUI(name) }
                try await CoverageClient.deleteLogs(found, token: token, devEUI: devEUI)
                removeLocal(devEUI: devEUI)
                serverMessage = "\(name) ist auf dem Server ausgeblendet. Im Archiv des Servers bleiben die Daten erhalten."
            } else {
                try await CoverageClient.deleteLogs(found, token: token, devEUI: nil)
                deleteLocal()
                serverMessage = "Logs auf dem Server gelöscht."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Drops one tester's rows from the cached coverage log, the others stay.
    private func removeLocal(devEUI: String) {
        let lines = CoverageMerge.parseCSV(coverage).filter { DevEUI.normalized($0.count > 9 ? $0[9] : "") != devEUI }
        deviceCounts[devEUI] = 0
        guard !lines.isEmpty else { return deleteLocal() }
        let data = Data(lines.map { $0.map { CoverageMerge.quoted($0) }.joined(separator: ",") + "\n" }.joined().utf8)
        try? data.write(to: coverageURL, options: .atomic)
        coverage = data
        recompute()
    }

    func report(_ failure: Error) { error = failure.localizedDescription }

    func clearError() { error = nil }

    private func store(_ data: Data) throws {
        guard CoverageMerge.isCoverage(data) else { throw CoverageError.notCoverage }
        try data.write(to: coverageURL, options: .atomic)
        coverage = data
        hasCoverage = true
        loadedAt = .now
        recompute()
    }

    private func recompute() {
        let server = hasCoverage ? ServerLog(coverage) : nil
        var used = Set<Int>()
        var merged: [MergedRow] = []
        var afterCoverage = 0
        archiveRows = []
        for log in logs {
            let single = server.flatMap { CoverageMerge.merge(device: log.data, server: $0, devEUI: log.devEUI, used: &used) }
            let rows = Archive.rows(result: single, device: log.data, tag: log.tag)
            archiveRows += rows
            if let single {
                merged += single.rows.map { row in
                    var copy = row
                    copy.device = log.tag
                    return copy
                }
                afterCoverage += single.rowsAfterCoverage
            }
        }
        result = server.flatMap { server in
            server.rows.last.map { last in
                MergeResult(rows: merged.enumerated().map { index, row in
                    var copy = row
                    copy.id = index
                    return copy
                }, lastServerTime: last.text, rowsAfterCoverage: afterCoverage)
            }
        }
        stats = result.map { CoverageStats($0) }
        if let result { try? result.csv.write(to: mergedURL, options: .atomic) }
        do {
            try commit()
        } catch {
            archiveError = error.localizedDescription
        }
        refreshSelection()
    }
}
