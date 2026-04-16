import SwiftUI
import WebKit

// MARK: - Persisted Models

struct BrowserHistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var date: Date
}

struct BrowserBookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var date: Date = Date()
}

// MARK: - Persistent Store

@MainActor
final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    private let historyKey   = "bsafe.browser.history"
    private let bookmarksKey = "bsafe.browser.bookmarks"
    private let maxHistory   = 500

    @Published var history:   [BrowserHistoryEntry] = []
    @Published var bookmarks: [BrowserBookmark]     = []

    private init() { load() }

    func addHistory(url: String, title: String) {
        guard !url.contains("google.com/search"),
              !url.isEmpty,
              url != "about:blank" else { return }
        // De-dupe by URL (keep most recent)
        history.removeAll { $0.url == url }
        history.insert(BrowserHistoryEntry(url: url, title: title.isEmpty ? url : title, date: Date()), at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        saveHistory()
    }

    func isBookmarked(_ url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    func toggleBookmark(url: String, title: String) {
        if let i = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: i)
        } else {
            bookmarks.insert(BrowserBookmark(url: url, title: title.isEmpty ? url : title), at: 0)
        }
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    // MARK: - Persistence

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([BrowserHistoryEntry].self, from: data) {
            history = decoded
        }
        if let data = d.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data) {
            bookmarks = decoded
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }
}

// MARK: - Browser Tab

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title:          String  = "New Tab"
    @Published var urlInput:       String  = ""
    @Published var currentURL:     String  = ""
    @Published var isLoading:      Bool    = false
    @Published var canGoBack:      Bool    = false
    @Published var canGoForward:   Bool    = false
    @Published var estimatedProgress: Double = 0
    @Published var isSecure:       Bool    = false

    let webView: WKWebView

    private var progressObservation: NSKeyValueObservation?

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

        // Track page load progress for the address bar progress indicator
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in self?.estimatedProgress = wv.estimatedProgress }
        }
    }

    deinit { progressObservation?.invalidate() }

    func navigate(to urlString: String) {
        var raw = urlString.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = raw.contains(".") && !raw.contains(" ")
                ? "https://\(raw)"
                : "https://www.google.com/search?q=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
        }
        if let url = URL(string: raw) {
            // Mark as "has page" immediately so the view switches from home to webview.
            currentURL = raw
            urlInput = raw
            webView.load(URLRequest(url: url))
        }
    }

    func reload()  { webView.reload() }
    func stop()    { webView.stopLoading() }
    func goHome()  {
        webView.stopLoading()
        urlInput = ""
        currentURL = ""
        title = "New Tab"
        estimatedProgress = 0
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

// MARK: - Browser Manager

@MainActor
final class BrowserManager: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?

    var activeTab: BrowserTab? {
        guard let id = activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == id })
    }

    init() {
        let first = BrowserTab()
        tabs = [first]
        activeTabID = first.id
    }

    func newTab(url: String? = nil) {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabID = tab.id
        if let url { tab.navigate(to: url) }
    }

    func closeTab(_ tab: BrowserTab) {
        guard tabs.count > 1 else { tab.goHome(); return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: idx)
            activeTabID = tabs[max(0, min(idx, tabs.count - 1))].id
        }
    }
}

// MARK: - Safe Browser View

