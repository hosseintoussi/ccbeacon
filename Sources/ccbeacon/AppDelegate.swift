import Cocoa
import CCBeaconCore

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var watcher: DispatchSourceFileSystemObject?
    var prevStates: [String: String] = [:]
    var pendingWaits: [String: DispatchWorkItem] = [:]
    var menuIsOpen = false
    var isMuted = false
    private let menuW: CGFloat = 310
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
            case "done" where prev == "working" || prev == "waiting":
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
        let justDone = sessions.filter { $0.state == "done" && (now - $0.ts) < 10 }

        let text: String
        let color: NSColor

        if !waiting.isEmpty {
            let alpha: CGFloat = (spinTick % 2 == 0) ? 1.0 : 0.45
            text  = "✦ \(waiting.count)"
            color = NSColor.systemOrange.withAlphaComponent(alpha)
        } else if !working.isEmpty {
            let longest = working.max(by: { $0.elapsed < $1.elapsed })!
            let prefix  = working.count > 1 ? "\(working.count) · " : ""
            text  = "\(spinChars[spinTick]) \(prefix)\(fmtClock(longest.elapsed))"
            color = NSColor.white.withAlphaComponent(0.75)
        } else if !justDone.isEmpty {
            text  = "✦ done"
            color = .systemGreen
        } else {
            text  = "✦"
            color = NSColor.white.withAlphaComponent(0.75)
        }

        button.attributedTitle = NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    // MARK: Menu

    func buildMenu(_ sessions: [Session]) {
        let menu   = NSMenu()
        let active = sessions.filter { $0.state != "done" }
        let done   = sessions.filter { $0.state == "done" }

        menu.addItem(headerItem(active: active, done: done))
        menu.addItem(.separator())

        if !active.isEmpty {
            menu.addItem(sectionLabel("Active"))
            for s in active { menu.addItem(sessionRow(s)) }
        }
        if !done.isEmpty {
            if !active.isEmpty { menu.addItem(.separator()) }
            menu.addItem(sectionLabel("Earlier today"))
            for s in done { menu.addItem(sessionRow(s)) }
        }
        if active.isEmpty && done.isEmpty {
            menu.addItem(emptyRow())
        }

        if let d = loadDailyStats() {
            menu.addItem(.separator())
            menu.addItem(dailyRow(d))
        }

        menu.addItem(.separator())

        let muteItem = NSMenuItem(
            title: isMuted ? "Unmute sounds" : "Mute sounds",
            action: #selector(toggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
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

    func headerItem(active: [Session], done: [Session]) -> NSMenuItem {
        let h: CGFloat = 68
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))

        let titleAttr = NSMutableAttributedString(
            string: "ccbeacon",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                         .foregroundColor: NSColor.labelColor])
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
        titleF.frame = NSRect(x: 14, y: h - 28, width: menuW - 28, height: 17)
        view.addSubview(titleF)

        let total = active.count + done.count
        if total > 0 {
            let cntF = lf("\(total) active", size: 11, weight: .regular,
                          color: .tertiaryLabelColor, mono: true)
            cntF.alignment = .right
            cntF.frame = NSRect(x: menuW - 90, y: h - 28, width: 76, height: 17)
            view.addSubview(cntF)
        }

        let running   = active.filter { $0.state == "working" }.count
        let waiting   = active.filter { $0.state == "waiting" }.count
        let doneCount = done.count
        let attr = NSMutableAttributedString()
        let bodyA: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        func appendDot(_ count: Int, _ label: String, _ col: NSColor) {
            if attr.length > 0 {
                attr.append(NSAttributedString(string: "   ", attributes: bodyA))
            }
            attr.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: col]))
            attr.append(NSAttributedString(string: "\(count) \(label)", attributes: bodyA))
        }
        if running   > 0 { appendDot(running,   "running",     .systemBlue) }
        if waiting   > 0 { appendDot(waiting,   "needs input", .systemOrange) }
        if doneCount > 0 { appendDot(doneCount, "done",        .systemGreen) }

        if attr.length > 0 {
            let sf = NSTextField(labelWithString: "")
            sf.attributedStringValue = attr
            sf.frame = NSRect(x: 14, y: 10, width: menuW - 28, height: 16)
            view.addSubview(sf)
        } else {
            let ef = lf("No sessions", size: 11.5, weight: .regular, color: .tertiaryLabelColor)
            ef.frame = NSRect(x: 14, y: 10, width: menuW - 28, height: 16)
            view.addSubview(ef)
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

    func sessionRow(_ session: Session) -> NSMenuItem {
        let isInput   = session.state == "waiting"
        let isRunning = session.state == "working"
        let isDone    = session.state == "done"
        let h: CGFloat = 66
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))

        if isInput {
            let tint = NSView(frame: view.bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
            view.addSubview(tint)
            let stripe = NSView(frame: NSRect(x: 0, y: 0, width: 2.5, height: h))
            stripe.wantsLayer = true
            stripe.layer?.backgroundColor = NSColor.systemOrange.cgColor
            view.addSubview(stripe)
        }

        let iSz: CGFloat = 13; let iX: CGFloat = 14; let iCY = h / 2
        if isRunning {
            let s = SpinnerView(size: iSz, color: .secondaryLabelColor)
            s.frame = NSRect(x: iX, y: iCY - iSz/2, width: iSz, height: iSz)
            view.addSubview(s)
        } else if isInput {
            let d = PulseDotView(size: iSz)
            d.frame = NSRect(x: iX, y: iCY - iSz/2, width: iSz, height: iSz)
            view.addSubview(d)
        } else if isDone {
            let circ = DoneCircleView(frame: NSRect(x: iX, y: iCY - iSz/2, width: iSz, height: iSz))
            view.addSubview(circ)
        }

        let cx: CGFloat = 35; let cw: CGFloat = menuW - cx - 14

        let dir = session.dirName.isEmpty ? session.id : session.dirName
        let nameF = lf(dir, size: 12.5, weight: .semibold, color: .labelColor)
        nameF.frame = NSRect(x: cx, y: h - 24, width: cw * 0.62, height: 16)
        view.addSubview(nameF)

        var rText = fmtElapsed(session.elapsed)
        var rColor = NSColor.secondaryLabelColor
        var rMono = true
        var rWeight = NSFont.Weight.regular
        if isInput {
            rText = "needs input"; rColor = .systemOrange; rMono = false; rWeight = .semibold
        } else if isDone {
            rText = "\(fmtElapsed(session.elapsed)) ago"; rColor = .systemGreen
        }
        let timeF = lf(rText, size: 11, weight: rWeight, color: rColor, mono: rMono)
        timeF.alignment = .right
        timeF.frame = NSRect(x: cx + cw * 0.62, y: h - 24, width: cw * 0.38, height: 16)
        view.addSubview(timeF)

        let modelStr = cleanModel(session.model)
        let pathStr  = session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let mp = [modelStr, pathStr].filter { !$0.isEmpty }.joined(separator: " · ")
        if !mp.isEmpty {
            let mpF = lf(mp, size: 11, weight: .regular, color: .tertiaryLabelColor)
            mpF.frame = NSRect(x: cx, y: h - 41, width: cw, height: 15)
            view.addSubview(mpF)
        }

        if session.totalTokens > 0 {
            let tok = "in \(fmtK(session.inputTokens)) · out \(fmtK(session.outputTokens)) · cache \(fmtK(session.cacheTokens))"
            let tokF = lf(tok, size: 10.5, weight: .regular, color: .tertiaryLabelColor, mono: true)
            tokF.frame = NSRect(x: cx, y: h - 57, width: cw, height: 14)
            view.addSubview(tokF)
        }

        let item = NSMenuItem(); item.view = view; return item
    }

    func emptyRow() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: 36))
        let f = lf("No active sessions", size: 12, weight: .regular, color: .tertiaryLabelColor)
        f.alignment = .center
        f.frame = NSRect(x: 14, y: 10, width: menuW - 28, height: 16)
        view.addSubview(f)
        let item = NSMenuItem(); item.view = view; return item
    }

    func dailyRow(_ d: DailyStats) -> NSMenuItem {
        let h: CGFloat = 32
        let view = NSView(frame: NSRect(x: 0, y: 0, width: menuW, height: h))
        let leftF = lf("Today · \(d.sessions) session\(d.sessions == 1 ? "" : "s")",
                       size: 11.5, weight: .regular, color: .secondaryLabelColor)
        leftF.frame = NSRect(x: 14, y: 8, width: 150, height: 16)
        view.addSubview(leftF)
        let tok = "in \(fmtK(d.inputTokens)) · out \(fmtK(d.outputTokens)) · cache \(fmtK(d.cacheTokens))"
        let rightF = lf(tok, size: 10.5, weight: .regular, color: .tertiaryLabelColor, mono: true)
        rightF.alignment = .right
        rightF.frame = NSRect(x: 160, y: 8, width: menuW - 174, height: 16)
        view.addSubview(rightF)
        let item = NSMenuItem(); item.view = view; return item
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
