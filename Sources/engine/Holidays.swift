//
//  Holidays.swift
//  摸鱼侠 plugin v0.3.0
//
//  China State Council statutory holidays 2026. Estimated from prior-
//  year patterns (公历日期固定假 + 农历节假) — exact dates and
//  adjusted-workday days may shift when the State Council announces
//  each year's calendar (typically Q4 of the prior year).
//
//  Data structure is a flat list rather than a JSON resource so the
//  plugin bundle stays single-binary and dependency-free. To update:
//  edit this file when the next year's official 国务院办公厅
//  announcement publishes.
//

import Foundation

struct Holiday {
    /// "元旦" / "春节" / "国庆" / etc.
    let name: String
    /// First day of the holiday window (yyyy-MM-dd, Asia/Shanghai).
    let startDate: String
    /// Total consecutive days off, including the trigger day. e.g.
    /// 国庆 = 8 covers 10/01-10/08 (when paired with 中秋 in 2026).
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
    /// 2026 法定假期 — estimated from typical State Council pattern.
    /// **Verify against the official 国务院办公厅 announcement.**
    static let entries2026: [Holiday] = [
        Holiday(name: "元旦",   startDate: "2026-01-01", days: 1),
        Holiday(name: "春节",   startDate: "2026-02-17", days: 7),
        Holiday(name: "清明",   startDate: "2026-04-04", days: 3),
        Holiday(name: "五一",   startDate: "2026-05-01", days: 5),
        Holiday(name: "端午",   startDate: "2026-06-19", days: 3),
        Holiday(name: "中秋·国庆", startDate: "2026-10-01", days: 8),
        // Roll-over to early 2027 so late-Dec users still see a next
        // holiday after the 2026 calendar runs out.
        Holiday(name: "元旦",   startDate: "2027-01-01", days: 3),
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
