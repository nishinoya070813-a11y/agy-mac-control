// AGY Mac Control：一个菜单栏小程序，替 Antigravity 截屏、点鼠标、打字。
// 只有这个程序拿“屏幕录制”和“辅助功能”权限；Antigravity 通过本机 127.0.0.1 端口 + 口令来请求它。
// 安全：按 Esc 立即暂停；在“密码”“钥匙串访问”里拒绝操作；退出程序 = 完全关闭。
import Cocoa
import Network

let SUPPORT = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/agy-mac-control")
let PORT: UInt16 = 47321
// 这些软件在最前面时，拒绝点击和输入
let DENIED_BUNDLES: Set<String> = ["com.apple.Passwords", "com.apple.keychainaccess"]

var token = ""
var paused = false
var ignoreEscUntil = Date.distantPast

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    let url = SUPPORT.appendingPathComponent("helper.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// ---------- 屏幕和输入 ----------

func mainScreenSize() -> CGSize { NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900) }

func frontmost() -> (String, String) {
    let a = NSWorkspace.shared.frontmostApplication
    return (a?.localizedName ?? "", a?.bundleIdentifier ?? "")
}

func screenshot() -> [String: Any] {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agcu-\(UUID().uuidString).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-C", "-m", tmp.path]   // 不出声、带鼠标指针、只截主屏
    try? p.run(); p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard let img = NSImage(contentsOf: tmp) else {
        return ["error": "截屏失败：请在 系统设置 → 隐私与安全性 → 屏幕与系统录音 里允许「AGY Mac Control」"]
    }
    // 缩到“点”的尺寸，这样截图上的像素坐标 = 点击用的坐标
    // （直接用 NSImage 画会按 Retina 2 倍出图，所以明确指定位图的像素宽高）
    let size = mainScreenSize()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        return ["error": "图片缓冲区创建失败"]
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
        return ["error": "图片编码失败"]
    }
    let (name, bid) = frontmost()
    return ["image": jpg.base64EncodedString(), "width": Int(size.width), "height": Int(size.height),
            "frontmost": name, "frontmostBundle": bid]
}

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    post(e)
}

// 鼠标慢慢滑过去（约 0.3 秒），用户能看清它要去哪
func glide(to p: CGPoint) {
    let start = CGEvent(source: nil)?.location ?? p
    let steps = 18
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // 先加速后减速
        let q = CGPoint(x: start.x + (p.x - start.x) * e, y: start.y + (p.y - start.y) * e)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
}

func click(_ x: Double, _ y: Double, right: Bool, count: Int) {
    let p = CGPoint(x: x, y: y)
    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) =
        right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    glide(to: p)
    DispatchQueue.main.async { Overlay.shared.ripple(at: p) }
    mouse(.mouseMoved, p, btn)
    for i in 1...max(1, count) { mouse(down, p, btn, clicks: i); mouse(up, p, btn, clicks: i) }
}

func drag(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    let a = CGPoint(x: x1, y: y1), b = CGPoint(x: x2, y: y2)
    glide(to: a)
    mouse(.mouseMoved, a, .left); mouse(.leftMouseDown, a, .left)
    for i in 1...12 {
        let t = Double(i) / 12
        mouse(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t), .left)
        usleep(20_000)
    }
    mouse(.leftMouseUp, b, .left)
}

func scroll(_ x: Double, _ y: Double, _ dy: Int, _ dx: Int) {
    glide(to: CGPoint(x: x, y: y))
    mouse(.mouseMoved, CGPoint(x: x, y: y), .left)
    // 约定：dy 正数 = 往下翻
    post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0))
}

func typeText(_ text: String) {
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
        let chunk = Array(units[i..<min(i + 16, units.count)])
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(e)
        }
        i += 16
    }
}

let KEYCODES: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
]

func pressKey(_ combo: String) -> String? {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    for part in combo.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn": flags.insert(.maskSecondaryFn)
        default: key = KEYCODES[part]
        }
    }
    guard let k = key else { return "不认识的按键：\(combo)" }
    if k == 53 { ignoreEscUntil = Date().addingTimeInterval(0.5) }  // 自己按的 Esc 不算“暂停”
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: down)
        e?.flags = flags
        post(e)
    }
    return nil
}

func runningApps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
        ["name": $0.localizedName ?? "", "bundle": $0.bundleIdentifier ?? "", "frontmost": $0.isActive]
    }
}

func openApp(_ name: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    let err = Pipe(); p.standardError = err
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0 ? nil : "打不开：\(name)"
}

// ---------- 处理请求 ----------

func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }

