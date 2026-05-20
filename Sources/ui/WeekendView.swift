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
        ScrollView {
            VStack(spacing: 14) {
                statusBadge

                heroCountdown

                partsRow

                if store.nextHoliday != nil {
                    holidayCard
                }

                Divider()
                    .background(WorkerTheme.overlay08)
                    .padding(.horizontal, 24)

                quoteCard

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Holiday card (next 法定假)

    /// Distance-to-next-statutory-holiday card. Splits visual weight
    /// with the weekend hero so users on a Friday don't just see "1 天
    /// 2 时" and miss that 国庆放 8 天 is next week.
    private var holidayCard: some View {
        Group {
            if let h = store.nextHoliday {
                holidayContent(h)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func holidayContent(_ h: UpcomingHoliday) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Left side: name + days-off line
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "party.popper.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WorkerTheme.tomato)
                    Text(h.isOngoing ? "假期中" : "下个法定假")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(WorkerTheme.fg55)
                        .tracking(0.3)
                }
                Text(h.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(WorkerTheme.fgPrimary)
                Text("放 \(h.days) 天")
                    .font(.system(size: 11))
                    .foregroundColor(WorkerTheme.fg55)
            }
            Spacer(minLength: 0)
            // Right side: distance / "假期中"
            VStack(alignment: .trailing, spacing: 2) {
                if h.isOngoing {
                    Text("🎉")
                        .font(.system(size: 28))
                } else {
                    Text("\(h.daysUntil)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(WorkerTheme.tomato)
                        .monospacedDigit()
                    Text("天后")
                        .font(.system(size: 10))
                        .foregroundColor(WorkerTheme.fg55)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            WorkerTheme.tomato.opacity(0.10),
                            WorkerTheme.tomato.opacity(0.02)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(WorkerTheme.tomato.opacity(0.30), lineWidth: 0.5)
                )
        )
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
