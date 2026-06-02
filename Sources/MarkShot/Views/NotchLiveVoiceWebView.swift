import SwiftUI
import WebKit

struct NotchLiveVoiceWebView: NSViewRepresentable {
    @ObservedObject var controller: NotchLiveVoiceController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "deskAgentLive")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if let url = URL(string: "http://127.0.0.1:4177/live-shell.html") {
            webView.load(URLRequest(url: url))
        }
        controller.attach(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller.attach(webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "deskAgentLive")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let controller: NotchLiveVoiceController

        init(controller: NotchLiveVoiceController) {
            self.controller = controller
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            Task { @MainActor in
                self.controller.handleBridgeMessage(message.body)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.controller.attach(webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                self.controller.markBridgeUnavailable("Live voice bridge failed to load: \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                self.controller.markBridgeUnavailable("Live voice helper is not reachable at 127.0.0.1:4177.")
            }
        }

        @available(macOS 12.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let isLocalLiveBridge = origin.host == "127.0.0.1" && origin.port == 4177
            if isLocalLiveBridge, type == .microphone || type == .cameraAndMicrophone {
                MarkShotLog.write("live webview media permission granted host=\(origin.host) port=\(origin.port) type=\(type.rawValue)")
                decisionHandler(.grant)
            } else {
                MarkShotLog.write("live webview media permission denied host=\(origin.host) port=\(origin.port) type=\(type.rawValue)")
                decisionHandler(.deny)
            }
        }
    }
}
