import Foundation
import WebKit

/// 思迅直连传输层：scheme 处理器 + JS 消息桥共用同一套发送逻辑。
///
/// 页面（index.html 的 iOS 直连引擎）会发两类请求：
///   1. WKScriptMessageHandler「nativeFetch」（主通道，可靠）：
///        postMessage({id, p, m, b}) → URLSession 直连思迅 → __sxboardReply(id, json)
///   2. sxboard:// 协议（备用通道）：
///        sxboard://fetch?p=/@raw&m=POST&b=<JSON>    逻辑请求转发
///        sxboard://direct?url=<相对路径>             原样 GET（验证码图片等，img 可用）
final class BridgeHandler: NSObject {

    static let target = URL(string: "http://1.12.232.80:8032")!
    private static let defaultTimeout: TimeInterval = 200   // 库存全量查询最慢 180 秒

    // MARK: - 公共发送逻辑（scheme / message 两个入口都走这里）

    /// payload: { method, url, body, headers, cookie }
    /// 结果:   { status, text, setCookies:[{name,value}] , error? }
    static func performFetch(_ payload: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        let method = (payload["method"] as? String ?? "GET").uppercased()
        let path = payload["url"] as? String ?? "/"
        let body = payload["body"] as? String ?? ""
        let extraHeaders = payload["headers"] as? [String: Any] ?? [:]
        let cookieHeader = payload["cookie"] as? String ?? ""

        guard let target = URL(string: Self.target.absoluteString + path) else {
            done(["status": 502, "text": "", "setCookies": [], "error": "目标地址非法"])
            return
        }

        var request = URLRequest(url: target, timeoutInterval: Self.defaultTimeout)
        request.httpMethod = method
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(Self.target.absoluteString + "/MainPage/MainFrame.aspx", forHTTPHeaderField: "Referer")
        request.setValue(Self.target.absoluteString, forHTTPHeaderField: "Origin")
        for (k, v) in extraHeaders { request.setValue(String(describing: v), forHTTPHeaderField: k) }
        if !cookieHeader.isEmpty { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if method == "POST", let data = body.data(using: .utf8) { request.httpBody = data }

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = Self.defaultTimeout
        let session = URLSession(configuration: config)

        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error = error {
                done(["status": 502, "text": "", "setCookies": [],
                      "error": "请求失败：" + error.localizedDescription])
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            var setCookies: [[String: String]] = []
            if let http = http {
                var fields: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String { fields[ks] = vs }
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: http.url ?? target)
                setCookies = cookies.map { ["name": $0.name, "value": $0.value] }
            }
            done(["status": status, "text": text, "setCookies": setCookies])
        }.resume()
    }

    // MARK: - JS 消息桥（主通道：postMessage → performFetch → evaluateJavaScript 回调）

    static func handleMessageBody(_ body: Any, replyTo webView: WKWebView) {
        guard let dict = body as? [String: Any],
              let id = dict["id"] as? Int else { return }
        let payload: [String: Any] = [
            "method": dict["m"] as? String ?? "GET",
            "url": dict["p"] as? String ?? "/",
            "body": dict["b"] as? String ?? "",
            "headers": [:],
            "cookie": "",
        ]
        performFetch(payload) { result in
            DispatchQueue.main.async {
                guard let data = try? JSONSerialization.data(withJSONObject: result, options: []),
                      let json = String(data: data, encoding: .utf8) else { return }
                // U+2028/U+2029 在 JS 字符串字面量里会报语法错，必须转义
                let safe = json
                    .replacingOccurrences(of: "\\u2028", with: "\\u2028")
                    .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                    .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
                webView.evaluateJavaScript("window.__sxboardReply(\(id), \(safe));", completionHandler: nil)
            }
        }
    }
}

/// sxboard:// 自定义协议处理器（备用通道：direct 给 <img> 用，fetch 兜底）
extension BridgeHandler: WKURLSchemeHandler {

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { finish(urlSchemeTask); return }
        switch url.host ?? "" {
        case "fetch":  handleFetch(urlSchemeTask, url)
        case "direct": handleDirect(urlSchemeTask, url)
        default:       finish(urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // URLSession 回调里若任务已被 WebKit 取消，respond 会抛异常，统一忽略
    }

    // MARK: - 逻辑请求转发（/@raw）

    private func handleFetch(_ task: WKURLSchemeTask, _ url: URL) {
        let qs = url.query ?? ""
        var p = "", m = "GET", b = ""
        for kv in qs.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let val = String(parts[1]).replacingOccurrences(of: "+", with: "%20")
            let dec = val.removingPercentEncoding ?? val
            switch key {
            case "p": p = dec
            case "m": m = dec
            case "b": b = dec
            default: break
            }
        }
        guard p == "/@raw", let payloadData = b.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            respondJSON(task, ["status": 502, "text": "", "setCookies": [],
                               "error": "桥参数无法解析"])
            return
        }
        Self.performFetch(payload) { result in
            DispatchQueue.main.async { self.respondJSON(task, result) }
        }
    }

    // MARK: - 原样 GET（验证码图片）

    private func handleDirect(_ task: WKURLSchemeTask, _ url: URL) {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = nil
        comps?.host = nil
        let qs = comps?.percentEncodedQuery ?? ""
        var rel = ""
        for kv in qs.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, String(parts[0]) == "url" {
                rel = String(parts[1]).replacingOccurrences(of: "+", with: "%20")
                    .removingPercentEncoding ?? String(parts[1])
            }
        }
        guard let target = URL(string: Self.target.absoluteString + rel) else { finish(task); return }
        var request = URLRequest(url: target, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let data = data, error == nil else { self.finish(task); return }
            do {
                let mime = (response as? HTTPURLResponse)?.mimeType ?? "image/png"
                let head = URLResponse(url: task.request.url ?? target,
                                       mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
                try task.didReceive(head)
                try task.didReceive(data)
                try task.didFinish()
            } catch {
                // WebKit 已取消本次加载，忽略
            }
        }.resume()
    }

    // MARK: - 响应

    private func respondJSON(_ task: WKURLSchemeTask, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { finish(task); return }
        let resp = URLResponse(url: task.request.url ?? Self.target,
                               mimeType: "application/json",
                               expectedContentLength: data.count, textEncodingName: "utf-8")
        do {
            try task.didReceive(resp)
            try task.didReceive(data)
            try task.didFinish()
        } catch {
            // 任务已被取消，忽略
        }
    }

    private func finish(_ task: WKURLSchemeTask) {
        do { try task.didFinish() } catch { }
    }
}
