import SwiftUI
import WebKit
import UIKit

// MARK: - Browser State

struct BrowserHistoryEntry: Identifiable {
    let id = UUID()
    let url: String
    let title: String
    let date: Date
}

@MainActor
class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String = "New Tab"
    @Published var urlInput: String = ""
    @Published var displayURL: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var progress: Double = 0
    let webView: WKWebView

    private var progressObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration) {
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.allowsLinkPreview = true
        // Use a recent mobile Safari user agent so sites serve the proper mobile layout
        self.webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                self?.progress = webView.estimatedProgress
            }
        }
    }

    deinit {
        progressObservation?.invalidate()
    }

    func navigate(to urlString: String) {
        var raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = raw.contains(".") && !raw.contains(" ")
                ? "https://\(raw)"
                : "https://www.google.com/search?q=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
        }
        if let url = URL(string: raw) {
            webView.load(URLRequest(url: url))
        }
    }

    func reload() {
        if webView.url != nil {
            webView.reload()
        } else if !urlInput.isEmpty {
            navigate(to: urlInput)
        }
    }

    func stop() {
        webView.stopLoading()
    }
}

@MainActor
class BrowserManager: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?
    @Published var history: [BrowserHistoryEntry] = []
    @Published var bookmarks: [BrowserHistoryEntry] = []

    // Shared across tabs so cookies, localStorage, and login sessions persist.
    private let processPool = WKProcessPool()
    private let dataStore = WKWebsiteDataStore.default()

    var activeTab: BrowserTab? {
        guard let id = activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    init() {
        loadBookmarks()
        let first = makeTab()
        tabs = [first]
        activeTabID = first.id
    }

    func makeConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = processPool
        cfg.websiteDataStore = dataStore
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsPictureInPictureMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        return cfg
    }

    func makeTab() -> BrowserTab {
        BrowserTab(configuration: makeConfiguration())
    }

    func newTab(url: String? = nil) {
        let tab = makeTab()
        tabs.append(tab)
        activeTabID = tab.id
        if let url { tab.navigate(to: url) }
    }

    func closeTab(_ tab: BrowserTab) {
        guard tabs.count > 1 else { return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: idx)
            activeTabID = tabs[max(0, min(idx, tabs.count - 1))].id
        }
    }

    func addHistory(url: String, title: String) {
        guard !url.contains("google.com/search") else { return }
        // De-dup most-recent
        history.removeAll { $0.url == url }
        let entry = BrowserHistoryEntry(url: url, title: title.isEmpty ? url : title, date: Date())
        history.insert(entry, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
    }

    // MARK: - Bookmarks (persisted in UserDefaults)

    private let bookmarksKey = "bsafe.browser.bookmarks"

    func toggleBookmark(url: String, title: String) {
        if let idx = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.insert(BrowserHistoryEntry(url: url, title: title.isEmpty ? url : title, date: Date()), at: 0)
        }
        saveBookmarks()
    }

    func isBookmarked(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    private func saveBookmarks() {
        let payload = bookmarks.map { ["url": $0.url, "title": $0.title, "date": $0.date.timeIntervalSince1970] as [String: Any] }
        UserDefaults.standard.set(payload, forKey: bookmarksKey)
    }

    private func loadBookmarks() {
        guard let raw = UserDefaults.standard.array(forKey: bookmarksKey) as? [[String: Any]] else { return }
        bookmarks = raw.compactMap {
            guard let url = $0["url"] as? String, let title = $0["title"] as? String else { return nil }
            let ts = $0["date"] as? Double ?? Date().timeIntervalSince1970
            return BrowserHistoryEntry(url: url, title: title, date: Date(timeIntervalSince1970: ts))
        }
    }
}

// MARK: - Safe Browser View

