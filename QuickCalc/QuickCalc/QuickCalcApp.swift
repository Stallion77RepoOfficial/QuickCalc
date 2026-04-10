//
//  QuickCalcApp.swift
//  QuickCalc
//
//  Created by Berke on 7.04.2026.
//

import SwiftUI

@main
struct QuickCalcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
