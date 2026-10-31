import SwiftUI
import UniformTypeIdentifiers

/// Data sources, evaluation and all exports in one place.
struct CoverageView: View {
    @Environment(FieldTester.self) private var tester
    @Environment(CoverageStore.self) private var coverage
    @State private var importing = false
    @State private var choosingExport = false
    @State private var deleteTarget: DeleteTarget?
    @State private var archiving = false

    private func number(_ value: Double?, _ unit: String) -> String {
        value.text { "\(signed(Int($0.rounded()))) \(unit)" }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                form
                    #if DEBUG
                    .task {
                        try? await Task.sleep(for: .seconds(1))
                        if let target = DemoData.scrollTarget { proxy.scrollTo(target, anchor: .top) }
                    }
                    #endif
            }
                .navigationTitle("Auswertung")
                .safeAreaInset(edge: .top, spacing: 0) { LinkBanner() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): coverage.importFile(url)
            case .failure(let error): coverage.report(error)
            }
        }
        .sheet(isPresented: $choosingExport) {
            MapExportView(content: MapContent(coverage: coverage), start: nil)
        }
    }

    private var form: some View {
        Form {
            Section {
                PeriodPicker()
            } footer: {
                Text("Statistik, Karte und Exporte folgen diesem Zeitraum. Tage zählen nach Ortszeit.")
            }
            if let error = coverage.archiveError {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let result = coverage.result, result.rowsAfterCoverage > 0 {
                Section {
                    StatusLabel(text: "\(result.rowsAfterCoverage) Zeilen sind neuer als das Coverage-Log und bleiben im Archiv unbekannt, bis du es neu lädst.",
                                symbol: EventSeverity.warning.symbol, color: .orange)
                }
            }
            if let stats = coverage.selectedStats {
                Section {
                    LabeledContent("Empfangen", value: "\(stats.received)")
                    LabeledContent("Verloren", value: "\(stats.lost)")
                    LabeledContent("Unbekannt", value: "\(stats.unknown)")
                    LabeledContent("Verlustquote", value: stats.lossRate.text {
                        $0.formatted(.percent.precision(.fractionLength(1)).locale(Locale(identifier: "de_DE")))
                    })
                    LabeledContent("Mittel RSSI", value: number(stats.meanRSSI, "dBm"))
                    LabeledContent("Mittel SNR", value: number(stats.meanSNR, "dB"))
                } header: {
                    Text("Ergebnis")
                } footer: {
                    Text("Unbekannt: älter als der erste Server-Eintrag, oder es gibt noch kein passendes Coverage-Log. Die Verlustquote lässt diese Zeilen weg.")
                }
                let trend = coverage.archive.trend(for: coverage.period)
                if !trend.isEmpty {
                    Section("Verlustquote im Verlauf") { LossChart(entries: trend) }.id("chart")
                }
                if !stats.gateways.isEmpty {
                    Section("Gateways je Uplink") {
                        ForEach(stats.gateways, id: \.value) {
                            LabeledContent($0.value == "1" ? "1 Gateway" : "\($0.value) Gateways", value: "\($0.count)×")
                        }
                    }
                }
                if !stats.spreadingFactors.isEmpty {
                    Section("Spreading Factor") {
                        ForEach(stats.spreadingFactors, id: \.value) { item in
                            LabeledContent(item.value.hasPrefix("SF") ? item.value : "SF\(item.value)", value: "\(item.count)×")
                        }
                    }
                }
            } else {
                Section {
                    ContentUnavailableView("Keine Daten", systemImage: "chart.pie",
                                           description: Text(coverage.archive.rowCount == 0
                                               ? "Das Archiv füllt sich mit jedem Log-Download. Ob ein Uplink ankam, weiß nur der Server, dafür zusätzlich das Coverage-Log laden."
                                               : "\(coverage.period.title) enthält keine Zeilen. Anderen Zeitraum wählen."))
                }
            }
            archiveSection.id("archive")
            exports
            sources
            deleting.id("delete")
        }
    }

    private var archiveSection: some View {
        Section {
            LabeledContent("Zeilen im Archiv", value: "\(coverage.archive.rowCount)")
            if coverage.skippedNoTime > 0 {
                LabeledContent("Ohne Zeit, nicht archiviert", value: "\(coverage.skippedNoTime)")
            }
            NavigationLink("Tage und Monate ansehen") { ArchiveListView() }
        } header: {
            Text("Archiv")
        } footer: {
            Text("Bleibt erhalten, auch wenn Logs auf Tester, Server oder iPhone gelöscht werden. In der Dateien-App unter LoRaScout, Ordner Archiv, je Tag eine CSV.")
        }
    }

    private var sources: some View {
        Section {
            LabeledContent("Tester-Log", value: "\(tester.logRows.count) Zeilen")
            if tester.logState == .loading { LogProgress() }
            if case .failed(let message) = tester.logState { Text(message).foregroundStyle(.red) }
            Button("Neue Zeilen vom Tester laden") { tester.downloadLog() }
                .disabled(tester.link != .ready || tester.logState == .loading)
            Button("Tester-Log komplett neu laden") { tester.downloadLog(fromStart: true) }
                .disabled(tester.link != .ready || tester.logState == .loading)

            LabeledContent("Coverage-Log", value: coverage.loadedAt.text { $0.germanText })
            if let last = coverage.result?.lastServerTime { LabeledContent("Letzter Eintrag", value: "\(last) UTC") }
            if let error = coverage.error { Text(error).foregroundStyle(.red) }
            Button(coverage.loading ? "Lädt …" : "Coverage-Log vom Server laden") {
                Task { await coverage.fetch() }
            }
            .disabled(coverage.loading)
            Button("Coverage-Log aus Datei importieren") { importing = true }
        } header: {
            Text("Daten")
        } footer: {
            Text("Das Coverage-Log kommt nur im Heim-WLAN vom Server und bleibt danach auf dem iPhone. Server und Token stehen unter Konfig.")
        }
    }

    private enum DeleteTarget: Identifiable, Equatable {
        case app, tester, server, archivePeriod(String), archiveAll
        var id: String { title }

        var title: String {
            switch self {
            case .app: "Daten auf dem iPhone löschen?"
            case .tester: "Log auf dem Tester löschen?"
            case .server: "Logs auf dem Server löschen?"
            case .archivePeriod(let title): "\(title) aus dem Archiv löschen?"
            case .archiveAll: "Ganzes Archiv löschen?"
            }
        }

        var message: String {
            switch self {
            case .app: "Tester-Log und Coverage-Log verschwinden aus der App. Archiv, Tester und Server behalten ihre Daten."
            case .tester: "Vorher werden neue Zeilen geladen und archiviert. Dann werden fieldlog.csv auf der SD-Karte und die Kopie in der App gelöscht. Klappt das Archivieren nicht, bleibt alles erhalten."
            case .server: "Vorher werden die Logs geladen und archiviert. Dann werden Coverage-Log und hochgeladenes Tester-Log im ioBroker gelöscht. Klappt das Archivieren nicht, bleibt alles erhalten."
            case .archivePeriod, .archiveAll: "Diese Zeilen sind dann auch in der Dateien-App weg und kommen nicht zurück, auch nicht aus Logs, die noch auf dem Tester liegen."
            }
        }
    }

    private func delete(_ target: DeleteTarget) {
        switch target {
        case .app:
            tester.clearLocalLog()
            coverage.deleteLocal()
        case .tester: Task { await deleteOnTester() }
        case .server: Task { await deleteOnServer() }
        case .archivePeriod: coverage.deleteArchive(coverage.period)
        case .archiveAll:
            coverage.deleteArchive(Period(kind: .all, anchor: coverage.period.anchor))
            coverage.selectKind(.all)
        }
    }

    /// Takes in what the tester still holds. Only works when connected, otherwise it stays with what the iPhone has.
    private func archiveFirst() async throws {
        if tester.link == .ready {
            guard await tester.downloadLogAndWait() else { throw ArchiveError.logDownload }
            coverage.update(device: tester.logData)
        }
        try coverage.archiveNow()
    }

    private func deleteOnTester() async {
        archiving = true
        defer { archiving = false }
        coverage.clearError()
        do {
            try await archiveFirst()
            tester.clearDeviceLog()
        } catch {
            coverage.report(error)
        }
    }

    private func deleteOnServer() async {
        archiving = true
        defer { archiving = false }
        coverage.clearError()
        await coverage.fetch()
        guard coverage.error == nil else { return }
        do {
            try await archiveFirst()
            await coverage.deleteOnServer()
        } catch {
            coverage.report(error)
        }
    }

    private var deleting: some View {
        Group {
            Section {
                if coverage.period.kind != .all {
                    Button("\(coverage.period.title) löschen", systemImage: "calendar.badge.minus", role: .destructive) {
                        deleteTarget = .archivePeriod(coverage.period.title)
                    }
                    .disabled(coverage.selected.rows.isEmpty)
                }
                Button("Ganzes Archiv löschen", systemImage: "archivebox", role: .destructive) { deleteTarget = .archiveAll }
                    .disabled(coverage.archive.rowCount == 0)
            } header: {
                Text("Archiv löschen")
            }
            logDeleting
        }
        .confirmationDialog(deleteTarget?.title ?? "", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible, presenting: deleteTarget) { target in
            Button("Löschen", role: .destructive) { delete(target) }
        } message: { target in
            Text(target.message)
        }
    }

    private var logDeleting: some View {
        Section {
            Button("Auf dem iPhone löschen", systemImage: "iphone", role: .destructive) { deleteTarget = .app }
                .disabled(tester.logState == .loading)
            Button("Auf dem Tester löschen", systemImage: "sdcard", role: .destructive) { deleteTarget = .tester }
                .disabled(tester.link != .ready || tester.logState == .loading || tester.clearingDeviceLog || archiving)
            Button("Auf dem Server löschen", systemImage: "server.rack", role: .destructive) { deleteTarget = .server }
                .disabled(coverage.loading || archiving)
            if archiving { Text("Wird vorher archiviert …") }
            if let error = coverage.error { Text(error).foregroundStyle(.red) }
            if let message = tester.clearMessage { Text(message) }
            if let message = coverage.serverMessage { Text(message) }
        } header: {
            Text("Logs löschen")
        } footer: {
            Text("Das Archiv bleibt dabei stehen. Konfiguration, Token und Kopplung bleiben ebenfalls erhalten.")
        }
    }

    private var exports: some View {
        Section("Exportieren") {
            if !coverage.selected.rows.isEmpty {
                ShareLink("Zeitraum als CSV", item: coverage.selectionURL)
            }
            Button("Zeitraum als JPG", systemImage: "photo") { choosingExport = true }
                .disabled(MapContent(coverage: coverage).points.isEmpty)
            if !tester.logRows.isEmpty {
                ShareLink("Rohes Tester-Log (CSV)", item: tester.logURL)
            }
        }
    }
}
