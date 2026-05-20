//
//  ExpandedView.swift
//  摸鱼侠 plugin v0.1
//
//  Top-level panel container — 380×620 (40pt notch + 580pt content).
//  Renders title bar + 5-tab pill strip + active tab body + footer.
//

import SwiftUI

struct ExpandedView: View {
    @ObservedObject var store: WorkerStore = .shared

    enum Tab: String, CaseIterable, Identifiable {
        case pomodoro = "番茄"
        case sit      = "久坐"
        case water    = "喝水"
        case clockout = "下班"
        case weekend  = "周末"
        var id: String { rawValue }

        var emoji: String {
            switch self {
            case .pomodoro: return "🍅"
            case .sit:      return "🪑"
            case .water:    return "💧"
            case .clockout: return "🏃"
            case .weekend:  return "🎉"
            }
        }
    }

    @State private var tab: Tab = .pomodoro

    var body: some View {
        VStack(spacing: 0) {
            // Notch reservation (40pt) — same pattern as 看盘侠 / Music
            // Player. Host's floating back-chevron lives here.
            Color.clear.frame(height: 40)
            topBar
            tabStrip
            body_
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 380, height: 620)
        .background(
            ZStack {
                WorkerTheme.panelBg
                RadialGradient(
                    colors: [Color.white.opacity(0.04), Color.clear],
                    center: .top,
                    startRadius: 4, endRadius: 220
                )
            }
        )
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 28, bottomTrailing: 28, topTrailing: 0)
            )
        )
        .onAppear {
            store.start()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(WorkerTheme.lime)
                    .frame(width: 7, height: 7)
                    .shadow(color: WorkerTheme.lime.opacity(0.6), radius: 4)
                Text("摸鱼侠")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WorkerTheme.fgPrimary)
            }
            Spacer()
            // Notification status dot — green = authorized, dim = falling
            // back to in-panel pulses.
            Circle()
                .fill(store.notificationsAuthorized ? WorkerTheme.lime.opacity(0.7) : WorkerTheme.fg35)
                .frame(width: 6, height: 6)
                .help(store.notificationsAuthorized ? "通知已开启" : "通知未开启 · 仅面板提示")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        // 5 tabs at 380pt panel — give them equal share with tight pad.
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { t in
                tabPill(tab: t, selected: tab == t) { tab = t }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tabPill(tab t: Tab, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(t.emoji).font(.system(size: 11))
                Text(t.rawValue)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundColor(selected ? Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0B/255) : WorkerTheme.fg70)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(selected ? WorkerTheme.lime : WorkerTheme.overlay04)
                    .overlay(
                        Capsule()
                            .stroke(selected ? Color.clear : WorkerTheme.overlay08, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body

    @ViewBuilder
    private var body_: some View {
        switch tab {
        case .pomodoro: PomodoroView(store: store)
        case .sit:      SitView(store: store)
        case .water:    WaterView(store: store)
        case .clockout: ClockoutView(store: store)
        case .weekend:  WeekendView(store: store)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                LiveDot()
                Text(footerLeftText)
            }
            Spacer()
            Text("v0.3.0 · 本地运行")
        }
        .font(.system(size: 11))
        .foregroundColor(WorkerTheme.fg40)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Rectangle()
                .fill(Color.clear)
                .overlay(
                    Rectangle()
                        .fill(WorkerTheme.overlay04)
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }

    private var footerLeftText: String {
        switch tab {
        case .pomodoro: return "今日 \(store.pomodoroTodayCount) 个番茄"
        case .sit:      return store.sitStart == nil ? "未开始计时" : "久坐监控中"
        case .water:    return "目标 \(store.waterGoal) 杯"
        case .clockout: return String(format: "%02d:%02d 下班", store.clockoutHour, store.clockoutMinute)
        case .weekend:  return "下个周六"
        }
    }
}

// MARK: - Live dot

private struct LiveDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(WorkerTheme.lime)
            .frame(width: 6, height: 6)
            .shadow(color: WorkerTheme.lime.opacity(0.7), radius: 4)
            .scaleEffect(pulse ? 0.8 : 1.0)
            .opacity(pulse ? 0.4 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
