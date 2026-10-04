import SwiftUI
import WebKit
import Combine

@MainActor
final class WebBrowser: NSObject, ObservableObject {
    static let home = URL(string: "https://home-expiry-map.bubbly-bread-0945.chatgpt.site/")!
    @Published var loading = true
    @Published var failure: String?
    @Published var notice: String?
    @Published var isSigningIn = false
    @Published var displayHost = ""
    @Published var calendarDraft: CalendarItem?
    let webView: WKWebView
    private var downloads: [ObjectIdentifier: URL] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        webView.load(URLRequest(url: Self.home))
    }
    @objc private func pullToRefresh() { retry() }
    func retry() {
        failure = nil
        loading = true
        if webView.url == nil { goHome() } else { webView.reload() }
    }
    func goHome() {
        failure = nil
        webView.load(URLRequest(url: Self.home))
    }
    func openInSafari() { UIApplication.shared.open(Self.home) }
    private func updateLocation(_ webView: WKWebView) {
        let host = webView.url?.host?.lowercased() ?? ""
        displayHost = host
        isSigningIn = !host.isEmpty && host != Self.home.host
    }
    private func failed(_ error: Error) {
        loading = false
        webView.scrollView.refreshControl?.endRefreshing()
        let error = error as NSError
        // Downloads and external links deliberately interrupt a navigation.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        failure = "请检查网络后重试。登录和家庭记录需要连接网络。"
    }
}

extension WebBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failure = nil
        updateLocation(webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateLocation(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        updateLocation(webView)
        webView.scrollView.refreshControl?.endRefreshing()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        failure = "页面已暂停，请重新加载。尚未保存的表单需要重新填写。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(url.scheme == "https" || url.scheme == "about" ? .allow : .cancel)
            return
        }
        switch NavigationRules.classify(url) {
        case .inApp:
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        case .external:
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        case .blocked:
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.response.mimeType == "text/calendar" {
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
}

extension WebBrowser: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        switch NavigationRules.classify(url) {
        case .inApp: webView.load(navigationAction.request)
        case .external: UIApplication.shared.open(url)
        case .blocked: break
        }
        return nil
    }
}

extension WebBrowser: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard response.mimeType == "text/calendar" || URL(fileURLWithPath: suggestedFilename).pathExtension.lowercased() == "ics" else {
            notice = "当前 App 仅接收日历提醒文件。"
            completionHandler(nil)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("expiry-\(UUID().uuidString).ics")
        downloads[ObjectIdentifier(download)] = url
        completionHandler(url)
    }
    func downloadDidFinish(_ download: WKDownload) {
        loading = false
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            calendarDraft = CalendarItem(draft: try CalendarDraft.parse(text))
        } catch { notice = "未能读取这条日历提醒，请返回事项详情重新添加。" }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: url) }
        loading = false
        notice = "日历提醒未能准备好，请重试。"
    }
}

struct BrowserView: UIViewRepresentable {
    @ObservedObject var browser: WebBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
