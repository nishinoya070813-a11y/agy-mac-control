// AGY Mac Control v2：一个菜单栏小程序，替 Antigravity 读界面、点按钮、打字、截屏。
// 只有这个程序拿“屏幕录制”和“辅助功能”权限；Antigravity 通过本机 127.0.0.1 端口 + 口令来请求它。
//
// v2 思路（参考 Codex）：优先读软件的“辅助功能树”（按钮/输入框清单，带编号），按编号直接操作，
// 大多数时候不用动真的鼠标；只截目标软件的窗口；读不到再退回整屏截图 + 坐标点击。
// 提示：右上角小浮窗（最近几步 + 停止/继续按钮）；按 Esc 也能立即暂停。
import Cocoa
import Network

let SUPPORT = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/agy-mac-control")
let PORT: UInt16 = 47321
// 这些软件不允许操作（在最前面时，或被指定为目标时）
let DENIED_BUNDLES: Set<String> = ["com.apple.Passwords", "com.apple.keychainaccess"]
let MAX_ELEMENTS = 500

var token = ""
var paused = false
var ignoreEscUntil = Date.distantPast
var lastActionAt = Date.distantPast

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    let url = SUPPORT.appendingPathComponent("helper.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

// ---------- 找软件 ----------

func mainScreenSize() -> CGSize { NSScreen.screens.first?.frame.size ?? CGSize(width: 1440, height: 900) }

func frontmost() -> (String, String) {
    let a = NSWorkspace.shared.frontmostApplication
    return (a?.localizedName ?? "", a?.bundleIdentifier ?? "")
}

func findRunning(_ name: String) -> NSRunningApplication? {
    let n = name.lowercased()
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    return apps.first { ($0.bundleIdentifier ?? "").lowercased() == n }
        ?? apps.first { ($0.localizedName ?? "").lowercased() == n }
        ?? apps.first { $0.bundleURL?.path.lowercased() == n }
        ?? apps.first { ($0.localizedName ?? "").lowercased().contains(n) }
}

/// 找到正在运行的软件；没开就在后台打开（不抢前台）
func resolveApp(_ name: String) -> NSRunningApplication? {
    if let a = findRunning(name) { return a }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = name.contains(".") && !name.contains("/") ? ["-g", "-b", name] : ["-g", "-a", name]
    p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    for _ in 0..<30 {
        if let a = findRunning(name) { usleep(400_000); return a }
        usleep(200_000)
    }
    return nil
}

func deniedError(_ app: NSRunningApplication) -> [String: Any]? {
    if DENIED_BUNDLES.contains(app.bundleIdentifier ?? "") {
        return ["error": "安全限制：不允许操作「\(app.localizedName ?? "")」。"]
    }
    return nil
}

// ---------- 辅助功能树 ----------

func axAttr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func axStr(_ e: AXUIElement, _ a: String) -> String? {
    guard let v = axAttr(e, a) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axAttr(e, kAXPositionAttribute), let s = axAttr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func axActions(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    return (names as? [String]) ?? []
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func clip(_ s: String, _ n: Int = 70) -> String {
    let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return t.count > n ? String(t.prefix(n)) + "…" : t
}

struct AXEntry { let el: AXUIElement; let label: String; let frame: CGRect? }
var axCache: [pid_t: [AXEntry]] = [:]

/// 某个元素的“名字”，用来显示和描述
func axLabel(_ e: AXUIElement) -> String {
    for a in [kAXTitleAttribute, kAXDescriptionAttribute, "AXLabel", kAXHelpAttribute, kAXPlaceholderValueAttribute] {
        if let s = axStr(e, a), !s.trimmingCharacters(in: .whitespaces).isEmpty { return clip(s, 40) }
    }
    if let v = axStr(e, kAXValueAttribute), !v.isEmpty { return clip(v, 40) }
    return ""
}

let BORING_ROLES: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown", "AXSplitter", "AXGrowArea"]

func appState(_ app: NSRunningApplication) -> [String: Any] {
    let pid = app.processIdentifier
    let root = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(root, 1.5)
    var windows = (axAttr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let fw = axAttr(root, kAXFocusedWindowAttribute) {
        let f = fw as! AXUIElement
        windows.removeAll { CFEqual($0, f) }
        windows.insert(f, at: 0)
    }
    var lines: [String] = []
    var entries: [AXEntry] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        if entries.count >= MAX_ELEMENTS || depth > 30 { return }
        let role = axStr(e, kAXRoleAttribute) ?? "?"
        let label = axLabel(e)
        let value = axStr(e, kAXValueAttribute).map { clip($0, 60) } ?? ""
        let actions = axActions(e).filter { $0 != "AXScrollToVisible" }
        let interesting = !actions.isEmpty || !label.isEmpty || !value.isEmpty
        var nextDepth = depth
        if interesting && !(BORING_ROLES.contains(role) && actions.isEmpty) {
            let i = entries.count
            let fr = axFrame(e)
            entries.append(AXEntry(el: e, label: label.isEmpty ? String(role.dropFirst(2)) : label, frame: fr))
            var s = String(repeating: "  ", count: min(depth, 8)) + "[\(i)] \(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)"
            if !label.isEmpty { s += " 「\(label)」" }
            if !value.isEmpty && value != label { s += " 值=\(value)" }
            if let en = axAttr(e, kAXEnabledAttribute) as? Bool, !en { s += " (不可用)" }
            if let f = fr { s += " @(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))" }
            let acts = actions.filter { $0 != "AXPress" }.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
            if actions.contains("AXPress") { s += " 可点" }
            if !acts.isEmpty { s += " 其他操作:" + acts.joined(separator: ",") }
            lines.append(s)
            nextDepth = depth + 1
        }
        for c in axChildren(e) { walk(c, nextDepth) }
    }
    for (wi, w) in windows.prefix(4).enumerated() {
        let title = axStr(w, kAXTitleAttribute) ?? ""
        lines.append("== 窗口\(wi + 1)「\(clip(title, 50))」" + (axFrame(w).map { " @(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? ""))
        walk(w, 0)
    }
    axCache[pid] = entries
    if windows.isEmpty { lines.append("（这个软件现在没有窗口，或者它不提供辅助功能信息。可以试试 computer_screenshot。）") }
    if entries.count >= MAX_ELEMENTS { lines.append("（元素太多，只列出前 \(MAX_ELEMENTS) 个）") }
    return ["app": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? "", "text": lines.joined(separator: "\n"),
            "count": entries.count, "frontmost": app.isActive]
}

func entry(_ app: NSRunningApplication, _ idx: Int) -> AXEntry? {
    guard let list = axCache[app.processIdentifier], idx >= 0, idx < list.count else { return nil }
    return list[idx]
}

// ---------- 截图 ----------

func scaled(_ img: NSImage, to size: CGSize) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
}

func capture(_ args: [String]) -> NSImage? {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agcu-\(UUID().uuidString).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = args + [tmp.path]
    try? p.run(); p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: tmp) }
    return NSImage(contentsOf: tmp)
}

let NO_SCREEN = "截屏失败：请在 系统设置 → 隐私与安全性 → 屏幕与系统录音 里允许「AGY Mac Control」"

func screenshot() -> [String: Any] {
    guard let img = capture(["-x", "-C", "-m"]) else { return ["error": NO_SCREEN] }
    let size = mainScreenSize()
    guard let jpg = scaled(img, to: size) else { return ["error": "图片编码失败"] }
    let (name, bid) = frontmost()
    return ["image": jpg.base64EncodedString(), "width": Int(size.width), "height": Int(size.height),
            "frontmost": name, "frontmostBundle": bid]
}

var lastWindowFrame: [pid_t: CGRect] = [:]

/// 只截某个软件最前面的那个窗口（被挡住也能截）
func windowShot(_ app: NSRunningApplication) -> [String: Any] {
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    guard let w = info.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                                      && ($0[kCGWindowLayer as String] as? Int) == 0 }),
          let num = w[kCGWindowNumber as String] as? Int,
          let bd = w[kCGWindowBounds as String] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bd) else {
        return ["error": "找不到「\(app.localizedName ?? "")」的窗口（可能被最小化或在别的桌面）"]
    }
    guard let img = capture(["-x", "-o", "-l", String(num)]) else { return ["error": NO_SCREEN] }
    guard let jpg = scaled(img, to: frame.size) else { return ["error": "图片编码失败"] }
    lastWindowFrame[app.processIdentifier] = frame
    return ["image": jpg.base64EncodedString(), "width": Int(frame.width), "height": Int(frame.height),
            "originX": Int(frame.minX), "originY": Int(frame.minY)]
}

