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
        let doc = wrappedHTML(prepareArtifactHTMLForDisplay(html))
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
            <script>
            window.MathJax = {
              tex: {
                inlineMath: [['\\\\(', '\\\\)']],
                displayMath: [['\\\\[', '\\\\]']]
              },
              svg: { fontCache: 'global' }
            };
            </script>
            <script type="text/javascript" id="MathJax-script" async
              src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js">
            </script>
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

private func prepareArtifactHTMLForDisplay(_ html: String) -> String {
    hydrateLocalArtifactImages(in: html)
}

private func hydrateLocalArtifactImages(in html: String) -> String {
    let pattern = #"(?is)<img\b[^>]*\bsrc\s*=\s*(['"])(.*?)\1[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }

    var cleaned = html
    let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
    let matches = regex.matches(in: cleaned, range: nsRange).reversed()

    for match in matches {
        guard let fullRange = Range(match.range(at: 0), in: cleaned),
              let srcRange = Range(match.range(at: 2), in: cleaned) else { continue }

        let rawSource = String(cleaned[srcRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dataURI = dataURIForLocalArtifactImageSource(rawSource) else { continue }

        let original = String(cleaned[fullRange])
        let replaced = original.replacingOccurrences(
            of: #"(?is)\bsrc\s*=\s*(['"])(.*?)\1"#,
            with: #"src="\#(dataURI)""#,
            options: .regularExpression
        )
        cleaned.replaceSubrange(fullRange, with: replaced)
    }

    cleaned = cleaned.replacingOccurrences(
        of: #"(?is)<img\b(?:(?!>).)*\bsrc\s*=\s*(['"])(https?://.*?)\1[^>]*>"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
    )
    return cleaned
}

private func dataURIForLocalArtifactImageSource(_ rawSource: String) -> String? {
    let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return nil }
    guard !source.lowercased().hasPrefix("data:image/") else { return nil }
    guard !source.lowercased().hasPrefix("http://"), !source.lowercased().hasPrefix("https://") else { return nil }

    let filename: String
    if source.lowercased().hasPrefix("attachment://") {
        filename = String(source.dropFirst("attachment://".count))
    } else if source.hasPrefix("file://"), let url = URL(string: source) {
        filename = url.lastPathComponent
    } else {
        filename = (source as NSString).lastPathComponent
    }

    guard !filename.isEmpty else { return nil }

    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let fileURL = documents
        .appendingPathComponent("image-attachments", isDirectory: true)
        .appendingPathComponent(filename)

    guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
    return "data:image/jpeg;base64,\(data.base64EncodedString())"
}
