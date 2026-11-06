import Foundation

let productSKU = "MK2F4X/A"
let productURL = URL(string: "https://www.apple.com/au/shop/buy-iphone/iphone-duo/7.6-inch-display-512gb-star-white")!
let targetStores = ["Broadway", "Sydney", "Bondi", "Chatswood Chase", "Miranda", "Castle Towers", "Penrith", "Charlestown", "Canberra"]
let stockURL: URL = {
    var c = URLComponents(string: "https://www.apple.com/au/shop/retail/pickup-message")!
    c.queryItems = [URLQueryItem(name: "pl", value: "true"), URLQueryItem(name: "mts.0", value: "regular"), URLQueryItem(name: "parts.0", value: productSKU), URLQueryItem(name: "location", value: "2007")]
    return c.url!
}()

enum PickupAvailability: String, Codable {
    case available, unavailable, ineligible
}

struct StockRow: Codable {
    let id: String
    let name: String
    let availability: PickupAvailability
    var available: Bool { availability == .available }
    let quote: String
}
struct StockError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var retryNotBefore: Date? = nil
    var errorDescription: String? { message }
}

// Parse the current retail pickup API, including its explicit pickupDisplay state.
// Missing stores, wrong SKUs, unknown states, and old responses are errors.
func parseStock(_ data: Data) throws -> [StockRow] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let head = root["head"] as? [String: Any], String(describing: head["status"] ?? "") == "200",
          let pickup = root["body"] as? [String: Any] else {
        throw StockError(message: "库存响应格式不符，无法判断库存")
    }
    if let error = pickup["errorMessage"] as? String, !error.isEmpty {
        throw StockError(message: "官网库存查询报错：\(error)")
    }
    guard let stores = pickup["stores"] as? [[String: Any]], !stores.isEmpty else {
        throw StockError(message: "官网未返回门店清单")
    }
    var found: [String: StockRow] = [:]
    for store in stores {
        guard let rawName = store["storeName"] as? String else { continue }
        let name = rawName.hasPrefix("Apple ") ? String(rawName.dropFirst(6)) : rawName
        guard targetStores.contains(name) else { continue }
        guard found[name] == nil,
              let id = store["storeNumber"] as? String, !id.isEmpty,
              let parts = store["partsAvailability"] as? [String: Any],
              let item = parts[productSKU] as? [String: Any],
              item["partNumber"] as? String == productSKU,
              let display = item["pickupDisplay"] as? String,
              let availability = PickupAvailability(rawValue: display) else {
            throw StockError(message: "\(name) 的指定型号或可自提标记缺失")
        }
        let quote = (item["pickupSearchQuote"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        found[name] = StockRow(id: id, name: name, availability: availability, quote: quote)
    }
    let missing = targetStores.filter { found[$0] == nil }
    guard missing.isEmpty else { throw StockError(message: "库存响应缺少门店：\(missing.joined(separator: ", "))") }
    return targetStores.compactMap { found[$0] }
}

func fetchStock(completion: @escaping (Result<[StockRow], Error>) -> Void) {
    var request = URLRequest(url: stockURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.setValue(productURL.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error { completion(.failure(error)); return }
        guard let response = response as? HTTPURLResponse else {
            completion(.failure(StockError(message: "没有收到官网 HTTP 响应"))); return
        }
        guard response.statusCode == 200 else {
            completion(.failure(StockError(message: "官网库存接口 HTTP \(response.statusCode)，无法判断是否有货", statusCode: response.statusCode, retryNotBefore: retryAfterDate(response.value(forHTTPHeaderField: "Retry-After"), now: Date())))); return
        }
        if let age = response.value(forHTTPHeaderField: "Age"), let seconds = Double(age), seconds > 60 {
            completion(.failure(StockError(message: "官网响应已缓存 \(Int(seconds)) 秒，库存可能过期"))); return
        }
        do { completion(.success(try parseStock(data ?? Data()))) }
        catch { completion(.failure(error)) }
    }.resume()
}

struct AlertTracker {
    private(set) var available = Set<String>()
    // Only successful observations change state; query failures do not re-arm alerts.
    mutating func observe(_ rows: [StockRow]) -> [StockRow] {
        let now = Set(rows.filter(\.available).map(\.id))
        let added = now.subtracting(available)
        available = now
        return rows.filter { added.contains($0.id) }
    }
}

func runSelfTests() throws {
    func fixture(_ enabled: Set<Int> = [], ineligible: Set<Int> = []) throws -> [String: Any] {
        let stores: [[String: Any]] = targetStores.enumerated().map { i, name in
            let display = enabled.contains(i) ? "available" : (ineligible.contains(i) ? "ineligible" : "unavailable")
            return ["storeNumber": "TEST\(i)", "storeName": name, "partsAvailability": [productSKU: ["partNumber": productSKU, "pickupSearchQuote": enabled.contains(i) ? "Available today" : "Currently unavailable", "pickupDisplay": display]]]
        }
        return ["head": ["status": "200"], "body": ["stores": stores]]
    }
    func parse(_ object: [String: Any]) throws -> [StockRow] { try parseStock(JSONSerialization.data(withJSONObject: object)) }
    func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw StockError(message: "测试失败：\(name)") }; print("PASS \(name)")
    }
    let empty = try parse(fixture())
    let stock = try parse(fixture([0, 8]))
    try check(empty.count == 9 && empty.allSatisfy { !$0.available }, "新接口九店明确无货")
    try check(stock.filter(\.available).map(\.name) == ["Broadway", "Canberra"], "任一目标门店有货")
    let ineligible = try parse(fixture([], ineligible: [0]))
    try check(ineligible[0].availability == .ineligible && !ineligible[0].available, "不可自提不冒充有货")
    var tracker = AlertTracker()
    try check(tracker.observe(stock).count == 2, "启动时已有库存立即提醒")
    try check(tracker.observe(stock).isEmpty, "相同库存不重复提醒")
    // Failed queries do not call observe, preserving notification state.
    try check(tracker.observe(stock).isEmpty, "查询故障不重置提醒状态")
    _ = tracker.observe(empty)
    try check(tracker.observe(stock).count == 2, "售罄后再次补货重新提醒")
    func rejects(_ x: [String: Any], _ name: String) throws {
        var rejected = false; do { _ = try parse(x) } catch { rejected = true }
        try check(rejected, name)
    }
    var x = try fixture(); var b = x["body"] as! [String: Any]; var stores = b["stores"] as! [[String: Any]]
    stores.removeLast(); b["stores"] = stores; x["body"] = b
    try rejects(x, "缺少目标门店必须报错")
    try rejects(["head": ["status": "200"], "body": ["errorMessage": "temporary failure"]], "接口错误不能当成无货")
    for badState in ["unknown", "AVAILABLE", ""] {
        var x = try fixture(); var b = x["body"] as! [String: Any]; var stores = b["stores"] as! [[String: Any]]
        stores[0]["partsAvailability"] = [productSKU: ["partNumber": productSKU, "pickupDisplay": badState]]
        b["stores"] = stores; x["body"] = b
        try rejects(x, "未知库存状态必须报错: \(badState)")
    }
    var wrong = try fixture(); var wb = wrong["body"] as! [String: Any]; var ws = wb["stores"] as! [[String: Any]]
    ws[0]["partsAvailability"] = ["OTHER/A": ["partNumber": "OTHER/A", "pickupDisplay": "available"]]
    wb["stores"] = ws; wrong["body"] = wb
    try rejects(wrong, "其他颜色或容量不能触发提醒")
    let oldBody = (try fixture())["body"] as! [String: Any]
    try rejects(["head": ["status": "200"], "body": ["content": ["pickupMessage": oldBody]]], "旧接口响应不可冒充新接口成功")
    var rejected = false; do { _ = try parseStock(Data("<html>error</html>".utf8)) } catch { rejected = true }
    try check(rejected, "HTML 错误页不能显示为无货")
    print("上述变化测试使用合成库存响应；真实查询另行实测。")
}
