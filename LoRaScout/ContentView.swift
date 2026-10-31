//
//  ContentView.swift
//  LoRaScout
//
//  Created by Alex on 31.10.26.
//

import SwiftUI

struct ContentView: View {
    @Environment(FieldTester.self) private var tester
    @Environment(CoverageStore.self) private var coverage
    @Environment(\.scenePhase) private var scenePhase
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
            if let toast = tester.toast {
                EventToast(event: toast) { tester.dismissToast() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: tester.toast)
        .sensoryFeedback(trigger: tester.toast) { _, toast in
            toast.map { $0.kind.severity == .success ? .success : .error }
        }
        .onChange(of: tester.toast) { _, toast in
            if let toast { AccessibilityNotification.Announcement(toast.kind.title).post() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { coverage.reloadArchive() }
        }
        .onChange(of: tester.logRows, initial: true) { coverage.update(device: tester.logData) }
        .onChange(of: tester.config?.server, initial: true) { _, server in
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
        .environment(FieldTester())
        .environment(CoverageStore())
}
