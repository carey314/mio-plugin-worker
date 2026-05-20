//
//  SoundPlayer.swift
//  摸鱼侠 plugin v0.2.1
//
//  Sit-reminder alert tone. The bundled UN notification sound is a
//  ~1s ding that's easy to miss in a meeting — for sit alerts we want
//  a 15s nag that makes you actually stand up.
//
//  Implementation: repeat the macOS system "Morse" sound (0.7s) once
//  per second for 15 ticks. Morse is the most distinctive notification
//  sound shipped with macOS — staccato 3-tone "S O S" pattern that
//  pierces background noise better than Glass/Hero/Ping/Funk/etc.
//
//  Plays via NSSound (not UNNotificationContent.sound) because UN
//  sounds are limited to ~30s but get truncated to ~5s on macOS, and
//  attach a single tone to a single notification — no way to fire a
//  repeated sequence from UN.
//

import AppKit
import Foundation

@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    private init() {}

    /// Sit-alert sound. Picked Submarine (1.5s sonar ping) over the
    /// original Morse — the sonar's longer sustain + lower pitch
    /// pierces noise-cancelling headphones and meeting audio better,
    /// while the 15-second 1Hz cadence still drives the urgency.
    /// To switch back: change to "Morse" / "Tink" / "Ping" / etc.
    /// All built-in: /System/Library/Sounds/*.aiff
    private let sitAlertURL = URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff")

    private var timer: Timer?
    private var remaining: Int = 0
    private var currentSound: NSSound?

    /// Repeated sit alert: play `count` times at 1Hz. Each play is a
    /// fresh NSSound so previous-in-flight playback doesn't get stomped
    /// (NSSound.play() is non-blocking; Submarine's 1.5s overlap with
    /// the next-second trigger creates a slightly layered effect —
    /// acoustically more present than crisp single beeps).
    ///
    /// Calling while a previous alert is still running cancels the old
    /// one and restarts from `count`. This keeps "user sat back down +
    /// trigger fired again 45min later" clean.
    ///
    /// Name retained for source compat (callsite is single, low cost).
    func playMorseSitAlert(count: Int = 15) {
        stop()
        remaining = count
        playOnce()  // fire immediately, then 1Hz repeat
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.playOnce() }
        }
    }

    /// Clockout celebration tone — Hero (1.1s heroic fanfare),
    /// played 3 times with 0.6s gap. Picked over the original Glass
    /// for more triumph energy on the "下班" moment. Glass was
    /// "✨ achievement"; Hero is "🎺 victory" — appropriate scale.
    /// To switch: change to "Funk" / "Sosumi" / "Glass" / etc.
    func playClockoutCelebration() {
        stop()
        let celebrationURL = URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff")
        // 3 chimes at 0s, 0.6s, 1.2s — full shot of joy, not a nag.
        // Schedule with DispatchQueue async since this is a fixed-shot
        // pattern, no need for a Timer loop.
        for delay in [0.0, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let _ = self else { return }
                if let s = NSSound(contentsOf: celebrationURL, byReference: true) {
                    s.play()
                }
            }
        }
    }

    /// Cancel any in-flight alert. Called by WorkerStore.sitStop() so
    /// "user stopped sit monitoring" silences the nag immediately.
    func stop() {
        timer?.invalidate()
        timer = nil
        remaining = 0
        currentSound?.stop()
        currentSound = nil
    }

    private func playOnce() {
        guard remaining > 0 else {
            stop()
            return
        }
        remaining -= 1
        // byReference: true — load lazily from the system path each call.
        // The cost is negligible (< 1ms) and avoids keeping a 200KB AIFF
        // resident across the 45min idle stretch between alerts.
        if let sound = NSSound(contentsOf: sitAlertURL, byReference: true) {
            sound.play()
            currentSound = sound
        } else {
            WorkerDebugLog.write("SoundPlayer: failed to load \(sitAlertURL.path)")
            stop()
        }
    }
}
