//
//  WorkerStore.swift
//  摸鱼侠 plugin
//
//  Single source of truth for all five tabs. Holds:
//    - pomodoro state machine (idle / focus / break / paused) driven by
//      a wallclock end-time so sleep / lock / app-quit don't lie about
//      remaining time
//    - sit-timer = accumulator of "seconds the user was actually
//      active." Idle > breakResetThreshold → counter resets (you got up
//      from the desk). The old startTimestamp model would count lunch
//      as sitting; this one only counts real input.
//    - pomodoro auto-loop with classic 4-focus → long-break cycle
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
    static let pomodoroHistory       = "pomodoro.history"        // [String: Int] (yyyy-MM-dd → count)
    static let pomodoroFocusMin      = "pomodoro.focusMin"       // Int, default 25
    static let pomodoroBreakMin      = "pomodoro.breakMin"       // Int, default 5
    static let pomodoroLongBreakMin  = "pomodoro.longBreakMin"   // Int, default 15
    static let pomodoroPhaseRaw      = "pomodoro.phaseRaw"       // String, current phase
    static let pomodoroEndsAt        = "pomodoro.endsAt"         // Double (timeIntervalSince1970), 0 = nil
    static let pomodoroAutoLoop      = "pomodoro.autoLoop"       // Bool, default true
    static let pomodoroCycleProg     = "pomodoro.cycleProgress"  // Int, 0..4 — focuses done in current 4-pack
    static let pomodoroPausedPhase   = "pomodoro.pausedPhase"    // String, phase to resume
    static let pomodoroPausedRemain  = "pomodoro.pausedRemain"   // Int seconds
    static let sitEnabled            = "sit.enabled"             // Bool, monitoring on/off
    static let sitTriggerMin         = "sit.triggerMin"          // Int, default 45
    static let sitLastNotified       = "sit.lastNotified"        // Double — last fired notification ts, to dedupe
    static let sitAccumActive        = "sit.accumActive"         // Int seconds, persisted active time
    static let waterHistory          = "water.history"           // [String: Int] (date → cups)
    static let waterGoal             = "water.goal"              // Int, default 8
    static let clockoutHHmm          = "clockout.hhmm"           // String "18:00"
}

private let suiteName = "com.mioisland.plugin.worker"

/// User went idle for this many seconds → we count the sitting session as broken.
/// 5 minutes is the bathroom-break / coffee-refill threshold: shorter idleness
/// (looking out the window, on a phone call) shouldn't reset the streak.
private let sitBreakResetThresholdSec: Double = 5 * 60

/// Persist sit counter every N ticks to avoid hammering UserDefaults each second.
private let sitPersistEveryTicks: Int = 30

/// If two consecutive tick fires are this far apart in wallclock, the
/// system was probably asleep (Timer pauses during sleep). Treat the
/// gap as "user was away" and reset the sit accumulator.
private let tickGapWakeThresholdSec: Double = 30

// MARK: - Pomodoro phase

enum PomodoroPhase: String {
    case idle      // not running
    case focus     // focus session going
    case rest      // break going
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
    @Published var pomodoroRemaining: Int = 25 * 60   // seconds, derived from pomodoroPhaseEndsAt each tick
    @Published var pomodoroFocusMin: Int = 25
    @Published var pomodoroBreakMin: Int = 5
    @Published var pomodoroLongBreakMin: Int = 15
    @Published var pomodoroTodayCount: Int = 0
    @Published var pomodoroAutoLoop: Bool = true
    /// 0..4 — number of focuses completed in the current 4-pack. After
    /// the 4th focus, the upcoming break is a long one; after the long
    /// break ends, this resets to 0. Dot indicator in PomodoroView reads
    /// this to draw the "🍅🍅⚪️⚪️" cycle position.
    @Published var pomodoroCycleProgress: Int = 0

    /// Wallclock target. tick computes remaining = endsAt - now. Storing
    /// this (instead of decrementing a counter every second) means the
    /// timer is correct after sleep, lock, app quit, anything.
    private var pomodoroPhaseEndsAt: Date? = nil

    /// Pre-pause snapshot so resume can restore the underlying phase.
    private var pausedPhase: PomodoroPhase = .focus
    private var pausedRemaining: Int = 25 * 60

