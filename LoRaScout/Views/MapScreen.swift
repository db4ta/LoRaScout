import MapKit
import SwiftUI

private extension LogStatus {
    var color: Color {
        switch self {
        case .ok: .green
        case .sent: .blue
        case .noAnswer: .red
        case .txFail: .orange
        case .test, .other: .gray
        }
    }

    var text: String {
        switch self {
        case .ok: "Antwort erhalten"
        case .sent: "Gesendet"
        case .noAnswer: "Keine Antwort"
        case .txFail: "Senden fehlgeschlagen"
        case .test: "Test"
        case .other(let raw): raw
        }
    }
}

private extension Received {
    var color: Color {
        switch self {
        case .yes: .green
        case .no: .red
        case .unknown: .gray
        }
    }

    var text: String {
        switch self {
        case .yes: "Empfangen"
        case .no: "Verloren"
        case .unknown: "Unbekannt"
        }
    }
}

struct MapPoint: Identifiable {
    var id: Int
    var coordinate: CLLocationCoordinate2D
    var color: Color
    var lines: [String]
    /// Ring in the tester's colour when several testers share the map.
    var ring: Color?
}

/// What map and JPG show for the chosen period: reception if known, otherwise what the device logged.
struct MapContent {
    var points: [MapPoint]
    var legend: [(text: String, color: Color)]
    /// Ring colours per tester, empty unless "Alle" shows more than one.
    var devices: [(text: String, color: Color)] = []
    var summary: String
    var periodTitle: String

    @MainActor init(coverage: CoverageStore) {
        let rows = coverage.selected.rows
        periodTitle = coverage.period.title
        if let filter = coverage.deviceFilter { periodTitle += " · " + DeviceTags.label(filter) }
        if rows.contains(where: { $0.received != .unknown }), let stats = coverage.selectedStats {
            points = rows.compactMap { row in
                guard let lat = row.latitude, let lng = row.longitude else { return nil }
                var lines = ["\(row.time) UTC: \(row.received.text)"]
                if row.received == .yes {
                    lines.append("\(row.gw) GW, RSSI \(row.rssi) dBm, SNR \(row.snr) dB, SF \(row.sf)")
                }
                return MapPoint(id: row.id, coordinate: .init(latitude: lat, longitude: lng),
                                color: row.received.color, lines: lines)
            }
            legend = [Received.yes, .no, .unknown].map { ($0.text, $0.color) }
            summary = "Empfangen \(stats.received) · Verloren \(stats.lost) · Unbekannt \(stats.unknown)"
        } else {
            points = rows.compactMap { row in
                guard let lat = row.latitude, let lng = row.longitude else { return nil }
                let status = LogStatus(row.status)
                var lines = ["\(row.time) UTC: \(status.text)"]
                if !row.rssi.isEmpty { lines.append("RSSI \(row.rssi) dBm, SNR \(row.snr) dB") }
                return MapPoint(id: row.id, coordinate: .init(latitude: lat, longitude: lng),
                                color: status.color, lines: lines)
            }
            legend = [LogStatus.ok, .sent, .noAnswer, .txFail].map { ($0.text, $0.color) }
            summary = "\(rows.count) Zeilen"
        }
        let shown = Set(rows.map(\.device))
        guard coverage.deviceFilter == nil, shown.count > 1 else { return }
        let all = coverage.deviceTags
        devices = all.filter(shown.contains).map { (DeviceTags.label($0), DeviceTags.color($0, among: all)) }
        // Points keep the row index as id, so the row's tester is at hand.
        points = points.map { point in
            var copy = point
            guard rows.indices.contains(point.id) else { return copy }
            let tag = rows[point.id].device
            copy.ring = DeviceTags.color(tag, among: all)
            copy.lines.insert(DeviceTags.label(tag), at: 0)
            return copy
        }
    }

