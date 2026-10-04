import Foundation

@main
struct LabelParserTests {
    static func main() {
        let dueCases: [(String, String?)] = [
            ("产品名称：鲜牛奶\n生产日期：2026.10.01\n保质期至：2026年10月08日", "2026-10-08"),
            ("生产日期2026-10-01 有效期至2027-10-01", "2027-10-01"),
            ("MFG\n2026-10-01\nEXP\n2027-10-01", "2027-10-01"),
            ("有效期至\n20281030", "2028-10-30"),
            ("Best before: 2028/6/3", "2028-06-03"),
            ("Expiry date:\n2028-06-30", "2028-06-30"),
            ("USE BY 2028.06.30", "2028-06-30"),
            ("Expires on: 2028-06-30", "2028-06-30"),
            ("有 效 期 至：２０２８年０６月３０日", "2028-06-30"),
            ("EXP 2028-06-30\nBest before 2028-06-30", "2028-06-30"),
            ("到期日：1900-01-01", "1900-01-01"),
            ("到期日期：2200-12-31", "2200-12-31"),
            ("EXP 2028-02-29", "2028-02-29"),
            ("EXP 2000-02-29", "2000-02-29"),
            ("生产日期2028-06-30", nil),
            ("制造日期2028-06-30", nil),
            ("包装日期2028-06-30", nil),
            ("Manufactured on 2028-06-30", nil),
            ("MFD 2028-06-30", nil),
            ("批号20280630", nil),
            ("LOT 20280630", nil),
            ("6902028063012", nil),
            ("保质期730天", nil),
            ("2028-06-30", nil),
            ("生产日期见瓶底\n有效期至见封口\n2028-06-30", nil),
            ("EXP 04/05/2028", nil),
            ("EXP 2028-06", nil),
            ("有效期至06月30日", nil),
            ("EXP 2O28-O6-3O", nil),
            ("有效期至2027-02-29", nil),
            ("EXP 1900-02-29", nil),
            ("EXP 2028-06-31", nil),
            ("EXP 2028-00-10", nil),
            ("EXP 2028-13-10", nil),
            ("EXP 2028-01-00", nil),
            ("EXP 1899-12-31", nil),
            ("EXP 2201-01-01", nil),
            ("EXP 2299-01-01", nil),
            ("EXP 202806301", nil),
            ("EXP 6902028063012", nil),
            ("有效期至2028-06-30\n到期日期2028-07-30", nil),
            ("EXP 2028-06-30 2028-07-30", nil),
            ("EXP 2028-06-30\n有效期至见瓶底", nil),
            ("EXP 2028-06-30\n到期日2028-02-30", nil),
            ("到期日\n生产日期2028-06-30", nil),
            ("EXPERIMENT 2028-06-30", nil),
            ("", nil)
        ]
        let nameCases: [(String, String?)] = [
            ("产品名称：鲜牛奶\n生产日期2026-10-01", "鲜牛奶"),
            ("Product name: Herbal tea\nEXP 2028-06-30", "Herbal tea"),
            ("维生素 C 片\n有效期至2028-01-01", "维生素 C 片"),
            ("生产日期2026-10-01\nEXP2027-10-01\n6902028063012", nil),
            ("品名：6902028063012", nil),
            ("净含量250克\n配料：牛奶\n批号123456", nil),
            ("", nil)
        ]
        var failures: [String] = []
        for (text, expected) in dueCases {
            let actual = LabelParser.parse(text).suggestedDueDate
            if actual != expected {
                failures.append("Date: \(text.debugDescription), expected \(String(describing: expected)), got \(String(describing: actual))")
            }
        }
        for (text, expected) in nameCases {
            let actual = LabelParser.parse(text).suggestedName
            if actual != expected {
                failures.append("Name: \(text.debugDescription), expected \(String(describing: expected)), got \(String(describing: actual))")
            }
        }
        let normalized = LabelParser.parse("品名：鲜牛奶\nＥＸＰ：２０２８－０６－３０")
        if normalized.text != "品名:鲜牛奶\nEXP:2028-06-30" {
            failures.append("Recognized text must remain available with compatibility normalization")
        }
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("PASS: \(dueCases.count + nameCases.count + 1) label parser assertions")
    }
}
