import Cocoa
import Foundation

// MARK: - Paths

let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cc-sessions")
let dailyFile   = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/cc-daily.json")

// MARK: - Token cache

private struct TokenSnapshot {
    let input: Int, output: Int, cache: Int, model: String, mtime: Date
}
private var tokenCache: [String: TokenSnapshot] = [:]

func readTokens(_ transcriptPath: String) -> (input: Int, output: Int, cache: Int, model: String) {
    guard !transcriptPath.isEmpty,
          let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
          let mtime = attrs[.modificationDate] as? Date
    else { return (0, 0, 0, "") }

    if let c = tokenCache[transcriptPath], c.mtime == mtime {
        return (c.input, c.output, c.cache, c.model)
    }

    var i = 0, o = 0, c = 0, model = ""
    if let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data  = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (entry["type"] as? String) == "assistant",
                  let msg   = entry["message"] as? [String: Any],
                  let usage = msg["usage"]     as? [String: Any]
            else { continue }
            i += usage["input_tokens"]                 as? Int ?? 0
            o += usage["output_tokens"]                as? Int ?? 0
            c += (usage["cache_creation_input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"]    as? Int ?? 0)
            if model.isEmpty { model = msg["model"] as? String ?? "" }
        }
    }

    tokenCache[transcriptPath] = TokenSnapshot(input: i, output: o, cache: c, model: model, mtime: mtime)
    return (input: i, output: o, cache: c, model: model)
}

// MARK: - Models

struct Session {
    let id: String
    let state: String
    let ts: TimeInterval
    let cwd: String
    let transcriptPath: String
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let cost: Double
    let model: String

    var elapsed: Int { max(0, Int(Date().timeIntervalSince1970 - ts)) }
    var dirName: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? cwd : last
    }
    var priority: Int {
        switch state {
        case "waiting": return 3
        case "working": return 2
        case "done":    return 1
        default:        return 0
        }
    }
}

struct DailyStats {
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let totalCost: Double
    let sessions: Int
}

// MARK: - Loading

func loadSessions() -> [Session] {
    let fm  = FileManager.default
    let now = Date().timeIntervalSince1970
    guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

    return files.compactMap { file -> Session? in
        guard file.hasSuffix(".json") else { return nil }
        let path = (sessionsDir as NSString).appendingPathComponent(file)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let state          = json["state"]           as? String       ?? ""
        let ts             = json["ts"]              as? TimeInterval ?? 0
        let transcriptPath = json["transcript_path"] as? String       ?? ""

        let stale: Bool
        if state == "done" {
            stale = (now - ts) > 14400  // 4 hours — visible in "Earlier today"
        } else if state == "working" {
            if let attrs   = try? fm.attributesOfItem(atPath: transcriptPath),
               let modified = attrs[.modificationDate] as? Date {
                stale = (now - modified.timeIntervalSince1970) > 1800
            } else {
                stale = (now - ts) > 3600
            }
        } else {
            stale = (now - ts) > 14400
        }

        if stale { try? fm.removeItem(atPath: path); return nil }

        let tok = readTokens(transcriptPath)
        return Session(
            id:             json["session_id"]    as? String ?? file,
            state:          state,
            ts:             ts,
            cwd:            json["cwd"]           as? String ?? "",
            transcriptPath: transcriptPath,
            totalTokens:    tok.input + tok.output + tok.cache,
            inputTokens:    tok.input,
            outputTokens:   tok.output,
            cacheTokens:    tok.cache,
            cost:           0,
            model:          tok.model
        )
    }.sorted { $0.priority > $1.priority }
}

func loadDailyStats() -> DailyStats? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: dailyFile)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let today = _dateFmt.string(from: Date())
    guard (json["date"] as? String) == today else { return nil }

    return DailyStats(
        totalTokens:  json["total_tokens"]  as? Int    ?? 0,
        inputTokens:  json["input_tokens"]  as? Int    ?? 0,
        outputTokens: json["output_tokens"] as? Int    ?? 0,
        cacheTokens:  json["cache_tokens"]  as? Int    ?? 0,
        totalCost:    json["total_cost"]    as? Double ?? 0,
        sessions:     json["sessions"]      as? Int    ?? 0
    )
}

// MARK: - Helpers

private let _numFmt: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; return f
}()

private let _dateFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
}()

