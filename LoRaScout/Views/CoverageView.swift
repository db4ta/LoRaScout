import SwiftUI
import UniformTypeIdentifiers

/// Data sources, evaluation and all exports in one place.
struct CoverageView: View {
    @Environment(TesterCentral.self) private var central
    @Environment(CoverageStore.self) private var coverage
    @State private var importing = false
    @State private var choosingExport = false
    @State private var deleteTarget: DeleteTarget?
    @State private var archiving = false

    /// "Auf dem Tester löschen" acts on the tester chosen in Netz and Konfig.
    private var tester: TesterSession { central.focused }
    private var anyLoading: Bool { central.sessions.contains { $0.logState == .loading } }
    private var canDownload: Bool { central.sessions.contains { $0.link == .ready } && !anyLoading }
    private var filterText: String { coverage.deviceFilter.map { " von " + DeviceTags.label($0) } ?? "" }
    /// The LoRaScout Server hides one tester's rows, the ioBroker script deletes everything.
    private var serverPerDevice: Bool { coverage.endpoint?.kind.perDevice ?? false }

    /// Name of the tester with this DevEUI, else the DevEUI.
    private func testerTitle(_ devEUI: String) -> String {
        central.known.first { $0.devEUI == devEUI }.map { KnownDevice.shortTitle($0.title) } ?? devEUI
    }

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
                DeviceFilterPicker()
            } footer: {
                Text(coverage.deviceTags.count > 1
                     ? "Statistik, Karte und Exporte folgen diesem Zeitraum und Tester. Tage zählen nach Ortszeit."
                     : "Statistik, Karte und Exporte folgen diesem Zeitraum. Tage zählen nach Ortszeit.")
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
                let trend = coverage.archive.trend(for: coverage.period, device: coverage.deviceFilter)
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
            ForEach(central.sessions) { session in
                LabeledContent(central.isMulti ? "Log \(session.shortTitle)" : "Tester-Log", value: "\(session.logRows.count) Zeilen")
                if session.logState == .loading { LogProgress(tester: session) }
                if case .failed(let message) = session.logState {
                    Text(central.isMulti ? "\(session.shortTitle): \(message)" : message).foregroundStyle(.red)
                }
            }
            if central.sessions.isEmpty { LabeledContent("Tester-Log", value: "kein Tester aktiv") }
            Button(central.isMulti ? "Neue Zeilen von allen Testern laden" : "Neue Zeilen vom Tester laden") {
                for session in central.sessions { session.downloadLog() }
            }
            .disabled(!canDownload)
            Button(central.isMulti ? "Alle Tester-Logs komplett neu laden" : "Tester-Log komplett neu laden") {
                for session in central.sessions { session.downloadLog(fromStart: true) }
            }
            .disabled(!canDownload)

            LabeledContent("Coverage-Log", value: coverage.loadedAt.text { $0.germanText })
            if let last = coverage.result?.lastServerTime { LabeledContent("Letzter Eintrag", value: "\(last) UTC") }
            if let endpoint = coverage.endpoint { LabeledContent("Server", value: endpoint.kind.title) }
            ForEach(coverage.deviceCounts.keys.sorted(), id: \.self) { devEUI in
                LabeledContent("Server \(testerTitle(devEUI))", value: "\(coverage.deviceCounts[devEUI] ?? 0) Uplinks")
            }
            if let error = coverage.error { Text(error).foregroundStyle(.red) }
            Button(coverage.loading ? "Lädt …" : "Coverage-Log vom Server laden") {
                Task { await coverage.fetch() }
            }
            .disabled(coverage.loading)
            Button("Coverage-Log aus Datei importieren") { importing = true }
        } header: {
            Text("Daten")
        } footer: {
            Text("Das Coverage-Log kommt nur im Heim-WLAN vom Server und bleibt danach auf dem iPhone. Server und Token stehen unter Konfig. Der LoRaScout Server liefert die Uplinks je Tester (DevEUI), so mischen sich Core2 und Tracker nie.")
        }
    }

    private enum DeleteTarget: Identifiable, Equatable {
        case app, tester(String), server, serverDevice(String), archivePeriod(String), archiveAll(String)
        var id: String { title }

        var title: String {
            switch self {
            case .app: "Daten auf dem iPhone löschen?"
            case .tester(let name): "Log auf \(name) löschen?"
            case .server: "Logs auf dem Server löschen?"
            case .serverDevice(let name): "\(name) auf dem Server ausblenden?"
            case .archivePeriod(let title): "\(title) aus dem Archiv löschen?"
            case .archiveAll(let scope): scope.isEmpty ? "Ganzes Archiv löschen?" : "Alles\(scope) aus dem Archiv löschen?"
            }
        }

        var message: String {
            switch self {
            case .app: "Tester-Logs und Coverage-Log verschwinden aus der App. Archiv, Tester und Server behalten ihre Daten."
            case .tester: "Vorher werden neue Zeilen geladen und archiviert. Dann werden fieldlog.csv auf der SD-Karte und die Kopie in der App gelöscht. Klappt das Archivieren nicht, bleibt alles erhalten."
            case .server: "Vorher werden die Logs geladen und archiviert. Dann werden Coverage-Log und hochgeladenes Tester-Log im ioBroker gelöscht. Klappt das Archivieren nicht, bleibt alles erhalten."
            case .serverDevice: "Vorher werden die Logs geladen und archiviert. Dann liefert der LoRaScout Server die bisherigen Uplinks und das hochgeladene Tester-Log dieses Testers nicht mehr an App und Tester. In seiner Datenbank bleiben sie erhalten (Weboberfläche, Exporte), andere Tester sind nicht betroffen."
            case .archivePeriod, .archiveAll: "Diese Zeilen sind dann auch in der Dateien-App weg und kommen nicht zurück, auch nicht aus Logs, die noch auf dem Tester liegen."
            }
        }
    }

    private func delete(_ target: DeleteTarget) {
        switch target {
        case .app:
            for session in central.sessions { session.clearLocalLog() }
            coverage.deleteLocal()
        case .tester: Task { await deleteOnTester() }
        case .server, .serverDevice: Task { await deleteOnServer() }
        case .archivePeriod: coverage.deleteArchive(coverage.period)
        case .archiveAll:
            coverage.deleteArchive(Period(kind: .all, anchor: coverage.period.anchor))
            coverage.selectKind(.all)
        }
    }

    /// Takes in what the testers still hold. Only connected ones, the others stay with what the iPhone has.
    private func archiveFirst() async throws {
        for session in central.sessions where session.link == .ready {
            guard await session.downloadLogAndWait() else { throw ArchiveError.logDownload }
        }
        coverage.update(logs: central.deviceLogs)
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
            await coverage.deleteOnServer(devEUI: tester.known?.devEUI, name: central.isMulti ? tester.shortTitle : tester.title)
        } catch {
            coverage.report(error)
        }
    }

    private var deleting: some View {
        Group {
            Section {
                if coverage.period.kind != .all {
                    Button("\(coverage.period.title)\(filterText) löschen", systemImage: "calendar.badge.minus", role: .destructive) {
                        deleteTarget = .archivePeriod(coverage.period.title + filterText)
                    }
                    .disabled(coverage.selected.rows.isEmpty)
                }
                Button(filterText.isEmpty ? "Ganzes Archiv löschen" : "Alles\(filterText) löschen", systemImage: "archivebox",
                       role: .destructive) { deleteTarget = .archiveAll(filterText) }
                    .disabled(coverage.archive.rowCount(device: coverage.deviceFilter) == 0)
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
                .disabled(anyLoading)
            Button(central.isMulti ? "Auf \(tester.shortTitle) löschen" : "Auf dem Tester löschen", systemImage: "sdcard",
                   role: .destructive) { deleteTarget = .tester(central.isMulti ? tester.shortTitle : "dem Tester") }
                .disabled(tester.link != .ready || anyLoading || tester.clearingDeviceLog || archiving)
            Button(serverPerDevice ? (central.isMulti ? "\(tester.shortTitle) auf dem Server ausblenden" : "Auf dem Server ausblenden")
                                   : "Auf dem Server löschen", systemImage: "server.rack", role: .destructive) {
                deleteTarget = serverPerDevice ? .serverDevice(central.isMulti ? tester.shortTitle : "Tester") : .server
            }
            .disabled(coverage.loading || archiving)
            if archiving { Text("Wird vorher archiviert …") }
            if let error = coverage.error { Text(error).foregroundStyle(.red) }
            if let message = tester.clearMessage { Text(message) }
            if let message = coverage.serverMessage { Text(message) }
        } header: {
            Text("Logs löschen")
        } footer: {
            Text((central.isMulti
                 ? "Löschen auf dem Tester und Ausblenden auf dem LoRaScout Server gelten für den in Netz und Konfig gewählten. Das Archiv bleibt dabei stehen. Konfiguration, Token und Kopplung bleiben ebenfalls erhalten."
                 : "Das Archiv bleibt dabei stehen. Konfiguration, Token und Kopplung bleiben ebenfalls erhalten.")
                + (serverPerDevice ? " Der LoRaScout Server löscht nichts, er blendet die Daten nur für App und Tester aus und behält sie in seinem eigenen Archiv." : ""))
        }
    }

    private var exports: some View {
        Section("Exportieren") {
            if !coverage.selected.rows.isEmpty {
                ShareLink("Zeitraum als CSV", item: DatedCSV(source: coverage.selectionURL, name: "Zeitraum-\(coverage.selectionSlug)"),
                          preview: SharePreview("Zeitraum als CSV"))
            }
            Button("Zeitraum als JPG", systemImage: "photo") { choosingExport = true }
                .disabled(MapContent(coverage: coverage).points.isEmpty)
            ForEach(central.sessions.filter { !$0.logRows.isEmpty }) { session in
                let title = central.isMulti ? "Rohes Log \(session.shortTitle) (CSV)" : "Rohes Tester-Log (CSV)"
                ShareLink(title, item: DatedCSV(source: session.logURL,
                                                name: session.deviceTag.isEmpty ? "Tester-Log" : "Tester-Log-\(session.deviceTag)"),
                          preview: SharePreview(title))
            }
            if coverage.hasCoverage {
                ShareLink("Rohes Server-Log (CSV)", item: DatedCSV(source: coverage.coverageURL, name: "Server-Log"),
                          preview: SharePreview("Rohes Server-Log"))
            }
        }
    }
}
