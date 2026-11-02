import SwiftUI

struct ConfigView: View {
    @Environment(FieldTester.self) private var tester
    @Environment(CoverageStore.self) private var coverage

    @State private var credentials: [ConfigID: String] = [:]
    @State private var interval = ""
    @State private var profile: UInt8 = 0
    @State private var upload = false
    @State private var displaySave = true
    @State private var displayAlways = false
    @State private var displayOffSeconds: UInt8 = 30
    @State private var brightness: UInt8 = 50
    @State private var cpuMHz: UInt8 = 80
    @State private var gnssStandby = false
    @State private var signalTones = false
    @AppStorage(SignalPlayer.enabledKey) private var appSignals = false
    @AppStorage("phoneScreenAwake") private var phoneScreenAwake = false
    @State private var wifiName = ""
    @State private var wifiPassword = ""
    @State private var server = ""
    @State private var token = ""
    @State private var inputError: String?
    @State private var coverageToken = ""

    /// The current value stays selectable even if the portal stored one that isn't on the list.
    private var brightnessChoices: [UInt8] { Set([10, 25, 50, 75, 100, brightness]).sorted() }
    private var displayOffChoices: [UInt8] { Set([15, 30, 60, 120, displayOffSeconds]).sorted() }

    private func setHint(_ isSet: Bool) -> String { isSet ? "gesetzt, neu eingeben zum Ändern" : "nicht gesetzt" }

    private var screenBinding: Binding<UInt8> {
        Binding(get: { tester.status?.screen ?? 0 }, set: { tester.showScreen($0) })
    }

    var body: some View {
        Screen(title: "Konfiguration") {
            Section("Verbindung") {
                LabeledContent("Tester") {
                    StatusLabel(text: tester.link.title, symbol: tester.link.symbol, color: tester.link.color)
                }
                if let name = tester.deviceName { LabeledContent("Name", value: name) }
            }
            if let config = tester.config {
                deviceSections(config)
            } else {
                Section {
                    ContentUnavailableView("Tester nicht verbunden", systemImage: "gearshape",
                                           description: Text("Die Geräte-Einstellungen erscheinen nach dem Verbinden."))
                }
            }
            signalSection
            coverageSection
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if tester.config != nil { saveBar }
        }
        .onChange(of: tester.config, initial: true) { _, config in
            // After a failed save the input stays so it can be corrected.
            if let config, !tester.configFailed { load(config) }
        }
    }

