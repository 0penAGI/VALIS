import SwiftUI
import WebKit

struct ArtifactView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webpagePrefs = WKWebpagePreferences()
        webpagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = webpagePrefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let doc = wrappedHTML(html)
        if context.coordinator.lastHTML != doc {
            context.coordinator.lastHTML = doc
            webView.loadHTMLString(doc, baseURL: nil)
        }
    }

    private func wrappedHTML(_ body: String) -> String {
        """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=yes">
            <style>
              html, body {
                margin: 0;
                padding: 0;
                background: transparent;
                color: #111;
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif;
              }
            </style>
          </head>
          <body>
            \(body)
          </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
