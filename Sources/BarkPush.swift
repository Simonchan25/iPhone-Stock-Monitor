import Foundation

// The device key stays in Application Support, never in source, logs, or exports.
struct BarkConfiguration: Codable {
    let deviceKey: String
    var strongAlerts: Bool? = nil
    static func parse(_ text: String) throws -> BarkConfiguration {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bark's Copy button may copy a curl example; extract its URL, never execute it.
        if input.hasPrefix("curl ") {
            let regex = try NSRegularExpression(pattern: #"https://api\.day\.app/[^\s\"'<>]+"#)
            let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
            guard matches.count == 1, let range = Range(matches[0].range, in: input) else { throw StockError(message: "请复制 Bark 的完整推送地址") }
            input = String(input[range])
        }
        guard let url = URLComponents(string: input), url.scheme == "https",
              url.host?.lowercased() == "api.day.app", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let key = url.path.split(separator: "/").first.map(String.init),
              key.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil,
              !["YOUR_KEY", "YOURKEY"].contains(key.uppercased()) else {
            throw StockError(message: "请粘贴 Bark 首页以 https://api.day.app/ 开头的推送地址")
        }
        return BarkConfiguration(deviceKey: key)
    }
    func request(title: String, body: String) throws -> URLRequest {
        // POST /push keeps the key out of URL logs and browser history.
        var request = URLRequest(url: URL(string: "https://api.day.app/push")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["device_key": deviceKey, "title": title, "body": body, "group": "iPhone Duo 库存", "url": productURL.absoluteString, "level": "timeSensitive", "sound": "alarm"]
        if strongAlerts == true {
            payload["level"] = "critical"
            payload["call"] = "1"
            payload["volume"] = "8"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}

class BarkPusher {
    let fileURL: URL
    private var configuration: BarkConfiguration?
    private var generation = UUID()
    var onStatus: ((String) -> Void)?
    private(set) var status = "iPhone 推送：未配置"
    var isConfigured: Bool { configuration != nil }
    var strongAlertsEnabled: Bool { configuration?.strongAlerts == true }
    var configuredAddress: String { configuration.map { "https://api.day.app/\($0.deviceKey)/" } ?? "" }
    init(fileURL: URL) {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                configuration = try JSONDecoder().decode(BarkConfiguration.self, from: Data(contentsOf: fileURL))
                status = configuration?.strongAlerts == true ? "iPhone 推送：已配置 Bark 强提醒" : "iPhone 推送：已配置 Bark"
            } catch { status = "iPhone 推送：配置无法读取，请重新设置" }
        }
    }
    func updateStatus(_ value: String) { status = value; onStatus?(value) }
    func configure(_ address: String, strongAlerts: Bool = false) throws {
        var config = try BarkConfiguration.parse(address)
        config.strongAlerts = strongAlerts
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        configuration = config; generation = UUID()
        updateStatus(strongAlerts ? "iPhone 推送：强提醒已配置，待手机确认声音" : "iPhone 推送：已配置，尚待手机确认测试消息")
    }
    func disable() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        generation = UUID(); configuration = nil
        updateStatus("iPhone 推送：已停用")
    }
    func send(title: String, body: String, isTest: Bool = false) {
        guard let configuration else { return }
        let currentGeneration = generation
        attempt(configuration, title, body, isTest, currentGeneration, attempt: 0)
    }
    private func attempt(_ config: BarkConfiguration, _ title: String, _ body: String, _ isTest: Bool, _ generation: UUID, attempt: Int) {
        guard self.generation == generation else { return }
        updateStatus("iPhone 推送：正在发送…")
        let request: URLRequest
        do { request = try config.request(title: title, body: body) }
        catch { updateStatus("iPhone 推送：消息生成失败"); return }
        URLSession.shared.dataTask(with: request) { data, response, error in
            let http = (response as? HTTPURLResponse)?.statusCode
            var accepted = false
            var apiCode: Int?
            if error == nil, http == 200, let data,
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = result["code"] as? Int { apiCode = code; accepted = code == 200 }
            DispatchQueue.main.async {
                guard self.generation == generation else { return }
                if accepted {
                    let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss"
                    self.updateStatus("iPhone 推送：Bark 已接受\(isTest ? "测试" : "补货")请求 \(clock.string(from: Date()))（非库存状态）")
                } else {
                    // Retry transport/server failures twice; invalid device keys need correction.
                    let retryable = error != nil || http == 429 || (http ?? 0) >= 500
                    if retryable && attempt < 2 {
                        let delay: TimeInterval = attempt == 0 ? 5 : 15
                        self.updateStatus("iPhone 推送：发送失败，\(Int(delay)) 秒后重试")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.attempt(config, title, body, isTest, generation, attempt: attempt + 1)
                        }
                    } else {
                        let reason = http == 200 ? "Bark 未接受消息\(apiCode.map { "（代码 \($0)）" } ?? "")" : (http.map { "HTTP \($0)" } ?? "网络错误")
                        self.updateStatus("iPhone 推送失败：\(reason)，请检查 Bark 设置")
                    }
                }
            }
        }.resume()
    }
}

