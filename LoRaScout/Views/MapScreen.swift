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
}

/// What map and JPG show for the chosen period: reception if known, otherwise what the device logged.
struct MapContent {
    var points: [MapPoint]
    var legend: [(text: String, color: Color)]
    var summary: String
    var periodTitle: String

    @MainActor init(coverage: CoverageStore) {
        let rows = coverage.selected.rows
        periodTitle = coverage.period.title
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
    }

    func exportImage(region: MKCoordinateRegion) async throws -> URL {
        let items = legend.map { MapImage.LegendItem(text: $0.text, color: UIColor($0.color)) }
        return try await MapImage.render(region: region, points: points, legend: items, summary: summary, period: periodTitle)
    }
}

struct MapScreen: View {
    @Environment(FieldTester.self) private var tester
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
                                .stroke(.white, lineWidth: 1)
                                .frame(width: 16, height: 16)
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
                        Button("Log vom Tester laden") { tester.downloadLog() }
                            .buttonStyle(.borderedProminent)
                            .disabled(tester.link != .ready)
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
                    Button("Log laden", systemImage: "arrow.down.circle") { tester.downloadLog() }
                        .disabled(tester.link != .ready || tester.logState == .loading)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ausschnitt als JPG", systemImage: "square.and.arrow.up") { choosingExport = true }
                        .disabled(content.points.isEmpty)
                }
            }
            .sheet(isPresented: $choosingExport) { MapExportView(content: content, start: region) }
        }
    }

    private func footer(_ content: MapContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if tester.logState == .loading { LogProgress() }
            Label("Zeitraum: \(content.periodTitle)", systemImage: "calendar").fontWeight(.semibold)
            if let selected {
                ForEach(selected.lines, id: \.self) { Text($0).fontWeight(.semibold) }
            } else {
                Text(content.summary).fontWeight(.semibold)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legend(content) }
                VStack(alignment: .leading, spacing: 4) { legend(content) }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func legend(_ content: MapContent) -> some View {
        ForEach(content.legend, id: \.text) { item in
            Label { Text(item.text) } icon: { Image(systemName: "circle.fill").foregroundStyle(item.color) }
        }
    }
}

struct LogProgress: View {
    @Environment(FieldTester.self) private var tester

    var body: some View {
        if let total = tester.logTotal, total > 0 {
            ProgressView("Log wird geladen", value: Double(min(tester.logReceived, total)), total: Double(total))
        } else {
            ProgressView("Log wird geladen")
        }
    }
}
