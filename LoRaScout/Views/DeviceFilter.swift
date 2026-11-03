import SwiftUI

/// Names and colours of testers in archive, map and exports, by the Device tag of the rows.
enum DeviceTags {
    /// Apart from the reception colours green, red, grey, blue and orange.
    private static let palette: [Color] = [.purple, .cyan, .pink, .brown, .indigo, .yellow]

    static func label(_ tag: String) -> String { tag.isEmpty ? "Ohne Namen" : KnownDevice.shortTitle(tag) }

    /// Stable per tester as long as the archive holds the same testers.
    static func color(_ tag: String, among tags: [String]) -> Color {
        palette[(tags.firstIndex(of: tag) ?? 0) % palette.count]
    }
}

/// Alle or one tester, for Karte, Auswertung and the archive list. Only there with more than one tester in the archive.
struct DeviceFilterPicker: View {
    @Environment(CoverageStore.self) private var coverage

    var body: some View {
        @Bindable var coverage = coverage
        if coverage.deviceTags.count > 1 {
            Picker("Tester", selection: $coverage.deviceFilter) {
                Text("Alle").tag(String?.none)
                ForEach(coverage.deviceTags, id: \.self) { Text(DeviceTags.label($0)).tag(String?.some($0)) }
            }
            .frame(minHeight: 44)
        }
    }
}
