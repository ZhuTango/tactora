import Foundation

/// Gregorian month grid. Calendar arithmetic preserves local dates across DST.
struct CalendarMonth {
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
        let first = calendar.date(byAdding: .day, value: -offset, to: start)!
        days = (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    func contains(_ date: Date) -> Bool { calendar.isDate(date, equalTo: start, toGranularity: .month) }
    func moving(months: Int) -> Date { calendar.date(byAdding: .month, value: months, to: start)! }
    var weekNumbers: [Int] {
        var iso = Calendar(identifier: .iso8601); iso.timeZone = calendar.timeZone
        return stride(from: 0, to: 42, by: 7).map { offset in
            let thursday = days[offset..<(offset + 7)].first { calendar.component(.weekday, from: $0) == 5 }!
            return iso.component(.weekOfYear, from: thursday)
        }
    }
}
