import SwiftUI
import WebKit

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
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.allowsBackForwardNavigationGestures = true
    }

    func navigate(to urlString: String) {
        var raw = urlString.trimmingCharacters(in: .whitespaces)
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
}

@MainActor
class BrowserManager: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?
    @Published var history: [BrowserHistoryEntry] = []

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
        guard tabs.count > 1 else { return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: idx)
            activeTabID = tabs[max(0, min(idx, tabs.count - 1))].id
        }
    }

    func addHistory(url: String, title: String) {
        guard !url.contains("google.com/search") else { return }
        let entry = BrowserHistoryEntry(url: url, title: title.isEmpty ? url : title, date: Date())
        history.insert(entry, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
    }
}

// MARK: - Safe Browser View

struct SafeBrowserView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager
    @StateObject private var browser = BrowserManager()
    @State private var showHistory = false
    @State private var showTabs = false
    @State private var blockedDomain: String? = nil
    @FocusState private var addressFocused: Bool

    private var allowedWebsites: [String] { settingsManager.configuration.allowedWebsites }
    private var isWhitelistMode: Bool { settingsManager.configuration.websiteFilterMode == .whitelist }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Address bar
                addressBar

                // Blocked notice
                if let blocked = blockedDomain {
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

                // Content
                if let tab = browser.activeTab {
                    if tab.webView.url != nil {
                        TabWebView(
                            tab: tab,
                            allowedWebsites: allowedWebsites,
                            isWhitelistMode: isWhitelistMode,
                            blockedDomain: $blockedDomain,
                            onNavigate: { url, title in browser.addHistory(url: url, title: title) }
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
        }
    }

    // MARK: - Address Bar

    private var addressBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: browser.activeTab?.isLoading == true ? "arrow.triangle.2.circlepath" : "lock.fill")
                    .font(.caption).foregroundStyle(browser.activeTab?.isLoading == true ? .orange : .green)
                TextField("Search or enter website", text: Binding(
                    get: { browser.activeTab?.urlInput ?? "" },
                    set: { browser.activeTab?.urlInput = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .focused($addressFocused)
                .onSubmit {
                    guard let tab = browser.activeTab else { return }
                    blockedDomain = nil
                    tab.navigate(to: tab.urlInput)
                }
                if !(browser.activeTab?.urlInput.isEmpty ?? true) {
                    Button { browser.activeTab?.urlInput = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                blockedDomain = nil
                guard let tab = browser.activeTab else { return }
                tab.navigate(to: tab.urlInput)
            } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
            }

            // Tab count button
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

    // MARK: - Home Screen

    private var homeScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !browser.history.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent")
                            .font(.headline).padding(.horizontal)
                        ForEach(browser.history.prefix(5)) { entry in
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
                    }
                }

                if !allowedWebsites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed Sites")
                            .font(.headline).padding(.horizontal)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(allowedWebsites, id: \.self) { domain in
                                Button {
                                    browser.activeTab?.urlInput = domain
                                    blockedDomain = nil
                                    browser.activeTab?.navigate(to: domain)
                                } label: {
                                    VStack(spacing: 6) {
                                        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(domain)")) {
                                            $0.resizable().scaledToFit()
                                        } placeholder: {
                                            Image(systemName: "globe").foregroundStyle(.secondary)
                                        }
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))

                                        Text(domain)
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
                browser.activeTab?.urlInput = ""
                browser.activeTab?.webView.stopLoading()
                // navigate to home by clearing webView URL
                browser.activeTab?.webView.load(URLRequest(url: URL(string: "about:blank")!))
            } label: {
                Image(systemName: "house")
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
                                Text(tab.urlInput.isEmpty ? "No page loaded" : tab.urlInput)
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
        return tab.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: TabWebView

        init(_ parent: TabWebView) { self.parent = parent }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }

            // Allow about:blank (home navigation)
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }

            guard parent.isWhitelistMode,
                  let host = url.host?.lowercased() else {
                decisionHandler(.allow)
                return
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

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            Task { @MainActor in parent.tab.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            Task { @MainActor in
                parent.tab.isLoading = false
                parent.tab.canGoBack = webView.canGoBack
                parent.tab.canGoForward = webView.canGoForward
                if let url = webView.url, url.absoluteString != "about:blank" {
                    let host = url.host ?? url.absoluteString
                    parent.tab.urlInput = host
                    parent.tab.title = webView.title ?? host
                    parent.onNavigate(host, webView.title ?? host)
                } else {
                    parent.tab.urlInput = ""
                    parent.tab.title = "New Tab"
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
