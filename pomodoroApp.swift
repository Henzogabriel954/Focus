//
//  pomodoroApp.swift
//  pomodoro
//
//  Created by Henzo  Gabriel on 02/01/26.
//

import SwiftUI

@main
struct FocusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 350, maxWidth: 500, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}