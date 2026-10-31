import SwiftUI

struct HomeView: View {
    @Environment(FieldTester.self) private var tester

    private var gps: (text: String, symbol: String, color: Color) {
        guard let status = tester.status else { return ("Unbekannt", "questionmark.circle.fill", .secondary) }
        if status.flags.contains(.gnssStandby) {
            return status.flags.contains(.gnssData) ? ("GPS wacht auf", "location.circle", .orange)
                                                    : ("GPS im Standby", "moon.fill", .blue)
        }
        if status.flags.contains(.fix) { return ("Fix, \(status.sats) Sat.", "location.fill", .green) }
        if status.flags.contains(.gnssData) { return ("Kein Fix", "location.slash.fill", .red) }
        return ("Keine Daten", "exclamationmark.triangle.fill", .red)
    }

    private var lora: (text: String, symbol: String, color: Color) {
        switch tester.status?.join {
        case .joined:
            // The AT firmware doesn't report TX and RX windows, so TX covers the whole send including its RX windows.
            if tester.status?.flags.contains(.awaitingNetwork) == true {
                ("Angemeldet\nRX, wartet auf Antwort", "arrow.down.circle.fill", .blue)
            } else if tester.status?.flags.contains(.loraBusy) == true {
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    tiles
                    MeasurementCard()
                    if let status = tester.status { DeviceCard(status: status) }
                    recentEvents
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(tester.deviceName ?? "LoRaScout")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { LinkBanner() }
            .safeAreaInset(edge: .bottom, spacing: 0) { SendBar() }
        }
    }

    private var tiles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { tileContent }.fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) { tileContent }
        }
    }

    @ViewBuilder private var tileContent: some View {
        let link = tester.link
        StatusTile(title: "Verbindung", value: link.title, symbol: link.symbol, color: link.color)
        StatusTile(title: "GPS", value: gps.text, symbol: gps.symbol, color: gps.color)
        StatusTile(title: "LoRaWAN", value: lora.text, symbol: lora.symbol, color: lora.color)
    }

    private var recentEvents: some View {
        Card {
            HStack {
                Text("Letzte Ereignisse").font(.headline)
                Spacer()
                NavigationLink("Alle") { EventsView() }
                    .frame(minHeight: 44)
            }
            if tester.events.isEmpty {
                Text("Noch nichts passiert. Der Verlauf beginnt mit der Verbindung zum Tester.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(tester.events.prefix(3)) { EventRow(event: $0) }
        }
    }
}

/// The last network answer, the main result of a test.
private struct MeasurementCard: View {
    @Environment(FieldTester.self) private var tester

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
    @Environment(FieldTester.self) private var tester
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
                StatusLabel(text: "SD-Karte fehlt, es wird nichts protokolliert.",
                            symbol: EventSeverity.warning.symbol, color: .orange)
            }
        }
        .font(.subheadline)
    }
}

/// SEND NOW in thumb reach, shows the whole sequence on the button.
private struct SendBar: View {
    @Environment(FieldTester.self) private var tester

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
                        .font(phase.isResult ? .headline : .title3.bold())
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(!tester.canSend)
            .accessibilityValue(phase.title)
            if case .blocked(let reason) = phase {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let message = tester.sendMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct EventsView: View {
    @Environment(FieldTester.self) private var tester

    var body: some View {
        List {
            ForEach(tester.events) { EventRow(event: $0) }
        }
        .overlay {
            if tester.events.isEmpty {
                ContentUnavailableView("Keine Ereignisse", systemImage: "clock",
                                       description: Text("Der Verlauf beginnt mit der Verbindung zum Tester und bleibt bis zum Beenden der App erhalten."))
            }
        }
        .navigationTitle("Ereignisse")
    }
}
