import SwiftUI
import WebKit

// MARK: - Safe Browser Tab

struct SafeBrowserView: View {
    @EnvironmentObject var settingsManager: ActiveScreenTimeSettingsManager

    @State private var urlInput: String = ""
    @State private var currentURL: URL? = nil
    @State private var isLoading = false
    @State private var blockedDomain: String? = nil
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var webViewRef: WKWebView? = nil

    private var allowedWebsites: [String] {
        settingsManager.configuration.allowedWebsites
    }
    private var isWhitelistMode: Bool {
        settingsManager.configuration.websiteFilterMode == .whitelist
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Address bar
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "lock.fill")
                            .font(.caption)
                            .foregroundStyle(isLoading ? .orange : .green)
                        TextField("Search or enter website", text: $urlInput)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onSubmit { navigate() }
                        if !urlInput.isEmpty {
                            Button { urlInput = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    Button { navigate() } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0, green: 0.4, blue: 0.15))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator)), alignment: .bottom)

                // Blocked notice
                if let blocked = blockedDomain {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(blocked) is not allowed")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Ask your admin to add it to the allowed list.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { blockedDomain = nil } label: {
                            Image(systemName: "xmark").foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                }

                // Web view or home screen
                if let url = currentURL {
                    BSAFEWebView(
                        url: url,
                        allowedWebsites: allowedWebsites,
                        isWhitelistMode: isWhitelistMode,
                        isLoading: $isLoading,
                        currentURL: $currentURL,
                        urlInput: $urlInput,
                        blockedDomain: $blockedDomain,
                        canGoBack: $canGoBack,
                        canGoForward: $canGoForward,
                        webViewRef: $webViewRef
                    )
                } else {
                    allowedSitesList
                }
            }
            .navigationTitle("B-SAFE Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { webViewRef?.goBack() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!canGoBack)

                    Spacer()

                    Button { webViewRef?.goForward() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!canGoForward)

                    Spacer()

                    Button { webViewRef?.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(currentURL == nil)

                    Spacer()

                    Button { currentURL = nil; urlInput = "" } label: {
                        Image(systemName: "house")
                    }
                }
            }
        }
    }

    // Home screen: grid of allowed sites
    private var allowedSitesList: some View {
        ScrollView {
            if allowedWebsites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "globe.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No allowed sites yet")
                        .font(.headline)
                    Text("Your admin hasn't added any sites to your allowed list.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allowed Sites")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.top, 16)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(allowedWebsites, id: \.self) { domain in
                            Button {
                                urlInput = domain
                                navigate()
                            } label: {
                                VStack(spacing: 8) {
                                    AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(domain)")) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: {
                                        Image(systemName: "globe")
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(domain)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func navigate() {
        var raw = urlInput.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // Add https if no scheme
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            // If it looks like a domain, navigate directly; otherwise Google it
            if raw.contains(".") && !raw.contains(" ") {
                raw = "https://\(raw)"
            } else {
                raw = "https://www.google.com/search?q=\(raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)"
            }
        }
        guard let url = URL(string: raw) else { return }
        blockedDomain = nil
        currentURL = url
    }
}

// MARK: - WKWebView wrapper

struct BSAFEWebView: UIViewRepresentable {
    let url: URL
    let allowedWebsites: [String]
    let isWhitelistMode: Bool
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?
    @Binding var urlInput: String
    @Binding var blockedDomain: String?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var webViewRef: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        DispatchQueue.main.async { webViewRef = webView }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL changed externally (new navigation from address bar)
        if webView.url != url && currentURL == url {
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BSAFEWebView

        init(_ parent: BSAFEWebView) { self.parent = parent }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard parent.isWhitelistMode,
                  let host = action.request.url?.host?.lowercased() else {
                decisionHandler(.allow)
                return
            }

            // Strip www. for comparison
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            let allowed = parent.allowedWebsites.contains { domain in
                let d = domain.lowercased()
                return bare == d || bare.hasSuffix(".\(d)")
            }

            if allowed {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                DispatchQueue.main.async {
                    self.parent.blockedDomain = bare
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            parent.isLoading = false
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            if let url = webView.url {
                parent.currentURL = url
                parent.urlInput = url.host ?? url.absoluteString
            }
        }

        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            parent.isLoading = false
        }
    }
}
