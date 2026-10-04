import Foundation

struct LabelScanResult: Equatable {
    var suggestedName: String?
    var suggestedDueDate: String?
    var text: String
}

enum LabelParser {
    private static let expiryPattern = #"有效期至|有效日期|失效日期|到期日期|到期日|截止日期|限用日期|使用期限|保质期至|best\s*before|expiry(?:\s*date)?|expires?(?:\s*on)?|exp\.?|use\s*by"#
    private static let expiry = regex("^(?:" + expiryPattern + ")$")
    private static let marker = regex(#"有效期至|有效日期|失效日期|到期日期|到期日|截止日期|限用日期|使用期限|保质期至|生产日期|制造日期|包装日期|批号|\b(?:best\s*before|expiry(?:\s*date)?|expires?(?:\s*on)?|exp\.?|use\s*by|mfg|mfd|manufactured(?:\s*on)?|lot)(?![a-z])"#)
    private static let date = regex(#"(?<!\d)((?:19|20|21|22)\d{2})(?:[年./-](\d{1,2})[月./-](\d{1,2})日?|(\d{2})(\d{2}))(?!\d)"#)
    private static let separator = regex(#"^[:：\s]*$"#)
    private static let chineseSpacing = regex(#"([\u3400-\u9fff])[^\S\n]+(?=[\u3400-\u9fff])"#)
    private static let nameLabel = regex(#"^(?:产品名称|商品名称|品名|名称|product(?:\s*name)?|name)\s*[:：]\s*(.+)$"#)
    private static let nameLetters = regex(#"[a-z\u3400-\u9fff]"#)
    private static let nameMetadata = regex(#"(?:日期|有效|到期|保质|失效|净含量|配料|储存|贮存|保存|营养|地址|电话|厂家|批号|许可|\b(?:exp|expiry|mfg|mfd|lot|best|use by|ingredients|storage)\b)"#)
    private static let longNumber = regex(#"\d{4,}"#)

    static func parse(_ text: String) -> LabelScanResult {
        let raw = String(text.prefix(8_000)).precomposedStringWithCompatibilityMapping
        let normalized = chineseSpacing.stringByReplacingMatches(in: raw, range: range(raw), withTemplate: "$1")
        let source = normalized as NSString
        let markers = marker.matches(in: normalized, range: range(normalized))
        var candidates = Set<String>()
        var uncertain = false

        for (index, match) in markers.enumerated() {
            let label = source.substring(with: match.range)
            guard hasMatch(expiry, in: label) else { continue }
            let start = NSMaxRange(match.range)
            let end = index + 1 < markers.count ? markers[index + 1].range.location : source.length
            let segment = source.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dates = date.matches(in: segment, range: range(segment))
            guard dates.count == 1, let match = dates.first,
                  hasMatch(separator, in: (segment as NSString).substring(to: match.range.location)),
                  let value = validDate(match, in: segment)
            else {
                uncertain = true
                continue
            }
            candidates.insert(value)
        }

        let lines = normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let labelledName = lines.compactMap { line -> String? in
            guard let match = nameLabel.firstMatch(in: line, range: range(line)) else { return nil }
            return (line as NSString).substring(with: match.range(at: 1))
        }.first
        let name = labelledName.flatMap { plausibleName($0) ? $0 : nil }
            ?? lines.prefix(5).first(where: plausibleName)
        return LabelScanResult(
            suggestedName: name,
            suggestedDueDate: !uncertain && candidates.count == 1 ? candidates.first : nil,
            text: raw
        )
    }

    private static func validDate(_ match: NSTextCheckingResult, in text: String) -> String? {
        let source = text as NSString
        func number(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(source.substring(with: range))
        }
        guard let year = number(1), (1900...2200).contains(year),
              let month = number(2) ?? number(4),
              let day = number(3) ?? number(5) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: value)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func plausibleName(_ name: String) -> Bool {
        (2...80).contains(name.count)
            && hasMatch(nameLetters, in: name)
            && !hasMatch(nameMetadata, in: name)
            && !hasMatch(longNumber, in: name)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are static and covered by the standalone parser tests.
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    private static func range(_ text: String) -> NSRange {
        NSRange(text.startIndex..<text.endIndex, in: text)
    }

    private static func hasMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: range(text)) != nil
    }
}
