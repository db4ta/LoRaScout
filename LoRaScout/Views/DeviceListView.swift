import SwiftUI

/// All testers in range plus the remembered ones. Up to four are active at once, each with its own link.
struct DeviceListView: View {
    @Environment(TesterCentral.self) private var central
    @Environment(\.dismiss) private var dismiss

    private var inRange: [NearbyDevice] {
        central.nearby.values.filter { central.session($0.id) == nil }
            .sorted { ($0.rssi ?? 0, $0.name) > ($1.rssi ?? 0, $1.name) }
    }

    private var remembered: [KnownDevice] {
        central.known.filter { central.session($0.id) == nil && central.nearby[$0.id] == nil }
    }

    private func isKnown(_ id: UUID) -> Bool { central.known.contains { $0.id == id } }

    private func detail(_ device: NearbyDevice) -> String {
        let level = device.rssi.map { "RSSI \($0) dBm" } ?? "Von iOS verbunden"
        return isKnown(device.id) ? level + " · bekannt" : level
    }

    var body: some View {
        List {
            if !central.sessions.isEmpty {
                Section {
                    ForEach(central.sessions) { session in
                        Button {
                            if let id = session.id { central.activate(id) }
                        } label: {
                            HStack {
                                DeviceRow(name: session.title, kind: session.kind,
                                          detail: session.link.title, detailColor: session.link.color)
                                Spacer()
                                if central.isMulti, central.focusedID == session.id {
                                    Text("Gewählt").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityValue(central.focusedID == session.id ? "Gewählt" : "")
                        .swipeActions {
                            if let id = session.id {
                                forgetButton(id)
                                Button("Trennen") { central.deactivate(id) }.tint(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Aktiv")
                } footer: {
                    Text("Aktive Tester sind gleichzeitig verbunden und kommen beim nächsten Start von selbst wieder. Antippen wählt einen für Netz und Konfig. Wischen zum Trennen oder Vergessen.")
                }
            }
            Section {
                ForEach(inRange) { device in
                    Button {
                        add(device.id)
                    } label: {
                        addRow(DeviceRow(name: device.name.isEmpty ? "Tester" : device.name, kind: device.kind,
                                         detail: detail(device), detailColor: .secondary))
                    }
                    .foregroundStyle(.primary)
                    .disabled(!central.canActivateMore)
                    .swipeActions { if isKnown(device.id) { forgetButton(device.id) } }
                }
                if inRange.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Suche weitere Tester …").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("In der Nähe")
            } footer: {
                Text(limitNote + "Ein verbundener Tester sendet keine Werbung und taucht hier nicht auf. Im WLAN-Portal ist Bluetooth aus.")
            }
            if !remembered.isEmpty {
                Section {
                    ForEach(remembered) { device in
                        Button {
                            add(device.id)
                        } label: {
                            addRow(DeviceRow(name: device.title, kind: device.kind, detail: "Nicht in Reichweite", detailColor: .secondary))
                        }
                        .foregroundStyle(.primary)
                        .disabled(!central.canActivateMore)
                        .swipeActions { forgetButton(device.id) }
                    }
                } header: {
                    Text("Bekannt")
                } footer: {
                    Text("Antippen aktiviert den Tester, die Verbindung kommt, sobald er in Reichweite ist. Wischen zum Vergessen. Die Kopplung in iOS bleibt, entfernen unter iOS-Einstellungen, Bluetooth.")
                }
            }
        }
        .navigationTitle("Geräte")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
        }
        .onAppear { central.startBrowsing() }
        .onDisappear { central.stopBrowsing() }
    }

    private var limitNote: String {
        central.canActivateMore ? "Antippen verbindet zusätzlich, bis zu \(TesterCentral.maxActive) Tester gleichzeitig. "
                                : "\(TesterCentral.maxActive) Tester sind aktiv, mehr gehen nicht gleichzeitig. Erst einen trennen. "
    }

    private func addRow(_ row: DeviceRow) -> some View {
        HStack {
            row
            Spacer()
            Image(systemName: "plus.circle").font(.title3).foregroundStyle(.tint).accessibilityHidden(true)
        }
        .accessibilityHint("Verbindet diesen Tester zusätzlich")
    }

    /// The first tester closes the list like before, further ones keep it open for more.
    private func add(_ id: UUID) {
        let first = central.sessions.isEmpty
        central.activate(id)
        if first { dismiss() }
    }

    private func forgetButton(_ id: UUID) -> some View {
        Button("Vergessen", role: .destructive) { central.forget(id) }
    }
}

struct DeviceRow: View {
    var name: String
    var kind: DeviceKind
    var detail: String
    var detailColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(kind.title).font(.subheadline).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(detailColor)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
