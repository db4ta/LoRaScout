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

    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Self.hostKey) }
    }

    let mergedURL = URL.documentsDirectory.appending(path: "merged.csv")
    var selectionURL: URL { URL.temporaryDirectory.appending(path: "LoRaScout-\(period.slug).csv") }
    var archive: Archive { book?.archive ?? Archive() }

    @ObservationIgnored private let coverageURL = URL.documentsDirectory.appending(path: "coverage.csv")
    @ObservationIgnored private var coverage = Data()
    @ObservationIgnored private var device = Data()

    private static let hostKey = "coverageHost"

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostKey) ?? ""
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

    func deleteArchive(_ target: Period) {
        do {
            try book?.remove(target)
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
        let summary = try book?.commit(Archive.rows(result: result, device: device), timeZone: .current)
        skippedNoTime = summary?.skippedNoTime ?? 0
        archiveError = nil
    }

    private func refreshSelection() {
        selected = archive.result(for: period)
        selectedStats = selected.rows.isEmpty ? nil : CoverageStats(selected)
        try? selected.csv.write(to: selectionURL, options: .atomic)
    }

    /// Fills in the server from the device, an edited value stays.
    func offerHost(_ server: String) {
        if host.isEmpty { host = CoverageClient.hostText(server: server) }
    }

    func saveToken(_ token: String) {
        let saved = TokenStore.save(token)
        tokenSet = saved || tokenSet
        tokenMessage = saved ? "Token im Schlüsselbund gespeichert." : "Token konnte nicht gespeichert werden."
    }

    func update(device: Data) {
        self.device = device
        recompute()
    }

    func fetch() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            guard let url = CoverageClient.url(server: host) else { throw CoverageError.noServer }
            guard let token = TokenStore.load() else { throw CoverageError.noToken }
            try store(try await CoverageClient.fetch(url: url, token: token))
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

    func deleteOnServer() async {
        error = nil
        serverMessage = nil
        loading = true
        defer { loading = false }
        do {
            guard let url = CoverageClient.url(server: host) else { throw CoverageError.noServer }
            guard let token = TokenStore.load() else { throw CoverageError.noToken }
            try await CoverageClient.deleteLogs(coverageURL: url, token: token)
            deleteLocal()
            serverMessage = "Logs auf dem Server gelöscht."
        } catch {
            self.error = error.localizedDescription
        }
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
        result = hasCoverage ? CoverageMerge.merge(device: device, server: coverage) : nil
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