// ---------- 鼠标和键盘 ----------

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(15_000) }

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton, clicks: Int = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    post(e)
}

/// 鼠标平滑移过去（约 0.25 秒）
func glide(to p: CGPoint) {
    let start = CGEvent(source: nil)?.location ?? p
    let steps = 14
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let k = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        let q = CGPoint(x: start.x + (p.x - start.x) * k, y: start.y + (p.y - start.y) * k)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(16_000)
    }
}

func click(_ p: CGPoint, right: Bool, count: Int) {
    let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) =
        right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    let hidePanel = DispatchQueue.main.sync { Panel.shared.covers(p) }
    if hidePanel { DispatchQueue.main.sync { Panel.shared.window?.orderOut(nil) } }
    glide(to: p)
    onMain { Overlay.ripple(at: p) }
    mouse(.mouseMoved, p, btn)
    for i in 1...max(1, count) { mouse(down, p, btn, clicks: i); mouse(up, p, btn, clicks: i) }
    if hidePanel { onMain { Panel.shared.window?.orderFrontRegardless() } }
}

func drag(_ a: CGPoint, _ b: CGPoint) {
    glide(to: a)
    mouse(.mouseMoved, a, .left); mouse(.leftMouseDown, a, .left)
    for i in 1...12 {
        let t = Double(i) / 12
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), .left)
        usleep(20_000)
    }
    mouse(.leftMouseUp, b, .left)
}