    @ViewBuilder
    private func deviceSections(_ config: DeviceConfig) -> some View {
        Section {
            LabeledContent("Auto-Uplink alle (s)") {
                TextField("60–3600", text: $interval)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Rückmeldung", selection: $profile) {
                ForEach(UInt8(0)...3, id: \.self) { Text(EventKind.profileName($0)).tag($0) }
            }
            Toggle("Signaltöne am Tester", isOn: $signalTones)
            Picker("Display zeigt", selection: screenBinding) {
                Text("Home").tag(UInt8(0))
                Text("Gateways").tag(UInt8(1))
                Text("Stats").tag(UInt8(2))
                Text("Upload").tag(UInt8(3))
            }
            Button("Tester neu starten", role: .destructive) { tester.restart() }
        } header: {
            Text("Gerät")
        } footer: {
            if tester.restartNeeded {
                Text("LoRaWAN-Schlüssel und Prozessortakt wirken erst nach einem Neustart.").foregroundStyle(.orange)
            } else {
                Text("Rückmeldung legt fest, wie der Tester OK und Fehler meldet. „Display zeigt“ wirkt sofort. Signaltöne: hoher Ton beim Senden, tiefer beim Empfang, Dreifachgong bei Fehlern. Sie klingen nur in Profilen mit Ton.")
            }
        }
        Section {
            Picker("Prozessortakt", selection: $cpuMHz) {
                ForEach([UInt8(80), 160, 240], id: \.self) { Text("\($0) MHz").tag($0) }
            }
            Picker("Helligkeit", selection: $brightness) {
                ForEach(brightnessChoices, id: \.self) { Text("\($0) %").tag($0) }
            }
            Toggle("Display dauerhaft an", isOn: Binding(get: { !displaySave }, set: { displaySave = !$0 }))
            Toggle("Auch ohne iPhone ausschalten", isOn: $displayAlways)
                .disabled(!displaySave)
            Picker("Display aus nach", selection: $displayOffSeconds) {
                ForEach(displayOffChoices, id: \.self) { Text("\($0) s").tag($0) }
            }
            .disabled(!displaySave)
            Toggle("GNSS-Standby", isOn: $gnssStandby)
        } header: {
            Text("Stromsparen")
        } footer: {
            Text("Der Prozessortakt wirkt nach einem Neustart, alles andere sofort. Das Display geht nach der eingestellten Zeit aus, wenn das iPhone verbunden ist. Ohne iPhone nur mit „Auch ohne iPhone ausschalten“. Tippen weckt es. GNSS-Standby: Der Empfänger wacht 15 s vor dem nächsten Uplink auf, SEND NOW wartet bis zu 10 s auf die Position. Dazwischen gibt es keine aktuelle Position.")
        }
        Section {
            ForEach(tester.network.credentials) { field in
                credentialRow(field, config)
            }
        } header: {
            Text("Netz: \(tester.network.name)")
        } footer: {
            Text("Diese Schlüssel stehen in der TTN-Console beim Gerät. Hex-Zeichen, ohne Leerzeichen.")
        }
        Section {
            TitledField(title: "WLAN-Name") { TextField("WLAN-Name", text: $wifiName).plainInput() }
            SecureField("WLAN-Passwort: \(setHint(config.wifiPasswordSet))", text: $wifiPassword)
            TitledField(title: "Server") {
                TextField("IP oder URL", text: $server).plainInput().keyboardType(.URL)
            }
            SecureField("Token: \(setHint(config.uploadTokenSet))", text: $token)
            Toggle("Upload beim Einschalten", isOn: $upload)
        } header: {
            Text("WLAN und Upload")
        } footer: {
            Text("Der Tester lädt sein Log beim Einschalten zum Server. Upload braucht WLAN-Name, Server und Token.")
        }
    }

    private var signalSection: some View {
        Section {
            Toggle("Signaltöne in der App", isOn: $appSignals)
            Button("Töne anhören") { tester.previewSignals() }
            Toggle("iPhone-Display bleibt an", isOn: $phoneScreenAwake)
        } header: {
            Text("App")
        } footer: {
            Text("Töne klingen wie am Tester, auch bei stumm geschaltetem iPhone, und nur solange die App im Vordergrund läuft. „iPhone-Display bleibt an“ verhindert die automatische Sperre, solange die App offen ist. Braucht mehr Akku.")
        }
    }

    private var coverageSection: some View {
        @Bindable var coverage = coverage
        return Section {
            TitledField(title: "Server") {
                TextField("IP oder URL", text: $coverage.host).plainInput().keyboardType(.URL)
            }
            SecureField(coverage.tokenSet ? "Token gesetzt, neu eingeben zum Ändern" : "Upload-Token", text: $coverageToken)
                .onSubmit(saveCoverageToken)
            Button("Token speichern", action: saveCoverageToken)
                .disabled(coverageToken.isEmpty)
            if let message = coverage.tokenMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Coverage-Server")
        } footer: {
            Text("Gilt nur für diese App. Der Server wird vom Tester übernommen und lässt sich ändern. Das Token ist dasselbe wie beim Upload, der Tester gibt es aber nicht heraus, darum hier eingeben. Es liegt im Schlüsselbund.")
        }
    }

