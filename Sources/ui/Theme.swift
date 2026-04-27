//
//  Theme.swift
//  摸鱼侠 plugin v0.1
//
//  Single source of truth for the design's colour tokens. Mirrors
//  看盘侠's palette so the two plugins feel like siblings.
//

import SwiftUI

enum WorkerTheme {
    // Lime accent — primary CTA / running-state highlight.
    static let lime = Color(red: 0xD4/255, green: 0xFF/255, blue: 0x3A/255)

    // Warm orange — pomodoro running glow.
    static let tomato = Color(red: 0xFF/255, green: 0x7A/255, blue: 0x4D/255)

    // Sky blue — sit timer active.
    static let sky = Color(red: 0x6E/255, green: 0xC1/255, blue: 0xFF/255)

    // Water blue — water tab.
    static let water = Color(red: 0x52/255, green: 0xC4/255, blue: 0xFF/255)

    // Clockout red — bar fill as it approaches the end.
    static let alertRed = Color(red: 0xFF/255, green: 0x5E/255, blue: 0x5E/255)

    // Weekend purple — the "freedom is coming" tab.
    static let weekendPurple = Color(red: 0xC9/255, green: 0x8B/255, blue: 0xFF/255)

    // Panel background — pure black with a hint of warmth.
    static let panelBg = Color(red: 0x05/255, green: 0x05/255, blue: 0x05/255)

    // Subtle white overlays used everywhere.
    static let overlay04 = Color.white.opacity(0.04)
    static let overlay06 = Color.white.opacity(0.06)
    static let overlay08 = Color.white.opacity(0.08)
    static let overlay12 = Color.white.opacity(0.12)
    static let overlay18 = Color.white.opacity(0.18)

    // Foreground tints.
    static let fgPrimary = Color(red: 0xF4/255, green: 0xF4/255, blue: 0xF5/255)
    static let fg85 = Color.white.opacity(0.85)
    static let fg70 = Color.white.opacity(0.7)
    static let fg55 = Color.white.opacity(0.55)
    static let fg45 = Color.white.opacity(0.45)
    static let fg40 = Color.white.opacity(0.4)
    static let fg35 = Color.white.opacity(0.35)
}

// MARK: - Time formatting helpers

enum WorkerFormat {
    /// 25:00 / 04:59 — m:ss style for the pomodoro / sit countdown.
    static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 1时23分 — for clockout / weekend.
    static func chineseShort(hours: Int, minutes: Int) -> String {
        if hours <= 0 { return "\(minutes)分" }
        return "\(hours)时\(minutes)分"
    }

    /// 2天3时5分 — for weekend countdown.
    static func dhm(days: Int, hours: Int, minutes: Int) -> String {
        if days > 0 { return "\(days)天\(hours)时\(minutes)分" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        return "\(minutes)分"
    }
}