func scroll(_ p: CGPoint, _ dy: Int, _ dx: Int) {
    glide(to: p)
    post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0))
}

/// 发键盘事件：指定了软件且它不在最前面时，直接发给那个软件（不抢前台）
func sendKey(_ e: CGEvent?, to app: NSRunningApplication?) {
    if let a = app, !a.isActive { e?.postToPid(a.processIdentifier) } else { e?.post(tap: .cghidEventTap) }
    usleep(12_000)
}

func typeText(_ text: String, to app: NSRunningApplication?) {
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
        let chunk = Array(units[i..<min(i + 16, units.count)])
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            sendKey(e, to: app)
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

func pressKey(_ combo: String, to app: NSRunningApplication?) -> String? {
    var flags: CGEventFlags = []
    var key: CGKeyCode?
    for part in combo.lowercased().split(separator: "+").map(String.init) {
        switch part {
        case "cmd", "command", "super": flags.insert(.maskCommand)
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
        sendKey(e, to: app)
    }
    return nil
}

func runningApps() -> [[String: Any]] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
        ["name": $0.localizedName ?? "", "bundle": $0.bundleIdentifier ?? "", "frontmost": $0.isActive]
    }
}

// ---------- 屏幕提示：右上角小浮窗 + 点击圆圈 + 元素高亮 ----------
// 这些窗口 sharingType = .none，不会出现在截图里。

final class Panel: NSObject {
    static let shared = Panel()
    var window: NSPanel?
    var title: NSTextField!
    var lines: [NSTextField] = []
    var button: NSButton!
    var history: [String] = []
    var hideTimer: Timer?
    let W: CGFloat = 300, H: CGFloat = 122

    func setup() {
        guard window == nil, let s = NSScreen.screens.first else { return }
        let p = NSPanel(contentRect: NSRect(x: s.frame.maxX - W - 14, y: s.visibleFrame.maxY - H - 10, width: W, height: H),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = .statusBar; p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.sharingType = .none
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.material = .hudWindow; v.state = .active; v.appearance = NSAppearance(named: .vibrantDark)
        v.wantsLayer = true; v.layer?.cornerRadius = 14; v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1; v.layer?.borderColor = NSColor(calibratedRed: 0.3, green: 0.6, blue: 1, alpha: 0.9).cgColor
        title = NSTextField(labelWithString: "")
        title.frame = NSRect(x: 14, y: H - 30, width: W - 100, height: 18)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold); title.textColor = .white
        v.addSubview(title)
        button = NSButton(title: "停止", target: self, action: #selector(toggle))
        button.bezelStyle = .rounded; button.controlSize = .small
        button.frame = NSRect(x: W - 80, y: H - 34, width: 68, height: 24)
        v.addSubview(button)
        for i in 0..<3 {
            let l = NSTextField(labelWithString: "")
            l.frame = NSRect(x: 14, y: H - 56 - CGFloat(i) * 20, width: W - 28, height: 18)
            l.font = .systemFont(ofSize: i == 0 ? 13 : 11.5, weight: i == 0 ? .medium : .regular)
            l.textColor = NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.55)
            l.lineBreakMode = .byTruncatingTail
            v.addSubview(l); lines.append(l)
        }
        let hint = NSTextField(labelWithString: "按 Esc 也能立即停止")
        hint.frame = NSRect(x: 14, y: 6, width: W - 28, height: 14)
        hint.font = .systemFont(ofSize: 10); hint.textColor = NSColor.white.withAlphaComponent(0.4)
        v.addSubview(hint)
        p.contentView = v
        window = p
    }

