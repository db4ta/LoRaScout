import SwiftUI

/// Gateways and statistics of the device screens 2 and 3.
struct NetworkView: View {
    @Environment(TesterCentral.self) private var central
    private var tester: TesterSession { central.focused }

    private var health: (text: String, symbol: String, color: Color) {
        guard let status = tester.status else { return ("–", "minus.circle", .secondary) }
        if status.flags.contains(.noNetworkAnswer) { return ("Keine Antwort", "xmark.octagon.fill", .red) }
        if status.flags.contains(.awaitingNetwork) { return ("Warte", "hourglass", .orange) }
        return status.feedbackAge == nil ? ("Noch keine", "minus.circle", .secondary) : ("OK", "checkmark.circle.fill", .green)
    }

    var body: some View {
        Screen(title: "Netz") {
            if central.isMulti {
                TesterOverview()
                TesterPicker()
            }
            if let status = tester.status {
                Section {
                    LabeledContent("Gateways", value: status.gwCount.text { "\($0)" })
                    LabeledContent("Bestes RSSI", value: status.gwCount == nil ? "–" : "\(signed(status.gwRssi)) dBm")
                    LabeledContent("Bestes SNR", value: status.gwCount == nil ? "–" : "\(signed(status.gwSnr)) dB")
                    LabeledContent("Netzantwort") {
                        StatusLabel(text: health.text, symbol: health.symbol, color: health.color)
                    }
                    LabeledContent("Alter der Antwort", value: status.feedbackAge.text { "\($0) s" })
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Gateways sind die Empfangsstationen, die den Tester gehört haben. RSSI ist die Signalstärke, SNR der Abstand zum Rauschen. \(tester.network.gatewayNote)")
                }
                Section {
                    LabeledContent("Gesendet", value: "\(status.sent)")
                    LabeledContent("Verloren", value: status.lost.text { "\($0)" })
                    LabeledContent("PER", value: status.lost == nil ? "–" : "\(status.per) %")
                } header: {
                    Text("Pakete")
                } footer: {
                    Text("PER ist der Anteil verlorener Pakete. Verloren zählt der Server und meldet es mit der Netzantwort.")
                }
                Section {
                    LabeledContent("Spreading Factor", value: status.spreadingFactor.text { "SF\($0)" })
                    LabeledContent("Sendeleistung", value: "ADR")
                } header: {
                    Text("Funk")
                } footer: {
                    Text("Ein höherer SF reicht weiter, sendet aber länger. Bei ADR regelt das Netz diese Werte selbst.")
                }
            } else {
                ContentUnavailableView("Keine Live-Daten", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Die Werte erscheinen, sobald der Tester verbunden ist."))
            }
        }
    }
}

/// All active testers side by side: gateways and signal of the last answer.
private struct TesterOverview: View {
    @Environment(TesterCentral.self) private var central

    private func answer(_ status: DeviceStatus?) -> String {
        guard let status else { return "keine Live-Daten" }
        if status.flags.contains(.noNetworkAnswer) { return "keine Netzantwort" }
        guard let count = status.gwCount else { return "noch keine Antwort" }
        return "\(count) GW · \(signed(status.gwRssi)) dBm · \(signed(status.gwSnr)) dB"
    }

    var body: some View {
        Section {
            ForEach(central.sessions) { session in
                LabeledContent {
                    Text(answer(session.status)).monospacedDigit()
                } label: {
                    StatusLabel(text: session.shortTitle, symbol: session.link.symbol, color: session.link.color)
                }
            }
        } header: {
            Text("Alle Tester")
        } footer: {
            Text("Letzte Netzantwort je Tester: Gateways, bestes RSSI und SNR.")
        }
    }
}

/// Chooses the tester the details below and Konfig belong to.
struct TesterPicker: View {
    @Environment(TesterCentral.self) private var central

    private var picker: some View {
        Picker("Tester", selection: Binding(get: { central.focused.id }, set: { central.focus($0) })) {
            ForEach(central.sessions) { Text($0.shortTitle).tag($0.id) }
        }
    }

    var body: some View {
        Section {
            // Four names don't fit side by side on an iPhone.
            if central.sessions.count <= 3 {
                picker.pickerStyle(.segmented).frame(minHeight: 44)
            } else {
                picker.pickerStyle(.menu)
            }
        } header: {
            Text("Details für")
        }
    }
}
