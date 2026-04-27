//
//  NotificationCenter.swift
//  摸鱼侠 plugin v0.1
//
//  Thin wrapper around UNUserNotificationCenter. Plugin bundles inherit
//  the host app's bundle identifier for notification authorization, so
//  the host (Mio Island) needs to have notifications allowed in System
//  Settings. We request once on activate; if it's denied we fall back
//  to the in-panel red-dot pulse pattern.
//

import Foundation
@preconcurrency import UserNotifications
import AppKit

@MainActor
final class WorkerNotificationCenter {
    static let shared = WorkerNotificationCenter()

    private(set) var isAuthorized: Bool = false
    private var didRequest: Bool = false

    private init() {}

    /// Asks the user once. Subsequent calls are no-ops.
    func requestAuthorizationIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in WorkerNotificationCenter.shared.isAuthorized = true }
            case .denied:
                Task { @MainActor in WorkerNotificationCenter.shared.isAuthorized = false }
                WorkerDebugLog.write("notifications denied — falling back to in-panel dot")
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error = error {
                        WorkerDebugLog.write("notif auth error: \(error)")
                    }
                    Task { @MainActor in WorkerNotificationCenter.shared.isAuthorized = granted }
                    WorkerDebugLog.write("notif auth granted=\(granted)")
                }
            @unknown default:
                Task { @MainActor in WorkerNotificationCenter.shared.isAuthorized = false }
            }
        }
    }

    /// Fire-and-forget local notification. Returns true if scheduled
    /// (best effort — auth status may flip between scheduling and firing).
    @discardableResult
    func notify(title: String, body: String, identifier: String = UUID().uuidString) -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // Trigger immediately. nil means deliver right away. We use a
        // 0.1s threshold trigger because some macOS builds are flaky
        // with truly-instant local notifications from plugin bundles.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err {
                WorkerDebugLog.write("notif schedule error: \(err)")
            }
        }

        // Always bounce the dock as a backup signal — works even when
        // notifications are denied.
        NSApp.requestUserAttention(.criticalRequest)
        return isAuthorized
    }
}
