// SlideOver – iPadOS-artiges Slide Over für macOS
// Menüleisten-App: je eine App pro Bildschirmseite (links/rechts) gleitet vom Rand herein.
// Position & Größe werden pro Seite und App gemerkt; im versteckten/verdeckten Zustand zeigt ein Griff mit Pfeil am Rand.

import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement

// MARK: - Bei Anmeldung starten

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SlideOver login item: \(error)")
        }
        if on && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Beim allerersten Start (auch nach einem Update von einer älteren Version) einmal aktivieren.
    static func setupDefault() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { set(true) }
    }
}

// MARK: - Einstellungen

enum Side: String, CaseIterable {
    case left, right
    var title: String { self == .left ? "Links" : "Rechts" }
    var key: String { self == .left ? "A" : "S" }
}

/// Gemerkte Fensterlage relativ zum sichtbaren Bildschirmbereich.
/// dx = Abstand zur Seitenkante des Slots, dy = Abstand von oben (AX-Koordinaten).
struct SavedFrame: Codable {
    var side: String?
    var dx: Double, dy: Double, w: Double, h: Double
}

struct Prefs {
    static let d = UserDefaults.standard
    static let defaultWidth: CGFloat = 440

    static func bundleID(_ side: Side) -> String? { d.string(forKey: "app." + side.rawValue) }
    static func setBundleID(_ id: String?, _ side: Side) { d.set(id, forKey: "app." + side.rawValue) }

    static func frame(_ side: Side, _ id: String) -> SavedFrame? {
        guard let data = d.data(forKey: "frame.\(side.rawValue).\(id)") else { return nil }
        return try? JSONDecoder().decode(SavedFrame.self, from: data)
    }
    static func setFrame(_ f: SavedFrame?, _ side: Side, _ id: String) {
        let key = "frame.\(side.rawValue).\(id)"
        if let f, let data = try? JSONEncoder().encode(f) { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
    }

    static var edgeTrigger: Bool {
        get { d.object(forKey: "edgeTrigger") as? Bool ?? true }
        set { d.set(newValue, forKey: "edgeTrigger") }
    }
    static var autoHide: Bool {
        get { d.object(forKey: "autoHide") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoHide") }
    }
    static var showHandle: Bool {
        get { d.object(forKey: "showHandle") as? Bool ?? true }
        set { d.set(newValue, forKey: "showHandle") }
    }

    /// Übernimmt die Einstellungen der Version mit nur einer App.
    static func migrate() {
        guard let old = d.string(forKey: "bundleID") else { return }
        let side = Side(rawValue: d.string(forKey: "side") ?? "right") ?? .right
        if bundleID(side) == nil { setBundleID(old, side) }
        if let data = d.data(forKey: "frame." + old),
           let f = try? JSONDecoder().decode(SavedFrame.self, from: data), f.side == nil || f.side == side.rawValue {
            setFrame(f, side, old)
        }
        for k in ["bundleID", "side", "width", "frame." + old] { d.removeObject(forKey: k) }
    }
}

// MARK: - Accessibility-Helfer

enum AX {
    static func window(of app: NSRunningApplication) -> AXUIElement? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v {
                return (v as! AXUIElement)
            }
        }
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &list) == .success,
           let arr = list as? [AXUIElement], let first = arr.first {
            return first
        }
        return nil
    }

    static func setPosition(_ w: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v) }
    }

    static func setSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v) }
    }

    static func frame(_ w: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func raise(_ w: AXUIElement) {
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }
}

var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// NSScreen-Rechteck (Ursprung unten links) ↔ AX-Koordinaten (Ursprung oben links).
func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

func appName(_ id: String?) -> String {
    guard let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "–" }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

// MARK: - Griff mit Pfeil am Bildschirmrand

