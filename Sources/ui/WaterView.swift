//
//  WaterView.swift
//  摸鱼侠 plugin v0.1
//
//  喝水 — 8 cup target with progress dots, tap big cup to log a sip.
//

import SwiftUI

struct WaterView: View {
    @ObservedObject var store: WorkerStore

    var body: some View {
        // No ScrollView — panel body sits at ~470pt available and we
        // tune everything below to fit: tighter VStack spacing, smaller
        // cup hero, toggles on a single row, no tipText.
        VStack(spacing: 10) {
            statusBadge

            cupHero

            controls

            Divider()
                .background(WorkerTheme.overlay08)
                .padding(.horizontal, 24)

            goalRow
            toggleRow

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    // MARK: - Toggle row (compact horizontal layout — saves vertical
    // space so the whole tab fits without a scroll bar).

    private var toggleRow: some View {
        HStack(spacing: 8) {
            togglePill(
                icon: "timer",
                label: "🍅 +1",
                isOn: store.waterAutoFromPomodoro,
                tint: WorkerTheme.tomato,
                action: { store.waterSetAutoFromPomodoro(!store.waterAutoFromPomodoro) }
            )
            togglePill(
                icon: "bell.fill",
                label: "整点提醒",
                isOn: store.waterHourlyReminder,
                tint: WorkerTheme.water,
                action: { store.waterSetHourlyReminder(!store.waterHourlyReminder) }
            )
        }
        .padding(.horizontal, 16)
    }

    /// Compact toggle for the horizontal toggleRow. Icon + short label +
    /// inline slim toggle track inside a single capsule. Sized to fit
    /// 2 across a 380pt panel with 16pt horizontal padding.
    private func togglePill(icon: String, label: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isOn ? tint : WorkerTheme.fg55)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isOn ? WorkerTheme.fgPrimary : WorkerTheme.fg70)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? tint.opacity(0.35) : WorkerTheme.overlay08)
                        .frame(width: 24, height: 14)
                    Circle()
                        .fill(isOn ? tint : WorkerTheme.fg55)
                        .frame(width: 10, height: 10)
                        .padding(2)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(WorkerTheme.overlay04)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isOn ? tint.opacity(0.35) : WorkerTheme.overlay08, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(WorkerTheme.water)
                .frame(width: 8, height: 8)
                .shadow(color: WorkerTheme.water.opacity(0.7), radius: 4)
            Text(badgeText)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fg85)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(WorkerTheme.overlay06))
    }

    private var badgeText: String {
        if store.waterCupsToday >= store.waterGoal {
            return "今日目标已达成 ✨"
        }
        return "今日 \(store.waterCupsToday) / \(store.waterGoal) 杯"
    }

    // MARK: - Cup hero (tappable)

    private var cupHero: some View {
        VStack(spacing: 8) {
            Button(action: { store.waterAddCup() }) {
                ZStack {
                    // Water-fill cup — sized down from 130×160 to fit
                    // the 380×580 panel without scroll.
                    cupShape
                        .frame(width: 100, height: 130)
                }
            }
            .buttonStyle(.plain)
            .help("点击杯子记录一杯水")

            // Progress dots
            HStack(spacing: 5) {
                ForEach(0..<store.waterGoal, id: \.self) { i in
                    Circle()
                        .fill(i < store.waterCupsToday ? WorkerTheme.water : WorkerTheme.overlay08)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(WorkerTheme.overlay12, lineWidth: 0.5)
                        )
                }
            }
        }
    }

    private var cupShape: some View {
        ZStack(alignment: .bottom) {
            // Outline (cup body — slight trapezoid)
            CupOutline()
                .stroke(WorkerTheme.fg55, lineWidth: 2.5)

            // Water fill (clipped to the cup)
            CupOutline()
                .fill(LinearGradient(
                    colors: [WorkerTheme.water.opacity(0.85), WorkerTheme.water.opacity(0.4)],
                    startPoint: .top, endPoint: .bottom
                ))
                .mask(
                    GeometryReader { geo in
                        let frac = min(1.0, Double(store.waterCupsToday) / Double(max(1, store.waterGoal)))
                        Rectangle()
                            .frame(width: geo.size.width, height: geo.size.height * CGFloat(frac))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                )
                .animation(.easeInOut(duration: 0.4), value: store.waterCupsToday)

            // Big number on top of the cup
            VStack {
                Spacer()
                Text("\(store.waterCupsToday)")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundColor(WorkerTheme.fgPrimary)
                    .monospacedDigit()
                Text("杯")
                    .font(.system(size: 11))
                    .foregroundColor(WorkerTheme.fg55)
                    .padding(.bottom, 18)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: { store.waterAddCup() }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("加一杯")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(red: 0x0B/255, green: 0x0B/255, blue: 0x0B/255))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Capsule().fill(WorkerTheme.lime))
            }
            .buttonStyle(.plain)

            Button(action: { store.waterRemoveCup() }) {
                HStack(spacing: 6) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("撤销")
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

    // MARK: - Goal row

    private var goalRow: some View {
        HStack(spacing: 0) {
            Text("每日目标")
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg55)
                .padding(.leading, 12)

            Spacer()

            Button(action: { store.waterSetGoal(store.waterGoal - 1) }) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WorkerTheme.fg70)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(WorkerTheme.overlay06))
            }
            .buttonStyle(.plain)

            Text("\(store.waterGoal)杯")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
                .frame(minWidth: 50)

            Button(action: { store.waterSetGoal(store.waterGoal + 1) }) {
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

}

// MARK: - Cup outline shape

private struct CupOutline: Shape {
    func path(in rect: CGRect) -> Path {
        // Slight trapezoid: narrower at the bottom. Straight rim with
        // a 4pt rounded base.
        var p = Path()
        let topInset: CGFloat = 0
        let bottomInset: CGFloat = rect.width * 0.08
        let radius: CGFloat = 8

        // Start top-left.
        p.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        // Top edge.
        p.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        // Right side (sloping inward).
        p.addLine(to: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY - radius))
        // Bottom-right curve.
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomInset - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX - bottomInset, y: rect.maxY)
        )
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.minX + bottomInset + radius, y: rect.maxY))
        // Bottom-left curve.
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomInset, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX + bottomInset, y: rect.maxY)
        )
        // Left side back to top.
        p.addLine(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
