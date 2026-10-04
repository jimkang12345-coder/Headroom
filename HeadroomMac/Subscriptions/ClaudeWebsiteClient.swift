import AppKit
import WebKit
import HeadroomCore

/// Reads the visible account usage page in an isolated, persistent WebKit session.
/// No cookie extraction, private endpoints, synthetic prompts, or browser-profile access.
@MainActor
final class ClaudeWebsiteClient: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onUsage: ((SubscriptionUsage) -> Void)?
    var onStatus: ((String) -> Void)?
    var enabled: Bool { session.enabled }
    var sessionDeletionRequired: Bool { session.deletionRequired }
    var isDeletingSession: Bool { session.isDeleting }
    private var session = ClaudeWebsiteSessionLifecycle()
    private var deletionTask: Task<Void, Error>?
    private let dataStoreIdentifier: UUID
    private let removeDataStore: (UUID) async throws -> Void
    private var webView: WKWebView?
    private var window: NSWindow?
    private var lastLoad = Date.distantPast
    private var nextLoad = Date.distantPast
    private var failures = 0
    private var awaitingSnapshot = false
    private var reading = false
    private let page = URL(string: "https://claude.ai/settings/usage")!

    init(dataStoreIdentifier: UUID = UUID(uuidString: "5CD0C2A0-1234-4500-A000-000000000001")!,
         removeDataStore: @escaping (UUID) async throws -> Void = ClaudeWebsiteClient.removePersistentStore) {
        self.dataStoreIdentifier = dataStoreIdentifier
        self.removeDataStore = removeDataStore
        super.init()
    }

    func setEnabled(_ value: Bool) {
        guard session.setEnabled(value) else { return }
        awaitingSnapshot = false
        reading = false
        if !value { webView?.stopLoading() }
        else { nextLoad = .distantPast; tick() }
    }

    /// Destroys the browser before deleting its dedicated persistent data store.
    /// Concurrent disconnect requests share one deletion; failed deletion must be retried.
    func disconnect() async throws {
        if let deletionTask { return try await deletionTask.value }
        session.beginDeletion()
        releaseBrowser()
        let identifier = dataStoreIdentifier
        let remove = removeDataStore
        let task = Task {
            defer { self.deletionTask = nil }
            do {
                try await remove(identifier)
                self.session.finishDeletion(succeeded: true)
            } catch {
                self.session.finishDeletion(succeeded: false)
                throw error
            }
        }
        deletionTask = task
        try await task.value
    }

    private func releaseBrowser() {
        awaitingSnapshot = false
        reading = false
        lastLoad = .distantPast
        nextLoad = .distantPast
        failures = 0
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.contentView = nil
        window?.close()
        window = nil
        webView = nil
    }

    static func removePersistentStore(_ identifier: UUID) async throws {
        // A first Code-feed connection or a repeated disconnect may have no website
        // profile. Only confirmed absence counts as successful cleanup; errors from
        // deleting an existing profile still reach the lifecycle's retry guard.
        guard await persistentStoreExists(identifier) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    static func persistentStoreExists(_ identifier: UUID) async -> Bool {
        // Some WebKit versions require initialization before identifier enumeration.
        // This in-memory store initializes WebKit without opening a website profile,
        // creating a browser, loading a page, or reading any cookies.
        let bootstrap = WKWebsiteDataStore.nonPersistent()
        let identifiers: [UUID] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
        withExtendedLifetime(bootstrap) {}
        return identifiers.contains(identifier)
    }
    private func prepare() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // Dedicated persistent store; independent of Safari/Chrome and other app browsing.
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1050, height: 750), configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        return view
    }
    func showConnection() {
        guard !session.deletionRequired, !session.isDeleting else {
            onStatus?("Delete the previous local Claude sign-in session before reconnecting.")
            return
        }
        let view = prepare()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 750),
                                 styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "Claude account usage · Sign in at claude.ai"
            panel.isReleasedWhenClosed = false
            panel.contentView = view
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setEnabled(true)
        if view.url == nil { reload() }
    }
    func tick(force: Bool = false) {
        guard enabled else { return }
        let now = Date()
        if awaitingSnapshot {
            if now.timeIntervalSince(lastLoad) > 25 {
                awaitingSnapshot = false
                fail("Claude usage page did not load. Open the Claude website connection to check your sign-in.")
            } else if webView?.isLoading == false { readPage() }
            return
        }
        // Don't reload a sign-in form while the user is entering credentials.
        if let url = webView?.url, !isUsagePage(url) {
            return
        }
        if !reading, now >= nextLoad || (force && now.timeIntervalSince(lastLoad) >= 5) { reload() }
    }
    private func isUsagePage(_ url: URL?) -> Bool {
        ClaudeWebsiteNavigationPolicy.isUsagePage(url)
    }
    private func reload() {
        guard enabled else { return }
        lastLoad = Date()
        awaitingSnapshot = true
        prepare().load(URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard enabled, self.webView === webView else { return }
        if isUsagePage(webView.url) {
            // React may not have rendered yet; the regular tick retries within the load deadline.
            awaitingSnapshot = true
            lastLoad = Date()
            readPage()
        } else {
            awaitingSnapshot = false
            onStatus?("Sign in to Claude in the website connection, then open Settings → Usage.")
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard enabled, self.webView === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        awaitingSnapshot = false
        fail("Claude website is unavailable. Retrying automatically; your last reading is preserved.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard enabled, self.webView === webView,
              navigationAction.targetFrame != nil, !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            return
        }
        // The provider may load third-party resources. Restrict top-level page navigation only.
        if navigationAction.targetFrame?.isMainFrame == true,
           !ClaudeWebsiteNavigationPolicy.allows(navigationAction.request.url) {
            onStatus?("This connection window stays on claude.ai. Other sign-in domains and pop-up windows are not supported yet.")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard enabled, self.webView === webView, navigationResponse.canShowMIMEType,
              !navigationResponse.isForMainFrame || ClaudeWebsiteNavigationPolicy.allows(navigationResponse.response.url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if enabled, self.webView === webView {
            onStatus?("Pop-up sign-in windows are not supported in this connection. Use a sign-in method that stays on claude.ai.")
        }
        return nil
    }
    private func readPage() {
        guard enabled, !reading, isUsagePage(webView?.url), let webView else { return }
        reading = true
        let expected = session.epoch
        webView.evaluateJavaScript("document.body.innerText") { [weak self] value, error in
            guard let self, self.session.acceptsReading(from: expected) else { return }
            self.reading = false
            guard error == nil, let text = value as? String,
                  let usage = try? SubscriptionUsage.claudeWebsite(text) else { return }
            self.awaitingSnapshot = false
            self.failures = 0
            self.nextLoad = Date().addingTimeInterval(30)
            self.onUsage?(usage)
        }
    }
    private func fail(_ message: String) {
        failures = min(failures + 1, 4)
        nextLoad = Date().addingTimeInterval(min(300, 30 * pow(2, Double(failures))))
        onStatus?(message)
    }
}
