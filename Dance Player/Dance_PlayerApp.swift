//
//  Dance_PlayerApp.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/14/26.
//

import SwiftUI
import AppKit

@main
struct Dance_PlayerApp: App {
    init() {
        if let iconURL = Bundle.main.url(forResource: "logo", withExtension: "jpg"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