    func refresh() {
        title.stringValue = paused ? "⏸ 已暂停" : "● Antigravity 正在操作电脑"
        title.textColor = paused ? .systemOrange : NSColor(calibratedRed: 0.45, green: 0.75, blue: 1, alpha: 1)
        button.title = paused ? "继续" : "停止"
        for (i, l) in lines.enumerated() { l.stringValue = i < history.count ? history[history.count - 1 - i] : "" }
    }

    func show(_ text: String?) {
        setup()
        if let t = text { history.append(t); if history.count > 3 { history.removeFirst() } }
        refresh()
        window?.alphaValue = 1
        window?.orderFrontRegardless()
        hideTimer?.invalidate()
        if !paused { hideTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in self.hide() } }
    }

    func hide() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; w.animator().alphaValue = 0 },
                                             completionHandler: { if w.alphaValue == 0 { w.orderOut(nil); self.history.removeAll() } })
    }

    func covers(_ p: CGPoint) -> Bool {
        guard let w = window, w.isVisible, let s = NSScreen.screens.first else { return false }
        let f = w.frame
        return CGRect(x: f.minX, y: s.frame.height - f.maxY, width: f.width, height: f.height).contains(p)
    }

    @objc func toggle() { setPaused(!paused) }
}

func setPaused(_ p: Bool) {
    paused = p
    log(p ? "已暂停" : "已继续")
    onMain {
        Panel.shared.show(p ? "已暂停：点“继续”或在菜单栏 🖱 AG 里恢复" : "已继续，可以接着操作")
        menuToggle?.title = p ? "继续允许控制" : "暂停（也可按 Esc）"
        setIcon(active: false)
    }
}

enum Overlay {
    static func make(_ f: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = true
        w.level = .screenSaver; w.hasShadow = false; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.sharingType = .none
        return w
    }
    static func flash(_ w: NSWindow, _ duration: Double) {
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ c in c.duration = duration; w.animator().alphaValue = 0 },
                                             completionHandler: { w.orderOut(nil) })
    }
    /// 坐标点击：点击处闪一个圆圈
    static func ripple(at p: CGPoint) {
        guard let s = NSScreen.screens.first else { return }
        let d: CGFloat = 44
        let w = make(NSRect(x: p.x - d / 2, y: s.frame.height - p.y - d / 2, width: d, height: d))
        let v = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d)); v.wantsLayer = true
        v.layer?.cornerRadius = d / 2; v.layer?.borderWidth = 3; v.layer?.borderColor = NSColor.systemBlue.cgColor
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
        w.contentView = v; flash(w, 0.7)
    }
    /// 按编号操作：在那个按钮/输入框周围闪一圈蓝框（不用动鼠标也能看清点了哪）
    static func highlight(_ r: CGRect) {
        guard let s = NSScreen.screens.first, r.width > 1, r.height > 1 else { return }
        let f = NSRect(x: r.minX - 4, y: s.frame.height - r.maxY - 4, width: r.width + 8, height: r.height + 8)
        let w = make(f)
        let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true
        v.layer?.cornerRadius = 8; v.layer?.borderWidth = 3; v.layer?.borderColor = NSColor.systemBlue.cgColor
        v.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        w.contentView = v; flash(w, 0.9)
    }
}

// ---------- 处理请求 ----------

func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
func say(_ t: String) { onMain { setIcon(active: true); Panel.shared.show(t) } }