    func exportImage(region: MKCoordinateRegion) async throws -> URL {
        let items = legend.map { MapImage.LegendItem(text: $0.text, color: UIColor($0.color)) }
        let rings = devices.map { MapImage.LegendItem(text: $0.text, color: UIColor($0.color)) }
        return try await MapImage.render(region: region, points: points, legend: items, devices: rings,
                                         summary: summary, period: periodTitle)
    }
}

struct MapScreen: View {
    @Environment(TesterCentral.self) private var central
    @Environment(CoverageStore.self) private var coverage
    @State private var selected: MapPoint?
    @State private var region: MKCoordinateRegion?
    @State private var choosingExport = false

    var body: some View {
        let content = MapContent(coverage: coverage)
        NavigationStack {
            Map {
                ForEach(content.points) { point in
                    Annotation("", coordinate: point.coordinate) {
                        Button {
                            selected = point
                        } label: {
                            Circle()
                                .fill(point.color)
                                .stroke(point.ring ?? .white, lineWidth: point.ring == nil ? 1 : 3)
                                .frame(width: point.ring == nil ? 16 : 18, height: point.ring == nil ? 16 : 18)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(point.lines.joined(separator: ", "))
                    }
                }
            }
            .onMapCameraChange(frequency: .onEnd) { region = $0.region }
            .overlay {
                if content.points.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Punkte", systemImage: "map")
                    } description: {
                        Text("\(content.periodTitle): keine Punkte. Sie kommen aus dem Log des Testers, Zeilen ohne GPS-Fix haben keine Position. Den Zeitraum wählst du in Auswertung.")
                    } actions: {
                        Button(central.isMulti ? "Logs der Tester laden" : "Log vom Tester laden") { downloadLogs() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canDownload)
                    }
                    .background(.regularMaterial)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { LinkBanner() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !content.points.isEmpty { footer(content) }
            }
            .navigationTitle("Karte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Log laden", systemImage: "arrow.down.circle") { downloadLogs() }
                        .disabled(!canDownload)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if coverage.deviceTags.count > 1 {
                        Menu {
                            DeviceFilterPicker()
                        } label: {
                            Label("Tester", systemImage: coverage.deviceFilter == nil
                                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ausschnitt als JPG", systemImage: "square.and.arrow.up") { choosingExport = true }
                        .disabled(content.points.isEmpty)
                }
            }
            .sheet(isPresented: $choosingExport) { MapExportView(content: content, start: region) }
        }
    }

    /// Every connected tester fetches what is new.
    private func downloadLogs() {
        for session in central.sessions { session.downloadLog() }
    }

    private var canDownload: Bool {
        central.sessions.contains { $0.link == .ready && $0.logState != .loading }
    }

    private func footer(_ content: MapContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(central.sessions.filter { $0.logState == .loading }) { LogProgress(tester: $0) }
            Label("Zeitraum: \(content.periodTitle)", systemImage: "calendar").fontWeight(.semibold)
            if let selected {
                ForEach(selected.lines, id: \.self) { Text($0).fontWeight(.semibold) }
            } else {
                Text(content.summary).fontWeight(.semibold)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legend(content.legend) }
                VStack(alignment: .leading, spacing: 4) { legend(content.legend) }
            }
            if !content.devices.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { legend(content.devices, ring: true) }
                    VStack(alignment: .leading, spacing: 4) { legend(content.devices, ring: true) }
                }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func legend(_ items: [(text: String, color: Color)], ring: Bool = false) -> some View {
        ForEach(items, id: \.text) { item in
            Label { Text(item.text) } icon: {
                Image(systemName: ring ? "circle" : "circle.fill").fontWeight(ring ? .heavy : .regular).foregroundStyle(item.color)
            }
        }
    }
}

struct LogProgress: View {
    @Environment(TesterCentral.self) private var central
    var tester: TesterSession

    private var title: String { central.isMulti ? "Log von \(tester.shortTitle)" : "Log wird geladen" }

    var body: some View {
        if let total = tester.logTotal, total > 0 {
            ProgressView(title, value: Double(min(tester.logReceived, total)), total: Double(total))
        } else {
            ProgressView(title)
        }
    }
}
