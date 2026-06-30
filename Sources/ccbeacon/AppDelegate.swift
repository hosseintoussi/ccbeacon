import Cocoa
import CCBeaconCore

private final class ClickableRowView: NSView {
    var onClick: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.push() }
    override func mouseExited(with event: NSEvent)  { NSCursor.pop() }

    override func mouseDown(with event: NSEvent) {
        NSCursor.pop()
        onClick?()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var menuIsOpen = false
    var isMuted = false
    private let menuW: CGFloat = 310
    private let inputColor = NSColor(red: 247/255, green: 144/255, blue: 9/255, alpha: 1)
    private var spinTick = 0
    private let spinChars = ["⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initial = loadSessions()
        prevStates = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.state) })
        watchSessionsDir()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    // MARK: File watching

    func watchSessionsDir() {
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        let fd = open(sessionsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.update() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src

    }

    // MARK: Update cycle

    func update() {
        let sessions = loadSessions()
        fireNotifications(sessions)
        updateButton(sessions)
        if !menuIsOpen { buildMenu(sessions) }
    }

    // MARK: Notifications

    func fireNotifications(_ sessions: [Session]) {
        let currentIds = Set(sessions.map { $0.id })
        for session in sessions {
            let prev = prevStates[session.id]
            guard prev != session.state else { continue }
            switch session.state {
            case "waiting":
                let sid = session.id; let dir = session.dirName; let tpath = session.transcriptPath
                pendingWaits[sid]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingWaits.removeValue(forKey: sid)
                    guard loadSessions().first(where: { $0.id == sid })?.state == "waiting" else { return }
                    if !tpath.isEmpty,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: tpath),
                       let mtime = attrs[.modificationDate] as? Date,
                       Date().timeIntervalSince(mtime) < 5 { return }
                    self.osxNotify("Claude needs input", body: dir, sound: "Sosumi")
                }
                pendingWaits[sid] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            case "idle" where prev == "working" || prev == "waiting":
                pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                osxNotify("Claude finished", body: session.dirName, sound: "Glass")
            default:
                if prev == "waiting" {
                    pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                }
            }
        }
        for id in pendingWaits.keys where !currentIds.contains(id) {
            pendingWaits[id]?.cancel(); pendingWaits.removeValue(forKey: id)
        }
        prevStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
    }

    func osxNotify(_ title: String, body: String, sound: String) {
        guard !isMuted else { return }
        NSSound(named: sound)?.play()
    }

    // MARK: Button

    func updateButton(_ sessions: [Session]) {
        guard let button = statusItem.button else { return }
        spinTick = (spinTick + 1) % spinChars.count
        let now = Date().timeIntervalSince1970

        let waiting  = sessions.filter { $0.state == "waiting" }
        let working  = sessions.filter { $0.state == "working" }
        let justDone = sessions.filter { $0.state == "idle" && (now - $0.ts) < 10 }

        let text: String
        let color: NSColor

        if !waiting.isEmpty {
            let alpha: CGFloat = (spinTick % 2 == 0) ? 1.0 : 0.45
            text  = ">_ \(waiting.count)"
            color = inputColor.withAlphaComponent(alpha)
        } else if !working.isEmpty {
            if working.count > 1 {
                text = "\(spinChars[spinTick]) \(working.count) sessions"
            } else {
                let longest = working.max(by: { $0.elapsed < $1.elapsed })!
                text = "\(spinChars[spinTick]) \(fmtClock(longest.elapsed))"
            }
            color = NSColor.white.withAlphaComponent(0.75)
        } else if !justDone.isEmpty {
            text  = ">_ Done"
            color = .systemGreen
        } else {
            text  = ">_"
            color = NSColor.white.withAlphaComponent(0.75)
        }

        button.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    // MARK: Menu

    func buildMenu(_ sessions: [Session]) {
        let menu   = NSMenu()
        let active = sessions.filter { $0.state == "working" || $0.state == "waiting" }
        let idle   = sessions.filter { $0.state == "idle" }

        menu.addItem(headerItem(active: active, idle: idle))

        if sessions.isEmpty {
            menu.addItem(emptyStateItem())
        } else {
            for s in sessions { menu.addItem(sessionRow(s)) }
        }

        menu.addItem(.separator())

        let muteItem = NSMenuItem(
            title: isMuted ? "Unmute sounds" : "Mute sounds",
            action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        muteItem.image = NSImage(systemSymbolName: isMuted ? "speaker.wave.2" : "speaker.slash",
                                 accessibilityDescription: nil)
        menu.addItem(muteItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)
        menu.addItem(quitItem)

        menu.delegate   = self
        statusItem.menu = menu
    }

    // MARK: Menu item factories

    func lf(_ text: String, size: CGFloat, weight: NSFont.Weight,
            color: NSColor, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                      : NSFont.systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    func headerItem(active: [Session], idle: [Session]) -> NSMenuItem {
        let h: CGFloat = 44
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))

        let titleAttr = NSMutableAttributedString(
            string: ">_",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                         .foregroundColor: NSColor.labelColor])
        titleAttr.append(NSAttributedString(
            string: "  ccbeacon",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                         .foregroundColor: NSColor.labelColor]))
        titleAttr.append(NSAttributedString(
            string: "  \(appVersion)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        if isDevBuild {
            titleAttr.append(NSAttributedString(
                string: "  dev",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                             .foregroundColor: NSColor.systemOrange]))
        }
        let titleF = NSTextField(labelWithString: "")
        titleF.attributedStringValue = titleAttr
        titleF.frame = NSRect(x: 14, y: (h - 17) / 2, width: menuW - 28, height: 17)
        view.addSubview(titleF)

        let total = active.count + idle.count
        if total > 0 {
            let cntF = lf("\(total) open", size: 11, weight: .regular,
                          color: .tertiaryLabelColor, mono: true)
            cntF.alignment = .right
            cntF.frame = NSRect(x: menuW - 90, y: (h - 17) / 2, width: 76, height: 17)
            view.addSubview(cntF)
        }

        let item = NSMenuItem(); item.view = view; return item
    }

    func sectionLabel(_ text: String) -> NSMenuItem {
        let h: CGFloat = 24
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        let f = lf(text.uppercased(), size: 10, weight: .semibold, color: .tertiaryLabelColor)
        f.frame = NSRect(x: 14, y: 5, width: menuW - 28, height: 14)
        view.addSubview(f)
        let item = NSMenuItem(); item.view = view; return item
    }

    func emptyStateItem() -> NSMenuItem {
        let h: CGFloat = 44
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        let f = lf("No active sessions", size: 12, weight: .regular, color: .tertiaryLabelColor)
        f.alignment = .center
        f.frame = NSRect(x: 14, y: (h - 16) / 2, width: menuW - 28, height: 16)
        view.addSubview(f)
        let item = NSMenuItem(); item.view = view; return item
    }

    func focusTerminalSession(tty: String, terminal: String) {
        let app: String
        if !terminal.isEmpty {
            app = terminal
        } else if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty {
            app = "iTerm2"
        } else {
            app = "Terminal"
        }

        let script: String
        switch app {
        case "iTerm2":
            script = """
            tell application \"iTerm2\"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is \"\(tty)\" then
                                activate
                                select w
                                tell t to select
                                tell s to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            script = """
            tell application \"Terminal\"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \"\(tty)\" then
                            activate
                            set selected tab of w to t
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    func sessionRow(_ session: Session) -> NSMenuItem {
        let isInput   = session.state == "waiting"
        let isRunning = session.state == "working"
        let isIdle    = session.state == "idle"
        let hasTTY    = !session.tty.isEmpty
        let h: CGFloat = 88
        let view: NSView
        if hasTTY {
            let cv = ClickableRowView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
            cv.onClick = { [weak self] in self?.focusTerminalSession(tty: session.tty, terminal: session.terminal) }
            view = cv
        } else {
            view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        }

        let accentColor: NSColor? = isInput ? inputColor : isRunning ? .systemBlue : nil
        if let color = accentColor {
            let tint = NSView(frame: view.bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
            view.addSubview(tint)
            let stripe = NSView(frame: NSRect(x: 0, y: 0, width: 2.5, height: h))
            stripe.wantsLayer = true
            stripe.layer?.backgroundColor = color.cgColor
            view.addSubview(stripe)
        }

        let iSz: CGFloat = 13; let iX: CGFloat = 14; let iCY = h / 2
        if isRunning {
            let s = SpinnerView(size: iSz, color: .systemBlue)
            s.frame = NSRect(x: iX, y: iCY - iSz/2, width: iSz, height: iSz)
            view.addSubview(s)
        } else if isInput {
            let d = PulseDotView(size: iSz)
            d.frame = NSRect(x: iX, y: iCY - iSz/2, width: iSz, height: iSz)
            view.addSubview(d)
        } else if isIdle {
            let dot = NSView(frame: NSRect(x: iX + 2, y: iCY - 4, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            view.addSubview(dot)
        }

        let cx: CGFloat = 35; let cw: CGFloat = menuW - cx - 14

        let dir = session.dirName.isEmpty ? session.id : session.dirName
        let nameF = lf(dir, size: 12.5, weight: .semibold, color: .labelColor)
        nameF.frame = NSRect(x: cx, y: h - 26, width: cw * 0.62, height: 16)
        view.addSubview(nameF)

        if hasTTY {
            let iconSz: CGFloat = 13
            let img = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
            let iconV = NSImageView(image: img ?? NSImage())
            iconV.contentTintColor = accentColor ?? .labelColor
            iconV.frame = NSRect(x: menuW - 14 - iconSz, y: h - 26 + (16 - iconSz) / 2, width: iconSz, height: iconSz)
            view.addSubview(iconV)
        } else {
            var rText = fmtElapsed(session.elapsed)
            var rColor = NSColor.secondaryLabelColor
            var rMono  = true
            let rWeight = NSFont.Weight.regular
            if isIdle {
                rText = "idle"; rColor = .tertiaryLabelColor; rMono = false
            }
            let timeF = lf(rText, size: 11, weight: rWeight, color: rColor, mono: rMono)
            timeF.alignment = .right
            timeF.frame = NSRect(x: cx + cw * 0.62, y: h - 26, width: cw * 0.38, height: 16)
            view.addSubview(timeF)
        }

        let modelStr = cleanModel(session.model)
        let pathStr  = session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        if !modelStr.isEmpty {
            let modelF = lf(modelStr, size: 11, weight: .regular, color: .tertiaryLabelColor)
            modelF.frame = NSRect(x: cx, y: 44, width: cw, height: 14)
            view.addSubview(modelF)
        }

        if !pathStr.isEmpty {
            let pathF = lf(pathStr, size: 10.5, weight: .regular, color: .tertiaryLabelColor)
            pathF.frame = NSRect(x: cx, y: 26, width: cw, height: 14)
            view.addSubview(pathF)
        }

        if session.totalTokens > 0 {
            let tok = "in \(fmtK(session.inputTokens)) · out \(fmtK(session.outputTokens)) · cache \(fmtK(session.cacheTokens))"
            let tokF = lf(tok, size: 10, weight: .regular, color: .tertiaryLabelColor, mono: true)
            tokF.frame = NSRect(x: cx, y: 8, width: cw, height: 14)
            view.addSubview(tokF)
        }

        let item = NSMenuItem()
        item.view = view
        return item
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        buildMenu(loadSessions())
    }

    @objc func toggleMute() {
        isMuted = !isMuted
        buildMenu(loadSessions())
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}