func runBarkSelfTests() throws {
    let testAddress = "https://api.day.app/TEST_DEVICE_KEY_123/示例内容?group=test"
    let config = try BarkConfiguration.parse(testAddress)
    guard config.deviceKey == "TEST_DEVICE_KEY_123" else { throw StockError(message: "Bark 地址解析失败") }
    let copied = try BarkConfiguration.parse("curl -X GET https://api.day.app/TEST_DEVICE_KEY_123/title/body?group=example")
    guard copied.deviceKey == config.deviceKey else { throw StockError(message: "Bark 复制命令解析失败") }
    let request = try config.request(title: "测试：不是补货", body: "Apple Broadway：检测时可自提")
    let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    guard request.url?.absoluteString == "https://api.day.app/push", request.httpMethod == "POST",
          json["device_key"] as? String == config.deviceKey, json["url"] as? String == productURL.absoluteString,
          json["body"] as? String == "Apple Broadway：检测时可自提", json["level"] as? String == "timeSensitive" else {
        throw StockError(message: "Bark 请求构造失败")
    }
    print("PASS Bark 精确地址解析与中文 POST 消息；密钥不在 URL 中")
    let strong = BarkConfiguration(deviceKey: "TEST_DEVICE_KEY_123", strongAlerts: true)
    let strongRequest = try strong.request(title: "强提醒测试（不是补货）", body: "test")
    let strongJSON = try JSONSerialization.jsonObject(with: strongRequest.httpBody!) as! [String: Any]
    guard strongJSON["level"] as? String == "critical", strongJSON["call"] as? String == "1", strongJSON["volume"] as? String == "8", strongJSON["sound"] as? String == "alarm" else { throw StockError(message: "强提醒参数错误") }
    let legacy = try JSONDecoder().decode(BarkConfiguration.self, from: Data(#"{"deviceKey":"TEST_DEVICE_KEY_123"}"#.utf8))
    guard legacy.strongAlerts != true, json["call"] == nil else { throw StockError(message: "未选择强提醒时不应自动覆盖静音") }
    print("PASS 用户选择强提醒后才发送 critical / call=1 / volume=8；旧配置保持普通提醒")

    for address in ["http://api.day.app/TEST_DEVICE_KEY", "https://example.com/TEST_DEVICE_KEY", "https://api.day.app.evil.example/TEST_DEVICE_KEY", "https://user:pass@api.day.app/TEST_DEVICE_KEY", "https://api.day.app/", "https://api.day.app/YOUR_KEY/title/body"] {
        var rejected = false; do { _ = try BarkConfiguration.parse(address) } catch { rejected = true }
        guard rejected else { throw StockError(message: "Bark 非预期地址未被拒绝") }
    }
    print("PASS 拒绝非 HTTPS、其他服务、带用户名密码和空密钥地址")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bark-config-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let pusher = BarkPusher(fileURL: temporary)
    try pusher.configure(testAddress)
    let permissions = try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? Int
    guard permissions == 0o600, pusher.isConfigured, BarkPusher(fileURL: temporary).isConfigured else { throw StockError(message: "Bark 配置权限或重载失败") }
    try pusher.configure(testAddress, strongAlerts: true)
    guard BarkPusher(fileURL: temporary).strongAlertsEnabled else { throw StockError(message: "强提醒配置重载失败") }
    try pusher.disable()
    guard !pusher.isConfigured, !FileManager.default.fileExists(atPath: temporary.path) else { throw StockError(message: "Bark 停用失败") }
    print("PASS 设备密钥仅保存为本地 0600 文件；可重载和停用删除")
}
