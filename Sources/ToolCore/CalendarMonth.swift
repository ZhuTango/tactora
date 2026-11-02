import Foundation

/// Gregorian month grid. Calendar arithmetic preserves local dates across DST.
struct CalendarMonth {
    var visibleWeeks: Int { days.count / 7 }
    let calendar: Calendar
    let start: Date
    let days: [Date]
    init(containing date: Date, firstWeekday: Int = 2, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday == 1 ? 1 : 2
        self.calendar = calendar
        start = calendar.dateInterval(of: .month, for: date)!.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -offset - 7, to: start)!
        let monthDays = calendar.range(of: .day, in: .month, for: start)!.count
        let weeks = (offset + monthDays + 6) / 7 + 2
        days = (0..<(weeks * 7)).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    func contains(_ date: Date) -> Bool { calendar.isDate(date, equalTo: start, toGranularity: .month) }
    func moving(months: Int) -> Date { calendar.date(byAdding: .month, value: months, to: start)! }
    var weekNumbers: [Int] {
        var iso = Calendar(identifier: .iso8601); iso.timeZone = calendar.timeZone
        return stride(from: 0, to: days.count, by: 7).map { offset in
            let thursday = days[offset..<(offset + 7)].first { calendar.component(.weekday, from: $0) == 5 }!
            return iso.component(.weekOfYear, from: thursday)
        }
    }
}

/// Chinese calendar supplied by Foundation, using the same local date as the month grid.
struct LunarDate {
    let monthName: String
    let dayName: String
    let isLeapMonth: Bool
    init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .chinese); calendar.timeZone = timeZone
        let parts = calendar.dateComponents(in: timeZone, from: date)
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let days = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        isLeapMonth = parts.isLeapMonth == true
        monthName = (isLeapMonth ? "闰" : "") + months[(parts.month ?? 1) - 1]
        dayName = days[(parts.day ?? 1) - 1]
    }
    var shortLabel: String { dayName == "初一" ? monthName : dayName }
    var fullLabel: String { monthName + dayName }
}

/// Mainland China schedule, State Council notice 国办发明电〔2025〕7号.
/// Source: https://www.gov.cn/zhengce/content/202511/content_7047090.htm
/// Verified against government republication:
/// https://www.wuhan.gov.cn/zwgk/tzgg/202511/t20251105_2672471.shtml
enum ChinaHolidays {
    struct Entry {
        let name: String
        let isWorkday: Bool
        var label: String { name + (isWorkday ? " · 调休上班" : " · 放假") }
        var badge: String { isWorkday ? "班" : "休" }
    }
    static let supportedYears: Set<Int> = [2026]
    private static let entries: [Int: Entry] = {
        var result: [Int: Entry] = [:]
        func holiday(_ month: Int, _ days: ClosedRange<Int>, _ name: String) {
            for day in days { result[month * 100 + day] = Entry(name: name, isWorkday: false) }
        }
        holiday(1, 1...3, "元旦")
        holiday(2, 15...23, "春节")
        holiday(4, 4...6, "清明节")
        holiday(5, 1...5, "劳动节")
        holiday(6, 19...21, "端午节")
        holiday(9, 25...27, "中秋节")
        holiday(10, 1...7, "国庆节")
        for (key, name) in [(104, "元旦"), (214, "春节"), (228, "春节"), (509, "劳动节"), (920, "国庆节"), (1010, "国庆节")] {
            result[key] = Entry(name: name, isWorkday: true)
        }
        return result
    }()
    static func entry(on date: Date, calendar: Calendar) -> Entry? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == 2026, let month = parts.month, let day = parts.day else { return nil }
        return entries[month * 100 + day]
    }
}

/// Day-level solar terms from apparent solar longitude (Meeus low-precision solar model).
/// Uses the displayed calendar's time zone; bounded to 1900...2100, not an ephemeris for exact times.
enum SolarTerms {
    static let names = ["春分", "清明", "谷雨", "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至", "小寒", "大寒", "立春", "雨水", "惊蛰"]
    static func label(on date: Date, calendar: Calendar) -> String? {
        guard (1900...2100).contains(calendar.component(.year, from: date)),
              let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
        let start = Int(floor(longitude(interval.start) / 15))
        let end = Int(floor(longitude(interval.end.addingTimeInterval(-0.001)) / 15))
        return start == end ? nil : names[end % 24]
    }
    private static func longitude(_ date: Date) -> Double {
        let t = (date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545) / 36525
        let mean = 280.46646 + t * (36000.76983 + t * 0.0003032)
        let anomaly = (357.52911 + t * (35999.05029 - 0.0001537 * t)) * .pi / 180
        let center = sin(anomaly) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * t) + sin(3 * anomaly) * 0.000289
        let apparent = mean + center - 0.00569 - 0.00478 * sin((125.04 - 1934.136 * t) * .pi / 180)
        return (apparent.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
