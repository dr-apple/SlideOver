// SlideOver – iPadOS-artiges Slide Over für macOS
// Menüleisten-App: eine beliebige App gleitet als Fenster vom Bildschirmrand herein.
// Position & Größe werden pro App gemerkt; im versteckten/verdeckten Zustand zeigt ein Griff mit Pfeil am Rand.

import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Einstellungen

enum Side: String { case left, right }

/// Gemerkte Fensterlage relativ zum sichtbaren Bildschirmbereich.
/// dx = Abstand zur gewählten Seitenkante, dy = Abstand von oben (AX-Koordinaten).
struct SavedFrame: Codable {
    var side: String
    var dx: Double, dy: Double, w: Double, h: Double
}

struct Prefs {
    static let d = UserDefaults.standard
    static var bundleID: String? {
        get { d.string(forKey: "bundleID") }
        set { d.set(newValue, forKey: "bundleID") }
    }
    static var side: Side {
        get { Side(rawValue: d.string(forKey: "side") ?? "right") ?? .right }
        set { d.set(newValue.rawValue, forKey: "side") }
    }
    static var width: CGFloat {
        get { let w = d.double(forKey: "width"); return w > 0 ? w : 440 }
        set { d.set(Double(newValue), forKey: "width") }
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

    static func frame(for id: String) -> SavedFrame? {
        guard let data = d.data(forKey: "frame." + id) else { return nil }
        return try? JSONDecoder().decode(SavedFrame.self, from: data)
    }
    static func setFrame(_ f: SavedFrame?, for id: String) {
        if let f, let data = try? JSONEncoder().encode(f) { d.set(data, forKey: "frame." + id) }
        else { d.removeObject(forKey: "frame." + id) }
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
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, v)
        }
    }

    static func setSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, v)
        }
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

/// NSScreen-Rechteck (Ursprung unten links) → AX-Koordinaten (Ursprung oben links). Gilt in beide Richtungen.
func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
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

// MARK: - App

