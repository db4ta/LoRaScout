import SwiftUI

extension EventSeverity {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}

/// Grouped surface used outside of forms.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

/// Symbol in the state color, text in the normal color so it keeps its contrast.
struct StatusLabel: View {
    var text: String
    var symbol: String
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).foregroundStyle(.primary)
        }
    }
}

struct StatusTile: View {
    var title: String
    var value: String
    var symbol: String
    var color: Color

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        layout {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct EventRow: View {
    var event: TesterEvent
    /// Names the tester when several are active.
    var device: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.severity.symbol)
                .foregroundStyle(event.kind.severity.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let device { Text(device).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(event.kind.title).font(.subheadline)
                if let hint = event.kind.deviceHint(profile: event.profile) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
                Text(event.date, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Appears on every tab when the tester gives its success or failure signal.
struct EventToast: View {
    var event: TesterEvent
    var device: String
    var dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.kind.severity.symbol)
                    .font(.title2)
                    .foregroundStyle(event.kind.severity.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(event.kind.title).font(.headline)
                    if let hint = event.kind.deviceHint(profile: event.profile) {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(.primary)
            .padding()
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(event.kind.severity.color, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .accessibilityHint("Zum Schließen tippen")
    }
}

extension TesterSession.Link {
    var title: String {
        switch self {
        case .starting: "Bluetooth startet"
        case .bluetoothOff: "Bluetooth aus"
        case .unauthorized: "Kein Zugriff"
        case .unsupported: "Kein Bluetooth"
        case .searching: "Suche Tester"
        case .connecting: "Verbindet"
        case .pairing: "Kopplung läuft"
        case .pairingFailed, .bondLost: "Kopplung gestört"
        case .ready: "Verbunden"
        case .choosing: "Kein Tester gewählt"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .choosing: "list.bullet.circle.fill"
        case .searching, .connecting, .pairing, .starting: "arrow.triangle.2.circlepath.circle.fill"
        default: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .searching, .connecting, .pairing, .starting, .choosing: .orange
        default: .red
        }
    }

    /// What to do in this state, nil when nothing is needed.
    var help: String? {
        switch self {
        case .starting: "Bluetooth wird vorbereitet."
        case .bluetoothOff: "Bluetooth im Kontrollzentrum einschalten."
        case .unauthorized: "In den iOS-Einstellungen bei LoRaScout den Bluetooth-Zugriff erlauben."
        case .unsupported: "Dieses Gerät hat kein Bluetooth LE, die Verbindung zum Tester geht hier nicht."
        case .searching: "Tester einschalten und in der Nähe halten. Im WLAN-Portal ist Bluetooth aus."
        case .connecting: "Verbindung wird aufgebaut. Hängt das länger, den Core2 neu starten."
        case .pairing: "Den 6-stelligen Code vom Display des Core2 im iOS-Dialog eingeben. Kommt kein Dialog, den Core2 neu starten."
        case .pairingFailed:
            "Kopplung nicht abgeschlossen. Core2 neu starten und „Erneut“ tippen. Hilft das nicht: iOS-Einstellungen, Bluetooth, FieldTester, „Dieses Gerät ignorieren“, dann neu koppeln."
        case .bondLost:
            "Der Tester kennt dieses iPhone nicht mehr. iOS-Einstellungen, Bluetooth, FieldTester, „Dieses Gerät ignorieren“. Danach Core2 neu starten und App neu öffnen."
        case .ready: nil
        case .choosing: "Auf Home „Gerät wählen“ tippen und einen Tester aussuchen."
        }
    }
}

/// Connection state above every screen, hidden once the device is ready.
struct LinkBanner: View {
    @Environment(TesterCentral.self) private var central
    private var tester: TesterSession { central.focused }

    /// With several testers the banner says which one it is about.
    private var title: String {
        central.isMulti && central.radio == nil ? "\(tester.shortTitle): \(tester.link.title)" : tester.link.title
    }

    var body: some View {
        if let help = tester.link.help {
            VStack(alignment: .leading, spacing: 6) {
                StatusLabel(text: title, symbol: tester.link.symbol, color: tester.link.color)
                    .font(.subheadline.weight(.semibold))
                Text(help).font(.footnote).fixedSize(horizontal: false, vertical: true)
                if tester.link == .pairingFailed {
                    Button("Erneut") { tester.retryPairing() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Form with the connection banner on top.
struct Screen<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            Form { content }
                #if DEBUG
                .defaultScrollAnchor(DemoData.scrollToBottom ? .bottom : nil, for: .initialOffset)
                #endif
                .navigationTitle(title)
                .safeAreaInset(edge: .top, spacing: 0) { LinkBanner() }
                .scrollDismissesKeyboard(.immediately)
                .toolbar {
                    // The number pad has no return key, so this is the way out of a field.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Fertig") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                            to: nil, from: nil, for: nil)
                        }
                    }
                }
        }
    }
}

extension Date {
    /// The app has no German localization yet, so the format is fixed instead of following the bundle language.
    var germanText: String {
        formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "de_DE")))
    }
}

extension Optional {
    func text(_ format: (Wrapped) -> String) -> String { map(format) ?? "–" }
}
