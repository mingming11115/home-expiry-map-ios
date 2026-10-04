import Foundation

@main
struct CalendarDraftTests {
    static func main() throws {
        let draft = try CalendarDraft.parse(event())
        try expect(draft.title == "滤芯更换", "reads the event summary")
        try expect(draft.location == "厨房", "reads the location")
        try expect(draft.notes == "检查型号", "reads the event description, not the alarm description")
        try expect(draft.reminderOffset == -259_200, "converts three reminder days to negative seconds")
        try expectLocalDate(draft.startDate, year: 2028, month: 2, day: 29)
        try expectLocalDate(draft.endDate, year: 2028, month: 3, day: 1)

        let folded = try CalendarDraft.parse(event(
            title: "第一行\\n第二行\\,含逗号\\;分号\\\\路径\r\n 后续\r\n\t文字",
            location: "抽屉\\,左侧",
            notes: "字面反斜线\\\\n不是换行\\N真正换行"
        ))
        try expect(folded.title == "第一行\n第二行,含逗号;分号\\路径后续文字", "unfolds before unescaping text")
        try expect(folded.location == "抽屉,左侧", "unescapes location")
        try expect(folded.notes == "字面反斜线\\n不是换行\n真正换行", "does not recursively unescape a literal backslash")

        let combining = try CalendarDraft.parse(event(title: "Cafe\r\n \u{0301}\\n\u{0301}下一行"))
        try expect(combining.title == "Cafe\u{0301}\n\u{0301}下一行", "preserves combining marks at fold and escape boundaries")

        let withoutAlarm = try CalendarDraft.parse(event(alarm: nil).replacingOccurrences(of: "\r\n", with: "\n"))
        try expect(withoutAlarm.reminderOffset == nil, "allows no alarm and LF line endings")
        let zeroAlarm = try CalendarDraft.parse(event(alarm: "-P0D"))
        try expect(zeroAlarm.reminderOffset == 0, "preserves a reminder on the due day")

        let invalid: [(String, String)] = [
            ("non-leap February", event(start: "20250229")),
            ("day overflow", event(start: "20260431")),
            ("month overflow", event(start: "20261301")),
            ("zero day", event(start: "20260100")),
            ("zero year", event(start: "00000101")),
            ("invalid end date", event(end: "20280230")),
            ("same start and end", event(end: "20280229")),
            ("end before start", event(end: "20280228")),
            ("date-time value", event(start: "20280229T000000Z")),
            ("hyphenated date", event(start: "2028-02-29")),
            ("missing DATE parameter", event().replacingOccurrences(of: "DTSTART;VALUE=DATE:", with: "DTSTART:")),
            ("unsupported TZID", event().replacingOccurrences(of: "DTSTART;VALUE=DATE:", with: "DTSTART;VALUE=DATE;TZID=UTC:")),
            ("missing start", event().replacingOccurrences(of: "DTSTART;VALUE=DATE:20280229\r\n", with: "")),
            ("missing end", event().replacingOccurrences(of: "DTEND;VALUE=DATE:20280301\r\n", with: "")),
            ("duplicate start", event().replacingOccurrences(of: "DTSTART;VALUE=DATE:20280229", with: "DTSTART;VALUE=DATE:20280229\r\nDTSTART;VALUE=DATE:20280229")),
            ("multiple events", event().replacingOccurrences(of: "END:VCALENDAR", with: "BEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20280302\r\nDTEND;VALUE=DATE:20280303\r\nEND:VEVENT\r\nEND:VCALENDAR")),
            ("missing event", "BEGIN:VCALENDAR\r\nEND:VCALENDAR"),
            ("unclosed event", event().replacingOccurrences(of: "END:VEVENT\r\n", with: "")),
            ("unsupported hourly alarm", event(alarm: "-PT1H")),
            ("missing alarm trigger", event().replacingOccurrences(of: "TRIGGER:-P3D\r\n", with: "")),
            ("duplicate alarm trigger", event().replacingOccurrences(of: "TRIGGER:-P3D", with: "TRIGGER:-P3D\r\nTRIGGER:-P1D")),
            ("overflowing alarm", event(alarm: "-P999999999999999999999999999D"))
        ]
        for (name, text) in invalid { try expectRejected(text, name) }

        let crossYear = try CalendarDraft.parse(event(start: "20261231", end: "20270101", alarm: "-P365D"))
        try expectLocalDate(crossYear.endDate, year: 2027, month: 1, day: 1)
        if Calendar.current.timeZone.identifier == "America/Los_Angeles" {
            let spring = try CalendarDraft.parse(event(start: "20260309", end: "20260310", alarm: "-P1D"))
            try expect(spring.reminderOffset == -82_800, "a calendar day across spring DST is 23 hours")
            let fall = try CalendarDraft.parse(event(start: "20261102", end: "20261103", alarm: "-P1D"))
            try expect(fall.reminderOffset == -90_000, "a calendar day across fall DST is 25 hours")
        }

        print("PASS: CalendarDraft valid exports, text, dates, alarms, and \(invalid.count) rejection cases; time zone \(Calendar.current.timeZone.identifier)")
    }

    static func event(
        start: String = "20280229", end: String = "20280301",
        title: String = "滤芯更换", location: String = "厨房",
        notes: String = "检查型号", alarm: String? = "-P3D"
    ) -> String {
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Expiry Map//ZH",
            "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "BEGIN:VEVENT",
            "UID:item-1@expiry-map", "SEQUENCE:1", "DTSTAMP:20261003T000000Z",
            "DTSTART;VALUE=DATE:\(start)", "DTEND;VALUE=DATE:\(end)",
            "SUMMARY:\(title)", "LOCATION:\(location)", "DESCRIPTION:\(notes)"
        ]
        if let alarm {
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:提醒文字", "TRIGGER:\(alarm)", "END:VALARM"]
        }
        return (lines + ["END:VEVENT", "END:VCALENDAR", ""]).joined(separator: "\r\n")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    static func expectRejected(_ text: String, _ name: String) throws {
        do { _ = try CalendarDraft.parse(text) }
        catch { return }
        throw TestFailure(message: "rejects \(name)")
    }

    static func expectLocalDate(_ date: Date, year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        try expect(parts.year == year && parts.month == month && parts.day == day, "preserves the Gregorian date in the current time zone")
        try expect(parts.hour == 0 && parts.minute == 0 && parts.second == 0, "constructs local midnight")
    }

    struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { "FAIL: \(message)" }
    }
}
