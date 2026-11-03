//
//  ContentView.swift
//  LoRaScout
//
//  Created by Alex on 31.10.26.
//

import SwiftUI

struct ContentView: View {
    @Environment(TesterCentral.self) private var central
    @Environment(CoverageStore.self) private var coverage
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("phoneScreenAwake") private var phoneScreenAwake = false
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "antenna.radiowaves.left.and.right", value: 0) { home }
            Tab("Netz", systemImage: "chart.bar", value: 1) { NetworkView() }
            Tab("Karte", systemImage: "map", value: 2) { MapScreen() }
            Tab("Auswertung", systemImage: "chart.pie", value: 3) { CoverageView() }
            Tab("Konfig", systemImage: "gearshape", value: 4) { ConfigView() }
        }
        .overlay(alignment: .top) {
            if let toast = central.toast {
                EventToast(event: toast.event, device: toast.device) { central.dismissToast() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: central.toast)
        .sensoryFeedback(trigger: central.toast) { _, toast in
            toast.map { $0.event.kind.severity == .success ? .success : .error }
        }
        .onChange(of: central.toast) { _, toast in
            if let toast { AccessibilityNotification.Announcement("\(toast.device): \(toast.event.kind.title)").post() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coverage.reloadArchive() }
            UIApplication.shared.isIdleTimerDisabled = phoneScreenAwake && phase == .active
        }
        .onChange(of: phoneScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onChange(of: central.logsKey, initial: true) { coverage.update(logs: central.deviceLogs) }
        .onChange(of: central.known.compactMap(\.devEUI), initial: true) { _, list in coverage.knownDevEUIs = list }
        .onChange(of: central.sessions.compactMap { $0.config?.server.nonEmpty }.first, initial: true) { _, server in
            if let server { coverage.offerHost(server) }
        }
        #if DEBUG
        .onAppear { if DemoData.isActive { tab = DemoData.tab } }
        .task {
            guard DemoData.writeImage, let region = MapImage.fittingRegion(MapContent(coverage: coverage).points) else { return }
            let url = try? await MapContent(coverage: coverage).exportImage(region: region)
            if let url {
                let target = URL.documentsDirectory.appending(path: "demo.jpg")
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
            }
        }
        #endif
    }
}

private extension ContentView {
    @ViewBuilder var home: some View {
        #if DEBUG
        if DemoData.showEvents {
            NavigationStack { EventsView() }
        } else if DemoData.showList {
            NavigationStack { ArchiveListView() }
        } else {
            HomeView()
        }
        #else
        HomeView()
        #endif
    }
}

#Preview {
    ContentView()
        .environment(TesterCentral())
        .environment(CoverageStore())
}