final class SlideOverController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = SlideOverController()

    var statusItem: NSStatusItem!
    var isShown = false
    var animTimer: Timer?
    var edgeTimer: Timer?
    var edgeSince: Date?
    var shownScreen: NSScreen?
    var hotKeyRefs: [EventHotKeyRef?] = []
    let handle = HandlePanel()

    let margin: CGFloat = 10

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        registerHotKeys()
        handle.view.onClick = { [weak self] in self?.handleClicked() }

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
            self?.checkEdge()
        }
        updateHandle()
    }

    func updateIcon() {
        let name = Prefs.side == .right ? "sidebar.right" : "sidebar.left"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Slide Over")
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let current = Prefs.bundleID.flatMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }.map { FileManager.default.displayName(atPath: $0.path) } ?? "–"
        let head = NSMenuItem(title: "Slide-Over-App: \(current)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        let t = NSMenuItem(title: visibleNow ? "Ausblenden  (⌃⌥S)" : "Einblenden  (⌃⌥S)",
                           action: #selector(toggle), keyEquivalent: "")
        t.target = self
        t.isEnabled = Prefs.bundleID != nil
        menu.addItem(t)
        menu.addItem(.separator())

        // App-Auswahl
        let pick = NSMenuItem(title: "App wählen", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let it = NSMenuItem(title: app.localizedName ?? "?", action: #selector(pickApp(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = app.bundleIdentifier
            it.state = app.bundleIdentifier == Prefs.bundleID ? .on : .off
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                it.image = icon
            }
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let hint = NSMenuItem(title: "Tipp: ⌃⌥⇧S nimmt die vorderste App", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sub.addItem(hint)
        pick.submenu = sub
        menu.addItem(pick)

        // Seite
        let sideItem = NSMenuItem(title: "Seite", action: nil, keyEquivalent: "")
        let sideMenu = NSMenu()
        for (title, s) in [("Rechts", Side.right), ("Links", Side.left)] {
            let it = NSMenuItem(title: title, action: #selector(pickSide(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = s.rawValue
            it.state = Prefs.side == s ? .on : .off
            sideMenu.addItem(it)
        }
        sideItem.submenu = sideMenu
        menu.addItem(sideItem)

        // Größe
        let widthItem = NSMenuItem(title: "Größe", action: nil, keyEquivalent: "")
        let widthMenu = NSMenu()
        let info = NSMenuItem(title: "Fenster einfach verschieben/ziehen – wird gemerkt", action: nil, keyEquivalent: "")
        info.isEnabled = false
        widthMenu.addItem(info)
        widthMenu.addItem(.separator())
        for (title, w) in [("Schmal (360)", 360.0), ("Mittel (440)", 440.0), ("Breit (560)", 560.0), ("Sehr breit (720)", 720.0)] {
            let it = NSMenuItem(title: title, action: #selector(pickWidth(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = w
            widthMenu.addItem(it)
        }
        widthMenu.addItem(.separator())
        let reset = NSMenuItem(title: "Position & Größe zurücksetzen", action: #selector(resetFrame), keyEquivalent: "")
        reset.target = self
        widthMenu.addItem(reset)
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)

        menu.addItem(.separator())
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
        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "⚠︎ Bedienungshilfen-Zugriff erteilen…", action: #selector(openAXSettings), keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
        }
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func pickApp(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        setTarget(id)
        updateHandle()
    }
    @objc func pickSide(_ s: NSMenuItem) {
        setSide(Side(rawValue: s.representedObject as! String) ?? .right)
    }
    @objc func pickWidth(_ s: NSMenuItem) {
        let w = CGFloat(s.representedObject as! Double)
        Prefs.width = w
        if let id = Prefs.bundleID, var f = Prefs.frame(for: id) {
            f.w = Double(w)
            Prefs.setFrame(f, for: id)
        }
        if visibleNow { show(animated: false) }
    }
    @objc func resetFrame() {
        guard let id = Prefs.bundleID else { return }
        Prefs.setFrame(nil, for: id)
        if visibleNow { show(animated: false) }
        updateHandle()
    }
    @objc func toggleHandle() { Prefs.showHandle.toggle(); updateHandle() }
    @objc func toggleEdge() { Prefs.edgeTrigger.toggle() }
    @objc func toggleAutoHide() { Prefs.autoHide.toggle() }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setTarget(_ id: String) {
        if id != Prefs.bundleID {
            if visibleNow { hide() }
            isShown = false
        }
        Prefs.bundleID = id
        if let f = Prefs.frame(for: id), let s = Side(rawValue: f.side) { Prefs.side = s; updateIcon() }
    }

    func setSide(_ s: Side) {
        Prefs.side = s
        if let id = Prefs.bundleID, var f = Prefs.frame(for: id) {
            f.side = s.rawValue
            Prefs.setFrame(f, for: id)
        }
        updateIcon()
        if visibleNow { show(animated: true) }
        updateHandle()
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
        let defs: [(UInt32, UInt32, UInt32)] = [
            (1, UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey)),             // ⌃⌥S  ein/aus
            (2, UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | shiftKey)),  // ⌃⌥⇧S vorderste App setzen
            (3, UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey)),             // ⌃⌥A  Seite wechseln
        ]
        for (id, key, mods) in defs {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, mods, EventHotKeyID(signature: sig, id: id), GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    func hotKey(_ id: UInt32) {
        switch id {
        case 1: toggle()
        case 2:
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bid = front.bundleIdentifier,
                  bid != Bundle.main.bundleIdentifier else { return }
            setTarget(bid)
            isShown = false
            show(animated: true)
        case 3:
            if visibleNow { saveCurrentFrame() }
            setSide(Prefs.side == .right ? .left : .right)
        default: break
        }
    }

    // MARK: Zustand

    var targetApp: NSRunningApplication? {
        guard let id = Prefs.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first
    }

    /// Slide Over ist eingeblendet und nicht versteckt.
    var visibleNow: Bool {
        guard isShown, let app = targetApp, !app.isHidden else { return false }
        return true
    }

    /// Eingeblendet, aber eine andere App liegt davor.
    var coveredNow: Bool {
        visibleNow && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Prefs.bundleID
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
        let side = Prefs.side
        var w = Prefs.width, h = vis.height - 2 * margin, dx = margin, dy = margin
        if let id = Prefs.bundleID, let f = Prefs.frame(for: id) {
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

    /// Aktuelle Fensterlage merken (wenn das Fenster überwiegend sichtbar ist). Seite wird aus der Lage abgeleitet.
    func saveCurrentFrame() {
        guard let id = Prefs.bundleID, let app = targetApp, !app.isHidden,
              let win = AX.window(of: app), let cur = AX.frame(win) else { return }
        let center = NSPoint(x: cur.midX, y: primaryHeight - cur.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) else { return }
        let vis = flip(screen.visibleFrame)
        let inter = cur.intersection(vis)
        guard !inter.isNull, inter.width >= cur.width * 0.6 else { return } // halb rausgeschoben → nicht merken

        let side: Side = cur.midX < vis.midX ? .left : .right
        let dx = side == .right ? vis.maxX - cur.maxX : cur.minX - vis.minX
        Prefs.setFrame(SavedFrame(side: side.rawValue, dx: Double(max(0, dx)), dy: Double(max(0, cur.minY - vis.minY)),
                                  w: Double(cur.width), h: Double(cur.height)), for: id)
        if side != Prefs.side { Prefs.side = side; updateIcon() }
        shownScreen = screen
    }

    // MARK: Ein-/Ausblenden

    @objc func toggle() {
        if visibleNow && !coveredNow { hide() } else { show(animated: true) }
    }

    func handleClicked() {
        show(animated: true)
    }

    func show(animated: Bool) {
        guard AXIsProcessTrusted() else { openAXSettings(); return }
        guard let id = Prefs.bundleID else { NSSound.beep(); return }

        guard let app = targetApp else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { NSSound.beep(); return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.show(animated: true) }
            }
            return
        }

        let wasVisible = visibleNow
        if wasVisible { saveCurrentFrame() } // z.B. verdeckt → nur nach vorne holen, Lage beibehalten
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
            self.updateHandle()
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
        guard let app = targetApp else { isShown = false; updateHandle(); return }
        saveCurrentFrame()
        isShown = false
        guard let win = AX.window(of: app), let cur = AX.frame(win) else { app.hide(); updateHandle(); return }
        let (_, off) = frames(on: screenForShow())
        animate(win, from: cur.origin, to: CGPoint(x: off.minX, y: cur.minY), duration: 0.18) {
            app.hide()
            self.updateHandle()
        }
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
        let wanted = Prefs.showHandle && targetApp != nil && (!visibleNow || coveredNow)
        guard wanted else { handle.orderOut(nil); return }

        let screen = screenForShow()
        let (on, _) = frames(on: screen)
        let size = handle.frame.size
        let f = screen.frame
        let midY = primaryHeight - on.midY // AX → NS
        let x = Prefs.side == .right ? f.maxX - size.width - 2 : f.minX + 2
        let y = min(max(midY - size.height / 2, screen.visibleFrame.minY + 4), screen.visibleFrame.maxY - size.height - 4)
        handle.view.side = Prefs.side
        handle.setFrameOrigin(NSPoint(x: x, y: y))
        handle.orderFrontRegardless()
    }

    // MARK: Automatik

    @objc func appActivated(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let isTarget = app.bundleIdentifier == Prefs.bundleID
        let isSelf = app.bundleIdentifier == Bundle.main.bundleIdentifier
        if isShown, !isTarget, !isSelf {
            if Prefs.autoHide { hide(); return }
            saveCurrentFrame()
        }
        updateHandle()
    }

    @objc func appStateChanged(_ n: Notification) {
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.bundleIdentifier == Prefs.bundleID,
           n.name == NSWorkspace.didTerminateApplicationNotification || n.name == NSWorkspace.didHideApplicationNotification {
            if animTimer == nil { isShown = false }
        }
        updateHandle()
    }

    @objc func screensChanged() {
        if let s = shownScreen, !NSScreen.screens.contains(s) { shownScreen = nil }
        updateHandle()
    }

    /// Maus ~0,3 s am gewählten Bildschirmrand (nicht in den Ecken) → einblenden.
    func checkEdge() {
        guard Prefs.edgeTrigger, !visibleNow, Prefs.bundleID != nil,
              NSEvent.pressedMouseButtons == 0 else { edgeSince = nil; return }
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { edgeSince = nil; return }
        let f = s.frame
        let atEdge = Prefs.side == .right ? m.x >= f.maxX - 1 : m.x <= f.minX
        let inMiddle = m.y > f.minY + f.height * 0.15 && m.y < f.maxY - f.height * 0.15
        let neighbour = NSScreen.screens.contains { o in
            o != s && (Prefs.side == .right ? abs(o.frame.minX - f.maxX) < 2 : abs(o.frame.maxX - f.minX) < 2)
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

// MARK: - Start

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = SlideOverController.shared
app.run()
