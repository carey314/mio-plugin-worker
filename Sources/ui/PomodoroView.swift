//
//  PomodoroView.swift
//  摸鱼侠 plugin v0.1
//
//  Big timer + start/pause/reset + today's count + focus/break adjusters.
//

import SwiftUI

struct PomodoroView: View {
    @ObservedObject var store: WorkerStore

    var body: some View {
        VStack(spacing: 14) {
            phaseHeader

            timerRing

            controls

            Divider()
                .background(WorkerTheme.overlay08)
                .padding(.horizontal, 24)

            statsRow

            settingsRowPrimary
            settingsRowSecondary

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: - Phase header (badge + cycle dots)

    private var phaseHeader: some View {
        HStack(spacing: 10) {
            phaseBadge
            cycleDots
        }
    }

    private var phaseBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
                .shadow(color: phaseColor.opacity(0.7), radius: 4)
            Text(store.pomodoroPhase.label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fg85)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(WorkerTheme.overlay06))
    }

    /// Four dots showing position in the 4-focus cycle. Filled = focus
    /// completed; the last empty dot is the long-break gate. After a
    /// long break the row resets to all empty (fresh cycle).
    private var cycleDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < store.pomodoroCycleProgress ? WorkerTheme.tomato : WorkerTheme.overlay12)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .stroke(WorkerTheme.overlay18, lineWidth: 0.5)
                    )
            }
        }
        .help("4 个番茄一组，第 4 个后进入长休息")
    }

    private var phaseColor: Color {
        switch store.pomodoroPhase {
        case .focus:  return WorkerTheme.tomato
        case .rest:   return WorkerTheme.lime
        case .paused: return WorkerTheme.fg55
        case .idle:   return WorkerTheme.fg40
        }
    }

    // MARK: - Big circular ring

    private var timerRing: some View {
        ZStack {
            // Track
            Circle()
                .stroke(WorkerTheme.overlay08, lineWidth: 8)

            // Progress
            Circle()
                .trim(from: 0, to: progressFraction)
                .stroke(
                    phaseColor,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: store.pomodoroRemaining)

            VStack(spacing: 4) {
                Text(WorkerFormat.mmss(store.pomodoroRemaining))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(WorkerTheme.fgPrimary)
                Text(subText)
                    .font(.system(size: 11))
                    .foregroundColor(WorkerTheme.fg55)
            }
        }
        .frame(width: 200, height: 200)
        .padding(.vertical, 4)
    }

    private var progressFraction: CGFloat {
        let total: Int
        switch store.pomodoroPhase {
        case .focus:           total = store.pomodoroFocusMin * 60
        case .rest:            total = store.pomodoroBreakMin * 60
        case .paused, .idle:   total = store.pomodoroFocusMin * 60
        }
        guard total > 0 else { return 0 }
        let remaining = max(0, store.pomodoroRemaining)
        return CGFloat(total - remaining) / CGFloat(total)
    }

    private var subText: String {
        switch store.pomodoroPhase {
        case .focus:  return "专注 \(store.pomodoroFocusMin) 分钟"
        case .rest:   return "休息 \(store.pomodoroBreakMin) 分钟"
        case .paused: return "点击继续"
        case .idle:   return "准备开始"
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            // Primary start/pause button
            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    Image(systemName: primaryIcon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(primaryLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0B/255))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Capsule().fill(WorkerTheme.lime))
            }
            .buttonStyle(.plain)

            // Reset
            Button(action: { store.pomodoroReset() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重置")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(WorkerTheme.fg85)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(
                    Capsule()
                        .fill(WorkerTheme.overlay06)
                        .overlay(Capsule().stroke(WorkerTheme.overlay12, lineWidth: 0.5))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var primaryIcon: String {
        switch store.pomodoroPhase {
        case .focus, .rest: return "pause.fill"
        default:            return "play.fill"
        }
    }

    private var primaryLabel: String {
        switch store.pomodoroPhase {
        case .focus, .rest: return "暂停"
        case .paused:       return "继续"
        case .idle:         return "开始"
        }
    }

    private func primaryAction() {
        switch store.pomodoroPhase {
        case .focus, .rest:
            store.pomodoroPause()
        case .paused, .idle:
            store.pomodoroStart()
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                title: "今日番茄",
                value: "\(store.pomodoroTodayCount)",
                accent: WorkerTheme.tomato
            )
            statCard(
                title: "专注时长",
                value: "\(store.pomodoroTodayCount * store.pomodoroFocusMin)分",
                accent: WorkerTheme.lime
            )
        }
        .padding(.horizontal, 16)
    }

    private func statCard(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(WorkerTheme.fg55)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(accent)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Settings

    private var settingsRowPrimary: some View {
        HStack(spacing: 10) {
            stepperPill(
                title: "专注",
                value: store.pomodoroFocusMin,
                onMinus: { store.pomodoroSetFocus(store.pomodoroFocusMin - 5) },
                onPlus:  { store.pomodoroSetFocus(store.pomodoroFocusMin + 5) }
            )
            stepperPill(
                title: "短休",
                value: store.pomodoroBreakMin,
                onMinus: { store.pomodoroSetBreak(store.pomodoroBreakMin - 1) },
                onPlus:  { store.pomodoroSetBreak(store.pomodoroBreakMin + 1) }
            )
        }
        .padding(.horizontal, 16)
    }

    private var settingsRowSecondary: some View {
        HStack(spacing: 10) {
            stepperPill(
                title: "长休",
                value: store.pomodoroLongBreakMin,
                onMinus: { store.pomodoroSetLongBreak(store.pomodoroLongBreakMin - 5) },
                onPlus:  { store.pomodoroSetLongBreak(store.pomodoroLongBreakMin + 5) }
            )
            autoLoopPill
        }
        .padding(.horizontal, 16)
    }

    /// Toggle pill for "auto-loop." Tap to flip; visual state mirrors
    /// the running tomato (lime when on). Default is on — unchecking
    /// makes the timer stop after each break for a manual restart.
    private var autoLoopPill: some View {
        Button(action: { store.pomodoroSetAutoLoop(!store.pomodoroAutoLoop) }) {
            HStack(spacing: 6) {
                Image(systemName: store.pomodoroAutoLoop ? "infinity" : "playpause")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(store.pomodoroAutoLoop ? WorkerTheme.lime : WorkerTheme.fg55)
                Text(store.pomodoroAutoLoop ? "自动循环" : "单次")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(store.pomodoroAutoLoop ? WorkerTheme.fgPrimary : WorkerTheme.fg70)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(WorkerTheme.overlay04)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(store.pomodoroAutoLoop ? WorkerTheme.lime.opacity(0.4) : WorkerTheme.overlay08, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(store.pomodoroAutoLoop ? "番茄/休息自动衔接" : "每次休息结束后停下，等你手动开始")
    }

    private func stepperPill(title: String, value: Int, onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg55)
                .padding(.leading, 10)
                .padding(.trailing, 6)

            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)

            Text("\(value)分")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
                .frame(minWidth: 40)

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
    }
}