func handle(_ req: [String: Any]) -> [String: Any] {
    guard (req["token"] as? String) == token else { return ["error": "口令不对"] }
    let action = req["action"] as? String ?? ""
    if action == "status" {
        return ["paused": paused, "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
                "screen": ["width": Int(mainScreenSize().width), "height": Int(mainScreenSize().height)]]
    }
    if paused { return ["error": "用户按了 Esc 暂停了电脑控制。请停下来，等用户在菜单栏「AGY Mac Control」里点“继续”。"] }
    let mutating: Set<String> = ["click", "drag", "scroll", "type", "key", "move"]
    if mutating.contains(action) {
        if !AXIsProcessTrusted() { return ["error": "没有辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 里允许「AGY Mac Control」"] }
        let (name, bid) = frontmost()
        if DENIED_BUNDLES.contains(bid) { return ["error": "安全限制：「\(name)」在最前面时不允许操作。"] }
    }
    log("\(action) \(req.filter { $0.key != "token" && $0.key != "text" })")
    let what = describe(action, req)
    DispatchQueue.main.async { setIcon(active: true); Overlay.shared.show(what) }
    switch action {
    case "screenshot": return screenshot()
    case "click":
        guard let x = num(req, "x"), let y = num(req, "y") else { return ["error": "缺少 x/y"] }
        click(x, y, right: (req["button"] as? String) == "right", count: Int(num(req, "count") ?? 1))
    case "move":
        guard let x = num(req, "x"), let y = num(req, "y") else { return ["error": "缺少 x/y"] }
        glide(to: CGPoint(x: x, y: y))
    case "drag":
        guard let a = num(req, "x1"), let b = num(req, "y1"), let c = num(req, "x2"), let d = num(req, "y2") else { return ["error": "缺少坐标"] }
        drag(a, b, c, d)
    case "scroll":
        scroll(num(req, "x") ?? 0, num(req, "y") ?? 0, Int(num(req, "dy") ?? 0), Int(num(req, "dx") ?? 0))
    case "type":
        typeText(req["text"] as? String ?? "")
    case "key":
        if let e = pressKey(req["combo"] as? String ?? "") { return ["error": e] }
    case "apps": return ["apps": runningApps()]
    case "open_app":
        if let e = openApp(req["name"] as? String ?? "") { return ["error": e] }
    default: return ["error": "不支持的操作：\(action)"]
    }
    let (name, _) = frontmost()
    return ["ok": true, "frontmost": name]
}

// ---------- 屏幕上的提示：发光边框 + 顶部状态条 + 点击圆圈 ----------
// 这些窗口设成 sharingType = .none，不会出现在截图里，所以不会干扰智能体判断界面。

let workQueue = DispatchQueue(label: "agcu.work")

func describe(_ a: String, _ r: [String: Any]) -> String {
    func n(_ k: String) -> Int { Int(num(r, k) ?? 0) }
    switch a {
    case "screenshot": return "👀 正在看屏幕"
    case "click":
        let kind = (r["button"] as? String) == "right" ? "右键点击" : (n("count") >= 2 ? "双击" : "点击")
        return "🖱 \(kind) (\(n("x")), \(n("y")))"
    case "move": return "🖱 移到 (\(n("x")), \(n("y")))"
    case "drag": return "🖱 拖动 (\(n("x1")), \(n("y1"))) → (\(n("x2")), \(n("y2")))"
    case "scroll": return n("dy") >= 0 ? "🖱 往下滚动" : "🖱 往上滚动"
    case "type":
        let t = r["text"] as? String ?? ""
        return "⌨️ 输入：" + (t.count > 24 ? String(t.prefix(24)) + "…" : t)
    case "key": return "⌨️ 按键 " + (r["combo"] as? String ?? "")
    case "open_app": return "📂 打开「" + (r["name"] as? String ?? "") + "」"
    case "apps": return "📋 查看正在运行的软件"
    default: return a
    }
}

class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let c = NSColor(calibratedRed: 0.25, green: 0.55, blue: 1, alpha: 1)
        for (w, a) in [(16.0, 0.10), (9.0, 0.22), (3.0, 0.95)] {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2), xRadius: 12, yRadius: 12)
            p.lineWidth = w
            c.withAlphaComponent(a).setStroke()
            p.stroke()
        }
    }
}

class Overlay {
    static let shared = Overlay()
    var border: NSWindow?
    var hud: NSWindow?
    var label: NSTextField?
    var hideTimer: Timer?

    func makeWindow(_ frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true          // 点击会穿过去，不挡操作
        w.level = .screenSaver
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.sharingType = .none                // 不出现在截图里
        return w
    }

