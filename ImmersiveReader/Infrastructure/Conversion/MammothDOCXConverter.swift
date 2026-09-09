import Foundation
import WebKit

@MainActor
final class MammothDOCXConverter: DOCXConverting {
    /// Identifies the conversion output format for on-disk caches. Bump it whenever
    /// Mammoth, the sanitizer or the block mapping would produce different blocks.
    nonisolated static let conversionVersion = 1

    static let defaultMaximumFileSize = DocumentFileLimits.docxMaximumBytes
    static let defaultMaximumConvertedHTMLSize = 8 * 1_024 * 1_024

    private let resourceBundle: Bundle
    private let maximumFileSize: Int64
    private let maximumConvertedHTMLSize: Int

    init(
        resourceBundle: Bundle = .main,
        maximumFileSize: Int64 = MammothDOCXConverter.defaultMaximumFileSize,
        maximumConvertedHTMLSize: Int = MammothDOCXConverter.defaultMaximumConvertedHTMLSize
    ) {
        self.resourceBundle = resourceBundle
        self.maximumFileSize = max(1, maximumFileSize)
        self.maximumConvertedHTMLSize = max(1, maximumConvertedHTMLSize)
    }

    func convert(document: ReaderDocument) async throws -> DOCXConversionResult {
        guard document.format == .docx else {
            throw DOCXConversionError.unsupportedFormat(document.format)
        }

        let fileURL = document.fileURL
        let maximumFileSize = self.maximumFileSize
        let base64Document = try await Task.detached(priority: .userInitiated) {
            try DOCXFileReader.base64Document(
                at: fileURL,
                maximumBytes: maximumFileSize
            )
        }.value
        try Task.checkCancellation()

        let script = try MammothScriptResource.load(from: resourceBundle)
        let runtimeResponse = try await convertWithMammoth(
            base64Document: base64Document,
            script: script
        )
        try Task.checkCancellation()

        if runtimeResponse.error == "outputTooLarge" {
            throw DOCXConversionError.convertedContentTooLarge(
                maximumBytes: maximumConvertedHTMLSize
            )
        }

        let sanitized: DOCXHTMLSanitizer.Output
        let maximumConvertedHTMLSize = self.maximumConvertedHTMLSize
        do {
            sanitized = try await Task.detached(priority: .userInitiated) {
                try DOCXHTMLSanitizer.sanitize(
                    runtimeResponse.html,
                    maximumUTF8Bytes: maximumConvertedHTMLSize
                )
            }.value
        } catch let error as DOCXConversionError {
            throw error
        } catch {
            throw DOCXConversionError.sanitizationFailed
        }

        guard !sanitized.blocks.isEmpty else {
            throw DOCXConversionError.emptyDocument
        }

        return DOCXConversionResult(
            sanitizedHTML: sanitized.html,
            plainText: sanitized.plainText,
            readerContent: ReaderTextContent(format: .docx, blocks: sanitized.blocks),
            warnings: runtimeResponse.messages
        )
    }

