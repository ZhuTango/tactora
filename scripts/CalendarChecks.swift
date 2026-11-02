import Foundation
@main struct CalendarChecks {
 static func main() {
  var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  func date(_ y: Int, _ m: Int, _ d: Int) -> Date { c.date(from: DateComponents(year:y, month:m, day:d, hour:12))! }
  let leap = CalendarMonth(containing: date(2024,2,15), firstWeekday: 2, timeZone:c.timeZone)
  precondition(leap.days.count == 49)
  precondition(c.component(.day, from:leap.days[0]) == 22 && c.component(.month, from:leap.days[0]) == 1)
  precondition(leap.days.filter { leap.contains($0) }.count == 29)
  let february = CalendarMonth(containing: date(2027,2,1), firstWeekday:2, timeZone:c.timeZone)
  precondition(february.visibleWeeks == 6 && february.days.count == 42)
  precondition(c.component(.day, from: february.days.last!) == 7)
  let sunday = CalendarMonth(containing: date(2026,11,10), firstWeekday:1, timeZone:c.timeZone)
  precondition(c.component(.day, from:sunday.days[0]) == 25)
  let november = CalendarMonth(containing: date(2026,11,2), firstWeekday:2, timeZone:c.timeZone)
  precondition(c.component(.month,from:november.days.first!) == 10 && c.component(.day,from:november.days.first!) == 19)
  precondition(c.component(.month,from:november.days.last!) == 12 && c.component(.day,from:november.days.last!) == 13)
  let december = CalendarMonth(containing:date(2026,12,31), firstWeekday:2, timeZone:c.timeZone)
  precondition(c.component(.year,from:december.moving(months:1)) == 2027)
  precondition(c.component(.month,from:december.moving(months:1)) == 1)
  let dst = CalendarMonth(containing:date(2026,3,8), firstWeekday:2, timeZone:c.timeZone)
  precondition(Set(dst.days.map { c.startOfDay(for:$0) }).count == dst.days.count)
  for pair in zip(dst.days,dst.days.dropFirst()) { precondition(c.dateComponents([.day],from:pair.0,to:pair.1).day == 1) }
  let jan = CalendarMonth(containing:date(2021,1,1), firstWeekday:2, timeZone:c.timeZone)
  precondition(jan.weekNumbers.first == 52)
  precondition(LunarDate(date(2024,2,10), timeZone:c.timeZone).fullLabel == "正月初一")
  precondition(LunarDate(date(2023,3,22), timeZone:c.timeZone).fullLabel == "闰二月初一")
  precondition(LunarDate(date(2024,9,17), timeZone:c.timeZone).fullLabel == "八月十五")
  precondition(LunarDate(date(2024,2,9), timeZone:c.timeZone).monthName == "腊月")
  var holidays = 0, workdays = 0
  for month in 1...12 {
   for day in 1...c.range(of:.day, in:.month, for:date(2026,month,1))!.count {
    if let entry = ChinaHolidays.entry(on:date(2026,month,day),calendar:c) {
     if entry.isWorkday { workdays += 1 } else { holidays += 1 }
    }
   }
  }
  precondition(holidays == 33 && workdays == 6)
  precondition(ChinaHolidays.entry(on:date(2026,2,14),calendar:c)?.isWorkday == true)
  precondition(ChinaHolidays.entry(on:date(2026,2,15),calendar:c)?.name == "春节")
  precondition(ChinaHolidays.entry(on:date(2026,2,24),calendar:c) == nil)
  precondition(ChinaHolidays.entry(on:date(2027,1,1),calendar:c) == nil)
  print("PASS: leap year, Sunday/Monday grids, year transition, DST and ISO week numbers")
 }
}