struct SafeBrowserView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @StateObject private var browser = BrowserManager()
    @State private var showHistory = false
    @State private var showTabs = false
    @State private var showShare = false
    @State private var blockedDomain: String? = nil
    @FocusState private var addressFocused: Bool

    private var allowedWebsites: [String] { settingsManager.configuration.allowedWebsites }
    private var blockedWebsites: [String] { settingsManager.configuration.blockedWebsites }
    private var isWhitelistMode: Bool { settingsManager.configuration.websiteFilterMode == .whitelist }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                progressBar

                if let blocked = blockedDomain {
                    blockedNotice(domain: blocked)
                }

                if let tab = browser.activeTab {
                    if tab.webView.url != nil {
                        TabWebView(
                            tab: tab,
                            allowedWebsites: allowedWebsites,
                            blockedWebsites: blockedWebsites,
                            isWhitelistMode: isWhitelistMode,
                            blockedDomain: $blockedDomain,
                            onNavigate: { url, title in browser.addHistory(url: url, title: title) },
                            onOpenInNewTab: { url in browser.newTab(url: url) }
                        )
                    } else {
                        homeScreen
                    }
                }
            }
            .navigationTitle("B-SAFE Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { bottomToolbar }
            .sheet(isPresented: $showHistory) { historySheet }
            .sheet(isPresented: $showTabs) { tabsSheet }
            .sheet(isPresented: $showShare) {
                if let urlString = browser.activeTab?.webView.url?.absoluteString,
                   let url = URL(string: urlString) {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    // MARK: - Address Bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: lockIconName)
                    .font(.caption)
                    .foregroundStyle(lockIconColor)
                TextField("Search or enter website", text: Binding(
                    get: { browser.activeTab?.urlInput ?? "" },
                    set: { browser.activeTab?.urlInput = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    guard let tab = browser.activeTab else { return }
                    blockedDomain = nil
                    tab.navigate(to: tab.urlInput)
                }
                if let tab = browser.activeTab, tab.isLoading {
                    Button { tab.stop() } label: {
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                } else if let tab = browser.activeTab, tab.webView.url != nil {
                    Button { tab.reload() } label: {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                } else if !(browser.activeTab?.urlInput.isEmpty ?? true) {
                    Button { browser.activeTab?.urlInput = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button { showTabs = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(red: 0, green: 0.4, blue: 0.15), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                    Text("\(browser.tabs.count)")
                        .font(.caption).fontWeight(.bold)
                        .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator)), alignment: .bottom)
    }

    private var lockIconName: String {
        if browser.activeTab?.isLoading == true { return "arrow.triangle.2.circlepath" }
        if let url = browser.activeTab?.webView.url, url.scheme == "https" { return "lock.fill" }
        return "magnifyingglass"
    }

    private var lockIconColor: Color {
        if browser.activeTab?.isLoading == true { return .orange }
        if let url = browser.activeTab?.webView.url, url.scheme == "https" { return .green }
        return .secondary
    }

    @ViewBuilder
    private var progressBar: some View {
        if let tab = browser.activeTab, tab.isLoading, tab.progress < 1 {
            ProgressView(value: tab.progress)
                .progressViewStyle(.linear)
                .tint(Color(red: 0, green: 0.4, blue: 0.15))
                .frame(height: 2)
        }
    }

    @ViewBuilder
    private func blockedNotice(domain: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(domain) is not allowed")
                    .font(.subheadline).fontWeight(.medium)
                Text(isWhitelistMode
                     ? "Ask your admin to add it to the allowed list."
                     : "This site is on the blocked list.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { blockedDomain = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    // MARK: - Home Screen

    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !browser.bookmarks.isEmpty {
                    homeSection(title: "Bookmarks") {
                        siteGrid(entries: browser.bookmarks)
                    }
                }

                if !browser.history.isEmpty {
                    homeSection(title: "Recent") {
                        ForEach(browser.history.prefix(5)) { entry in
                            historyRow(entry: entry)
                        }
                    }
                }

                if !allowedWebsites.isEmpty {
                    homeSection(title: "Allowed Sites") {
                        siteGrid(entries: allowedWebsites.map {
                            BrowserHistoryEntry(url: $0, title: $0, date: Date())
                        })
                    }
                } else if isWhitelistMode {
                    VStack(spacing: 12) {
                        Image(systemName: "globe.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Allowed Sites").font(.headline)
                        Text("Your admin hasn't added any sites to your allowed list yet.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func homeSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal)
            content()
        }
    }

    @ViewBuilder
    private func historyRow(entry: BrowserHistoryEntry) -> some View {
        Button {
            browser.activeTab?.urlInput = entry.url
            blockedDomain = nil
            browser.activeTab?.navigate(to: entry.url)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(entry.url)")) {
                    $0.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(entry.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func siteGrid(entries: [BrowserHistoryEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(entries) { entry in
                Button {
                    browser.activeTab?.urlInput = entry.url
                    blockedDomain = nil
                    browser.activeTab?.navigate(to: entry.url)
                } label: {
                    VStack(spacing: 6) {
                        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(entry.url)")) {
                            $0.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                        Text(entry.title.isEmpty ? entry.url : entry.title)
                            .font(.caption2).lineLimit(1).foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Bottom Toolbar

    @ToolbarContentBuilder
    private var bottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { browser.activeTab?.webView.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(browser.activeTab?.canGoBack != true)

            Spacer()

            Button { browser.activeTab?.webView.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(browser.activeTab?.canGoForward != true)

            Spacer()

            Button {
                showShare = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(browser.activeTab?.webView.url == nil)

            Spacer()

            Menu {
                if let tab = browser.activeTab, let url = tab.webView.url?.absoluteString {
                    Button {
                        browser.toggleBookmark(url: url, title: tab.title)
                    } label: {
                        Label(browser.isBookmarked(url: url) ? "Remove Bookmark" : "Add Bookmark",
                              systemImage: browser.isBookmarked(url: url) ? "bookmark.slash" : "bookmark")
                    }
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                    Button { tab.reload() } label: {
                        Label("Reload Page", systemImage: "arrow.clockwise")
                    }
                }
                Button { showHistory = true } label: {
                    Label("History", systemImage: "clock")
                }
                Button {
                    browser.activeTab?.webView.load(URLRequest(url: URL(string: "about:blank")!))
                    browser.activeTab?.urlInput = ""
                } label: {
                    Label("Home", systemImage: "house")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }

            Spacer()

            Button { browser.newTab() } label: {
                Image(systemName: "plus.square.on.square")
            }
        }
    }

    // MARK: - History Sheet

    private var historySheet: some View {
        NavigationStack {
            Group {
                if browser.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No History").font(.headline)
                        Text("Sites you visit will appear here.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(browser.history) { entry in
                            Button {
                                showHistory = false
                                browser.activeTab?.urlInput = entry.url
                                blockedDomain = nil
                                browser.activeTab?.navigate(to: entry.url)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                    Text(entry.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(entry.date.formatted(.relative(presentation: .named)))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete { browser.history.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showHistory = false } }
                ToolbarItem(placement: .destructiveAction) {
                    if !browser.history.isEmpty {
                        Button("Clear", role: .destructive) { browser.history.removeAll() }
                    }
                }
            }
        }
    }

    // MARK: - Tabs Sheet

    private var tabsSheet: some View {
        NavigationStack {
            List {
                ForEach(browser.tabs) { tab in
                    Button {
                        browser.activeTabID = tab.id
                        showTabs = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                                    .font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                Text(tab.displayURL.isEmpty ? "No page loaded" : tab.displayURL)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if browser.activeTabID == tab.id {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            browser.closeTab(tab)
                        } label: { Label("Close", systemImage: "xmark") }
                    }
                }
            }
            .navigationTitle("Tabs (\(browser.tabs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showTabs = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { browser.newTab(); showTabs = false } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}

// MARK: - Per-Tab WebView

struct TabWebView: UIViewRepresentable {
    let tab: BrowserTab
    let allowedWebsites: [String]
    let blockedWebsites: [String]
    let isWhitelistMode: Bool
    @Binding var blockedDomain: String?
    let onNavigate: (String, String) -> Void
    let onOpenInNewTab: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = tab.webView
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // Pull-to-refresh
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.handleRefresh(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.refreshControl = refresh

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: TabWebView
        weak var refreshControl: UIRefreshControl?

        init(_ parent: TabWebView) { self.parent = parent }

        @objc func handleRefresh(_ sender: UIRefreshControl) {
            Task { @MainActor in
                self.parent.tab.webView.reload()
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }

            // Allow about:blank (home navigation) and non-http(s) schemes
            // (mailto:, tel:, etc.) — UIApplication will handle those.
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
            if let scheme = url.scheme, scheme != "http" && scheme != "https" {
                decisionHandler(.cancel)
                Task { @MainActor in UIApplication.shared.open(url) }
                return
            }

            // Subresource requests (iframes, sub-frames) — let the page render.
            // We only enforce the filter on main-frame top-level navigations.
            let isMainFrame = action.targetFrame?.isMainFrame ?? true

            // target=_blank / window.open: open in a new tab and stop here.
            if action.targetFrame == nil {
                Task { @MainActor in self.parent.onOpenInNewTab(url.absoluteString) }
                decisionHandler(.cancel)
                return
            }

            guard isMainFrame, let host = url.host else {
                decisionHandler(.allow)
                return
            }

            // Blacklist mode: block listed domains.
            if !parent.isWhitelistMode {
                if DomainMatcher.matches(host: host, anyOf: parent.blockedWebsites) {
                    decisionHandler(.cancel)
                    Task { @MainActor in
                        self.parent.blockedDomain = DomainMatcher.normalize(host) ?? host
                    }
                    return
                }
                decisionHandler(.allow)
                return
            }

            // Whitelist mode: only allow listed domains (and their subdomains).
            if DomainMatcher.matches(host: host, anyOf: parent.allowedWebsites) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                Task { @MainActor in
                    self.parent.blockedDomain = DomainMatcher.normalize(host) ?? host
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            Task { @MainActor in parent.tab.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                parent.tab.isLoading = false
                parent.tab.canGoBack = webView.canGoBack
                parent.tab.canGoForward = webView.canGoForward
                refreshControl?.endRefreshing()
                if let url = webView.url, url.absoluteString != "about:blank" {
                    let host = url.host ?? url.absoluteString
                    parent.tab.urlInput = host
                    parent.tab.displayURL = url.absoluteString
                    parent.tab.title = webView.title ?? host
                    parent.onNavigate(url.absoluteString, webView.title ?? host)
                } else {
                    parent.tab.urlInput = ""
                    parent.tab.displayURL = ""
                    parent.tab.title = "New Tab"
                }
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            Task { @MainActor in
                parent.tab.isLoading = false
                refreshControl?.endRefreshing()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            Task { @MainActor in
                parent.tab.isLoading = false
                refreshControl?.endRefreshing()
            }
        }

        // MARK: WKUIDelegate

        /// Handle window.open / target=_blank by opening a new tab.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Returning nil tells WebKit to not create a new web view — instead
            // we open the destination URL as a new tab in our manager.
            if let url = navigationAction.request.url {
                Task { @MainActor in self.parent.onOpenInNewTab(url.absoluteString) }
            }
            return nil
        }

        /// JS alert(): show as a SwiftUI alert via UIAlertController on top window.
        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            presentAlert(title: nil, message: message, actions: [
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }
            ])
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            presentAlert(title: nil, message: message, actions: [
                UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
            ])
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            topController()?.present(alert, animated: true)
        }

        private func presentAlert(title: String?, message: String, actions: [UIAlertAction]) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            actions.forEach { alert.addAction($0) }
            topController()?.present(alert, animated: true)
        }

        private func topController() -> UIViewController? {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first
                .map { vc -> UIViewController in
                    var top = vc
                    while let presented = top.presentedViewController { top = presented }
                    return top
                }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
