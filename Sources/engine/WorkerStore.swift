//
//  WorkerStore.swift
//  摸鱼侠 plugin v0.1
//
//  Single source of truth for all five tabs. Holds:
//    - pomodoro state machine (idle / focus / break / paused)
//    - sit-timer countup (start timestamp)
//    - water tally (cups today)
//    - clockout target time (HH:mm)
//    - weekend countdown (computed)
//
//  All persisted to UserDefaults with suite "com.mioisland.plugin.worker".
//  A single 1Hz Timer drives all derived "now" values.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Persistence keys

private enum K {
    static let pomodoroHistory   = "pomodoro.history"        // [String: Int] (yyyy-MM-dd → count)
    static let pomodoroFocusMin  = "pomodoro.focusMin"       // Int, default 25
    static let pomodoroBreakMin  = "pomodoro.breakMin"       // Int, default 5
    static let sitStart          = "sit.start"               // Double (timeIntervalSince1970), 0 = idle
    static let sitTriggerMin     = "sit.triggerMin"          // Int, default 45
    static let sitLastNotified   = "sit.lastNotified"        // Double — last fired notification ts, to dedupe
    static let waterHistory      = "water.history"           // [String: Int] (date → cups)
    static let waterGoal         = "water.goal"              // Int, default 8
    static let clockoutHHmm      = "clockout.hhmm"           // String "18:00"
}

private let suiteName = "com.mioisland.plugin.worker"

// MARK: - Pomodoro phase

enum PomodoroPhase: String {
    case idle      // not running
    case focus     // 25 min focus going
    case rest      // 5 min break going
    case paused    // paused mid-phase

    var label: String {
        switch self {
        case .idle:   return "准备开始"
        case .focus:  return "专注中"
        case .rest:   return "休息中"
        case .paused: return "已暂停"
        }
    }
}

// MARK: - Store

@MainActor
final class WorkerStore: ObservableObject {
    static let shared = WorkerStore()

    private let defaults: UserDefaults

    // MARK: Published state

    /// Pomodoro
    @Published var pomodoroPhase: PomodoroPhase = .idle
    @Published var pomodoroRemaining: Int = 25 * 60   // seconds
    @Published var pomodoroFocusMin: Int = 25
    @Published var pomodoroBreakMin: Int = 5
    @Published var pomodoroTodayCount: Int = 0
    /// Pre-pause snapshot so resume can restore the underlying phase.
    private var pausedPhase: PomodoroPhase = .focus
    private var pausedRemaining: Int = 25 * 60

    /// Sit
    @Published var sitStart: Date? = nil           // nil = not seated yet
    @Published var sitTriggerMin: Int = 45
    @Published var sitElapsedSec: Int = 0          // computed each tick

    /// Water
    @Published var waterCupsToday: Int = 0
    @Published var waterGoal: Int = 8

    /// Clockout
    @Published var clockoutHour: Int = 18
    @Published var clockoutMinute: Int = 0

    /// Weekend (derived)
    @Published var weekendDays: Int = 0
    @Published var weekendHours: Int = 0
    @Published var weekendMinutes: Int = 0

    /// Notification status surfaced to UI for the in-panel fallback.
    @Published var notificationsAuthorized: Bool = false

    // MARK: Private

