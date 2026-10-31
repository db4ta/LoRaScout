//
//  LoRaScoutApp.swift
//  LoRaScout
//
//  Created by Alex on 31.10.26.
//

import SwiftUI

@main
struct LoRaScoutApp: App {
    @State private var tester = FieldTester()
    @State private var coverage = CoverageStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(tester)
                .environment(coverage)
        }
    }
}
