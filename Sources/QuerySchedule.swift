import Foundation

func retryAfterDate(_ value: String?, now: Date) -> Date? {
    guard let value else { return nil }
    if let seconds = Double(value), seconds >= 0 { return now.addingTimeInterval(seconds) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
}

// One request covers all target stores. The same gate applies to timers, wake,
// manual checks, and process restarts. Cooldown is policy, not an Apple SLA.
struct QuerySchedule: Codable {
    static let normalInterval: TimeInterval = 150
    static let blockedCooldown: TimeInterval = 15 * 60
    static let budgetWindow: TimeInterval = 60 * 60
    static let requestLimit = 24
    var nextAllowedAt: Date = .distantPast
    var blockedUntil: Date?
    var consecutiveFailures = 0
    var schemaVersion = 2
    private(set) var requestTimes: [Date] = []

    enum CodingKeys: String, CodingKey { case nextAllowedAt, blockedUntil, consecutiveFailures, schemaVersion, requestTimes }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextAllowedAt = try c.decode(Date.self, forKey: .nextAllowedAt)
        blockedUntil = try c.decodeIfPresent(Date.self, forKey: .blockedUntil)
        consecutiveFailures = try c.decode(Int.self, forKey: .consecutiveFailures)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        requestTimes = try c.decodeIfPresent([Date].self, forKey: .requestTimes) ?? []
    }
    func requestsInWindow(at date: Date) -> [Date] {
        requestTimes.filter { $0 > date.addingTimeInterval(-Self.budgetWindow) }.sorted()
    }
    func budgetReadyAt(at date: Date) -> Date? {
        let times = requestsInWindow(at: date)
        guard times.count >= Self.requestLimit else { return nil }
        return times[times.count - Self.requestLimit].addingTimeInterval(Self.budgetWindow + 1)
    }
    func nextRequestDate(at date: Date) -> Date {
        max(nextAllowedAt, budgetReadyAt(at: date) ?? .distantPast)
    }
    func canRequest(at date: Date) -> Bool { date >= nextRequestDate(at: date) }
    func isCooling(at date: Date) -> Bool { (blockedUntil ?? .distantPast) > date }
    func isBudgetWaiting(at date: Date) -> Bool { (budgetReadyAt(at: date) ?? .distantPast) > date }
    mutating func importCompletedRequests(_ dates: [Date], at date: Date) {
        // Legacy logs record completions, which are later than starts. Counting
        // them conservatively avoids granting fresh quota during this upgrade.
        requestTimes = dates.filter { $0 > date.addingTimeInterval(-Self.budgetWindow) }.sorted()
        schemaVersion = 2
        nextAllowedAt = nextRequestDate(at: date)
    }
    mutating func started(at date: Date) {
        requestTimes = requestsInWindow(at: date); requestTimes.append(date)
        nextAllowedAt = max(nextAllowedAt, date.addingTimeInterval(Self.normalInterval))
        nextAllowedAt = nextRequestDate(at: date)
    }
    mutating func succeeded(at date: Date) {
        consecutiveFailures = 0; blockedUntil = nil
        nextAllowedAt = date.addingTimeInterval(Self.normalInterval)
        nextAllowedAt = nextRequestDate(at: date)
    }
    mutating func failed(_ error: Error, at date: Date) {
        consecutiveFailures += 1
        let failure = error as? StockError
        if [403, 429, 541].contains(failure?.statusCode ?? 0) {
            let until = max(date.addingTimeInterval(Self.blockedCooldown), failure?.retryNotBefore ?? date)
            blockedUntil = until; nextAllowedAt = until
        } else {
            blockedUntil = nil
            let seconds = max(Self.normalInterval, min(300, 60 * pow(2, Double(min(consecutiveFailures - 1, 3)))))
            nextAllowedAt = max(date.addingTimeInterval(seconds), failure?.retryNotBefore ?? date)
        }
        nextAllowedAt = nextRequestDate(at: date)
    }
    static func load(from url: URL) throws -> QuerySchedule {
        guard FileManager.default.fileExists(atPath: url.path) else { return QuerySchedule() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QuerySchedule.self, from: Data(contentsOf: url))
    }
    func persist(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

func stockRowText(_ row: StockRow?, name: String, currentUnknown: Bool) -> String {
    guard !currentUnknown, let row else { return "?  Apple \(name)    未知" }
    let status = row.available ? "可自提" : (row.availability == .ineligible ? "不可自提" : "无货")
    return "\(row.available ? "●" : "○")  Apple \(name)    \(status)"
}

func runScheduleSelfTests() throws {
    func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw StockError(message: "测试失败：\(name)") }; print("PASS \(name)")
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var policy = QuerySchedule(); policy.started(at: now)
    try check(!policy.canRequest(at: now.addingTimeInterval(149)), "手动检查不能突破 150 秒最短请求间隔")
    policy.failed(StockError(message: "blocked", statusCode: 541), at: now)
    try check(policy.isCooling(at: now.addingTimeInterval(899)) && !policy.canRequest(at: now.addingTimeInterval(899)), "HTTP 541 主动冷却 15 分钟")
    try check(policy.canRequest(at: now.addingTimeInterval(900)), "冷却到期才允许再次请求")
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(QuerySchedule.self, from: encoder.encode(policy))
    try check(!restored.canRequest(at: now.addingTimeInterval(100)), "重启后仍遵守持久化冷却")
    policy.failed(StockError(message: "rate limited", statusCode: 429, retryNotBefore: now.addingTimeInterval(3600)), at: now)
    try check(policy.nextAllowedAt == now.addingTimeInterval(3600), "尊重更长的 Retry-After")
    policy.succeeded(at: now.addingTimeInterval(3600))
    try check(policy.blockedUntil == nil && policy.consecutiveFailures == 0 && policy.nextAllowedAt == now.addingTimeInterval(3750), "成功后恢复约 150 秒轮询")
    var budget = QuerySchedule()
    let burst = (0..<24).map { now.addingTimeInterval(Double($0)) }
    budget.importCompletedRequests(burst, at: now.addingTimeInterval(24))
    try check(!budget.canRequest(at: now.addingTimeInterval(3599)), "24 次预算用完后必须等待最早请求离开一小时窗口")
    let encodedBudget = try encoder.encode(budget)
    let reloadedBudget = try decoder.decode(QuerySchedule.self, from: encodedBudget)
    try check(!reloadedBudget.canRequest(at: now.addingTimeInterval(1000)), "重启不会刷新小时请求预算")
    budget.failed(StockError(message: "network failure"), at: now.addingTimeInterval(25))
    try check(budget.requestsInWindow(at: now.addingTimeInterval(26)).count == 24, "失败不会清空已用请求预算")
    let legacyObject: [String: Any] = ["nextAllowedAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(900)), "blockedUntil": ISO8601DateFormatter().string(from: now.addingTimeInterval(900)), "consecutiveFailures": 2]
    var migrated = try decoder.decode(QuerySchedule.self, from: JSONSerialization.data(withJSONObject: legacyObject))
    try check(migrated.schemaVersion == 1 && migrated.isCooling(at: now), "升级读取旧调度时保留已有冷却")
    migrated.importCompletedRequests(burst, at: now.addingTimeInterval(24))
    try check(migrated.schemaVersion == 2 && !migrated.canRequest(at: now.addingTimeInterval(1000)), "升级后导入旧请求记录，不清空额度")
    // A full-day scheduler replay proves the client-side request bound, not
    // Apple's undisclosed limit or future availability of the live service.
    var replay = QuerySchedule(); var starts: [Date] = []; var cursor = now
    while cursor < now.addingTimeInterval(24 * 3600) {
        cursor = max(cursor, replay.nextRequestDate(at: cursor))
        guard replay.canRequest(at: cursor) else { throw StockError(message: "预算调度未达到允许时间") }
        replay.started(at: cursor); starts.append(cursor); replay.succeeded(at: cursor)
        let recent = starts.filter { $0 > cursor.addingTimeInterval(-3600) }
        guard recent.count <= 24 else { throw StockError(message: "滚动一小时超过 24 次") }
        cursor = cursor.addingTimeInterval(1)
    }
    print("PASS 完整一天的调度回放满足小时预算（不代表真实服务已稳定一天）")
    let row = StockRow(id: "TEST", name: "Broadway", availability: .unavailable, quote: "")
    try check(stockRowText(row, name: row.name, currentUnknown: true).hasSuffix("未知"), "查询故障不再显示旧的无货状态")
    try check(stockRowText(row, name: row.name, currentUnknown: false).hasSuffix("无货"), "仅有效成功结果显示无货")
    try check(retryAfterDate("120", now: now) == now.addingTimeInterval(120), "解析 Retry-After 秒数")
    try check(retryAfterDate("Tue, 27 Oct 2026 13:15:00 GMT", now: now) != nil, "解析 Retry-After HTTP 日期")
}
