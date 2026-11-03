import SwiftUI

/// Short state texts shared by the single view and the cards of several testers.
enum TesterStateText {
    static func gps(_ status: DeviceStatus?) -> (text: String, symbol: String, color: Color) {
        guard let status else { return ("Unbekannt", "questionmark.circle.fill", .secondary) }
        if status.flags.contains(.gnssStandby) {
            return status.flags.contains(.gnssData) ? ("GPS wacht auf", "location.circle", .orange)
                                                    : ("GPS im Standby", "moon.fill", .blue)
        }
        if status.flags.contains(.fix) { return ("Fix, \(status.sats) Sat.", "location.fill", .green) }
        if status.flags.contains(.gnssData) { return ("Kein Fix", "location.slash.fill", .red) }
        return ("Keine Daten", "exclamationmark.triangle.fill", .red)
    }

    static func lora(_ status: DeviceStatus?) -> (text: String, symbol: String, color: Color) {
        switch status?.join {
        case .joined:
            // The AT firmware doesn't report TX and RX windows, so TX covers the whole send including its RX windows.
            if status?.flags.contains(.awaitingNetwork) == true {
                ("Angemeldet\nRX, wartet auf Antwort", "arrow.down.circle.fill", .blue)
            } else if status?.flags.contains(.loraBusy) == true {
                ("Angemeldet\nTX, sendet", "antenna.radiowaves.left.and.right", .orange)
            } else {
                ("Angemeldet\nBereit", "checkmark.circle.fill", .green)
            }
        case .joining: ("Join läuft", "arrow.triangle.2.circlepath.circle.fill", .orange)
        case .failed: ("Fehlgeschlagen", "xmark.circle.fill", .red)
        case .idle: ("Nicht angemeldet", "minus.circle.fill", .orange)
        case nil: ("Unbekannt", "questionmark.circle.fill", .secondary)
        }
    }
}

struct HomeView: View {
    @Environment(TesterCentral.self) private var central
    @State private var choosingDevice = false