    private func saveCoverageToken() {
        guard !coverageToken.isEmpty else { return }
        coverage.saveToken(coverageToken)
        coverageToken = ""
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            if let inputError {
                Text(inputError).foregroundStyle(.red)
            } else if let message = tester.configMessage {
                let severity = tester.configFailed ? EventSeverity.failure : .success
                StatusLabel(text: message, symbol: severity.symbol, color: severity.color)
            }
            Button(action: save) {
                Text(tester.savingConfig ? "Speichert …" : "Auf dem Tester speichern")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tester.savingConfig || tester.link != .ready)
        }
        .font(.footnote)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func credentialRow(_ field: CredentialField, _ config: DeviceConfig) -> some View {
        let binding = Binding { credentials[field.id] ?? "" } set: { credentials[field.id] = $0 }
        if field.isSecret {
            SecureField("\(field.label): \(setHint(config.isSet(field.id)))", text: binding)
        } else {
            TitledField(title: field.label) { TextField(field.label, text: binding).plainInput() }
        }
    }

    private func load(_ config: DeviceConfig) {
        for field in tester.network.credentials {
            credentials[field.id] = field.isSecret ? "" : config.text(field.id)
        }
        interval = String(config.interval)
        profile = config.profile
        upload = config.uploadOnBoot
        displaySave = config.displaySave
        displayAlways = config.displayAlways
        displayOffSeconds = config.displayOffSeconds
        brightness = config.brightness
        cpuMHz = config.cpuMHz
        gnssStandby = config.gnssStandby
        signalTones = config.signalTones
        wifiName = config.wifiName
        server = config.server
        wifiPassword = ""
        token = ""
    }

    private func save() {
        guard let config = tester.config else { return }
        inputError = nil
        var writes: [ConfigWrite] = []

        for field in tester.network.credentials {
            let input = credentials[field.id] ?? ""
            if field.isSecret && input.isEmpty { continue }
            guard let value = field.normalized(input) else {
                inputError = "\(field.label): \(field.hexLength) Hex-Zeichen nötig."
                return
            }
            if field.isSecret || value != config.text(field.id).uppercased() {
                writes.append(.text(field.id, value))
            }
        }

        guard let seconds = UInt16(interval), (60...3600).contains(seconds) else {
            inputError = "Intervall: 60 bis 3600 Sekunden."
            return
        }
        if seconds != config.interval { writes.append(.interval(seconds)) }
        if profile != config.profile { writes.append(.profile(profile)) }

        let texts: [(ConfigID, String, String, Int, String?)] = [
            (.wifiName, "WLAN-Name", wifiName, 32, config.wifiName),
            (.wifiPassword, "WLAN-Passwort", wifiPassword, 64, nil),
            (.server, "Server", server, ConfigWrite.maxValueSize, config.server),
            (.uploadToken, "Token", token, 40, nil),
        ]
        for (id, label, value, limit, current) in texts where value != (current ?? "") {
            guard !value.isEmpty, value.utf8.count <= limit else {
                inputError = value.isEmpty ? "\(label) darf nicht leer sein." : "\(label): höchstens \(limit) Bytes."
                return
            }
            writes.append(.text(id, value))
        }
        if displaySave != config.displaySave { writes.append(.flag(.displaySave, displaySave)) }
        if displayAlways != config.displayAlways { writes.append(.flag(.displayAlways, displayAlways)) }
        if displayOffSeconds != config.displayOffSeconds { writes.append(.byte(.displayOffSeconds, displayOffSeconds)) }
        if brightness != config.brightness { writes.append(.byte(.brightness, brightness)) }
        if cpuMHz != config.cpuMHz { writes.append(.byte(.cpuMHz, cpuMHz)) }
        if gnssStandby != config.gnssStandby { writes.append(.flag(.gnssStandby, gnssStandby)) }
        if signalTones != config.signalTones { writes.append(.flag(.signalTones, signalTones)) }
        if upload != config.uploadOnBoot { writes.append(.uploadOnBoot(upload)) }

        if writes.isEmpty {
            inputError = "Keine Änderungen."
            return
        }
        tester.save(writes)
    }
}

/// A filled text field hides its placeholder, so the name stays visible above it.
private struct TitledField<Field: View>: View {
    var title: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            field
        }
    }
}

private extension View {
    func plainInput() -> some View {
        textInputAutocapitalization(.never).autocorrectionDisabled()
    }
}