final class HandleView: NSView {
    var onClick: (() -> Void)?
    let effect = NSVisualEffectView()
    let arrow = NSImageView()
    var side: Side = .right { didSet { updateArrow() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 7
        effect.layer?.masksToBounds = true
        addSubview(effect)

        arrow.frame = bounds.insetBy(dx: 2, dy: 8)
        arrow.autoresizingMask = [.width, .height]
        arrow.contentTintColor = .labelColor
        arrow.imageScaling = .scaleProportionallyUpOrDown
        addSubview(arrow)
        updateArrow()
        alphaValue = 0.8
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateArrow() {
        let name = side == .right ? "chevron.compact.left" : "chevron.compact.right"
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        arrow.image = NSImage(systemSymbolName: name, accessibilityDescription: "Slide Over einblenden")?
            .withSymbolConfiguration(cfg)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.8 }
}

final class HandlePanel: NSPanel {
    let view = HandleView(frame: NSRect(x: 0, y: 0, width: 18, height: 72))

    init() {
        super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
    }
    override var canBecomeKey: Bool { false }
}

// MARK: - Ein Slide-Over-Platz (links oder rechts)

final class Slot {
    let side: Side
    var isShown = false
    var shownScreen: NSScreen?
    var animTimer: Timer?
    var edgeSince: Date?
    let handle = HandlePanel()
    let margin: CGFloat = 10

    init(side: Side) {
        self.side = side
        handle.view.side = side
        handle.view.onClick = { [weak self] in self?.show(animated: true) }
    }

    var bundleID: String? {
        get { Prefs.bundleID(side) }
        set { Prefs.setBundleID(newValue, side) }
    }

    var app: NSRunningApplication? {
        guard let id = bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// Eingeblendet und nicht versteckt.
    var visibleNow: Bool {
        guard isShown, let app, !app.isHidden else { return false }
        return true
    }

    /// Eingeblendet, aber eine fremde App (nicht die andere Slide-Over-App) liegt davor.
    var coveredNow: Bool {
        guard visibleNow else { return false }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front != bundleID && !SlideOverController.shared.isSlotApp(front)
    }

    // MARK: Geometrie

    func screenForShow() -> NSScreen {
        if let s = shownScreen, NSScreen.screens.contains(s) { return s }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Ziel- und Versteck-Rahmen (AX-Koordinaten) – nutzt die gemerkte Lage, sonst Standard.
    func frames(on screen: NSScreen) -> (on: CGRect, off: CGRect) {
        let vis = flip(screen.visibleFrame)
        let full = flip(screen.frame)
        var w = Prefs.defaultWidth, h = vis.height - 2 * margin, dx = margin, dy = margin
        if let id = bundleID, let f = Prefs.frame(side, id) {
            w = f.w; h = f.h; dx = f.dx; dy = f.dy
        }
        w = min(max(w, 200), vis.width)
        h = min(max(h, 200), vis.height)
        dx = min(max(dx, 0), vis.width - w)
        dy = min(max(dy, 0), vis.height - h)
        let y = vis.minY + dy
        let onX = side == .right ? vis.maxX - w - dx : vis.minX + dx
        let offX = side == .right ? full.maxX + 4 : full.minX - w - 4
        return (CGRect(x: onX, y: y, width: w, height: h), CGRect(x: offX, y: y, width: w, height: h))
    }

    /// Aktuelle Fensterlage merken (nur wenn das Fenster überwiegend sichtbar ist).
    func saveCurrentFrame() {
        guard let id = bundleID, let app, !app.isHidden,
              let win = AX.window(of: app), let cur = AX.frame(win) else { return }
        let center = NSPoint(x: cur.midX, y: primaryHeight - cur.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) else { return }
        let vis = flip(screen.visibleFrame)
        let inter = cur.intersection(vis)
        guard !inter.isNull, inter.width >= cur.width * 0.6 else { return }
        let dx = side == .right ? vis.maxX - cur.maxX : cur.minX - vis.minX
        Prefs.setFrame(SavedFrame(side: side.rawValue, dx: Double(max(0, dx)), dy: Double(max(0, cur.minY - vis.minY)),
                                  w: Double(cur.width), h: Double(cur.height)), side, id)
        shownScreen = screen
    }

    func setWidth(_ w: CGFloat) {
        guard let id = bundleID else { return }
        if visibleNow { saveCurrentFrame() }
        var f = Prefs.frame(side, id) ?? SavedFrame(side: side.rawValue, dx: Double(margin), dy: Double(margin),
                                                    w: Double(w), h: 100_000)
        f.w = Double(w)
        Prefs.setFrame(f, side, id)
        if visibleNow { show(animated: false) }
    }

    func resetFrame() {
        guard let id = bundleID else { return }
        Prefs.setFrame(nil, side, id)
        if visibleNow { show(animated: false) }
        updateHandle()
    }

    // MARK: Ein-/Ausblenden

    func toggle() {
        if visibleNow && !coveredNow && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            hide()
        } else {
            show(animated: true)
        }
    }

    func show(animated: Bool) {
        guard AXIsProcessTrusted() else { SlideOverController.shared.openAXSettings(); return }
        guard let id = bundleID else { NSSound.beep(); return }

        guard let app else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { NSSound.beep(); return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.show(animated: true) }
            }
            return
        }

        let wasVisible = visibleNow
        if wasVisible { saveCurrentFrame() }
        let screen = screenForShow()
        let (on, off) = frames(on: screen)
        let wasHidden = app.isHidden

        app.unhide()
        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + (wasHidden ? 0.08 : 0.0)) {
            guard let win = AX.window(of: app) else {
                if let url = app.bundleURL { NSWorkspace.shared.open(url) }
                return
            }
            let slideIn = animated && !wasVisible
            AX.setSize(win, on.size)
            let start: CGPoint = slideIn ? off.origin : (AX.frame(win)?.origin ?? on.origin)
            if slideIn { AX.setPosition(win, start) }
            AX.raise(win)
            self.isShown = true
            self.shownScreen = screen
            SlideOverController.shared.refresh()
            if animated && start != on.origin {
                self.animate(win, from: start, to: on.origin, duration: 0.22) {
                    AX.setSize(win, on.size) // manche Apps korrigieren die Größe nach dem Verschieben
                    AX.setPosition(win, on.origin)
                }
            } else {
                AX.setPosition(win, on.origin)
            }
        }
    }