    private var tester: TesterSession { central.focused }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    deviceButton
                    if central.isMulti {
                        ForEach(central.sessions) { TesterCard(session: $0) }
                    } else {
                        tiles
                        MeasurementCard(tester: tester)
                        if let status = tester.status { DeviceCard(tester: tester, status: status) }
                    }
                    recentEvents
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(central.isMulti ? "\(central.sessions.count) Tester" : tester.deviceName ?? "LoRaScout")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Each card shows its own connection, the banner only Bluetooth itself.
                if !central.isMulti || central.radio != nil { LinkBanner() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !central.isMulti { SendBar(tester: tester) }
            }
            .sheet(isPresented: $choosingDevice) {
                NavigationStack { DeviceListView() }
            }
            // With nothing remembered the list comes up by itself.
            .onChange(of: tester.link == .choosing, initial: true) { _, choosing in
                if choosing { choosingDevice = true }
            }
            #if DEBUG
            .onAppear { if DemoData.showDevices { choosingDevice = true } }
            #endif
        }
    }

    /// Current testers, tapping opens the list to add or pick one.
    private var deviceButton: some View {
        Button { choosingDevice = true } label: {
            HStack {
                if central.isMulti {
                    Label("\(central.sessions.count) Tester aktiv", systemImage: "square.stack.3d.up.fill").font(.headline)
                } else if let current = tester.known {
                    DeviceRow(name: tester.deviceName ?? current.title, kind: tester.kind,
                              detail: tester.link.title, detailColor: tester.link.color)
                } else {
                    Label("Kein Tester gewählt", systemImage: "list.bullet.circle").font(.headline)
                }
                Spacer()
                Text("Geräte").font(.subheadline)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Öffnet die Liste der Tester")
    }

    private var tiles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { tileContent }.fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) { tileContent }
        }
    }

    @ViewBuilder private var tileContent: some View {
        let link = tester.link
        let gps = TesterStateText.gps(tester.status), lora = TesterStateText.lora(tester.status)
        StatusTile(title: "Verbindung", value: link.title, symbol: link.symbol, color: link.color)
        StatusTile(title: "GPS", value: gps.text, symbol: gps.symbol, color: gps.color)
        StatusTile(title: "LoRaWAN", value: lora.text, symbol: lora.symbol, color: lora.color)
    }

    private var recentEvents: some View {
        let recent = central.isMulti ? Array(EventsView.all(central).prefix(3)) : tester.events.prefix(3).map { (nil, $0) }
        return Card {
            HStack {
                Text("Letzte Ereignisse").font(.headline)
                Spacer()
                NavigationLink("Alle") { EventsView() }
                    .frame(minHeight: 44)
            }
            if recent.isEmpty {
                Text("Noch nichts passiert. Der Verlauf beginnt mit der Verbindung zum Tester.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(recent, id: \.1.id) { EventRow(event: $0.1, device: $0.0) }
        }
    }
}

/// One of several active testers: state, last answer and its own SEND NOW. Tapping the name selects it for Netz and Konfig.
private struct TesterCard: View {
    @Environment(TesterCentral.self) private var central
    var session: TesterSession

    private var measurement: (text: String, symbol: String, color: Color) {
        guard let status = session.status else { return ("Keine Live-Daten", "minus.circle", .secondary) }
        if status.flags.contains(.noNetworkAnswer) { return ("Keine Netzantwort", EventSeverity.failure.symbol, .red) }
        guard let count = status.gwCount, let age = status.feedbackAge else {
            return ("Noch keine Messung", "minus.circle", .secondary)
        }
        let gateways = count == 1 ? "1 Gateway" : "\(count) Gateways"
        return ("\(gateways) · RSSI \(signed(status.gwRssi)) dBm · SNR \(signed(status.gwSnr)) dB · vor \(age) s",
                "antenna.radiowaves.left.and.right", SignalQuality.rate(rssi: status.gwRssi, snr: status.gwSnr).color)
    }

    var body: some View {
        let selected = central.focusedID == session.id
        let gps = TesterStateText.gps(session.status), lora = TesterStateText.lora(session.status)
        let link = session.link
        Card {
            Button { central.focus(session.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: session.kind.symbol).font(.title3).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).font(.headline)
                        StatusLabel(text: link.title, symbol: link.symbol, color: link.color).font(.caption)
                    }
                    Spacer()
                    if selected {
                        Text("Gewählt").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Wählt diesen Tester für Netz und Konfig")
            if let help = link.help {
                Text(help).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if link == .pairingFailed {
                    Button("Erneut") { session.retryPairing() }.buttonStyle(.bordered)
                }
            } else {
                StatusLabel(text: gps.text, symbol: gps.symbol, color: gps.color).font(.subheadline)
                StatusLabel(text: lora.text.replacingOccurrences(of: "\n", with: ", "), symbol: lora.symbol, color: lora.color)
                    .font(.subheadline)
                StatusLabel(text: measurement.text, symbol: measurement.symbol, color: measurement.color)
                    .font(.subheadline)
                SendButton(tester: session, compact: true)
            }
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 16).stroke(.tint, lineWidth: 2) }
        }
    }
}

/// The last network answer, the main result of a test.
private struct MeasurementCard: View {
    var tester: TesterSession

