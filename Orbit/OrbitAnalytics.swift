//
//  OrbitAnalytics.swift
//  Orbit
//
//  Publication-safe analytics shim. Orbit intentionally ships with no
//  bundled third-party telemetry configuration in the open source build.
//

import Foundation

enum OrbitAnalytics {
    static func configure() {}
    static func trackAppOpened() {}
    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingDemoTriggered() {}
    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}
    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
}