    private func convertWithMammoth(
        base64Document: String,
        script: String
    ) async throws -> MammothRuntimeResponse {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigationDelegate = OfflineMammothNavigationDelegate()
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        do {
            try await navigationDelegate.loadRuntimePage(
                Self.runtimeHTML,
                in: webView
            )
            _ = try await webView.evaluateJavaScript(Self.disableNetworkJavaScript)
            _ = try await webView.evaluateJavaScript(script)
            let isMammothReady = try await webView.evaluateJavaScript(
                "typeof window.mammoth === 'object' && typeof window.mammoth.convertToHtml === 'function'"
            )
            guard (isMammothReady as? Bool) == true else {
                throw DOCXConversionError.mammothRuntimeUnavailable
            }

            let value = try await webView.callAsyncJavaScript(
                Self.convertJavaScript,
                arguments: [
                    "docxBase64": base64Document,
                    "maximumCharacterCount": maximumConvertedHTMLSize,
                ],
                in: nil,
                contentWorld: .page
            )
            guard let json = value as? String,
                  let data = json.data(using: .utf8) else {
                throw DOCXConversionError.malformedConversionResponse
            }
            do {
                return try JSONDecoder().decode(MammothRuntimeResponse.self, from: data)
            } catch {
                throw DOCXConversionError.malformedConversionResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DOCXConversionError {
            throw error
        } catch {
            throw DOCXConversionError.conversionFailed
        }
    }

    private static let runtimeHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; connect-src 'none'; img-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; style-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'">
      </head>
      <body></body>
    </html>
    """

    private static let disableNetworkJavaScript = """
    (() => {
      const blocked = () => Promise.reject(new Error("Network access is disabled"));
      globalThis.fetch = blocked;
      globalThis.XMLHttpRequest = class {
        constructor() { throw new Error("Network access is disabled"); }
      };
      globalThis.WebSocket = class {
        constructor() { throw new Error("Network access is disabled"); }
      };
      globalThis.EventSource = class {
        constructor() { throw new Error("Network access is disabled"); }
      };
      globalThis.open = () => null;
    })();
    """

    private static let convertJavaScript = """
    const binary = atob(docxBase64);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }

    const imageConverter = mammoth.images.imgElement(() => Promise.resolve({}));
    const result = await mammoth.convertToHtml(
      { arrayBuffer: bytes.buffer },
      {
        includeDefaultStyleMap: true,
        includeEmbeddedStyleMap: false,
        convertImage: imageConverter
      }
    );

    if (result.value.length > maximumCharacterCount) {
      return JSON.stringify({ html: "", messages: [], error: "outputTooLarge" });
    }

    const messages = (result.messages || []).slice(0, 100).map((item) => {
      const message = item && item.message ? item.message : String(item);
      return String(message).slice(0, 500);
    });
    return JSON.stringify({ html: result.value, messages });
    """
}

private enum DOCXFileReader {
    static func base64Document(at url: URL, maximumBytes: Int64) throws -> String {
        let isAccessingSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw DOCXConversionError.fileUnavailable
        }

        guard values.isSymbolicLink != true else {
            throw DOCXConversionError.symbolicLinkNotSupported
        }
        guard values.isRegularFile == true else {
            throw DOCXConversionError.notARegularFile
        }

        let reportedSize = Int64(values.fileSize ?? 0)
        guard reportedSize > 0 else {
            throw DOCXConversionError.emptyDocument
        }
        guard reportedSize <= maximumBytes else {
            throw DOCXConversionError.fileTooLarge(maximumBytes: maximumBytes)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DOCXConversionError.fileUnavailable
        }
        guard !data.isEmpty else {
            throw DOCXConversionError.emptyDocument
        }
        guard Int64(data.count) <= maximumBytes else {
            throw DOCXConversionError.fileTooLarge(maximumBytes: maximumBytes)
        }
        return data.base64EncodedString()
    }
}

private enum MammothScriptResource {
    static func load(from bundle: Bundle) throws -> String {
        let locations = [
            bundle.url(forResource: "mammoth.browser.min", withExtension: "js"),
            bundle.url(
                forResource: "mammoth.browser.min",
                withExtension: "js",
                subdirectory: "Mammoth"
            ),
            bundle.url(
                forResource: "mammoth.browser.min",
                withExtension: "js",
                subdirectory: "Vendor/Mammoth"
            ),
            bundle.url(
                forResource: "mammoth.browser.min",
                withExtension: "js",
                subdirectory: "Resources/Vendor/Mammoth"
            ),
        ]

        guard let url = locations.compactMap({ $0 }).first else {
            throw DOCXConversionError.mammothResourceMissing
        }

        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            guard !script.isEmpty else {
                throw DOCXConversionError.mammothResourceUnreadable
            }
            return script
        } catch let error as DOCXConversionError {
            throw error
        } catch {
            throw DOCXConversionError.mammothResourceUnreadable
        }
    }
}

private struct MammothRuntimeResponse: Decodable {
    let html: String
    let messages: [String]
    let error: String?
}

@MainActor
private final class OfflineMammothNavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private weak var loadingWebView: WKWebView?

    func loadRuntimePage(_ html: String, in webView: WKWebView) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                loadingWebView = webView
                webView.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingLoad()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        finish(with: .success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(with: .failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        finish(with: .failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(with: .failure(DOCXConversionError.mammothRuntimeUnavailable))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(scheme == "about" ? .allow : .cancel)
    }

    private func finish(with result: Result<Void, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        loadingWebView = nil
        continuation.resume(with: result)
    }

    private func cancelPendingLoad() {
        loadingWebView?.stopLoading()
        finish(with: .failure(CancellationError()))
    }
}