    var body: some View {
        Card {
            Text("Letzte Messung").font(.headline)
            if let status = tester.status, status.flags.contains(.noNetworkAnswer) {
                StatusLabel(text: "Keine Netzantwort", symbol: EventSeverity.failure.symbol, color: .red)
                    .font(.title2.bold())
                Text("Am letzten SEND NOW kam nichts zurück.").font(.subheadline).foregroundStyle(.secondary)
            } else if let status = tester.status, let count = status.gwCount, let age = status.feedbackAge {
                let quality = SignalQuality.rate(rssi: status.gwRssi, snr: status.gwSnr)
                Text(count == 1 ? "1 Gateway" : "\(count) Gateways").font(.largeTitle.bold())
                Label("Signal: \(quality.title)", systemImage: "cellularbars")
                    .font(.title3.weight(.semibold))
                Text("RSSI \(signed(status.gwRssi)) dBm · SNR \(signed(status.gwSnr)) dB · vor \(age) s")
                    .font(.subheadline).foregroundStyle(.secondary)
                DisclosureGroup("So wird bewertet") {
                    Text(SignalQuality.explanation).font(.footnote).foregroundStyle(.secondary)
                }
                .font(.footnote)
                .frame(minHeight: 44)
            } else {
                Text("Noch keine Messung").font(.title3.weight(.semibold))
                Text("Mit SEND NOW fragst du das Netz: Wie viele Gateways hören den Tester, und wie stark?")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DeviceCard: View {
    var tester: TesterSession
    var status: DeviceStatus

    var body: some View {
        Card {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let next = NextUplink.derive(status: status, interval: tester.config?.interval,
                                             lastUplink: tester.lastUplink, now: context.date)
                LabeledContent("Nächster Auto-Uplink") {
                    Text(next.text).monospacedDigit()
                }
            }
            LabeledContent("Rückmeldung am Tester", value: EventKind.profileName(status.profile))
            if !status.flags.contains(.sdReady) {
                StatusLabel(text: "\(tester.kind.logStorage) fehlt, es wird nichts protokolliert.",
                            symbol: EventSeverity.warning.symbol, color: .orange)
            }
        }
        .font(.subheadline)
    }
}

/// SEND NOW in thumb reach, shows the whole sequence on the button.
private struct SendBar: View {
    var tester: TesterSession

    var body: some View {
        SendButton(tester: tester, compact: false)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
    }
}

/// SEND NOW of one tester with its phase, reasons and errors.
struct SendButton: View {
    var tester: TesterSession
    var compact: Bool

    private var tint: Color {
        if case .result(let event) = tester.sendPhase { return event.severity.color }
        return .accentColor
    }

    var body: some View {
        let phase = tester.sendPhase
        VStack(spacing: 6) {
            Button {
                tester.sendNow()
            } label: {
                HStack {
                    if phase == .requested || phase == .queued || phase == .waitingForNetwork { ProgressView() }
                    if case .result(let event) = phase {
                        Image(systemName: event.severity.symbol)
                    }
                    Text(phase.title)
                        .font(phase.isResult || compact ? .headline : .title3.bold())
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!tester.canSend)
            .accessibilityLabel(compact ? "SEND NOW \(tester.shortTitle)" : phase.title)
            .accessibilityValue(phase.title)
            if case .blocked(let reason) = phase {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let message = tester.sendMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

struct EventsView: View {
    @Environment(TesterCentral.self) private var central

    /// Events of all active testers, newest first, named when there are several.
    static func all(_ central: TesterCentral) -> [(String?, TesterEvent)] {
        guard central.isMulti else { return central.focused.events.map { (nil, $0) } }
        return central.sessions.flatMap { session in session.events.map { (session.shortTitle, $0) } }
            .sorted { $0.1.date > $1.1.date }
    }

    var body: some View {
        let events = Self.all(central)
        List {
            ForEach(events, id: \.1.id) { EventRow(event: $0.1, device: $0.0) }
        }
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("Keine Ereignisse", systemImage: "clock",
                                       description: Text("Der Verlauf beginnt mit der Verbindung zum Tester und bleibt bis zum Beenden der App erhalten."))
            }
        }
        .navigationTitle("Ereignisse")
    }
}

private extension SignalQuality {
    var color: Color {
        switch self {
        case .veryGood, .good: .green
        case .weak: .orange
        case .critical: .red
        }
    }
}
