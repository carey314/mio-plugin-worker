//
//  ClockoutView.swift
//  摸鱼侠 plugin v0.1
//
//  下班 — 距离下班 X时Y分. Red bar fills as the day progresses.
//

import SwiftUI

struct ClockoutView: View {
    @ObservedObject var store: WorkerStore
    @State private var editing: Bool = false
    @State private var editHour: Int = 18
    @State private var editMinute: Int = 0

    var body: some View {
        VStack(spacing: 18) {
            statusBadge

            countdownDisplay

            progressBar

            controls

            Divider()
                .background(WorkerTheme.overlay08)
                .padding(.horizontal, 24)

            timeRow

            tipText

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: - Status

    private var statusBadge: some View {
        let isOff = store.clockoutRemainingSec >= 86400 - 60 // basically never
        let almost = store.clockoutProgress >= 0.95
        let dotColor: Color = almost ? WorkerTheme.alertRed : WorkerTheme.lime
        return HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: dotColor.opacity(0.7), radius: 4)
            Text(isOff ? "下班时间未设置" : (almost ? "马上就能下班！" : "今日工作中"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fg85)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(WorkerTheme.overlay06))
    }

    // MARK: - Countdown

    private var countdownDisplay: some View {
        let total = store.clockoutRemainingSec
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return VStack(spacing: 6) {
            Text("距离下班")
                .font(.system(size: 12))
                .foregroundColor(WorkerTheme.fg55)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                bigPart(value: h, suffix: "时")
                bigPart(value: m, suffix: "分")
                bigPart(value: s, suffix: "秒", small: true)
            }
            Text(targetLabel)
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
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
    }

    private func bigPart(value: Int, suffix: String, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.system(size: small ? 28 : 44, weight: .semibold, design: .rounded))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
            Text(suffix)
                .font(.system(size: small ? 12 : 14, weight: .medium))
                .foregroundColor(WorkerTheme.fg55)
        }
    }

    private var targetLabel: String {
        String(format: "目标 %02d:%02d", store.clockoutHour, store.clockoutMinute)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(WorkerTheme.overlay06)
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [WorkerTheme.tomato, WorkerTheme.alertRed],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(
                        width: max(0, geo.size.width * CGFloat(store.clockoutProgress)),
                        height: 10
                    )
                    .animation(.linear(duration: 0.3), value: store.clockoutProgress)
            }
        }
        .frame(height: 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: {
                editHour = store.clockoutHour
                editMinute = store.clockoutMinute
                editing.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: editing ? "checkmark" : "clock")
                        .font(.system(size: 11, weight: .semibold))
                    Text(editing ? "完成" : "调整下班时间")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0B/255))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Capsule().fill(WorkerTheme.lime))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Time row (only shown when editing)

    @ViewBuilder
    private var timeRow: some View {
        if editing {
            HStack(spacing: 10) {
                stepperPill(
                    title: "时",
                    value: editHour,
                    onMinus: {
                        editHour = max(0, editHour - 1)
                        store.clockoutSet(hour: editHour, minute: editMinute)
                    },
                    onPlus: {
                        editHour = min(23, editHour + 1)
                        store.clockoutSet(hour: editHour, minute: editMinute)
                    }
                )
                stepperPill(
                    title: "分",
                    value: editMinute,
                    onMinus: {
                        editMinute = max(0, editMinute - 5)
                        store.clockoutSet(hour: editHour, minute: editMinute)
                    },
                    onPlus: {
                        editMinute = min(55, editMinute + 5)
                        store.clockoutSet(hour: editHour, minute: editMinute)
                    }
                )
            }
            .padding(.horizontal, 16)
        } else {
            EmptyView()
        }
    }

    private func stepperPill(title: String, value: Int, onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg55)
                .padding(.leading, 10)

            Spacer()

            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)

            Text(String(format: "%02d", value))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
                .frame(minWidth: 36)

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
    }

    private var tipText: some View {
        Text("下班时间到时不会响铃 —\n本插件只负责让你看着时间倒计时偷着乐。")
            .font(.system(size: 11))
            .foregroundColor(WorkerTheme.fg45)
            .padding(.horizontal, 20)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