let workQueue = DispatchQueue(label: "agcu.work")

func handle(_ req: [String: Any]) -> [String: Any] {
    guard (req["token"] as? String) == token else { return ["error": "口令不对"] }
    let action = req["action"] as? String ?? ""
    if action == "status" {
        return ["paused": paused, "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
                "screen": ["width": Int(mainScreenSize().width), "height": Int(mainScreenSize().height)]]
    }
    if paused { return ["error": "用户暂停了电脑控制。请停下来，等用户点“继续”。"] }
    if !AXIsProcessTrusted() && action != "screenshot" && action != "apps" {
        return ["error": "没有辅助功能权限：请在 系统设置 → 隐私与安全性 → 辅助功能 里允许「AGY Mac Control」"]
    }
    log("\(action) \(req.filter { !["token", "text", "value"].contains($0.key) })")

    // 指定了目标软件的操作
    var app: NSRunningApplication?
    if let name = req["app"] as? String, !name.isEmpty {
        guard let a = resolveApp(name) else { return ["error": "找不到或打不开软件：\(name)"] }
        if let e = deniedError(a) { return e }
        app = a
    }
    let appName = app?.localizedName ?? ""

    func done(_ extra: [String: Any] = [:]) -> [String: Any] {
        lastActionAt = Date()
        var r: [String: Any] = ["ok": true, "frontmost": frontmost().0]
        extra.forEach { r[$0.key] = $0.value }
        return r
    }

    switch action {
    case "app_state":
        guard let a = app else { return ["error": "缺少 app"] }
        // 刚操作完时等一下，让界面更新
        let since = Date().timeIntervalSince(lastActionAt)
        if since < 0.8 { usleep(UInt32((0.8 - since) * 1_000_000)) }
        say("📖 读取「\(appName)」的界面")
        var r = appState(a)
        if (req["screenshot"] as? Bool) == true {
            let shot = windowShot(a)
            if let img = shot["image"] { r["image"] = img; ["width", "height", "originX", "originY"].forEach { r[$0] = shot[$0] } }
            else if let e = shot["error"] { r["screenshotError"] = e }
        }
        return r

    case "click_element", "set_value", "element_action":
        guard let a = app, let idx = num(req, "index").map(Int.init) else { return ["error": "缺少 app 或 index"] }
        guard let en = entry(a, idx) else { return ["error": "编号 \(idx) 不存在：请先 computer_get_app_state 获取最新界面"] }
        if let f = en.frame { onMain { Overlay.highlight(f) } }
        if action == "click_element" {
            say("🔘 点击「\(en.label)」· \(appName)")
            let r = AXUIElementPerformAction(en.el, kAXPressAction as CFString)
            if r != .success {
                // 不支持“按下”的元素：退回到在它中心点一下（会动鼠标）
                guard let f = en.frame else { return ["error": "这个元素不能直接点（\(r.rawValue)），也没有位置信息"] }
                a.activate(); usleep(250_000)
                click(CGPoint(x: f.midX, y: f.midY), right: false, count: 1)
                return done(["note": "这个元素不支持直接按下，已改为在它中心点击"])
            }
            return done()
        }
        if action == "set_value" {
            let v = req["value"] as? String ?? ""
            say("✏️ 填写「\(en.label)」：\(clip(v, 24))")
            AXUIElementSetAttributeValue(en.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if AXUIElementSetAttributeValue(en.el, kAXValueAttribute as CFString, v as CFTypeRef) != .success {
                // 设不进去就退回到聚焦后打字
                a.activate(); usleep(250_000)
                _ = pressKey("cmd+a", to: a); typeText(v, to: a)
                return done(["note": "直接设置失败，已改为聚焦后打字"])
            }
            return done()
        }
        let act = req["name"] as? String ?? ""
        let full = act.hasPrefix("AX") ? act : "AX" + act
        say("⚙️ 对「\(en.label)」执行 \(act)")
        let r = AXUIElementPerformAction(en.el, full as CFString)
        return r == .success ? done() : ["error": "执行 \(act) 失败（\(r.rawValue)）：看 get_app_state 里这个元素列出的“其他操作”"]

    case "screenshot":
        say("👀 看整个屏幕")
        return screenshot()

    case "click", "move", "drag", "scroll":
        // 坐标操作（后备方案，会动鼠标）。带 app 时坐标是相对那个窗口截图的
        var off = CGPoint.zero
        if let a = app {
            if let f = lastWindowFrame[a.processIdentifier] { off = f.origin }
            if !a.isActive { a.activate(); usleep(300_000) }
        } else if DENIED_BUNDLES.contains(frontmost().1) {
            return ["error": "安全限制：「\(frontmost().0)」在最前面时不允许操作。"]
        }
        func pt(_ xk: String, _ yk: String) -> CGPoint? {
            guard let x = num(req, xk), let y = num(req, yk) else { return nil }
            return CGPoint(x: x + off.x, y: y + off.y)
        }
        switch action {
        case "click":
            guard let p = pt("x", "y") else { return ["error": "缺少 x/y"] }
            let right = (req["button"] as? String) == "right", n = Int(num(req, "count") ?? 1)
            say("🖱 \(right ? "右键点击" : (n >= 2 ? "双击" : "点击")) (\(Int(p.x)), \(Int(p.y)))" + (appName.isEmpty ? "" : " · \(appName)"))
            click(p, right: right, count: n)
        case "move":
            guard let p = pt("x", "y") else { return ["error": "缺少 x/y"] }
            say("🖱 移到 (\(Int(p.x)), \(Int(p.y)))"); glide(to: p)
        case "drag":
            guard let a = pt("x1", "y1"), let b = pt("x2", "y2") else { return ["error": "缺少坐标"] }
            say("🖱 拖动 (\(Int(a.x)), \(Int(a.y))) → (\(Int(b.x)), \(Int(b.y)))"); drag(a, b)
        default:
            let p = pt("x", "y") ?? CGEvent(source: nil)?.location ?? .zero
            let dy = Int(num(req, "dy") ?? 0)
            say(dy >= 0 ? "🖱 往下滚动" : "🖱 往上滚动"); scroll(p, dy, Int(num(req, "dx") ?? 0))
        }
        return done()

    case "type":
        if app == nil, DENIED_BUNDLES.contains(frontmost().1) { return ["error": "安全限制：当前软件不允许输入。"] }
        let t = req["text"] as? String ?? ""
        say("⌨️ 输入：\(clip(t, 24))" + (appName.isEmpty ? "" : " · \(appName)"))
        typeText(t, to: app)
        return done()

    case "key":
        if app == nil, DENIED_BUNDLES.contains(frontmost().1) { return ["error": "安全限制：当前软件不允许按键。"] }
        let c = req["combo"] as? String ?? ""
        say("⌨️ 按键 \(c)" + (appName.isEmpty ? "" : " · \(appName)"))
        if let e = pressKey(c, to: app) { return ["error": e] }
        return done()

    case "apps":
        return ["apps": runningApps()]

    case "open_app":
        guard let a = app else { return ["error": "缺少 app"] }
        say("📂 打开「\(appName)」")
        a.activate()
        return done()

    default:
        return ["error": "不支持的操作：\(action)"]
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
                        let res = workQueue.sync { handle(req) }   // 一次只做一个操作；提示在主线程画
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
var menuToggle: NSMenuItem?
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
        let t = NSMenuItem(title: "暂停（也可按 Esc）", action: #selector(togglePause), keyEquivalent: "")
        t.target = self; menu.addItem(t); menuToggle = t
        let perm = NSMenuItem(title: "检查权限", action: #selector(checkPerms), keyEquivalent: "")
        perm.target = self; menu.addItem(perm)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出（完全关闭电脑控制）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        setIcon(active: false)

        // 第一次运行时弹出系统的授权提示
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }

        // 全局 Esc：立刻暂停
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 && Date() > ignoreEscUntil && !paused { setPaused(true) }
        }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!)
        do {
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = serve
            listener?.start(queue: .global())
            log("启动 v2，端口 \(PORT)")
        } catch { log("端口启动失败：\(error)") }
    }

    @objc func togglePause() { setPaused(!paused) }

    @objc func checkPerms() {
        let a = NSAlert()
        a.messageText = "AGY Mac Control · 权限"
        a.informativeText = "辅助功能（读界面、点按钮、打字）：\(AXIsProcessTrusted() ? "✅ 已允许" : "❌ 未允许")\n"
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
