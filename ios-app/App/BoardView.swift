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

struct BoardWebView: UIViewRepresentable {
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 页面通过 sxboard:// 协议与原生层通信（见 BridgeHandler）
        cfg.setURLSchemeHandler(BridgeHandler(), forURLScheme: "sxboard")
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
