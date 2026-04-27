//
//  SitView.swift
//  摸鱼侠 plugin v0.1
//
//  久坐 — countup since "sat down" timestamp. Bouncing ring/dot when
//  threshold crossed. Fires a notification once every triggerMin.
//

import SwiftUI

struct SitView: View {
    @ObservedObject var store: WorkerStore
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 18) {
            statusBadge

            timerDisplay

            controls

            Divider()
                .background(WorkerTheme.overlay08)
                .padding(.horizontal, 24)

            triggerRow

            tipText

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onChange(of: store.sitElapsedSec) { _, newVal in
            // When we cross the trigger boundary, kick the bounce
            // animation to draw the eye to the panel.
            let trig = store.sitTriggerMin * 60
            if trig > 0 && newVal == trig {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) {
                    bounce = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                        bounce = false
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
                .shadow(color: badgeColor.opacity(0.7), radius: 4)
                .scaleEffect(overThreshold ? (bounce ? 1.4 : 1.15) : 1.0)
                .opacity(overThreshold ? 0.95 : 1.0)
            Text(badgeText)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fg85)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(WorkerTheme.overlay06))
    }

    private var badgeText: String {
        if store.sitStart == nil { return "未开始" }
        if overThreshold { return "需要起身活动！" }
        return "久坐监控中"
    }

    private var badgeColor: Color {
        if store.sitStart == nil { return WorkerTheme.fg40 }
        return overThreshold ? WorkerTheme.alertRed : WorkerTheme.sky
    }

    private var overThreshold: Bool {
        guard store.sitStart != nil else { return false }
        return store.sitElapsedSec >= store.sitTriggerMin * 60
    }

    // MARK: - Timer

    private var timerDisplay: some View {
        VStack(spacing: 6) {
            Text(elapsedLine)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(WorkerTheme.fg55)
            Text(bigDigits)
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundColor(overThreshold ? WorkerTheme.alertRed : WorkerTheme.fgPrimary)
                .monospacedDigit()
                .scaleEffect(bounce ? 1.06 : 1.0)
            Text(progressHint)
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg45)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(overThreshold ? WorkerTheme.alertRed.opacity(0.5) : WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
    }

    private var elapsedLine: String {
        if store.sitStart == nil { return "已坐 0 分钟" }
        let mins = store.sitElapsedSec / 60
        return "已坐 \(mins) 分钟"
    }

    private var bigDigits: String {
        let elapsed = store.sitElapsedSec
        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private var progressHint: String {
        if store.sitStart == nil { return "点下方按钮开始计时" }
        let trig = store.sitTriggerMin * 60
        let remain = max(0, trig - store.sitElapsedSec)
        if remain == 0 {
            return "已超过 \(store.sitTriggerMin) 分钟阈值"
        }
        let m = remain / 60
        return "距下次提醒 \(m) 分"
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: {
                if store.sitStart == nil {
                    store.sitStartNow()
                } else {
                    store.sitStop()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: store.sitStart == nil ? "play.fill" : "stop.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(store.sitStart == nil ? "开始计时" : "停止")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0B/255))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Capsule().fill(WorkerTheme.lime))
            }
            .buttonStyle(.plain)

            Button(action: {
                // Restart = stop + immediate start.
                store.sitStop()
                store.sitStartNow()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("重新计时")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(WorkerTheme.fg85)
                .padding(.horizontal, 14)
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

    // MARK: - Trigger row

    private var triggerRow: some View {
        HStack(spacing: 0) {
            Text("提醒间隔")
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg55)
                .padding(.leading, 12)

            Spacer()

            Button(action: { store.sitSetTrigger(store.sitTriggerMin - 5) }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)

            Text("\(store.sitTriggerMin)分")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
                .frame(minWidth: 50)

            Button(action: { store.sitSetTrigger(store.sitTriggerMin + 5) }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
    }

    private var tipText: some View {
        Text("每隔 \(store.sitTriggerMin) 分钟提醒一次，记得起来动一动。")
            .font(.system(size: 11))
            .foregroundColor(WorkerTheme.fg45)
            .padding(.horizontal, 20)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
