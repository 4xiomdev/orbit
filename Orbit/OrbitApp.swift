//
//  OrbitApp.swift
//  Orbit
//
//  Menu bar-only Orbit app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with Orbit voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(OrbitAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the Orbit lifecycle: creates the menu bar panel and starts
/// the Orbit voice pipeline on launch.
@MainActor
final class OrbitAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let orbitManager = OrbitManager()
    private let installedBundlePath = "/Applications/Orbit.app"

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🪐 Orbit: Starting...")
        print("🪐 Orbit: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        OrbitAnalytics.configure()
        OrbitAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(orbitManager: orbitManager)
        orbitManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if orbitManager.setupStage != .ready {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        orbitManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        let currentBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let isInstalledBundle = currentBundlePath == installedBundlePath
        OrbitSupportLog.append(
            "app",
            "bundlePath=\(currentBundlePath) installedBundle=\(isInstalledBundle) loginItemStatus=\(loginItemService.status.rawValue)"
        )

        if !isInstalledBundle {
            if loginItemService.status == .enabled {
                do {
                    try loginItemService.unregister()
                    OrbitSupportLog.append("app", "unregistered login item for non-installed bundle")
                    print("🪐 Orbit: Removed login item for non-installed bundle")
                } catch {
                    OrbitSupportLog.append("app", "failed to unregister login item: \(error.localizedDescription)")
                    print("⚠️ Orbit: Failed to unregister login item: \(error)")
                }
            } else {
                OrbitSupportLog.append("app", "skipped login item registration for non-installed bundle")
            }
            return
        }

        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                OrbitSupportLog.append("app", "registered login item for installed bundle")
                print("🪐 Orbit: Registered as login item")
            } catch {
                OrbitSupportLog.append("app", "failed to register login item: \(error.localizedDescription)")
                print("⚠️ Orbit: Failed to register as login item: \(error)")
            }
        } else {
            OrbitSupportLog.append("app", "login item already enabled for installed bundle")
        }
    }
}