func fmtElapsed(_ s: Int) -> String {
    if s < 60   { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

func fmtK(_ n: Int) -> String {
    if n == 0           { return "0" }
    if n < 1_000        { return "\(n)" }
    if n < 1_000_000    { return String(format: "%.1fk", Double(n) / 1_000) }
    return String(format: "%.2fM", Double(n) / 1_000_000)
}

func fmtFull(_ n: Int) -> String { _numFmt.string(from: NSNumber(value: n)) ?? "\(n)" }

// M:SS clock for the menu bar button (0:47, 2:14, 1:23 for hours as H:MM)
func fmtClock(_ s: Int) -> String {
    if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
    return String(format: "%d:%02d", s / 3600, (s % 3600) / 60)
}

func cleanModel(_ m: String) -> String { m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m }

// MARK: - Animated indicator views

class SpinnerView: NSView {
    private let arcColor: NSColor
    init(size: CGFloat, color: NSColor = .systemBlue) {
        arcColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard window != nil else { return }
        let sz = bounds.width
        let arc = CAShapeLayer()
        // Frame must match parent so anchorPoint (0.5,0.5) lands at the center of the view.
        // Without this the rotation pivots around (0,0) — the corner — not the center.
        arc.frame = CGRect(x: 0, y: 0, width: sz, height: sz)
        let path = CGMutablePath()
        // 240° arc (4π/3) leaves a clear 120° gap so it reads as a spinner, not a full ring.
        path.addArc(center: CGPoint(x: sz/2, y: sz/2), radius: sz/2 - 1.5,
                    startAngle: 0, endAngle: .pi * 4/3, clockwise: false)
        arc.path = path; arc.fillColor = nil
        arc.strokeColor = arcColor.cgColor; arc.lineWidth = 2; arc.lineCap = .round
        layer?.addSublayer(arc)
        let rot = CABasicAnimation(keyPath: "transform.rotation.z")
        rot.fromValue = 0; rot.toValue = Double.pi * 2
        rot.duration = 0.85; rot.repeatCount = .infinity
        arc.add(rot, forKey: "spin")
    }
}

class PulseDotView: NSView {
    private let dotColor: NSColor
    init(size: CGFloat, color: NSColor = .systemOrange) {
        dotColor = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard window != nil else { return }
        let sz = bounds.width
        let dot = CAShapeLayer()
        // Same fix: frame must be set so scale animation expands from center, not corner.
        dot.frame = CGRect(x: 0, y: 0, width: sz, height: sz)
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: sz, height: sz), transform: nil)
        dot.fillColor = dotColor.cgColor
        layer?.addSublayer(dot)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.75, 1.0] as [NSNumber]
        scale.keyTimes = [0, 0.5, 1] as [NSNumber]
        scale.duration = 1.4; scale.repeatCount = .infinity
        dot.add(scale, forKey: "pulse")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 0.4, 1.0] as [NSNumber]
        fade.keyTimes = [0, 0.5, 1] as [NSNumber]
        fade.duration = 1.4; fade.repeatCount = .infinity
        dot.add(fade, forKey: "fade")
    }
}

// Draws a filled green circle with a white checkmark via AppKit — avoids NSTextField
// vertical-centering issues that leave the ✓ glyph floating off-center.
class DoneCircleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let ck = NSBezierPath()
        ck.lineWidth = 1.6
        ck.lineCapStyle  = .round
        ck.lineJoinStyle = .round
        let w = bounds.width, h = bounds.height
        // Checkmark in AppKit y-up coords: left-middle → dip (low) → upper-right
        ck.move(to: NSPoint(x: w * 0.22, y: h * 0.46))
        ck.line(to: NSPoint(x: w * 0.42, y: h * 0.26))
        ck.line(to: NSPoint(x: w * 0.78, y: h * 0.66))
        NSColor.white.setStroke()
        ck.stroke()
    }
}

// MARK: - AppDelegate

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

        let waiting = sessions.filter { $0.state == "waiting" }
        let working = sessions.filter { $0.state == "working" }
        let justDone = sessions.filter { $0.state == "done" && (now - $0.ts) < 10 }

        let text: String
        let color: NSColor

        if !waiting.isEmpty {
            // Amber glyph + count, pulse by alternating opacity each tick
            let alpha: CGFloat = (spinTick % 2 == 0) ? 1.0 : 0.45
            text  = "✦ \(waiting.count)"
            color = NSColor.systemOrange.withAlphaComponent(alpha)
        } else if !working.isEmpty {
            // Blue spinner + M:SS; for multiple: N · M:SS
            let longest = working.max(by: { $0.elapsed < $1.elapsed })!
            let prefix  = working.count > 1 ? "\(working.count) · " : ""
            text  = "\(spinChars[spinTick]) \(prefix)\(fmtClock(longest.elapsed))"
            color = NSColor.white.withAlphaComponent(0.75)
        } else if !justDone.isEmpty {
            // Brief green flash (≤10s after Stop)
            text  = "✦ done"
            color = .systemGreen
        } else {
            // Idle — glyph at readable opacity
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

        menu.delegate  = self
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

        let titleF = lf("ccbeacon", size: 13, weight: .bold, color: .labelColor)
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

        // Summary using attributed string with colored dots
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

        // Input: orange tint + left stripe
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

        // Icon (centered vertically)
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

        // Content (icon col = 14+13+8 = 35px offset, 14px right pad)
        let cx: CGFloat = 35; let cw: CGFloat = menuW - cx - 14

        // Line 1: name (left) + time/status (right)
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

        // Line 2: model · path
        let modelStr = cleanModel(session.model)
        let pathStr  = session.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let mp = [modelStr, pathStr].filter { !$0.isEmpty }.joined(separator: " · ")
        if !mp.isEmpty {
            let mpF = lf(mp, size: 11, weight: .regular, color: .tertiaryLabelColor)
            mpF.frame = NSRect(x: cx, y: h - 41, width: cw, height: 15)
            view.addSubview(mpF)
        }

        // Line 3: token counts
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

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
