import AppKit
import Foundation
import Darwin

let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iPhoneDuoStockMonitor")
try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
let stateURL = supportDirectory.appendingPathComponent("status.json")
let logURL = supportDirectory.appendingPathComponent("monitor.log")
let scheduleURL = supportDirectory.appendingPathComponent("query-schedule.json")
func log(_ text: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
    let data = Data(line.utf8)
    if !FileManager.default.fileExists(atPath: logURL.path) { try? data.write(to: logURL) }
    else if let handle = try? FileHandle(forWritingTo: logURL) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
    // Keep local logs bounded without discarding the current runtime state.
    if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 2_000_000 {
        let old = supportDirectory.appendingPathComponent("monitor.previous.log")
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.moveItem(at: logURL, to: old)
    }
}

class Monitor: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var item: NSStatusItem!
    var window: NSWindow!
    var statusLabel: NSTextField!
    var detailLabel: NSTextField!
    var storeLabel: NSTextField!
    var pauseButton: NSButton!
    var checkButton: NSButton!
    var schedule = QuerySchedule()
    var pushStatusLabel: NSTextField!
    var pushWindow: NSWindow?
    var pushAddressField: NSSecureTextField?
    var pushSetupStatus: NSTextField?
    var pushStrongCheckbox: NSButton?
    var bark: BarkPusher!
    var alertPanel: NSPanel?
    var alertLabel: NSTextField?
    var timer: Timer?
    var soundTimer: Timer?
    var tracker = AlertTracker()
    var rows: [StockRow] = []
    var lastSuccess: Date?
    var lastAttempt: Date?
    var nextCheck: Date?
    var busy = false
    var paused = false
    var failures = 0
    var errorText: String?
    var activity: NSObjectProtocol?
    var statusText = "正在建立首次库存查询…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Duo ⏳"
        let menu = NSMenu()
        addMenu(menu, "查看监控状态", #selector(showWindow))
        addMenu(menu, "立即检查", #selector(checkNow))
        addMenu(menu, "测试弹窗和提示音", #selector(testAlert))
        addMenu(menu, "iPhone 推送设置", #selector(showPushSettings))
        addMenu(menu, "打开苹果购买页面", #selector(openApple))
        menu.addItem(.separator())
        addMenu(menu, "退出本次监控", #selector(quit))
        item.menu = menu
        bark = BarkPusher(fileURL: supportDirectory.appendingPathComponent("iphone-push.json"))
        bark.onStatus = { [weak self] value in
            self?.pushStatusLabel?.stringValue = value
            self?.pushSetupStatus?.stringValue = value
            log("IPHONE_PUSH \(value)")
            self?.save()
        }
        restoreHistory()
        do {
            schedule = try QuerySchedule.load(from: scheduleURL)
            if schedule.schemaVersion < 2 {
                let iso = ISO8601DateFormatter()
                let priorLog = try String(contentsOf: logURL, encoding: .utf8)
                let completed = priorLog.split(separator: "\n").filter { $0.contains(" SUCCESS ") || $0.contains(" ERROR ") }.compactMap { iso.date(from: String($0.prefix(20))) }
                schedule.importCompletedRequests(completed, at: Date())
                try schedule.persist(to: scheduleURL)
                log("BUDGET_MIGRATION recentRequests=\(schedule.requestTimes.count) limit=\(QuerySchedule.requestLimit)/hour")
            }
            failures = schedule.consecutiveFailures
        }
        catch { paused = true; statusText = "调度状态无法读取，已暂停"; errorText = "请检查本地调度状态文件" }
        createWindow()
        if !CommandLine.arguments.contains("--background") { showWindow() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "持续监控用户指定的 iPhone 门店补货")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showWindow), name: Notification.Name("com.local.iphoneduostock.showWindow"), object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        log("START v1.5.2 endpoint=/shop/retail/pickup-message product=\(productSKU) postcode=\(monitorPostcode) targets=\(targetStores.joined(separator: ","))")
        check()
        if CommandLine.arguments.contains("--test-alert") { testAlert() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func addMenu(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: ""); m.target = self; menu.addItem(m)
    }
    func label(_ text: String, _ size: CGFloat, _ rect: NSRect) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text); l.font = .systemFont(ofSize: size); l.frame = rect; l.isSelectable = true; return l
    }
    func button(_ title: String, _ action: Selector, _ rect: NSRect) -> NSButton {
        let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; b.frame = rect; return b
    }
    func createWindow() {
        let extraStoreHeight = CGFloat(max(0, targetStores.count - 9) * 24)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 610 + extraStoreHeight), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "iPhone Duo 库存监控"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 610 + extraStoreHeight)); window.contentView = v
        v.addSubview(label(productDescription, 23, NSRect(x: 28, y: 555 + extraStoreHeight, width: 600, height: 35)))
        v.addSubview(label("美国 Apple Store｜邮编 \(monitorPostcode)｜附近 \(targetStores.count) 家门店", 13, NSRect(x: 28, y: 526 + extraStoreHeight, width: 600, height: 25)))
        statusLabel = label(statusText, 18, NSRect(x: 28, y: 468 + extraStoreHeight, width: 600, height: 47)); v.addSubview(statusLabel)
        detailLabel = label("", 12, NSRect(x: 28, y: 391 + extraStoreHeight, width: 604, height: 70)); v.addSubview(detailLabel)
        storeLabel = label("", 14, NSRect(x: 28, y: 140, width: 604, height: 240 + extraStoreHeight)); storeLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular); v.addSubview(storeLabel)
        checkButton = button("立即检查", #selector(checkNow), NSRect(x: 22, y: 89, width: 100, height: 32)); v.addSubview(checkButton)
        pauseButton = button("暂停监控", #selector(togglePause), NSRect(x: 128, y: 89, width: 100, height: 32)); v.addSubview(pauseButton)
        v.addSubview(button("测试提醒", #selector(testAlert), NSRect(x: 234, y: 89, width: 100, height: 32)))
        v.addSubview(button("打开购买页面", #selector(openApple), NSRect(x: 340, y: 89, width: 130, height: 32)))
        v.addSubview(button("iPhone 推送", #selector(showPushSettings), NSRect(x: 476, y: 89, width: 150, height: 32)))
        pushStatusLabel = label(bark.status, 11, NSRect(x: 28, y: 122, width: 604, height: 18))
        pushStatusLabel.textColor = .secondaryLabelColor; v.addSubview(pushStatusLabel)
        let note = label("接口反复受限，当前方案无法保证持续监控或第一时间发现补货。\n正常约 150 秒查询；受拒后至少 15 分钟再尝试，届时仍可能失败。\n关闭窗口继续运行；关机、睡眠或断网无法查询。Mac 静音时无提示音。", 11, NSRect(x: 28, y: 18, width: 604, height: 60)); note.textColor = .secondaryLabelColor; v.addSubview(note)
        render()
    }
    @objc func showPushSettings() {
        if let pushWindow { pushWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "iPhone 推送设置 · Bark"; w.isReleasedWhenClosed = false; w.center()
        let v = NSView(frame: w.contentView!.bounds); w.contentView = v
        v.addSubview(label("连接你的 iPhone", 23, NSRect(x: 24, y: 362, width: 570, height: 35)))
        v.addSubview(label("1. 在 iPhone 安装 Bark 并允许通知。\n2. 复制 Bark 首页的推送地址或示例命令，粘贴到下方。", 14, NSRect(x: 24, y: 301, width: 570, height: 54)))
        let field = NSSecureTextField(frame: NSRect(x: 24, y: 265, width: 570, height: 28))
        field.placeholderString = "https://api.day.app/你的设备密钥/"; field.stringValue = bark.configuredAddress
        field.font = .systemFont(ofSize: 13); pushAddressField = field; v.addSubview(field)
        v.addSubview(label("地址仅保存在此 Mac，不写入日志或程序包。补货门店、检测时间和购买链接会经 Bark 服务器推送到手机。", 11, NSRect(x: 24, y: 214, width: 570, height: 43)))
        let strong = NSButton(checkboxWithTitle: "强提醒：静音/专注也响，连续约 30 秒（音量 8/10）", target: nil, action: nil)
        strong.frame = NSRect(x: 24, y: 176, width: 570, height: 28); strong.state = bark.strongAlertsEnabled ? .on : .off
        pushStrongCheckbox = strong; v.addSubview(strong)
        v.addSubview(label("需在 iPhone 为 Bark 开启“重要警告”；启用后夜间也可能响铃。", 11, NSRect(x: 24, y: 144, width: 570, height: 26)))
        pushSetupStatus = label(bark.status, 12, NSRect(x: 24, y: 90, width: 570, height: 46)); v.addSubview(pushSetupStatus!)
        v.addSubview(button("保存并发送测试", #selector(savePushSettings), NSRect(x: 18, y: 39, width: 160, height: 38)))
        v.addSubview(button("停用 iPhone 推送", #selector(disablePush), NSRect(x: 185, y: 39, width: 160, height: 38)))
        v.addSubview(button("Bark 下载", #selector(openBarkDownload), NSRect(x: 352, y: 39, width: 110, height: 38)))
        pushWindow = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openBarkDownload() { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/au/app/bark-custom-notifications/id1403753865")!) }
    @objc func savePushSettings() {
        do {
            try bark.configure(pushAddressField?.stringValue ?? "", strongAlerts: pushStrongCheckbox?.state == .on)
            bark.send(title: "iPhone 库存提醒测试（不是补货）", body: "收到这条消息代表手机推送链路可用。这是测试，没有发现真实库存。", isTest: true)
        } catch { pushSetupStatus?.stringValue = error.localizedDescription }
    }
    @objc func disablePush() {
        do { try bark.disable(); pushAddressField?.stringValue = "" }
        catch { pushSetupStatus?.stringValue = "无法停用推送，请重试" }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func openApple() { NSWorkspace.shared.open(productURL) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func checkNow() { guard !busy else { return }; if paused { paused = false; pauseButton.title = "暂停监控"; statusText = "等待下一次查询" }; check() }
    @objc func woke() { if !paused { check() } }
    @objc func togglePause() {
        paused.toggle(); pauseButton.title = paused ? "继续监控" : "暂停监控"
        if paused { timer?.invalidate(); nextCheck = nil; statusText = "已暂停监控"; item.button?.title = "Duo 暂停"; save(); render() }
        else { statusText = "等待下一次查询"; check() }
    }
    func restoreHistory() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isCurrentMonitorState(state) else { return }
        let iso = ISO8601DateFormatter()
        lastSuccess = (state["lastSuccess"] as? String).flatMap { iso.date(from: $0) }
        lastAttempt = (state["lastAttempt"] as? String).flatMap { iso.date(from: $0) }
        if let array = state["rows"], let encoded = try? JSONSerialization.data(withJSONObject: array),
           let previous = try? JSONDecoder().decode([StockRow].self, from: encoded),
           previous.count == targetStores.count, Set(previous.map(\.name)) == Set(targetStores) { rows = previous }
        errorText = state["error"] as? String ?? (lastSuccess == nil ? nil : "等待启动后的新查询，当前库存未知")
    }
    @discardableResult func persistSchedule() -> Bool {
        do { try schedule.persist(to: scheduleURL); return true }
        catch {
            paused = true; nextCheck = nil; statusText = "调度状态保存失败，已暂停"
            errorText = "无法保存请求间隔和冷却时间，请检查文件权限"
            pauseButton?.title = "继续监控"; save(); render(); return false
        }
    }
    func armTimer() {
        timer?.invalidate()
        guard !paused else { nextCheck = nil; return }
        nextCheck = schedule.nextRequestDate(at: Date())
        let t = Timer(timeInterval: max(1, nextCheck!.timeIntervalSinceNow), repeats: false) { [weak self] _ in self?.check() }
        timer = t; RunLoop.main.add(t, forMode: .common)
    }
    func check() {
        guard !busy, !paused else { return }
        timer?.invalidate()
        let now = Date()
        guard schedule.canRequest(at: now) else {
            if schedule.isCooling(at: now) {
                statusText = "监控中断：Apple 拒绝库存查询"; item.button?.title = "Duo 中断"
            } else if schedule.isBudgetWaiting(at: now) {
                statusText = "请求预算保护：等待下一次查询"; item.button?.title = "Duo 等待"
            }
            armTimer(); save(); render(); return
        }
        schedule.started(at: now)
        guard persistSchedule() else { return }
        busy = true; lastAttempt = now; nextCheck = nil
        if errorText != nil || lastSuccess == nil { statusText = "正在重新查询，当前库存未知…" }
        render()
        fetchStock { result in DispatchQueue.main.async { self.receive(result) } }
    }
    func receive(_ result: Result<[StockRow], Error>) {
        busy = false
        let now = Date()
        // Rate limits still apply if the user paused while a request was in flight.
        switch result {
        case .success: schedule.succeeded(at: now)
        case .failure(let error): schedule.failed(error, at: now); errorText = error.localizedDescription
        }
        failures = schedule.consecutiveFailures
        guard persistSchedule() else { return }
        if paused { statusText = "已暂停监控"; nextCheck = nil; save(); render(); return }
        switch result {
        case .success(let data):
            rows = data; lastSuccess = now; errorText = nil
            let stock = rows.filter(\.available)
            let newlyAvailable = tracker.observe(rows)
            statusText = stock.isEmpty ? "正常监控：最近查询 \(targetStores.count) 家均无货" : "发现库存：\(stock.count) 家门店可自提"
            item.button?.title = stock.isEmpty ? "Duo 0/\(targetStores.count)" : "Duo 有货!"
            log("SUCCESS available=\(stock.map(\.name).joined(separator: ",")) stores=\(rows.count) next=\(ISO8601DateFormatter().string(from: schedule.nextAllowedAt))")
            if !newlyAvailable.isEmpty {
                showAlert(title: "\(restockDescription) 有货了！", text: newlyAvailable.map { "Apple \($0.name)：可自提" }.joined(separator: "\n") + "\n\n请立即在苹果官网确认并下单。库存可能随时售罄。", repeating: true)
                log("RESTOCK_ALERT \(newlyAvailable.map(\.name).joined(separator: ","))")
                bark.send(title: "\(restockDescription) 补货", body: "检测时间：\(time(now))\n" + newlyAvailable.map { "Apple \($0.name)：检测时可自提" }.joined(separator: "\n") + "\n点击打开苹果官网，确认最新库存。")
            }
        case .failure(let error):
            errorText = error.localizedDescription
            let cooling = schedule.isCooling(at: now)
            statusText = cooling ? "监控中断：Apple 拒绝库存查询" : "查询故障：当前库存未知"
            item.button?.title = cooling ? "Duo 中断" : "Duo !"
            log("ERROR count=\(failures) retry=\(Int(schedule.nextAllowedAt.timeIntervalSince(now)))s \(error.localizedDescription)")
        }
        armTimer(); save(); render()
    }
    func time(_ date: Date?) -> String {
        guard let date = date else { return "尚无" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; f.timeZone = .current; return f.string(from: date)
    }
    func render() {
        guard statusLabel != nil else { return }
        statusLabel.stringValue = statusText
        statusLabel.textColor = errorText != nil || schedule.isCooling(at: Date()) ? .systemOrange : (rows.contains(where: \.available) ? .systemGreen : .labelColor)
        var detail = "最近尝试：\(time(lastAttempt))    最近成功：\(time(lastSuccess))\n"
        detail += busy ? "查询中…" : (paused ? "监控暂停中" : "\(errorText == nil ? "下次查询" : "下次尝试（不保证恢复）")：\(time(nextCheck))")
        if let error = errorText { detail += "\n\(error)" }
        detailLabel.stringValue = detail
        let requestHeld = schedule.isCooling(at: Date()) || schedule.isBudgetWaiting(at: Date())
        checkButton?.isEnabled = !busy && !requestHeld
        checkButton?.title = requestHeld ? "等待中" : "立即检查"
        pauseButton?.title = paused ? "继续监控" : "暂停监控"
        let unknown = errorText != nil || paused || lastSuccess == nil || schedule.isCooling(at: Date())
        let storeText = targetStores.map { name in
            stockRowText(rows.first(where: { $0.name == name }), name: name, currentUnknown: unknown)
        }.joined(separator: "\n")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 8
        storeLabel.attributedStringValue = NSAttributedString(string: storeText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
    func save() {
        let encoder = JSONEncoder()
        let encoded = (try? encoder.encode(rows)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        var x: [String: Any] = ["product": productSKU, "postcode": monitorPostcode, "targets": targetStores, "status": statusText, "paused": paused, "consecutiveFailures": failures, "rows": encoded, "updatedAt": ISO8601DateFormatter().string(from: Date())]
        x["iphonePushConfigured"] = bark?.isConfigured ?? false
        x["iphonePushStatus"] = bark?.status ?? "未配置"
        if let lastAttempt { x["lastAttempt"] = ISO8601DateFormatter().string(from: lastAttempt) }
        if let blockedUntil = schedule.blockedUntil { x["cooldownUntil"] = ISO8601DateFormatter().string(from: blockedUntil) }
        x["normalIntervalSeconds"] = QuerySchedule.normalInterval
        x["hourlyRequestLimit"] = QuerySchedule.requestLimit
        x["requestsInWindow"] = schedule.requestsInWindow(at: Date()).count
        if let lastSuccess { x["lastSuccess"] = ISO8601DateFormatter().string(from: lastSuccess) }
        if let nextCheck { x["nextCheck"] = ISO8601DateFormatter().string(from: nextCheck) }
        if let errorText { x["error"] = errorText }
        try? JSONSerialization.data(withJSONObject: x, options: [.prettyPrinted, .sortedKeys]).write(to: stateURL, options: .atomic)
    }
    @objc func testAlert() {
        log("TEST_ALERT synthetic=true")
        bark.send(title: "iPhone 库存提醒测试（不是补货）", body: "收到这条消息代表手机推送链路可用。这是测试，没有发现真实库存。", isTest: true)
        showAlert(title: "测试提醒（不是补货）", text: "这是提醒链路测试，没有发现真实库存。\n\n真实补货时也会出现这个置顶窗口并响铃，窗口会持续显示，直到你关闭。", repeating: false)
    }
    func showAlert(title: String, text: String, repeating: Bool) {
        soundTimer?.invalidate()
        alertPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title; panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false; panel.center()
        let view = NSView(frame: panel.contentView!.bounds); panel.contentView = view
        view.addSubview(label(title, 24, NSRect(x: 25, y: 360, width: 510, height: 40)))
        alertLabel = label(text, 16, NSRect(x: 25, y: 80, width: 510, height: 270)); view.addSubview(alertLabel!)
        view.addSubview(button("打开购买页面", #selector(openApple), NSRect(x: 20, y: 20, width: 150, height: 40)))
        view.addSubview(button("关闭提醒", #selector(closeAlert), NSRect(x: 180, y: 20, width: 120, height: 40)))
        alertPanel = panel; panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NSSound(named: NSSound.Name("Glass"))?.play()
        if repeating {
            var count = 0
            soundTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                guard let self, self.alertPanel?.isVisible == true, count < 11 else { timer.invalidate(); return }
                count += 1; NSSound(named: NSSound.Name("Glass"))?.play()
            }
        }
    }
    @objc func closeAlert() { soundTimer?.invalidate(); alertPanel?.close() }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); soundTimer?.invalidate(); if let activity { ProcessInfo.processInfo.endActivity(activity) }
        statusText = "程序已退出，未在监控"; nextCheck = nil; paused = true; save(); log("STOP")
    }
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests(); try runBarkSelfTests(); try runScheduleSelfTests(); exit(0) } catch { print(error.localizedDescription); exit(1) }
}
if CommandLine.arguments.contains("--check-once") {
    var finished = false; var code: Int32 = 1
    fetchStock { result in
        switch result {
        case .success(let rows): print(rows.map { "\($0.name): \($0.available ? "AVAILABLE" : "unavailable")" }.joined(separator: "\n")); code = 0
        case .failure(let error): print("CHECK FAILED: \(error.localizedDescription)")
        }
        finished = true
    }
    while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    exit(code)
}
// Kernel-owned file lock prevents a LaunchAgent and a double-click from polling twice.
let lockDescriptor = Darwin.open(supportDirectory.appendingPathComponent("monitor.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard lockDescriptor >= 0 else { fputs("无法创建监控进程锁\n", stderr); exit(1) }
if Darwin.lockf(lockDescriptor, F_TLOCK, 0) != 0 {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.iphoneduostock.showWindow"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}
let app = NSApplication.shared
let monitor = Monitor()
app.delegate = monitor
app.run()
