//
//  WeekendView.swift
//  摸鱼侠 plugin v0.1
//
//  周末 — countdown to next Saturday 00:00.
//

import SwiftUI

struct WeekendView: View {
    @ObservedObject var store: WorkerStore

    var body: some View {
        VStack(spacing: 18) {
            statusBadge

            heroCountdown

            partsRow

            Divider()
                .background(WorkerTheme.overlay08)
                .padding(.horizontal, 24)

            quoteCard

            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    // MARK: - Status

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(WorkerTheme.weekendPurple)
                .frame(width: 8, height: 8)
                .shadow(color: WorkerTheme.weekendPurple.opacity(0.7), radius: 4)
            Text(badgeText)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WorkerTheme.fg85)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Capsule().fill(WorkerTheme.overlay06))
    }

    private var badgeText: String {
        if store.weekendDays == 0 && store.weekendHours < 12 {
            return "周末就在眼前 ✨"
        }
        return "距离周末"
    }

    // MARK: - Hero countdown

    private var heroCountdown: some View {
        VStack(spacing: 4) {
            Text("还有")
                .font(.system(size: 12))
                .foregroundColor(WorkerTheme.fg55)
            Text(WorkerFormat.dhm(
                days: store.weekendDays,
                hours: store.weekendHours,
                minutes: store.weekendMinutes
            ))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundColor(WorkerTheme.weekendPurple)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 16)
            Text("下个周六 00:00")
                .font(.system(size: 11))
                .foregroundColor(WorkerTheme.fg45)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [
                            WorkerTheme.weekendPurple.opacity(0.18),
                            WorkerTheme.weekendPurple.opacity(0.04)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(WorkerTheme.weekendPurple.opacity(0.35), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Parts row

    private var partsRow: some View {
        HStack(spacing: 10) {
            partCard(label: "天", value: store.weekendDays)
            partCard(label: "时", value: store.weekendHours)
            partCard(label: "分", value: store.weekendMinutes)
        }
        .padding(.horizontal, 16)
    }

    private func partCard(label: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(WorkerTheme.fgPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(WorkerTheme.fg55)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WorkerTheme.overlay04)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(WorkerTheme.overlay08, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Quote card

    private var quoteCard: some View {
        let q = quoteForToday()
        return VStack(alignment: .leading, spacing: 6) {
            Text("今日打工语录")
                .font(.system(size: 10.5))
                .foregroundColor(WorkerTheme.fg55)
            Text(q)
                .font(.system(size: 12.5))
                .foregroundColor(WorkerTheme.fg85)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

    private func quoteForToday() -> String {
        // Stable per-day rotation. Day-of-year as the index keeps the
        // quote consistent for the whole day.
        let quotes = [
            "周末是充电的理由，工作日是放电的代价。",
            "上班是为了更好地下班。",
            "再坚持一下，咖啡就在转角等你。",
            "生活不止眼前的KPI，还有诗和周末的咖啡馆。",
            "每一秒倒计时都是给未来周末的铺垫。",
            "工作再忙，水也要喝完八杯。",
            "下班的钟声永远比开会的提示音动听。"
        ]
        let cal = Calendar(identifier: .gregorian)
        let day = cal.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return quotes[day % quotes.count]
    }
}
