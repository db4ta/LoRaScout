import SwiftUI

/// Gateways and statistics of the device screens 2 and 3.
struct NetworkView: View {
    @Environment(FieldTester.self) private var tester

    private var health: (text: String, symbol: String, color: Color) {
        guard let status = tester.status else { return ("–", "minus.circle", .secondary) }
        if status.flags.contains(.noNetworkAnswer) { return ("Keine Antwort", "xmark.octagon.fill", .red) }
        if status.flags.contains(.awaitingNetwork) { return ("Warte", "hourglass", .orange) }
        return status.feedbackAge == nil ? ("Noch keine", "minus.circle", .secondary) : ("OK", "checkmark.circle.fill", .green)
    }

    var body: some View {
        Screen(title: "Netz") {
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
