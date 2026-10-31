import MapKit
import SwiftUI

/// Pick section and zoom for the JPG. The map is square like the image, so it shows exactly what gets exported.
struct MapExportView: View {
    let content: MapContent
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var region: MKCoordinateRegion?
    @State private var exporting = false
    @State private var exportFile: ExportFile?
    @State private var exportError: String?

    init(content: MapContent, start: MKCoordinateRegion?) {
        self.content = content
        let first = start ?? MapImage.fittingRegion(content.points)
        _position = State(initialValue: first.map { .region($0) } ?? .automatic)
        _region = State(initialValue: first)
    }

    private func zoom(_ factor: Double) {
        guard var next = region else { return }
        next.span.latitudeDelta = min(next.span.latitudeDelta * factor, 150)
        next.span.longitudeDelta = min(next.span.longitudeDelta * factor, 300)
        position = .region(next)
    }

    private func showAll() {
        guard let all = MapImage.fittingRegion(content.points) else { return }
        position = .region(all)
    }

    private func export() {
        guard let region else { return }
        exporting = true
        exportError = nil
        Task {
            defer { exporting = false }
            do {
                exportFile = ExportFile(url: try await content.exportImage(region: region))
            } catch {
                exportError = "Kartenbild konnte nicht erstellt werden. Internet nötig für die Kartenkacheln."
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Map(position: $position) {
                    ForEach(content.points) { point in
                        Annotation("", coordinate: point.coordinate) {
                            Circle()
                                .fill(point.color)
                                .stroke(.white, lineWidth: 1)
                                .frame(width: 12, height: 12)
                        }
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { region = $0.region }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button("Verkleinern", systemImage: "minus.magnifyingglass") { zoom(2) }
                        .labelStyle(.iconOnly)
                    Button("Vergrößern", systemImage: "plus.magnifyingglass") { zoom(0.5) }
                        .labelStyle(.iconOnly)
                    Button("Alle Punkte", systemImage: "arrow.up.left.and.arrow.down.right") { showAll() }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Text("Karte verschieben und mit zwei Fingern zoomen. Das Bild zeigt genau diesen Ausschnitt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let exportError {
                    Text(exportError).font(.footnote).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Button {
                    export()
                } label: {
                    Text(exporting ? "Bild wird erstellt …" : "Als JPG exportieren")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(exporting || region == nil)
            }
            .padding()
            .navigationTitle("Kartenausschnitt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .sheet(item: $exportFile) { ShareSheet(url: $0.url) }
        }
    }
}