    func setup() {
        guard border == nil, let s = NSScreen.screens.first else { return }
        let b = makeWindow(s.frame)
        b.contentView = BorderView(frame: NSRect(origin: .zero, size: s.frame.size))
        border = b

        let hw: CGFloat = 480, hh: CGFloat = 56
        let h = makeWindow(NSRect(x: s.frame.midX - hw / 2, y: s.visibleFrame.maxY - hh - 12, width: hw, height: hh))
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: hw, height: hh))
        v.material = .hudWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
        let l = NSTextField(labelWithString: "")
        l.frame = NSRect(x: 14, y: 24, width: hw - 28, height: 22)
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: "Antigravity 正在操作电脑 · 按 Esc 立即停止")
        sub.frame = NSRect(x: 14, y: 6, width: hw - 28, height: 16)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = NSColor.white.withAlphaComponent(0.75)
        sub.alignment = .center
        v.addSubview(l)
        v.addSubview(sub)
        h.contentView = v
        hud = h
        label = l
    }

    func show(_ text: String) {
        setup()
        label?.stringValue = text
        border?.alphaValue = 1
        hud?.alphaValue = 1
        border?.orderFrontRegardless()
        hud?.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in self.hide() }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.4
            self.border?.animator().alphaValue = 0
            self.hud?.animator().alphaValue = 0
        }, completionHandler: {
            if self.hud?.alphaValue == 0 { self.border?.orderOut(nil); self.hud?.orderOut(nil) }
        })
    }

    func ripple(at p: CGPoint) {
        guard let s = NSScreen.screens.first else { return }
        let d: CGFloat = 46
        let w = makeWindow(NSRect(x: p.x - d / 2, y: s.frame.height - p.y - d / 2, width: d, height: d))
        let v = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        v.wantsLayer = true
        v.layer?.cornerRadius = d / 2
        v.layer?.borderWidth = 3
        v.layer?.borderColor = NSColor.systemBlue.cgColor
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
        w.contentView = v
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.7
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }
}

// ---------- 极简 HTTP 服务（只监听 127.0.0.1） ----------

func serve(_ conn: NWConnection) {
    var buf = Data()
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, err in
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let len = head.split(separator: "\r\n").compactMap { line -> Int? in
                    let p = line.split(separator: ":", maxSplits: 1)
                    return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = buf[r.upperBound...]
                if body.count >= len {
                    let req = (try? JSONSerialization.jsonObject(with: Data(body.prefix(len)))) as? [String: Any] ?? [:]
                    DispatchQueue.global().async {
                        let res = workQueue.sync { handle(req) }   // 一次只做一个操作；界面提示在主线程画
                        let out = (try? JSONSerialization.data(withJSONObject: res)) ?? Data("{}".utf8)
                        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n".utf8)
                        resp.append(out)
                        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
                    }
                    return
                }
            }
            if done || err != nil { conn.cancel(); return }
            receive()
        }
    }
    conn.start(queue: .global())
    receive()
}

// ---------- 菜单栏 ----------

var statusItem: NSStatusItem!
var idleTimer: Timer?

func setIcon(active: Bool) {
    statusItem.button?.title = paused ? "⏸ AG" : (active ? "🟢 AG" : "🖱 AG")
    idleTimer?.invalidate()
    if active && !paused {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in setIcon(active: false) }
    }
}

class Delegate: NSObject, NSApplicationDelegate {
    var listener: NWListener?
    let toggle = NSMenuItem(title: "暂停（也可按 Esc）", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: SUPPORT, withIntermediateDirectories: true)
        let tokenURL = SUPPORT.appendingPathComponent("token")
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8), !t.isEmpty { token = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        else {
            token = UUID().uuidString + UUID().uuidString
            try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        toggle.target = self
        menu.addItem(toggle)
        let perm = NSMenuItem(title: "检查权限", action: #selector(checkPerms), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出（完全关闭电脑控制）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon(active: false)

        // 第一次运行时弹出系统的授权提示
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }

        // 全局 Esc：立刻暂停
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && Date() > ignoreEscUntil && !paused { self.setPaused(true) }
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!)
        do {
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = serve
            listener?.start(queue: .global())
            log("启动，端口 \(PORT)")
        } catch { log("端口启动失败：\(error)") }
    }

    func setPaused(_ p: Bool) {
        paused = p
        toggle.title = p ? "继续允许控制" : "暂停（也可按 Esc）"
        setIcon(active: false)
        log(p ? "已暂停" : "已继续")
        if p { Overlay.shared.show("⏸ 已暂停：在菜单栏 🖱 AG 里点“继续允许控制”") }
    }

    @objc func togglePause() { setPaused(!paused) }

    @objc func checkPerms() {
        let a = NSAlert()
        a.messageText = "AGY Mac Control · 权限"
        a.informativeText = "辅助功能（点鼠标、打字）：\(AXIsProcessTrusted() ? "✅ 已允许" : "❌ 未允许")\n"
            + "屏幕录制（截屏）：\(CGPreflightScreenCaptureAccess() ? "✅ 已允许" : "❌ 未允许")\n\n"
            + "在 系统设置 → 隐私与安全性 里打开这两项。改完需要退出再重新打开本程序。"
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
