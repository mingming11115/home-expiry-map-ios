import Foundation

enum NavigationRules {
    enum Decision: Equatable {
        case inApp
        case external
        case blocked
    }

    private static let siteHost = "home-expiry-map.bubbly-bread-0945.chatgpt.site"
    private static let inAppHosts: Set<String> = [
        siteHost,
        "auth.openai.com",
        "auth0.openai.com",
        "chatgpt.com",
        "auth.chatgpt.com",
        "accounts.google.com",
        "appleid.apple.com",
        "account.apple.com",
        "login.microsoftonline.com",
        "login.live.com"
    ]

    static func classify(_ url: URL) -> Decision {
        guard url.user == nil, url.password == nil else { return .blocked }

        switch url.scheme?.lowercased() {
        case "https":
            guard let host = url.host?.lowercased(), !host.isEmpty else { return .blocked }
            return inAppHosts.contains(host) ? .inApp : .external
        case "mailto", "tel":
            return .external
        case "blob":
            // A blob inherits the origin encoded after "blob:". Only blobs
            // from the published app's HTTPS origin may stay in the web view.
            let nestedAddress = String(url.absoluteString.dropFirst("blob:".count))
            guard let nestedURL = URL(string: nestedAddress),
                  nestedURL.user == nil,
                  nestedURL.password == nil,
                  nestedURL.scheme?.lowercased() == "https",
                  nestedURL.host?.lowercased() == siteHost,
                  nestedURL.port == nil || nestedURL.port == 443
            else { return .blocked }
            return .inApp
        default:
            return .blocked
        }
    }
}