struct SafeBrowserView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @StateObject private var browser = BrowserManager()
    @StateObject private var store   = BrowserStore.shared

    @State private var showHistory = false
    @State private var showTabs    = false
    @State private var showBookmarks = false
    @State private var blockedDomain: String? = nil
    @FocusState private var addressFocused: Bool

    private var allowedWebsites: [String] { settingsManager.configuration.allowedWebsites }
    private var isWhitelistMode: Bool { settingsManager.configuration.websiteFilterMode == .whitelist }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                progressBar
                if let blocked = blockedDomain { blockedBanner(blocked) }

                if let tab = browser.activeTab {
                    if !tab.currentURL.isEmpty {
                        TabWebView(
                            tab: tab,
                            allowedWebsites: allowedWebsites,
                            isWhitelistMode: isWhitelistMode,
                            blockedDomain: $blockedDomain,
                            onNavigate: { url, title in store.addHistory(url: url, title: title) }
                        )
                    } else {
                        homeScreen
                    }
                }
            }
            .navigationTitle("B-SAFE Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { bottomToolbar }
            .sheet(isPresented: $showHistory)   { historySheet }
            .sheet(isPresented: $showBookmarks) { bookmarksSheet }
            .sheet(isPresented: $showTabs)      { tabsSheet }
        }
    }

    // MARK: - Address Bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                // Lock/loading/warning indicator
                Group {
                    if browser.activeTab?.isLoading == true {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                    } else if browser.activeTab?.isSecure == true {
                        Image(systemName: "lock.fill").foregroundStyle(.green)
                    } else if !(browser.activeTab?.currentURL.isEmpty ?? true) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                TextField("Search or enter website", text: Binding(
                    get: { browser.activeTab?.urlInput ?? "" },
                    set: { browser.activeTab?.urlInput = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($addressFocused)
                .submitLabel(.go)
                .onSubmit {
                    guard let tab = browser.activeTab else { return }
                    blockedDomain = nil
                    addressFocused = false
                    tab.navigate(to: tab.urlInput)
                }

                if !(browser.activeTab?.urlInput.isEmpty ?? true) && addressFocused {
                    Button { browser.activeTab?.urlInput = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                } else if !(browser.activeTab?.currentURL.isEmpty ?? true) {
                    // Reload / stop
                    Button {
                        if browser.activeTab?.isLoading == true { browser.activeTab?.stop() }
                        else { browser.activeTab?.reload() }
                    } label: {
                        Image(systemName: browser.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                if let url = browser.activeTab?.currentURL, !url.isEmpty {
                    Button {
                        UIPasteboard.general.string = url
                    } label: { Label("Copy URL", systemImage: "doc.on.doc") }
                    ShareLink(item: URL(string: url) ?? URL(string: "about:blank")!)
                }
            }

            // Bookmark star — only shown once a page is loaded
            if let url = browser.activeTab?.currentURL, !url.isEmpty {
                Button {
                    store.toggleBookmark(url: url, title: browser.activeTab?.title ?? url)
                } label: {
                    Image(systemName: store.isBookmarked(url) ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(store.isBookmarked(url) ? .yellow : Color(red: 0, green: 0.4, blue: 0.15))
                }
            }

            // Tabs
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
    }

    private var progressBar: some View {
        Group {
            if let tab = browser.activeTab, tab.isLoading, tab.estimatedProgress < 1 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color(red: 0, green: 0.4, blue: 0.15))
                        .frame(width: geo.size.width * tab.estimatedProgress, height: 2)
                }
                .frame(height: 2)
            } else {
                Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator))
            }
        }
    }

    private func blockedBanner(_ blocked: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(blocked) is not allowed")
                    .font(.subheadline).fontWeight(.medium)
                Text("Ask your admin to add it to the allowed list.")
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
            VStack(alignment: .leading, spacing: 24) {
                if !store.bookmarks.isEmpty {
                    homeSection(title: "Bookmarks", systemImage: "star.fill") {
                        siteGrid(store.bookmarks.map { (url: $0.url, title: $0.title) })
                    }
                }

                if !store.history.isEmpty {
                    homeSection(title: "Recent", systemImage: "clock") {
                        VStack(spacing: 0) {
                            ForEach(store.history.prefix(6)) { entry in
                                historyRow(entry)
                                    .padding(.horizontal).padding(.vertical, 8)
                                if entry.id != store.history.prefix(6).last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                    }
                }

                if !allowedWebsites.isEmpty {
                    homeSection(title: "Allowed Sites", systemImage: "checkmark.shield.fill") {
                        siteGrid(allowedWebsites.map { (url: $0, title: $0) })
                    }
                } else if isWhitelistMode {
                    VStack(spacing: 12) {
                        Image(systemName: "globe.slash").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Allowed Sites").font(.headline)
                        Text("Your admin hasn't added any sites to your allowed list yet.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }

                if store.bookmarks.isEmpty && store.history.isEmpty && allowedWebsites.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "globe").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("Start Browsing").font(.headline)
                        Text("Type a website in the address bar above to get going.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.vertical)
        }
    }

    @ViewBuilder
    private func homeSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                Text(title).font(.headline)
            }
            .padding(.horizontal)
            content()
        }
    }

    private func siteGrid(_ sites: [(url: String, title: String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                            GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(sites.prefix(12), id: \.url) { site in
                Button {
                    blockedDomain = nil
                    browser.activeTab?.navigate(to: site.url)
                } label: {
                    VStack(spacing: 6) {
                        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(site.url)")) {
                            $0.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(displayHost(site.title))
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

    private func historyRow(_ entry: BrowserHistoryEntry) -> some View {
        Button {
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
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func displayHost(_ s: String) -> String {
        if let u = URL(string: s), let h = u.host { return h }
        return s
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

            Button { browser.activeTab?.goHome() } label: {
                Image(systemName: "house")
            }

            Spacer()

            Button { showBookmarks = true } label: {
                Image(systemName: "star")
            }

            Spacer()

            Button { showHistory = true } label: {
                Image(systemName: "clock")
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
                if store.history.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No History").font(.headline)
                        Text("Sites you visit will appear here.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.history) { entry in
                            Button {
                                showHistory = false
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
                        .onDelete(perform: store.removeHistory)
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showHistory = false } }
                ToolbarItem(placement: .destructiveAction) {
                    if !store.history.isEmpty {
                        Button("Clear", role: .destructive) { store.clearHistory() }
                    }
                }
            }
        }
    }

    // MARK: - Bookmarks Sheet

    private var bookmarksSheet: some View {
        NavigationStack {
            Group {
                if store.bookmarks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "star").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Bookmarks").font(.headline)
                        Text("Tap the star in the address bar to save a page.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else {
                    List {
                        ForEach(store.bookmarks) { mark in
                            Button {
                                showBookmarks = false
                                blockedDomain = nil
                                browser.activeTab?.navigate(to: mark.url)
                            } label: {
                                HStack(spacing: 10) {
                                    AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(mark.url)")) {
                                        $0.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    }
                                    .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mark.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                                        Text(mark.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .onDelete(perform: store.removeBookmarks)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showBookmarks = false } }
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
                        HStack(spacing: 10) {
                            AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(tab.currentURL)")) {
                                $0.resizable().scaledToFit()
                            } placeholder: {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                            }
                            .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? "New Tab" : tab.title)
                                    .font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                Text(tab.currentURL.isEmpty ? "No page loaded" : tab.currentURL)
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
    let isWhitelistMode: Bool
    @Binding var blockedDomain: String?
    let onNavigate: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        tab.webView.navigationDelegate = context.coordinator
        tab.webView.uiDelegate = context.coordinator
        return tab.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: TabWebView

        init(_ parent: TabWebView) { self.parent = parent }

        // Enforce the whitelist inside the browser regardless of system filters.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }

            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }

            guard parent.isWhitelistMode, let host = url.host?.lowercased() else {
                decisionHandler(.allow); return
            }

            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let allowed = parent.allowedWebsites.contains { d in
                let domain = d.lowercased()
                return bare == domain || bare.hasSuffix(".\(domain)")
            }

            if allowed {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.parent.blockedDomain = bare }
            }
        }

        // Window.open / target="_blank" — route into the current tab
        func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            Task { @MainActor in parent.tab.isLoading = true }
        }

        func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
            Task { @MainActor in
                if let url = webView.url {
                    parent.tab.isSecure = url.scheme == "https"
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                parent.tab.isLoading = false
                parent.tab.canGoBack = webView.canGoBack
                parent.tab.canGoForward = webView.canGoForward
                if let url = webView.url, url.absoluteString != "about:blank" {
                    let full = url.absoluteString
                    parent.tab.currentURL = full
                    parent.tab.urlInput = full
                    parent.tab.title = webView.title?.isEmpty == false ? webView.title! : (url.host ?? full)
                    parent.tab.isSecure = url.scheme == "https"
                    parent.onNavigate(full, parent.tab.title)
                } else {
                    parent.tab.currentURL = ""
                    parent.tab.urlInput = ""
                    parent.tab.title = "New Tab"
                    parent.tab.isSecure = false
                }
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            Task { @MainActor in parent.tab.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
            Task { @MainActor in parent.tab.isLoading = false }
        }
    }
}
