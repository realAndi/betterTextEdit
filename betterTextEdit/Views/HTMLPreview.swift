import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A live preview of the HTML being edited.
///
/// The obvious approach — `loadHTMLString(_:baseURL:)` pointed at the file's
/// folder — doesn't work: WebKit treats a string load as an opaque origin, so
/// the page's stylesheets, scripts, and images never load. Loading the file off
/// disk instead would only ever show the *saved* version.
///
/// So the document is served through a custom scheme by ``PreviewSchemeHandler``:
/// the page itself comes from the editor's live text, and relative resources are
/// read from the real folder next to it. Edits appear as they're typed, `<link>`
/// and `<img>` resolve, and the handler refuses to serve anything outside the
/// document's own directory.
struct HTMLPreview: NSViewRepresentable {
    let html: String
    let directory: URL?
    let documentName: String
    let allowsJavaScript: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let handler = context.coordinator.handler
        handler.html = html
        handler.directory = directory
        handler.documentName = documentName

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        // A page renders against its own background, so give it paper to sit on
        // rather than letting the window's material show through.
        webView.underPageBackgroundColor = .white

        context.coordinator.webView = webView
        context.coordinator.load()
        return webView
    }

    func updateNSView(_: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let handler = coordinator.handler

        handler.directory = directory
        handler.documentName = documentName
        coordinator.webView?.configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript

        guard handler.html != html else { return }
        handler.html = html
        // Reloading on every keystroke would flicker; settle first.
        coordinator.scheduleReload()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelReload()
        webView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = PreviewSchemeHandler()
        weak var webView: WKWebView?

        private var reload: DispatchWorkItem?
        private var restoreScrollTo: Double = 0

        func scheduleReload() {
            reload?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reloadPreservingScroll() }
            reload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        func cancelReload() {
            reload?.cancel()
            reload = nil
        }

        func load() {
            guard let webView, let url = handler.documentURL else { return }
            webView.load(URLRequest(url: url))
        }

        /// Re-rendering from the top on every edit would make the preview
        /// useless for anything below the fold, so the scroll offset is carried
        /// across the reload.
        private func reloadPreservingScroll() {
            guard let webView else { return }
            webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                self?.restoreScrollTo = value as? Double ?? 0
                self?.load()
            }
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            guard restoreScrollTo > 0 else { return }
            webView.evaluateJavaScript("window.scrollTo(0, \(restoreScrollTo))")
            restoreScrollTo = 0
        }

        /// Clicking a link to the wider internet hands off to the browser rather
        /// than steering the preview somewhere the editor can't follow.
        func webView(
            _: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated,
                  let url = action.request.url,
                  url.scheme != PreviewSchemeHandler.scheme
            else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - Serving the document

/// Serves the in-progress document and the files sitting beside it.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "swiftpad-preview"

    var html = ""
    var documentName = "index.html"
    var directory: URL?

    var documentURL: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "document"
        components.path = "/" + (documentName.isEmpty ? "index.html" : documentName)
        return components.url
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let path = url.path
        let isDocument = path.isEmpty
            || path == "/"
            || path == "/" + documentName
            || path == "/index.html"

        let data: Data
        let mimeType: String

        if isDocument {
            data = Data(html.utf8)
            mimeType = "text/html"
        } else if let resource = resourceURL(for: path), let contents = try? Data(contentsOf: resource) {
            data = contents
            mimeType = UTType(filenameExtension: resource.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

    /// Resolves a request against the document's folder, and only that folder —
    /// a preview has no business reading its way up the filesystem.
    private func resourceURL(for path: String) -> URL? {
        guard let directory else { return nil }
        let root = directory.standardizedFileURL

        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty else { return nil }

        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }
}