    func hide() {
        guard let app else { isShown = false; SlideOverController.shared.refresh(); return }
        saveCurrentFrame()
        isShown = false
        guard !app.isHidden, let win = AX.window(of: app), let cur = AX.frame(win) else {
            app.hide(); SlideOverController.shared.refresh(); return
        }
        let (_, off) = frames(on: screenForShow())
        animate(win, from: cur.origin, to: CGPoint(x: off.minX, y: cur.minY), duration: 0.18) {
            app.hide()
            SlideOverController.shared.refresh()
        }
    }

    /// Slot leeren (z.B. weil die App auf die andere Seite wandert).
    func clear() {
        animTimer?.invalidate(); animTimer = nil
        isShown = false
        bundleID = nil
        updateHandle()
    }

    func animate(_ win: AXUIElement, from: CGPoint, to: CGPoint, duration: Double, done: @escaping () -> Void) {
        animTimer?.invalidate()
        let t0 = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] t in
            let p = min(1, (CACurrentMediaTime() - t0) / duration)
            let e = 1 - pow(1 - p, 3) // ease-out cubic
            AX.setPosition(win, CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e))
            if p >= 1 {
                t.invalidate()
                self?.animTimer = nil
                done()
            }
        }
        animTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Griff

    func updateHandle() {
        let wanted = Prefs.showHandle && app != nil && (!visibleNow || coveredNow)
        guard wanted else { handle.orderOut(nil); return }
        let screen = screenForShow()
        let (on, _) = frames(on: screen)
        let size = handle.frame.size
        let f = screen.frame
        let midY = primaryHeight - on.midY
        let x = side == .right ? f.maxX - size.width - 2 : f.minX + 2
        let y = min(max(midY - size.height / 2, screen.visibleFrame.minY + 4), screen.visibleFrame.maxY - size.height - 4)
        handle.setFrameOrigin(NSPoint(x: x, y: y))
        handle.orderFrontRegardless()
    }

    // MARK: Bildschirmrand

    /// Maus ~0,3 s an dieser Bildschirmkante (nicht in den Ecken) → einblenden.
    func checkEdge(_ m: NSPoint) {
        guard Prefs.edgeTrigger, !visibleNow, bundleID != nil,
              NSEvent.pressedMouseButtons == 0,
              let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { edgeSince = nil; return }
        let f = s.frame
        let atEdge = side == .right ? m.x >= f.maxX - 1 : m.x <= f.minX
        let inMiddle = m.y > f.minY + f.height * 0.15 && m.y < f.maxY - f.height * 0.15
        let neighbour = NSScreen.screens.contains { o in
            o != s && (side == .right ? abs(o.frame.minX - f.maxX) < 2 : abs(o.frame.maxX - f.minX) < 2)
                && o.frame.maxY > m.y && o.frame.minY < m.y
        }
        if atEdge && inMiddle && !neighbour {
            if let since = edgeSince {
                if Date().timeIntervalSince(since) > 0.3 { edgeSince = nil; shownScreen = s; show(animated: true) }
            } else { edgeSince = Date() }
        } else {
            edgeSince = nil
        }
    }
}

