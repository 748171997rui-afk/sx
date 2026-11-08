import SwiftUI
import WebKit

@main
struct SalesBoardApp: App {
    var body: some Scene {
        WindowGroup { BoardView() }
    }
}

struct BoardView: View {
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            BoardWebView(reloadToken: reloadToken)
        }
        .ignoresSafeArea()
    }
}

/// JS 消息桥协调器：页面 postMessage({id,p,m,b}) → performFetch → __sxboardReply 回调
final class NativeFetchCoordinator: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "nativeFetch", let wv = message.webView else { return }
        BridgeHandler.handleMessageBody(message.body, replyTo: wv)
    }
}

struct BoardWebView: UIViewRepresentable {
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 备用通道：sxboard:// 协议（验证码 <img> 用 direct；fetch 兜底）
        cfg.setURLSchemeHandler(BridgeHandler(), forURLScheme: "sxboard")
        // 主通道：postMessage 桥（WKWebView 里 fetch/XHR 无法访问自定义协议，必须走这个）
        cfg.userContentController.add(NativeFetchCoordinator(), name: "nativeFetch")
        // 标记「跑在 App 里」：index.html 的 IS_IOS_APP 检测依赖这个注入
        let marker = WKUserScript(
            source: "window.__SXBOARD_APP__=true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        cfg.userContentController.addUserScript(marker)

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.scrollView.isScrollEnabled = true
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            let root = url.deletingLastPathComponent()
            wv.loadFileURL(url, allowingReadAccessTo: root)
        } else {
            wv.loadHTMLString("<h3 style='font-family:-apple-system'>打包缺少 index.html：请把 sixun-report/index.html 拷到 ios-app/Resources/ 后重新编译。</h3>", baseURL: nil)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // token 变化时整页刷新（暂未用到，预留）
    }
}
