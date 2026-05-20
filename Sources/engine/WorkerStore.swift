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
    static let pomodoroQualityHist   = "pomodoro.qualityHistory" // [String: [Double]] (yyyy-MM-dd → [quality, ...])
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
    static let waterAutoFromPomo     = "water.autoFromPomo"      // Bool, default true
    static let waterHourlyReminder   = "water.hourlyReminder"    // Bool, default true
    static let lastWaterReminderHr   = "water.lastReminderHour"  // String "yyyy-MM-dd HH" — last hour that fired, scoped per-day
    static let clockoutHHmm          = "clockout.hhmm"           // String "18:00"
    static let lastClockoutCelebDate = "clockout.lastCelebDate"  // String yyyy-MM-dd, dedupe per-day
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
    /// Today's average focus-quality score (0..10). 10 = full focus
    /// (no >30s idle gap during any focus phase); 0 = idle the whole
    /// time. Updated each time a focus phase ends.
    @Published var pomodoroQualityTodayAvg: Double = 0
    /// Number of focus phases that contributed to today's avg.
    /// Used by PomodoroView to dim the score when n=0.
    @Published var pomodoroQualityTodayN: Int = 0
    /// Idle seconds accumulated within the active focus phase. A "second
    /// of idleness" = a 1Hz tick where SystemIdle.seconds > 30. Used to
    /// compute the focus quality on phase end.
    private var currentFocusIdleSec: Int = 0

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
    /// When ON (default), completing a pomodoro focus phase auto-adds
    /// 1 cup. Lazy-tracker users get streak-built without manual taps.
    @Published var waterAutoFromPomodoro: Bool = true
    /// When ON (default), hourly notification fires during 9-18 if today's
    /// cups < goal. Dedupe by last-fired-hour so plugin restart doesn't
    /// double-fire the same hour.
    @Published var waterHourlyReminder: Bool = true

    /// Clockout
    @Published var clockoutHour: Int = 18
    @Published var clockoutMinute: Int = 0
    /// Brief celebratory flag — true for ~5s after crossing the clockout
    /// boundary. ClockoutView reads this to overlay a banner. Reset by
    /// the tick after the fade window.
    @Published var clockoutCelebrationActive: Bool = false
    /// Wallclock at which celebration should clear. Tick monitors this.
    private var clockoutCelebrationEndsAt: Date? = nil
    /// Previous tick's clockout remaining seconds. Used to detect the
    /// >0 → 0 crossing edge.
    private var prevClockoutRemSec: Int? = nil

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
            // Accumulate idle time during focus phases so we can score
            // quality on phase end. Threshold > 30s drops "I'm thinking
            // about the code" false positives but catches "I went to
            // Slack / opened YouTube" real distractions.
            if pomodoroPhase == .focus && SystemIdle.seconds > 30 {
                currentFocusIdleSec += 1
            }
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

            // Threshold notification — fire once, then reset the
            // accumulator so the next triggerSec of sitting kicks a
            // FRESH cycle. The prior dedupe-by-lastFired path kept the
            // counter monotonically growing, so the panel showed "已坐
            // 90 分钟" / "已坐 135 分钟" instead of restarting each
            // cycle. Reset is the simpler dedupe: physically can't
            // re-fire until the user accumulates another triggerSec.
            let triggerSec = sitTriggerMin * 60
            if triggerSec > 0 && sitElapsedSec >= triggerSec {
                WorkerNotificationCenter.shared.notify(
                    title: "该起来动一下了",
                    body: "你已连续坐了 \(sitTriggerMin) 分钟，起身喝口水吧。"
                )
                // 1Hz × 15 ticks of system Morse tone — the UN
                // notification ding is too easy to miss in a meeting,
                // so the sit alert gets a louder, longer signal.
                SoundPlayer.shared.playMorseSitAlert(count: 15)
                WorkerDebugLog.write("sit threshold fired @ \(sitElapsedSec)s — resetting accumulator")

                // Reset for next cycle. Update lastFired for telemetry
                // even though it's no longer the dedupe gate.
                sitAccumActiveSec = 0
                sitElapsedSec = 0
                defaults.set(0, forKey: K.sitAccumActive)
                defaults.set(Date().timeIntervalSince1970, forKey: K.sitLastNotified)
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

        // 3.5. Water hourly reminder — workday window only.
        maybeFireWaterHourlyReminder(now: now)

        // 4. Clockout — fire celebration on the boundary crossing edge.
        let curClockoutRem = clockoutRemainingSec
        if let prev = prevClockoutRemSec, prev > 0 && curClockoutRem == 0 {
            triggerClockoutCelebrationIfNeeded()
        }
        prevClockoutRemSec = curClockoutRem
        // Clear the celebration flag once the fade window elapses.
        if let endsAt = clockoutCelebrationEndsAt, Date() >= endsAt {
            clockoutCelebrationActive = false
            clockoutCelebrationEndsAt = nil
        }

        // 5. Detect day rollover for pomodoro / water / sit counters.
        rolloverIfNeeded()
    }

    /// Hourly water nag — fires once at the top of the hour during
    /// workday (9..18) on weekdays if the user's behind their cup goal.
    /// Dedupes by storing the last-fired hour; plugin restart inside
    /// the same hour won't re-fire.
    private func maybeFireWaterHourlyReminder(now: Date) {
        guard waterHourlyReminder else { return }
        // Weekend = no nag — combined with the existing isWeekend gate
        // for clockout, this keeps Saturday/Sunday quiet.
        let weekday = calendar.component(.weekday, from: now)
        guard (2...6).contains(weekday) else { return }
        let hour = calendar.component(.hour, from: now)
        guard (9...18).contains(hour) else { return }
        // Already reached goal — no nag.
        guard waterCupsToday < waterGoal else { return }
        // Scope dedupe by date+hour so yesterday's 17:00 doesn't block
        // today's 17:00. Prior int-only key blocked the same hour
        // forever within calendar 24h cycles.
        let key = "\(Self.dateKey(now, calendar: calendar)) \(String(format: "%02d", hour))"
        let lastFiredKey = defaults.string(forKey: K.lastWaterReminderHr) ?? ""
        guard lastFiredKey != key else { return }
        defaults.set(key, forKey: K.lastWaterReminderHr)
        let remaining = waterGoal - waterCupsToday
        WorkerNotificationCenter.shared.notify(
            title: "💧 喝水时间到",
            body: "今天已喝 \(waterCupsToday) 杯，距 \(waterGoal) 杯目标还差 \(remaining) 杯。"
        )
        WorkerDebugLog.write("water hourly reminder fired @ \(hour):00, cups \(waterCupsToday)/\(waterGoal)")
    }

    /// Per-day-deduped celebration trigger. Fires UN notification +
    /// Glass tone × 3 + sets the in-panel banner flag for ~5s.
    private func triggerClockoutCelebrationIfNeeded() {
        let today = Self.dateKey(Date(), calendar: calendar)
        let lastCeleb = defaults.string(forKey: K.lastClockoutCelebDate) ?? ""
        guard lastCeleb != today else {
            WorkerDebugLog.write("clockout boundary @ \(today) but already celebrated, skip")
            return
        }
        defaults.set(today, forKey: K.lastClockoutCelebDate)

        WorkerDebugLog.write("clockout celebration fired for \(today)")
        WorkerNotificationCenter.shared.notify(
            title: "今日打卡下班 🎉",
            body: "辛苦了，到点了，关 IDE 下班！"
        )
        SoundPlayer.shared.playClockoutCelebration()
        clockoutCelebrationActive = true
        clockoutCelebrationEndsAt = Date().addingTimeInterval(5.0)
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

            // Cross-tab boost: a completed focus phase auto-logs a cup
            // of water unless the user has flipped the toggle off.
            // Rationale: people who do pomodoro typically need a break +
            // water anyway — couple the data so they don't have to tap.
            if waterAutoFromPomodoro {
                waterAddCup()
                WorkerDebugLog.write("water +1 from pomodoro phase end")
            }

            // Score the just-ended focus phase. focusSec is the total
            // wallclock length (pomodoroFocusMin × 60); idleSec is what
            // tickFire accumulated. quality = 10 × (1 − idle/total).
            let focusSec = max(1, pomodoroFocusMin * 60)
            let idleSec = min(currentFocusIdleSec, focusSec)
            let quality = 10.0 * (1.0 - Double(idleSec) / Double(focusSec))
            recordPomodoroQuality(quality)
            WorkerDebugLog.write("pomodoro focus quality = \(String(format: "%.1f", quality)) (idle \(idleSec)s / \(focusSec)s)")
            currentFocusIdleSec = 0  // reset for next focus

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

    /// Append `q` to today's quality list and recompute the published
    /// average. Stored as `[String: [Double]]` in defaults — keyed by
    /// the same yyyy-MM-dd date string as pomodoroHistory so a
    /// future "today: 6 focuses, avg 8.4/10" reads both in sync.
    private func recordPomodoroQuality(_ q: Double) {
        let today = Self.dateKey(Date(), calendar: calendar)
        var dict = (defaults.dictionary(forKey: K.pomodoroQualityHist) as? [String: [Double]]) ?? [:]
        var list = dict[today] ?? []
        list.append(q)
        dict[today] = list
        defaults.set(dict, forKey: K.pomodoroQualityHist)
        pomodoroQualityTodayN = list.count
        pomodoroQualityTodayAvg = list.reduce(0, +) / Double(list.count)
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
        // Silence any in-flight Morse alert from a prior trigger so the
        // user stopping monitoring also stops the nag immediately.
        SoundPlayer.shared.stop()
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

    func waterSetAutoFromPomodoro(_ on: Bool) {
        waterAutoFromPomodoro = on
        defaults.set(on, forKey: K.waterAutoFromPomo)
    }

    func waterSetHourlyReminder(_ on: Bool) {
        waterHourlyReminder = on
        defaults.set(on, forKey: K.waterHourlyReminder)
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

    /// Seconds remaining until **today's** clockout. Returns 0 when
    /// already past — the next day rolls automatically when calendar's
    /// dateComponents(.year,.month,.day, from: now) picks up the new
    /// date after midnight.
    ///
    /// Prior version rolled forward to tomorrow on `target <= now`, so
    /// the moment clockout was hit the counter jumped 1s → 86399s with
    /// no observable "zero" frame — celebrating the "下班" moment was
    /// impossible. Now: hit zero, hold zero until midnight, restart at
    /// new day's wall-time countdown.
    /// True iff today is Saturday or Sunday (local time). Used by
    /// ClockoutView to switch to a "今天不上班" mode without forcing
    /// the user to fiddle with their clockout time on the weekend.
    /// Next statutory China holiday, or nil if none configured.
    /// Backed by `HolidayDatabase`. WeekendView uses this to render
    /// the "距下个法定假 N 天" card.
    var nextHoliday: UpcomingHoliday? {
        HolidayDatabase.upcoming(from: Date(), timeZone: calendar.timeZone)
    }

    var isWeekend: Bool {
        let weekday = calendar.component(.weekday, from: Date())
        return weekday == 1 || weekday == 7  // Sun = 1, Sat = 7
    }

    var clockoutRemainingSec: Int {
        let now = Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = clockoutHour
        comps.minute = clockoutMinute
        comps.second = 0
        guard let target = calendar.date(from: comps) else { return 0 }
        if target <= now { return 0 }
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
            // Quality history resets too.
            let qDict = (defaults.dictionary(forKey: K.pomodoroQualityHist) as? [String: [Double]]) ?? [:]
            let todayQs = qDict[today] ?? []
            pomodoroQualityTodayN = todayQs.count
            pomodoroQualityTodayAvg = todayQs.isEmpty ? 0 : todayQs.reduce(0, +) / Double(todayQs.count)
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

        // Quality history for today (used for the "今日均分" stat card).
        let qDict = (defaults.dictionary(forKey: K.pomodoroQualityHist) as? [String: [Double]]) ?? [:]
        let todayQs = qDict[today] ?? []
        pomodoroQualityTodayN = todayQs.count
        pomodoroQualityTodayAvg = todayQs.isEmpty ? 0 : todayQs.reduce(0, +) / Double(todayQs.count)

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
        // Toggle defaults — "explicit-set check" so an installed-with-
        // false user doesn't get flipped back to true on update.
        waterAutoFromPomodoro = defaults.object(forKey: K.waterAutoFromPomo) != nil
            ? defaults.bool(forKey: K.waterAutoFromPomo)
            : true
        waterHourlyReminder = defaults.object(forKey: K.waterHourlyReminder) != nil
            ? defaults.bool(forKey: K.waterHourlyReminder)
            : true

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