// MARK: - Selbst-Update über GitHub Releases

final class Updater: @unchecked Sendable {
    static let repo = "dr-apple/SlideOver"
    static let shared = Updater()

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var auto: Bool {
        get { Prefs.d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { Prefs.d.set(newValue, forKey: "autoUpdate") }
    }
    private(set) var available: (version: String, url: URL)?
    private(set) var busy = false
    private var timer: Timer?

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.check(userInitiated: false) }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check(userInitiated: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do {
                var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                req.setValue("SlideOver-Updater", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    NSLog("SlideOver update check: HTTP \(status) \(String(decoding: data.prefix(300), as: UTF8.self))")
                    throw NSError(domain: "SlideOver", code: status,
                                  userInfo: [NSLocalizedDescriptionKey: "GitHub antwortet mit HTTP \(status)."])
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]],
                      let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                      let urlStr = zip["browser_download_url"] as? String, let url = URL(string: urlStr)
                else { throw NSError(domain: "SlideOver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kein Release gefunden."]) }

                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard Self.isNewer(version, than: current) else {
                    await MainActor.run {
                        self.available = nil
                        if userInitiated { self.alert("SlideOver ist aktuell", "Version \(self.current) ist die neueste.") }
                    }
                    return
                }
                await MainActor.run { self.available = (version, url) }
                if auto || userInitiated { try await install(version: version, from: url) }
            } catch {
                NSLog("SlideOver update failed: \(error)")
                if userInitiated {
                    await MainActor.run { self.alert("Update fehlgeschlagen", error.localizedDescription) }
                }
            }
        }
    }

    func installAvailable() {
        guard let a = available, !busy else { return }
        busy = true
        Task {
            defer { DispatchQueue.main.async { self.busy = false } }
            do { try await install(version: a.version, from: a.url) }
            catch { await MainActor.run { self.alert("Update fehlgeschlagen", error.localizedDescription) } }
        }
    }

    private func install(version: String, from url: URL) async throws {
        let fm = FileManager.default
        let (zipTmp, _) = try await URLSession.shared.download(from: url)
        let dir = fm.temporaryDirectory.appendingPathComponent("SlideOverUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("update.zip")
        try fm.moveItem(at: zipTmp, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw err("Entpacken fehlgeschlagen.") }

        let newApp = dir.appendingPathComponent("SlideOver.app")
        guard let b = Bundle(url: newApp), b.bundleIdentifier == Bundle.main.bundleIdentifier,
              (b.infoDictionary?["CFBundleShortVersionString"] as? String) == version
        else { throw err("Heruntergeladene App ist ungültig.") }

        // Quarantäne entfernen, damit Gatekeeper die selbst gebaute App nicht blockiert
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
        try? xattr.run(); xattr.waitUntilExit()

        let dest = Bundle.main.bundleURL
        _ = try fm.replaceItemAt(dest, withItemAt: newApp)
        Prefs.d.set(true, forKey: "justUpdated")
        Prefs.d.synchronize()

        await MainActor.run {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", dest.path]
            try? relaunch.run()
            NSApp.terminate(nil)
        }
    }

    /// Nach einem Update passt die alte Bedienungshilfen-Freigabe nicht mehr zur neuen Signatur → zurücksetzen,
    /// damit macOS sauber neu fragt.
    static func handlePostUpdate() {
        guard Prefs.d.bool(forKey: "justUpdated") else { return }
        Prefs.d.removeObject(forKey: "justUpdated")
        guard !AXIsProcessTrusted(), let id = Bundle.main.bundleIdentifier else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", id]
        try? p.run(); p.waitUntilExit()
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "SlideOver", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - App

final class SlideOverController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = SlideOverController()

    var statusItem: NSStatusItem!
    var slots: [Side: Slot] = [:]
    var edgeTimer: Timer?
    var hotKeyRefs: [EventHotKeyRef?] = []

    func slot(_ side: Side) -> Slot { slots[side]! }
    func isSlotApp(_ id: String?) -> Bool { id != nil && slots.values.contains { $0.bundleID == id } }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        Prefs.migrate()
        for s in Side.allCases { slots[s] = Slot(side: s) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Updater.handlePostUpdate()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        registerHotKeys()
        Updater.shared.start()
        LoginItem.setupDefault()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            nc.addObserver(self, selector: #selector(appStateChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            let m = NSEvent.mouseLocation
            self?.slots.values.forEach { $0.checkEdge(m) }
        }
        refresh()
    }

    func refresh() {
        let l = slot(.left).bundleID != nil, r = slot(.right).bundleID != nil
        let name = l && r ? "rectangle.split.3x1" : (l ? "sidebar.left" : "sidebar.right")
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Slide Over")
        slots.values.forEach { $0.updateHandle() }
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for side in [Side.left, Side.right] {
            let s = slot(side)
            let head = NSMenuItem(title: "\(side.title): \(appName(s.bundleID))", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)

            let t = NSMenuItem(title: (s.visibleNow ? "Ausblenden" : "Einblenden") + "  (⌃⌥\(side.key))",
                               action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
            t.target = self
            t.representedObject = side.rawValue
            t.isEnabled = s.bundleID != nil
            t.indentationLevel = 1
            menu.addItem(t)

            // App-Auswahl
            let pick = NSMenuItem(title: "App wählen", action: nil, keyEquivalent: "")
            pick.indentationLevel = 1
            let sub = NSMenu()
            for app in running {
                let it = NSMenuItem(title: app.localizedName ?? "?", action: #selector(pickApp(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [side.rawValue, app.bundleIdentifier ?? ""]
                it.state = app.bundleIdentifier == s.bundleID ? .on : .off
                if let other = slots.values.first(where: { $0 !== s && $0.bundleID == app.bundleIdentifier }) {
                    it.title += "  (\(other.side.title.lowercased()))"
                }
                if let icon = app.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    it.image = icon
                }
                sub.addItem(it)
            }
            sub.addItem(.separator())
            let none = NSMenuItem(title: "Keine", action: #selector(pickApp(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = [side.rawValue, ""]
            none.state = s.bundleID == nil ? .on : .off
            sub.addItem(none)
            let hint = NSMenuItem(title: "Tipp: ⌃⌥⇧\(side.key) nimmt die vorderste App", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            pick.submenu = sub
            menu.addItem(pick)

            // Größe
            let sizeItem = NSMenuItem(title: "Größe", action: nil, keyEquivalent: "")
            sizeItem.indentationLevel = 1
            sizeItem.isEnabled = s.bundleID != nil
            let sizeMenu = NSMenu()
            let info = NSMenuItem(title: "Fenster einfach verschieben/ziehen – wird gemerkt", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sizeMenu.addItem(info)
            sizeMenu.addItem(.separator())
            for (title, w) in [("Schmal (360)", 360.0), ("Mittel (440)", 440.0), ("Breit (560)", 560.0), ("Sehr breit (720)", 720.0)] {
                let it = NSMenuItem(title: title, action: #selector(pickWidth(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [side.rawValue, String(w)]
                sizeMenu.addItem(it)
            }
            sizeMenu.addItem(.separator())
            let reset = NSMenuItem(title: "Position & Größe zurücksetzen", action: #selector(resetFrame(_:)), keyEquivalent: "")
            reset.target = self
            reset.representedObject = side.rawValue
            sizeMenu.addItem(reset)
            sizeItem.submenu = sizeMenu
            menu.addItem(sizeItem)
            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: LoginItem.needsApproval ? "Bei Anmeldung starten (in Systemeinstellungen erlauben)"
                                                              : "Bei Anmeldung starten",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.enabled ? .on : (LoginItem.needsApproval ? .mixed : .off)
        menu.addItem(login)

        for (title, sel, on) in [
            ("Pfeil am Rand anzeigen", #selector(toggleHandle), Prefs.showHandle),
            ("Am Bildschirmrand einblenden", #selector(toggleEdge), Prefs.edgeTrigger),
            ("Automatisch ausblenden bei App-Wechsel", #selector(toggleAutoHide), Prefs.autoHide),
        ] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.state = on ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let up = Updater.shared
        let ver = NSMenuItem(title: "SlideOver \(up.current)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        if let a = up.available, !up.auto {
            let inst = NSMenuItem(title: "Update auf \(a.version) installieren", action: #selector(installUpdate), keyEquivalent: "")
            inst.target = self
            menu.addItem(inst)
        }
        let chk = NSMenuItem(title: up.busy ? "Suche nach Updates…" : "Nach Updates suchen…",
                             action: #selector(checkUpdates), keyEquivalent: "")
        chk.target = self
        chk.isEnabled = !up.busy
        menu.addItem(chk)
        let au = NSMenuItem(title: "Automatisch aktualisieren", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        au.target = self
        au.state = up.auto ? .on : .off
        menu.addItem(au)

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠︎ Bedienungshilfen-Zugriff erteilen…", action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleFromMenu(_ s: NSMenuItem) {
        guard let side = Side(rawValue: s.representedObject as? String ?? "") else { return }
        slot(side).toggle()
    }
    @objc func pickApp(_ s: NSMenuItem) {
        guard let v = s.representedObject as? [String], v.count == 2, let side = Side(rawValue: v[0]) else { return }
        assign(v[1].isEmpty ? nil : v[1], to: side, show: false)
    }
    @objc func pickWidth(_ s: NSMenuItem) {
        guard let v = s.representedObject as? [String], v.count == 2, let side = Side(rawValue: v[0]),
              let w = Double(v[1]) else { return }
        slot(side).setWidth(CGFloat(w))
    }
    @objc func resetFrame(_ s: NSMenuItem) {
        guard let side = Side(rawValue: s.representedObject as? String ?? "") else { return }
        slot(side).resetFrame()
    }
    @objc func toggleHandle() { Prefs.showHandle.toggle(); refresh() }
    @objc func toggleEdge() { Prefs.edgeTrigger.toggle() }
    @objc func toggleAutoHide() { Prefs.autoHide.toggle() }
    @objc func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc func installUpdate() { Updater.shared.installAvailable() }
    @objc func toggleAutoUpdate() { Updater.shared.auto.toggle() }
    @objc func toggleLoginItem() {
        if LoginItem.needsApproval { SMAppService.openSystemSettingsLoginItems(); return }
        LoginItem.set(!LoginItem.enabled)
    }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Legt die App für eine Seite fest. Eine App kann nur auf einer Seite liegen.
    func assign(_ id: String?, to side: Side, show: Bool) {
        let s = slot(side)
        if id != s.bundleID {
            if s.visibleNow { s.hide() }
            s.isShown = false
            if let id, let other = slots.values.first(where: { $0 !== s && $0.bundleID == id }) {
                if other.visibleNow { other.saveCurrentFrame() }
                other.clear()
            }
            s.bundleID = id
        }
        refresh()
        if show, id != nil { s.isShown = false; s.show(animated: true) }
    }

    // MARK: Hotkeys (Carbon, keine Extra-Berechtigung nötig)

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { SlideOverController.shared.hotKey(hk.id) }
            return noErr
        }, 1, &spec, nil, nil)

        let sig = OSType(0x534C_4F56) // 'SLOV'
        let ctrlOpt = UInt32(controlKey | optionKey), ctrlOptShift = UInt32(controlKey | optionKey | shiftKey)
        let defs: [(UInt32, UInt32, UInt32)] = [
            (1, UInt32(kVK_ANSI_S), ctrlOpt),       // ⌃⌥S  rechts ein/aus
            (2, UInt32(kVK_ANSI_S), ctrlOptShift),  // ⌃⌥⇧S vorderste App → rechts
            (3, UInt32(kVK_ANSI_A), ctrlOpt),       // ⌃⌥A  links ein/aus
            (4, UInt32(kVK_ANSI_A), ctrlOptShift),  // ⌃⌥⇧A vorderste App → links
        ]
        for (id, key, mods) in defs {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, mods, EventHotKeyID(signature: sig, id: id), GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    func hotKey(_ id: UInt32) {
        let side: Side = id <= 2 ? .right : .left
        if id % 2 == 1 {
            slot(side).toggle()
        } else {
            guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier else { return }
            assign(bid, to: side, show: true)
        }
    }

    // MARK: Automatik

    @objc func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let id = app.bundleIdentifier
        if !isSlotApp(id) && id != Bundle.main.bundleIdentifier {
            for s in slots.values where s.isShown {
                if Prefs.autoHide { s.hide() } else { s.saveCurrentFrame() }
            }
        }
        refresh()
    }

    @objc func appStateChanged(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           n.name == NSWorkspace.didTerminateApplicationNotification || n.name == NSWorkspace.didHideApplicationNotification {
            for s in slots.values where s.bundleID == app.bundleIdentifier && s.animTimer == nil { s.isShown = false }
        }
        refresh()
    }

    @objc func screensChanged() {
        for s in slots.values {
            if let sc = s.shownScreen, !NSScreen.screens.contains(sc) { s.shownScreen = nil }
        }
        refresh()
    }
}

// MARK: - Start

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = SlideOverController.shared
app.run()