    /// Sit
    /// Kept as Date? for UI compat — nil = monitoring off, non-nil = on.
    /// The actual elapsed value is in sitElapsedSec, computed from the
    /// accumulator below — NOT from this Date.
    @Published var sitStart: Date? = nil
    @Published var sitTriggerMin: Int = 45
    @Published var sitElapsedSec: Int = 0

    /// Accumulator — incremented each tick where the user looked active
    /// (idle < ~1 min) and reset when they're away long enough to count
    /// as a real break. This is what gets shown to the user.
    private var sitAccumActiveSec: Int = 0
    private var sitTickCount: Int = 0
    /// Wallclock timestamp of the last tick fire. A gap larger than
    /// `tickGapWakeThreshold` means the system slept (Timer doesn't run
    /// while the Mac is asleep). On wake, idle-time API resets to ~0
    /// immediately because the unlock counts as input — so we can't
    /// rely on it alone to detect "user came back from a long break."
    /// The wallclock gap is the missing signal.
    private var lastTickAt: Date? = nil

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
        // Flush any unsaved sit progress before going dark.
        defaults.set(sitAccumActiveSec, forKey: K.sitAccumActive)
    }

    // MARK: - Tick (1Hz)

    private func tickFire() {
        // Detect system-sleep gaps. Timer.scheduledTimer pauses while
        // the Mac is asleep, so two consecutive fires more than
        // `tickGapWakeThresholdSec` apart means the user almost
        // certainly stepped away (lid closed for lunch, etc).
        let now = Date()
        let sleepGap: TimeInterval = lastTickAt.map { now.timeIntervalSince($0) } ?? 0
        let didSleepWake = sleepGap > tickGapWakeThresholdSec
        lastTickAt = now

        // 1. Pomodoro — wallclock countdown.
        if let endsAt = pomodoroPhaseEndsAt,
           pomodoroPhase == .focus || pomodoroPhase == .rest {
            let remaining = max(0, Int(endsAt.timeIntervalSinceNow))
            pomodoroRemaining = remaining
            if remaining <= 0 {
                pomodoroPhaseEnded()
            }
        }

        // 2. Sit — input-idle accumulator.
        if sitStart != nil {
            // System wake from sleep counts as "stepped away" — clear the
            // counter so 4 hours of lid-closed doesn't show as 4 hours
            // of sitting.
            if didSleepWake {
                if sitAccumActiveSec > 0 {
                    WorkerDebugLog.write("sit reset: woke from \(Int(sleepGap))s sleep gap")
                }
                sitAccumActiveSec = 0
                defaults.set(0.0, forKey: K.sitLastNotified)
            }

            let idle = SystemIdle.seconds
            if idle >= sitBreakResetThresholdSec {
                // User has been away long enough that we count it as a
                // real break. Reset the active-time counter and the
                // notification dedupe so the next sitting session can
                // trigger a fresh alert.
                if sitAccumActiveSec > 0 {
                    WorkerDebugLog.write("sit reset: idle=\(Int(idle))s ≥ threshold")
                }
                sitAccumActiveSec = 0
                defaults.set(0.0, forKey: K.sitLastNotified)
            } else if idle < 60 {
                // User is currently active (last input within ~1 min).
                // Each 1Hz tick under that condition counts as one
                // second of "real sitting" — naturally pauses while
                // they're idle 1-5 min (e.g. on a call) and resets if
                // they leave for longer.
                sitAccumActiveSec += 1
            }
            // else: idle 1-5 min → hold steady, neither grow nor reset.

            sitElapsedSec = sitAccumActiveSec

            // Threshold notification, deduped by triggerSec.
            let triggerSec = sitTriggerMin * 60
            if triggerSec > 0 && sitElapsedSec >= triggerSec {
                let lastFired = defaults.double(forKey: K.sitLastNotified)
                let nowTs = Date().timeIntervalSince1970
                if nowTs - lastFired >= Double(triggerSec) {
                    defaults.set(nowTs, forKey: K.sitLastNotified)
                    WorkerNotificationCenter.shared.notify(
                        title: "该起来动一下了",
                        body: "你已连续坐了 \(sitTriggerMin) 分钟，起身喝口水吧。"
                    )
                    WorkerDebugLog.write("sit threshold notification fired (\(sitElapsedSec)s)")
                }
            }

            // Persist accumulator once every N ticks (cheap & resilient).
            sitTickCount += 1
            if sitTickCount >= sitPersistEveryTicks {
                sitTickCount = 0
                defaults.set(sitAccumActiveSec, forKey: K.sitAccumActive)
            }
        } else {
            sitElapsedSec = 0
        }

        // 3. Weekend countdown — recompute every tick (cheap).
        recomputeWeekend()

        // 4. Detect day rollover for pomodoro / water / sit counters.
        rolloverIfNeeded()
    }

    // MARK: - Pomodoro

    /// Total duration (seconds) of the active phase. Used as denominator
    /// for the progress ring fraction in PomodoroView.
    ///
    /// P0 fix (2026-05-19 review): the ring previously used
    /// `pomodoroFocusMin * 60` as denominator for the paused state,
    /// which is wrong when the user paused mid-break (denominator was
    /// 25min while remaining was a break's 5min worth → ring read 80%
    /// done when it was actually ~40%). Now `paused` looks at the
    /// underlying `pausedPhase` so break/long-break paused renders right.
    var pomodoroPhaseTotalSec: Int {
        let isLongBreak = pomodoroCycleProgress >= 4
        switch pomodoroPhase {
        case .focus:
            return pomodoroFocusMin * 60
        case .rest:
            return (isLongBreak ? pomodoroLongBreakMin : pomodoroBreakMin) * 60
        case .paused:
            switch pausedPhase {
            case .rest:
                return (isLongBreak ? pomodoroLongBreakMin : pomodoroBreakMin) * 60
            default:
                return pomodoroFocusMin * 60
            }
        case .idle:
            return pomodoroFocusMin * 60
        }
    }

    func pomodoroStart() {
        if pomodoroPhase == .paused {
            pomodoroPhase = pausedPhase
            pomodoroRemaining = pausedRemaining
            pomodoroPhaseEndsAt = Date(timeIntervalSinceNow: TimeInterval(pausedRemaining))
            persistPomodoroRuntime()
            return
        }
        pomodoroPhase = .focus
        pomodoroRemaining = pomodoroFocusMin * 60
        pomodoroPhaseEndsAt = Date(timeIntervalSinceNow: TimeInterval(pomodoroRemaining))
        persistPomodoroRuntime()
    }

    func pomodoroPause() {
        guard pomodoroPhase == .focus || pomodoroPhase == .rest else { return }
        pausedPhase = pomodoroPhase
        // Snapshot the *current* remaining so resume picks up from here,
        // not from the original start.
        if let endsAt = pomodoroPhaseEndsAt {
            pausedRemaining = max(0, Int(endsAt.timeIntervalSinceNow))
        } else {
            pausedRemaining = pomodoroRemaining
        }
        pomodoroPhase = .paused
        pomodoroPhaseEndsAt = nil
        persistPomodoroRuntime()
    }

    func pomodoroReset() {
        pomodoroPhase = .idle
        pomodoroRemaining = pomodoroFocusMin * 60
        pomodoroPhaseEndsAt = nil
        pausedRemaining = pomodoroFocusMin * 60
        // Keep cycleIndex — resetting mid-cycle shouldn't lose your progress.
        persistPomodoroRuntime()
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

    func pomodoroSetLongBreak(_ min: Int) {
        let v = max(1, min)
        pomodoroLongBreakMin = v
        defaults.set(v, forKey: K.pomodoroLongBreakMin)
    }

    func pomodoroSetAutoLoop(_ on: Bool) {
        pomodoroAutoLoop = on
        defaults.set(on, forKey: K.pomodoroAutoLoop)
    }

    private func pomodoroPhaseEnded() {
        switch pomodoroPhase {
        case .focus:
            // Increment today's tally + advance the cycle counter.
            pomodoroTodayCount += 1
            persistPomodoroToday()
            pomodoroCycleProgress = min(4, pomodoroCycleProgress + 1)
            defaults.set(pomodoroCycleProgress, forKey: K.pomodoroCycleProg)

            // 4th focus in the cycle → long break; otherwise short.
            let isLongBreak = pomodoroCycleProgress >= 4
            let breakMin = isLongBreak ? pomodoroLongBreakMin : pomodoroBreakMin
            let bodyText = isLongBreak
                ? "完成 4 个番茄，享受 \(breakMin) 分钟长休息。"
                : "干得漂亮！开始 \(breakMin) 分钟休息。"
            WorkerNotificationCenter.shared.notify(
                title: "番茄完成 🍅",
                body: bodyText
            )
            pomodoroPhase = .rest
            pomodoroRemaining = breakMin * 60
            pomodoroPhaseEndsAt = Date(timeIntervalSinceNow: TimeInterval(pomodoroRemaining))

        case .rest:
            // If we just finished a long break, the next focus starts a
            // fresh 4-pack — reset the dot row.
            let wasLongBreak = pomodoroCycleProgress >= 4
            if wasLongBreak {
                pomodoroCycleProgress = 0
                defaults.set(0, forKey: K.pomodoroCycleProg)
            }
            // Auto-loop: jump straight into the next focus instead of
            // sitting idle waiting for the user to come tap "开始" again.
            // Classic Pomodoro rhythm — start once, run all morning.
            if pomodoroAutoLoop {
                WorkerNotificationCenter.shared.notify(
                    title: "下一个番茄开始 🍅",
                    body: "回到工作 — \(pomodoroFocusMin) 分钟专注开始。"
                )
                pomodoroPhase = .focus
                pomodoroRemaining = pomodoroFocusMin * 60
                pomodoroPhaseEndsAt = Date(timeIntervalSinceNow: TimeInterval(pomodoroRemaining))
            } else {
                WorkerNotificationCenter.shared.notify(
                    title: "休息结束",
                    body: "回到工作 — 再来一个 \(pomodoroFocusMin) 分钟番茄？"
                )
                pomodoroPhase = .idle
                pomodoroRemaining = pomodoroFocusMin * 60
                pomodoroPhaseEndsAt = nil
            }
        default:
            break
        }
        persistPomodoroRuntime()
    }

    private func persistPomodoroToday() {
        var dict = (defaults.dictionary(forKey: K.pomodoroHistory) as? [String: Int]) ?? [:]
        dict[Self.dateKey(Date(), calendar: calendar)] = pomodoroTodayCount
        defaults.set(dict, forKey: K.pomodoroHistory)
    }

    /// Persist the runtime fields that change with start/pause/reset/phase
    /// transitions. Keeps a relaunch consistent with what the user saw.
    private func persistPomodoroRuntime() {
        defaults.set(pomodoroPhase.rawValue, forKey: K.pomodoroPhaseRaw)
        defaults.set(pomodoroPhaseEndsAt?.timeIntervalSince1970 ?? 0.0, forKey: K.pomodoroEndsAt)
        defaults.set(pausedPhase.rawValue, forKey: K.pomodoroPausedPhase)
        defaults.set(pausedRemaining, forKey: K.pomodoroPausedRemain)
    }

    // MARK: - Sit

    func sitStartNow() {
        sitStart = Date()
        sitAccumActiveSec = 0
        sitElapsedSec = 0
        sitTickCount = 0
        defaults.set(true, forKey: K.sitEnabled)
        defaults.set(0, forKey: K.sitAccumActive)
        defaults.set(0.0, forKey: K.sitLastNotified)
    }

    func sitStop() {
        sitStart = nil
        sitAccumActiveSec = 0
        sitElapsedSec = 0
        sitTickCount = 0
        defaults.set(false, forKey: K.sitEnabled)
        defaults.set(0, forKey: K.sitAccumActive)
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
            // Sitting through midnight is weird — start a fresh day's
            // active-time count so the badge doesn't show "已坐 1380 分".
            sitAccumActiveSec = 0
            defaults.set(0, forKey: K.sitAccumActive)
        }
    }

    // MARK: - Load + recompute

    private func loadPersisted() {
        // Pomodoro — settings.
        let storedFocus = defaults.integer(forKey: K.pomodoroFocusMin)
        pomodoroFocusMin = storedFocus > 0 ? storedFocus : 25
        let storedBreak = defaults.integer(forKey: K.pomodoroBreakMin)
        pomodoroBreakMin = storedBreak > 0 ? storedBreak : 5
        let storedLong = defaults.integer(forKey: K.pomodoroLongBreakMin)
        pomodoroLongBreakMin = storedLong > 0 ? storedLong : 15
        // autoLoop default true — only flip if explicitly written to false.
        if defaults.object(forKey: K.pomodoroAutoLoop) != nil {
            pomodoroAutoLoop = defaults.bool(forKey: K.pomodoroAutoLoop)
        } else {
            pomodoroAutoLoop = true
        }
        pomodoroCycleProgress = max(0, min(4, defaults.integer(forKey: K.pomodoroCycleProg)))

        let pomDict = (defaults.dictionary(forKey: K.pomodoroHistory) as? [String: Int]) ?? [:]
        let today = Self.dateKey(Date(), calendar: calendar)
        pomodoroTodayCount = pomDict[today] ?? 0
        lastSeenDay = today

        // Pomodoro — runtime resume.
        let pausedRaw = defaults.string(forKey: K.pomodoroPausedPhase) ?? "focus"
        pausedPhase = PomodoroPhase(rawValue: pausedRaw) ?? .focus
        let storedPausedRem = defaults.integer(forKey: K.pomodoroPausedRemain)
        pausedRemaining = storedPausedRem > 0 ? storedPausedRem : pomodoroFocusMin * 60

        let phaseRaw = defaults.string(forKey: K.pomodoroPhaseRaw) ?? "idle"
        let savedPhase = PomodoroPhase(rawValue: phaseRaw) ?? .idle
        let endsAtTs = defaults.double(forKey: K.pomodoroEndsAt)

        if savedPhase == .paused {
            // Pause survives across launches with its remaining intact.
            pomodoroPhase = .paused
            pomodoroRemaining = pausedRemaining
            pomodoroPhaseEndsAt = nil
        } else if endsAtTs > 0 && (savedPhase == .focus || savedPhase == .rest) {
            let endsAt = Date(timeIntervalSince1970: endsAtTs)
            let now = Date()
            if endsAt > now {
                // Still running.
                pomodoroPhase = savedPhase
                pomodoroPhaseEndsAt = endsAt
                pomodoroRemaining = max(0, Int(endsAt.timeIntervalSinceNow))
            } else {
                // Phase ended while we were away. If a focus was lost,
                // count it once. We don't try to fast-forward through
                // multiple phases — just resume to idle and let the
                // user start fresh.
                if savedPhase == .focus {
                    pomodoroTodayCount += 1
                    persistPomodoroToday()
                    pomodoroCycleProgress = min(4, pomodoroCycleProgress + 1)
                    defaults.set(pomodoroCycleProgress, forKey: K.pomodoroCycleProg)
                    WorkerDebugLog.write("pomodoro: caught up 1 missed focus on launch")
                }
                pomodoroPhase = .idle
                pomodoroRemaining = pomodoroFocusMin * 60
                pomodoroPhaseEndsAt = nil
                defaults.set(0.0, forKey: K.pomodoroEndsAt)
                defaults.set(PomodoroPhase.idle.rawValue, forKey: K.pomodoroPhaseRaw)
            }
        } else {
            pomodoroPhase = .idle
            pomodoroRemaining = pomodoroFocusMin * 60
            pomodoroPhaseEndsAt = nil
        }

        // Sit — settings + accumulator.
        let storedTrig = defaults.integer(forKey: K.sitTriggerMin)
        sitTriggerMin = storedTrig > 0 ? storedTrig : 45
        // Read enabled flag with explicit "never set" check so default-on
        // doesn't bite users who have disabled monitoring.
        if defaults.object(forKey: K.sitEnabled) != nil {
            let on = defaults.bool(forKey: K.sitEnabled)
            sitStart = on ? Date() : nil
        } else {
            sitStart = nil
        }
        sitAccumActiveSec = max(0, defaults.integer(forKey: K.sitAccumActive))
        sitElapsedSec = sitAccumActiveSec
        sitTickCount = 0

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
        // sitElapsedSec is the accumulator; nothing to recompute on its
        // own — the next tickFire will refresh it.
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
