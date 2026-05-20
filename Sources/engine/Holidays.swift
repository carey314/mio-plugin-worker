//
//  Holidays.swift
//  摸鱼侠 plugin v0.3.0
//
//  China State Council statutory holidays for 2026. Calibrated to the
//  公历日期 + 农历对应日 + typical 调休 pattern; **the official 国务院
//  办公厅 announcement (usually released Nov of prior year)** is the
//  ultimate source of truth. If a date here disagrees with 国务院
//  notice when published, edit this file and re-release.
//
//  Reference dates used (公历 yyyy-MM-dd → 农历):
//    2026-02-17 → 农历 正月 初一 (春节)
//    2026-04-05 → 清明 (公历固定)
//    2026-06-19 → 农历 五月 初五 (端午)
//    2026-09-25 → 农历 八月 十五 (中秋)
//
//  In years where 中秋 falls within 6 days of 国庆, the State Council
//  typically merges them into a single 8-10 day window. 2026 has
//  中秋 09-25 (Fri) and 国庆 10-01 (Thu) → window 09-25 ~ 10-04 is the
//  most likely pattern (with 10-10 Saturday or earlier 09-20 Sunday
//  for makeup work day).
//
//  Data structure is a flat list rather than a JSON resource so the
//  plugin bundle stays single-binary and dependency-free.
//

import Foundation

struct Holiday {
    /// "元旦" / "春节" / "国庆" / etc.
    let name: String
    /// First day of the holiday window (yyyy-MM-dd, Asia/Shanghai).
    let startDate: String
    /// Total consecutive days off, including the trigger day.
    let days: Int
}

/// Resolved upcoming holiday with the days remaining and start Date.
struct UpcomingHoliday {
    let name: String
    let startDate: Date
    let days: Int
    /// Days from now to startDate. 0 = today is day 1 of the holiday.
    let daysUntil: Int
    /// True when "now" falls inside [startDate, startDate+days).
    let isOngoing: Bool
}

enum HolidayDatabase {
    /// 2026 法定假期 — best estimate per typical State Council调休 pattern.
    /// VERIFY against the official 国务院办公厅 公告 when published.
    ///
    /// 春节 starts on 除夕 (the day before 初一) per 2024 policy update.
    /// 中秋 + 国庆 merged because 2026 中秋 09-25 falls 6 days before
    /// 国庆 10-01 — same pattern as 2017 / 2020 when they were close.
    static let entries2026: [Holiday] = [
        // 元旦 周四 — 单日不调休（2024 政策起元旦只放 1 天）
        Holiday(name: "元旦",         startDate: "2026-01-01", days: 1),
        // 春节 02-16 除夕 ~ 02-22 初七，7 天。调休 02-14 周六 + 02-28 周六上班
        Holiday(name: "春节",         startDate: "2026-02-16", days: 7),
        // 清明 04-05 周日，调休 04-04 ~ 04-06 共 3 天
        Holiday(name: "清明",         startDate: "2026-04-04", days: 3),
        // 五一 05-01 周五 ~ 05-05 周二，5 天。调休 04-26 周日上班
        Holiday(name: "劳动节",       startDate: "2026-05-01", days: 5),
        // 端午 06-19 周五 ~ 06-21 周日，3 天（自然连周末，无调休）
        Holiday(name: "端午",         startDate: "2026-06-19", days: 3),
        // 中秋 + 国庆 合并 09-25 周五 ~ 10-04 周日，10 天
        // 调休 09-19 / 10-10 周六上班
        Holiday(name: "中秋·国庆",    startDate: "2026-09-25", days: 10),
        // 跨年 roll-over — 元旦 2027 估计 01-01 周五 ~ 01-03 周日，3 天
        Holiday(name: "元旦",         startDate: "2027-01-01", days: 3),
    ]

    /// Returns the soonest upcoming or currently-ongoing holiday.
    /// `now` is injectable for testability.
    static func upcoming(from now: Date, timeZone: TimeZone) -> UpcomingHoliday? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        for h in entries2026 {
            guard let start = fmt.date(from: h.startDate) else { continue }
            guard let end = cal.date(byAdding: .day, value: h.days, to: start) else { continue }
            if now >= start && now < end {
                // In the holiday window already.
                return UpcomingHoliday(
                    name: h.name, startDate: start,
                    days: h.days, daysUntil: 0, isOngoing: true
                )
            }
            if start > now {
                // Floor-divide of seconds to days for an integer answer
                // independent of locale calendar shenanigans.
                let secs = start.timeIntervalSince(now)
                let daysUntil = Int(ceil(secs / 86400.0))
                return UpcomingHoliday(
                    name: h.name, startDate: start,
                    days: h.days, daysUntil: daysUntil, isOngoing: false
                )
            }
        }
        return nil
    }
}
