import AppKit
import SwiftUI

@MainActor
final class AdminAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DroplyAdminApp: App {
    @NSApplicationDelegateAdaptor(AdminAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AdminViewModel()

    var body: some Scene {
        Window("Droply Admin", id: "admin") {
            AdminContentView(viewModel: viewModel)
                .frame(minWidth: 940, minHeight: 640)
        }
        .windowStyle(.titleBar)
    }
}
