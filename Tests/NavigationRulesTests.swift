import Foundation

@main
struct NavigationRulesTests {
    static func main() {
        typealias Decision = NavigationRules.Decision
        let site = "home-expiry-map.bubbly-bread-0945.chatgpt.site"
        var cases: [(String, String, Decision)] = [
            ("published home", "https://\(site)/", .inApp),
            ("published deep link", "https://\(site)/?join=sample#details", .inApp),
            ("host case is insensitive", "HTTPS://HOME-EXPIRY-MAP.BUBBLY-BREAD-0945.CHATGPT.SITE/", .inApp),
            ("query does not change origin", "https://\(site)/?next=https://example.org", .inApp),
            ("unrelated HTTPS", "https://example.org/", .external),
            ("site suffix spoof", "https://\(site).example.org/", .external),
            ("site prefix spoof", "https://evil-\(site)/", .external),
            ("unlisted site subdomain", "https://preview.\(site)/", .external),
            ("auth suffix spoof", "https://auth.openai.com.example.org/", .external),
            ("unlisted OpenAI subdomain", "https://api.openai.com/", .external),
            ("trailing dot is not exact host", "https://\(site)./", .external),
            ("HTTPS localhost stays external", "https://localhost/", .external),
            ("email link", "mailto:family@example.org?subject=Reminder", .external),
            ("telephone link", "tel:+8613800000000", .external),
            ("site over HTTP", "http://\(site)/", .blocked),
            ("HTTP localhost", "http://localhost:3000/", .blocked),
            ("HTTP loopback", "http://127.0.0.1:3000/", .blocked),
            ("file URL", "file:///private/tmp/reminder.ics", .blocked),
            ("JavaScript URL", "javascript:alert(1)", .blocked),
            ("data URL", "data:text/calendar,BEGIN:VCALENDAR", .blocked),
            ("unknown protocol", "ftp://\(site)/", .blocked),
            ("relative URL", "/settings", .blocked),
            ("HTTPS without a host", "https:/reminder.ics", .blocked),
            ("username on allowed host", "https://someone@\(site)/", .blocked),
            ("password on allowed host", "https://someone:password@\(site)/", .blocked),
            ("empty username", "https://@\(site)/", .blocked),
            ("site disguised as username", "https://\(site)@example.org/", .blocked),
            ("credentials on external URL", "https://someone:password@example.org/", .blocked),
            ("credentials on mailto authority", "mailto://someone:password@example.org", .blocked),
            ("site blob", "blob:https://\(site)/sample-calendar", .inApp),
            ("site blob default port", "blob:https://\(site):443/sample-calendar", .inApp),
            ("site blob different port", "blob:https://\(site):8443/sample-calendar", .blocked),
            ("blob from other site", "blob:https://example.org/sample-calendar", .blocked),
            ("blob from auth origin", "blob:https://auth.openai.com/sample-calendar", .blocked),
            ("blob suffix spoof", "blob:https://\(site).example.org/sample-calendar", .blocked),
            ("blob username spoof", "blob:https://someone@\(site)/sample-calendar", .blocked),
            ("blob site disguised as username", "blob:https://\(site)@example.org/sample-calendar", .blocked),
            ("blob from HTTP", "blob:http://\(site)/sample-calendar", .blocked),
            ("blob null origin", "blob:null/sample-calendar", .blocked),
            ("nested blob", "blob:blob:https://\(site)/sample-calendar", .blocked),
            ("blob from file", "blob:file:///private/tmp/reminder.ics", .blocked)
        ]
        for host in [
            "auth.openai.com", "auth0.openai.com", "chatgpt.com", "auth.chatgpt.com",
            "accounts.google.com", "appleid.apple.com", "account.apple.com",
            "login.microsoftonline.com", "login.live.com"
        ] {
            cases.append(("allowed auth host \(host)", "https://\(host)/authorize", .inApp))
        }

        var failures: [String] = []
        for (name, rawURL, expected) in cases {
            guard let url = URL(string: rawURL) else {
                failures.append("FAIL \(name): invalid test fixture \(rawURL)")
                continue
            }
            let actual = NavigationRules.classify(url)
            if actual != expected {
                failures.append("FAIL \(name): expected \(expected), got \(actual) — \(rawURL)")
            }
        }
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("PASS: \(cases.count) navigation rule assertions")
    }
}
