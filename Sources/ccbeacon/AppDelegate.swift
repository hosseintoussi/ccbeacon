import Cocoa
import CCBeaconCore

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var menuIsOpen = false
    var isMuted = UserDefaults.standard.bool(forKey: "muted")
    // Elapsed-time labels of the currently built menu, by session id — updated in
    // place each tick while the menu is open (rebuilding would close the menu).
    var liveTimeLabels: [String: NSTextField] = [:]
    let menuW: CGFloat = 310
    private let inputColor = NSColor(red: 247/255, green: 144/255, blue: 9/255, alpha: 1)
    private var spinTick = 0
    private let spinChars = ["⣾","⣽","⣻","⢿","⡿","⣟","⣯","⣷"]

    func applicationDidFinishLaunching(_ n: Notification) {
        syncClaudeIntegration()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let initial = loadSessions()
        prevStates = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0.state) })
        watchSessionsDir()
        update()
        // .common mode so the timer keeps firing while the status item menu is open —
        // in .default mode the spinner and elapsed times freeze during menu tracking.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        if menuIsOpen {
            for s in sessions where s.state == "working" || s.state == "waiting" {
                liveTimeLabels[s.id]?.stringValue = fmtElapsed(s.elapsed)
            }
        } else {
            buildMenu(sessions)
        }
    }

    // MARK: Notifications

    func fireNotifications(_ sessions: [Session]) {
        let currentIds = Set(sessions.map { $0.id })
        for session in sessions {
            let prev = prevStates[session.id]
            guard prev != session.state else { continue }
            switch session.state {
            case "waiting":
                let sid = session.id; let tpath = session.transcriptPath
                pendingWaits[sid]?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.pendingWaits.removeValue(forKey: sid)
                    guard loadSessions().first(where: { $0.id == sid })?.state == "waiting" else { return }
                    if !tpath.isEmpty,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: tpath),
                       let mtime = attrs[.modificationDate] as? Date,
                       Date().timeIntervalSince(mtime) < 5 { return }
                    self.playSound("Sosumi")
                }
                pendingWaits[sid] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            case "idle" where prev == "working" || prev == "waiting":
                pendingWaits[session.id]?.cancel(); pendingWaits.removeValue(forKey: session.id)
                playSound("Glass")
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

    // Audio cue only — the visual "notification" is the menu bar icon changing state.
    func playSound(_ name: String) {
        guard !isMuted else { return }
        NSSound(named: name)?.play()
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
                text = "\(spinChars[spinTick]) \(fmtBarTime(longest.elapsed))"
            }
            // Dynamic color: resolves against the menu bar's appearance at draw time,
            // so it stays readable on both dark and light menu bars.
            color = .labelColor
        } else if !justDone.isEmpty {
            text  = ">_ Done"
            color = .systemGreen
        } else {
            text  = ">_"
            color = .labelColor
        }

        button.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    // MARK: Menu

    func buildMenu(_ sessions: [Session]) {
        liveTimeLabels.removeAll()
        let menu   = NSMenu()
        let active = sessions.filter { $0.state == "working" || $0.state == "waiting" }
        let idle   = sessions.filter { $0.state == "idle" }

        menu.addItem(headerItem(active: active, idle: idle))

        if sessions.isEmpty {
            menu.addItem(emptyStateItem())
        } else {
            // Sessions arrive sorted by priority, so idle rows form a trailing block;
            // label it when there are active rows above to separate the two groups.
            var idleLabelInserted = false
            for s in sessions {
                if s.state == "idle" && !active.isEmpty && !idleLabelInserted {
                    menu.addItem(sectionLabel("Idle"))
                    idleLabelInserted = true
                }
                menu.addItem(sessionRow(s))
            }
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
        titleF.frame = NSRect(x: 18, y: (h - 17) / 2, width: menuW - 36, height: 17)
        view.addSubview(titleF)

        let total = active.count + idle.count
        if total > 0 {
            let cntF = lf("\(total) open", size: 11, weight: .regular,
                          color: .secondaryLabelColor, mono: true)
            cntF.alignment = .right
            cntF.frame = NSRect(x: menuW - 94, y: (h - 17) / 2, width: 76, height: 17)
            view.addSubview(cntF)
        }

        let item = NSMenuItem(); item.view = view; return item
    }

    func sectionLabel(_ text: String) -> NSMenuItem {
        let h: CGFloat = 22
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        let f = lf(text.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
        f.frame = NSRect(x: 18, y: 4, width: menuW - 36, height: 14)
        view.addSubview(f)
        let item = NSMenuItem(); item.view = view; return item
    }

    func emptyStateItem() -> NSMenuItem {
        let h: CGFloat = 44
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        let f = lf("No active sessions", size: 12, weight: .regular, color: .secondaryLabelColor)
        f.alignment = .center
        f.frame = NSRect(x: 14, y: (h - 16) / 2, width: menuW - 28, height: 16)
        view.addSubview(f)
        let item = NSMenuItem(); item.view = view; return item
    }

    // Only these two can be focused by tty via AppleScript; rows for other terminals
    // aren't clickable (see canFocus below) rather than guessing and activating the wrong app.
    static let focusableTerminals: Set<String> = ["iTerm2", "Terminal"]

    func canFocus(_ session: Session) -> Bool {
        !session.tty.isEmpty && Self.focusableTerminals.contains(session.terminal)
    }

    func focusTerminalSession(tty: String, terminal: String) {
        // tty is interpolated into AppleScript — accept only a plain device path.
        guard tty.range(of: #"^/dev/tty[A-Za-z0-9]*$"#, options: .regularExpression) != nil else { return }

        let script: String
        switch terminal {
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
        case "Terminal":
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
        default:
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    // Card layout, three lines:
    //   [state icon] project-name ............ elapsed   ← labelColor / secondary (accent when waiting)
    //                ~/path/to/project                    ← secondary
    //                model · in X · out Y · cache Z       ← tertiary mono (the fine print)
    // Hovering a clickable card highlights it and swaps the time for "open ↗".
    func sessionRow(_ session: Session) -> NSMenuItem {
        let isInput   = session.state == "waiting"
        let isRunning = session.state == "working"
        let h: CGFloat = 72
        let view = SessionCardView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        view.style  = isInput ? .waiting : isRunning ? .working : .idle
        view.accent = inputColor

        // Card insets 6/3, inner padding 12 → content spans 18…292.
        let textX: CGFloat  = 40
        let rightW: CGFloat = 76
        let rightX = menuW - 18 - rightW
        let nameY: CGFloat  = h - 27
        let iSz: CGFloat    = 13
        let iconY = nameY + (16 - iSz) / 2

        if isRunning {
            let s = SpinnerView(size: iSz, color: .controlAccentColor)
            s.frame = NSRect(x: 18, y: iconY, width: iSz, height: iSz)
            view.addSubview(s)
        } else if isInput {
            let d = PulseDotView(size: 10, color: inputColor)
            d.frame = NSRect(x: 19.5, y: iconY + 1.5, width: 10, height: 10)
            view.addSubview(d)
        } else {
            view.addSubview(IdleDotView(frame: NSRect(x: 21, y: iconY + 3, width: 7, height: 7)))
        }

        let dir = session.dirName.isEmpty ? session.id : session.dirName
        let nameF = lf(dir, size: 13, weight: .semibold, color: .labelColor)
        nameF.frame = NSRect(x: textX, y: nameY, width: rightX - textX - 8, height: 16)
        view.addSubview(nameF)

        let isIdle = session.state == "idle"
        let timeF = lf(isIdle ? "idle" : fmtElapsed(session.elapsed),
                       size: 11, weight: isInput ? .semibold : .regular,
                       color: isInput ? inputColor : isIdle ? .tertiaryLabelColor : .secondaryLabelColor)
        timeF.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: isInput ? .semibold : .regular)
        timeF.alignment = .right
        timeF.frame = NSRect(x: rightX, y: nameY, width: rightW, height: 16)
        view.addSubview(timeF)
        if !isIdle { liveTimeLabels[session.id] = timeF }

        // Middle line: path on the left, model on the right.
        let modelStr = cleanModel(session.model)
        var pathW = menuW - textX - 18
        if !modelStr.isEmpty {
            let modelF = lf(modelStr, size: 10.5, weight: .regular, color: .tertiaryLabelColor)
            modelF.alignment = .right
            modelF.frame = NSRect(x: menuW - 18 - 100, y: h - 45, width: 100, height: 14)
            view.addSubview(modelF)
            pathW -= 108
        }
        let pathStr = session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if !pathStr.isEmpty {
            let pathF = lf(pathStr, size: 11, weight: .regular, color: .secondaryLabelColor)
            pathF.lineBreakMode = .byTruncatingMiddle  // keep the leaf directory visible
            pathF.frame = NSRect(x: textX, y: h - 45, width: pathW, height: 14)
            view.addSubview(pathF)
        }

        if session.totalTokens > 0 {
            let tok = "in \(fmtK(session.inputTokens)) · out \(fmtK(session.outputTokens)) · cache \(fmtK(session.cacheTokens))"
            let tokF = lf(tok, size: 10, weight: .regular, color: .tertiaryLabelColor, mono: true)
            tokF.frame = NSRect(x: textX, y: h - 62, width: menuW - textX - 18, height: 13)
            view.addSubview(tokF)
        }

        if canFocus(session) {
            let openF = lf("open ↗", size: 11, weight: .semibold,
                           color: isInput ? inputColor : .controlAccentColor)
            openF.alignment = .right
            openF.frame = timeF.frame
            openF.isHidden = true
            view.addSubview(openF)
            view.onHoverChange = { hovering in
                timeF.isHidden = hovering
                openF.isHidden = !hovering
            }
            view.onClick = { [weak self] in
                self?.focusTerminalSession(tty: session.tty, terminal: session.terminal)
            }
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
        UserDefaults.standard.set(isMuted, forKey: "muted")
        buildMenu(loadSessions())
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }
}