    private var tick: Timer?
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.timeZone = TimeZone.current
        return c
    }()

    // MARK: - Init

    private init() {
        // UserDefaults(suiteName:) returns nil only when the suite name
        // is invalid (e.g. the global suite). For a normal bundle ID it
        // always succeeds, but fall back to .standard defensively.
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        loadPersisted()
    }

    // MARK: - Lifecycle

    func start() {
        WorkerDebugLog.write("store start")
        recomputeAll()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFire() }
        }
    }

    func stop() {
        WorkerDebugLog.write("store stop")
        tick?.invalidate()
        tick = nil
    }

    // MARK: - Tick (1Hz)

    private func tickFire() {
        // 1. Pomodoro countdown
        if pomodoroPhase == .focus || pomodoroPhase == .rest {
            if pomodoroRemaining > 0 {
                pomodoroRemaining -= 1
            }
            if pomodoroRemaining <= 0 {
                pomodoroPhaseEnded()
            }
        }

        // 2. Sit countup + threshold notification
        if let start = sitStart {
            let elapsed = max(0, Int(Date().timeIntervalSince(start)))
            sitElapsedSec = elapsed
            // Fire once per crossing of the trigger (and once per
            // additional trigger period after that).
            let triggerSec = sitTriggerMin * 60
            if triggerSec > 0 && elapsed >= triggerSec {
                let lastFired = defaults.double(forKey: K.sitLastNotified)
                let nowTs = Date().timeIntervalSince1970
                // Only fire if we crossed *this* boundary (i.e. last
                // fired more than triggerSec ago, or never).
                if nowTs - lastFired >= Double(triggerSec) {
                    defaults.set(nowTs, forKey: K.sitLastNotified)
                    WorkerNotificationCenter.shared.notify(
                        title: "该起来动一下了",
                        body: "你已连续坐了 \(sitTriggerMin) 分钟，起身喝口水吧。"
                    )
                    WorkerDebugLog.write("sit threshold notification fired (\(elapsed)s)")
                }
            }
        } else {
            sitElapsedSec = 0
        }

        // 3. Weekend countdown — recompute every tick (cheap).
        recomputeWeekend()

        // 4. Detect day rollover for pomodoro / water counters.
        rolloverIfNeeded()
    }

    // MARK: - Pomodoro

    func pomodoroStart() {
        if pomodoroPhase == .paused {
            pomodoroPhase = pausedPhase
            pomodoroRemaining = pausedRemaining
            return
        }
        pomodoroPhase = .focus
        pomodoroRemaining = pomodoroFocusMin * 60
    }

    func pomodoroPause() {
        guard pomodoroPhase == .focus || pomodoroPhase == .rest else { return }
        pausedPhase = pomodoroPhase
        pausedRemaining = pomodoroRemaining
        pomodoroPhase = .paused
    }

    func pomodoroReset() {
        pomodoroPhase = .idle
        pomodoroRemaining = pomodoroFocusMin * 60
    }

    func pomodoroSetFocus(_ min: Int) {
        let v = max(1, min)
        pomodoroFocusMin = v
        defaults.set(v, forKey: K.pomodoroFocusMin)
        if pomodoroPhase == .idle {
            pomodoroRemaining = v * 60
        }
    }

    func pomodoroSetBreak(_ min: Int) {
        let v = max(1, min)
        pomodoroBreakMin = v
        defaults.set(v, forKey: K.pomodoroBreakMin)
    }

    private func pomodoroPhaseEnded() {
        switch pomodoroPhase {
        case .focus:
            // Increment today's tally.
            pomodoroTodayCount += 1
            persistPomodoroToday()
            WorkerNotificationCenter.shared.notify(
                title: "番茄完成 🍅",
                body: "干得漂亮！开始 \(pomodoroBreakMin) 分钟休息。"
            )
            pomodoroPhase = .rest
            pomodoroRemaining = pomodoroBreakMin * 60
        case .rest:
            WorkerNotificationCenter.shared.notify(
                title: "休息结束",
                body: "回到工作 — 再来一个 \(pomodoroFocusMin) 分钟番茄？"
            )
            pomodoroPhase = .idle
            pomodoroRemaining = pomodoroFocusMin * 60
        default:
            break
        }
    }

    private func persistPomodoroToday() {
        var dict = (defaults.dictionary(forKey: K.pomodoroHistory) as? [String: Int]) ?? [:]
        dict[Self.dateKey(Date(), calendar: calendar)] = pomodoroTodayCount
        defaults.set(dict, forKey: K.pomodoroHistory)
    }

    // MARK: - Sit

    func sitStartNow() {
        sitStart = Date()
        sitElapsedSec = 0
        defaults.set(Date().timeIntervalSince1970, forKey: K.sitStart)
        defaults.set(0.0, forKey: K.sitLastNotified)
    }

    func sitStop() {
        sitStart = nil
        sitElapsedSec = 0
        defaults.set(0.0, forKey: K.sitStart)
        defaults.set(0.0, forKey: K.sitLastNotified)
    }

    func sitSetTrigger(_ min: Int) {
        let v = max(5, min)
        sitTriggerMin = v
        defaults.set(v, forKey: K.sitTriggerMin)
        // Reset dedupe window so the new threshold gets a fresh check.
        defaults.set(0.0, forKey: K.sitLastNotified)
    }

    // MARK: - Water

    func waterAddCup() {
        waterCupsToday += 1
        persistWaterToday()
    }

    func waterRemoveCup() {
        guard waterCupsToday > 0 else { return }
        waterCupsToday -= 1
        persistWaterToday()
    }

    func waterSetGoal(_ goal: Int) {
        let v = max(1, goal)
        waterGoal = v
        defaults.set(v, forKey: K.waterGoal)
    }

    private func persistWaterToday() {
        var dict = (defaults.dictionary(forKey: K.waterHistory) as? [String: Int]) ?? [:]
        dict[Self.dateKey(Date(), calendar: calendar)] = waterCupsToday
        defaults.set(dict, forKey: K.waterHistory)
    }

    // MARK: - Clockout

    func clockoutSet(hour: Int, minute: Int) {
        let h = max(0, min(23, hour))
        let m = max(0, min(59, minute))
        clockoutHour = h
        clockoutMinute = m
        defaults.set(String(format: "%02d:%02d", h, m), forKey: K.clockoutHHmm)
    }

    /// Seconds remaining until today's clockout. If it's already past,
    /// returns the seconds until tomorrow's clockout (rolls over).
    var clockoutRemainingSec: Int {
        let now = Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = clockoutHour
        comps.minute = clockoutMinute
        comps.second = 0
        var target = calendar.date(from: comps) ?? now
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return max(0, Int(target.timeIntervalSince(now)))
    }

    /// 0.0 = full workday left, 1.0 = at/past clockout time. Used for
    /// the red bar fill. Anchor: 9 hours before clockout = full bar.
    var clockoutProgress: Double {
        let remaining = Double(clockoutRemainingSec)
        let workdaySec: Double = 9 * 3600
        let elapsed = workdaySec - remaining
        return max(0.0, min(1.0, elapsed / workdaySec))
    }

    // MARK: - Weekend

    private func recomputeWeekend() {
        // Next Saturday 00:00 local. If today is already Saturday/Sunday,
        // we still target the *next* Saturday (so users on weekends see
        // a fresh ~7-day countdown — that mirrors the spec's "周末 = 距
        // 离下个周六" intent).
        let now = Date()
        let weekday = calendar.component(.weekday, from: now) // Sun=1 ... Sat=7
        // Days until next Saturday. If today is Saturday before midnight,
        // we already passed the boundary today, so the next one is +7.
        var daysUntilSat = (7 - weekday + 7) % 7
        if daysUntilSat == 0 { daysUntilSat = 7 }

        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        guard let midnightToday = calendar.date(from: comps),
              let target = calendar.date(byAdding: .day, value: daysUntilSat, to: midnightToday) else {
            return
        }
        let total = max(0, Int(target.timeIntervalSince(now)))
        weekendDays = total / 86400
        let rem1 = total % 86400
        weekendHours = rem1 / 3600
        let rem2 = rem1 % 3600
        weekendMinutes = rem2 / 60
    }

    // MARK: - Day rollover

    private var lastSeenDay: String = ""

    private func rolloverIfNeeded() {
        let today = Self.dateKey(Date(), calendar: calendar)
        if lastSeenDay.isEmpty {
            lastSeenDay = today
            return
        }
        if today != lastSeenDay {
            WorkerDebugLog.write("day rollover \(lastSeenDay) → \(today)")
            lastSeenDay = today
            // Reload day-scoped counters.
            let pomDict = (defaults.dictionary(forKey: K.pomodoroHistory) as? [String: Int]) ?? [:]
            pomodoroTodayCount = pomDict[today] ?? 0
            let waterDict = (defaults.dictionary(forKey: K.waterHistory) as? [String: Int]) ?? [:]
            waterCupsToday = waterDict[today] ?? 0
        }
    }

    // MARK: - Load + recompute

    private func loadPersisted() {
        // Pomodoro
        let storedFocus = defaults.integer(forKey: K.pomodoroFocusMin)
        pomodoroFocusMin = storedFocus > 0 ? storedFocus : 25
        let storedBreak = defaults.integer(forKey: K.pomodoroBreakMin)
        pomodoroBreakMin = storedBreak > 0 ? storedBreak : 5
        pomodoroRemaining = pomodoroFocusMin * 60

        let pomDict = (defaults.dictionary(forKey: K.pomodoroHistory) as? [String: Int]) ?? [:]
        let today = Self.dateKey(Date(), calendar: calendar)
        pomodoroTodayCount = pomDict[today] ?? 0
        lastSeenDay = today

        // Sit
        let storedTrig = defaults.integer(forKey: K.sitTriggerMin)
        sitTriggerMin = storedTrig > 0 ? storedTrig : 45
        let sitTs = defaults.double(forKey: K.sitStart)
        if sitTs > 0 {
            sitStart = Date(timeIntervalSince1970: sitTs)
        } else {
            sitStart = nil
        }

        // Water
        let storedGoal = defaults.integer(forKey: K.waterGoal)
        waterGoal = storedGoal > 0 ? storedGoal : 8
        let waterDict = (defaults.dictionary(forKey: K.waterHistory) as? [String: Int]) ?? [:]
        waterCupsToday = waterDict[today] ?? 0

        // Clockout
        let hhmm = defaults.string(forKey: K.clockoutHHmm) ?? "18:00"
        let parts = hhmm.split(separator: ":").map { Int($0) ?? 0 }
        if parts.count == 2 {
            clockoutHour = parts[0]
            clockoutMinute = parts[1]
        } else {
            clockoutHour = 18
            clockoutMinute = 0
        }
    }

    private func recomputeAll() {
        recomputeWeekend()
        if let start = sitStart {
            sitElapsedSec = max(0, Int(Date().timeIntervalSince(start)))
        }
    }

    // MARK: - Helpers

    private static func dateKey(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
