import Cocoa
import CCBeaconCore

// Dev-only: `ccbeacon --snapshot [dir]` renders the dropdown with fixture sessions to
// menu-dark.png / menu-light.png so layout and color changes can be reviewed without
// clicking through the real menu bar.

private final class MenuBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

func renderMenuSnapshots(to dir: String) {
    let delegate = AppDelegate()
    let now = Date().timeIntervalSince1970
    let sessions = [
        Session(id: "s1", state: "waiting", ts: now - 154, cwd: "/Users/dev/code/api-gateway",
                transcriptPath: "", totalTokens: 184_000, inputTokens: 12_400, outputTokens: 8_200,
                cacheTokens: 163_400, model: "claude-opus-4-8", tty: "/dev/ttys004", terminal: "iTerm2"),
        Session(id: "s2", state: "working", ts: now - 2_115, cwd: "/Users/dev/code/ccbeacon",
                transcriptPath: "", totalTokens: 1_432_000, inputTokens: 84_200, outputTokens: 41_700,
                cacheTokens: 1_306_100, model: "claude-fable-5", tty: "/dev/ttys007", terminal: "iTerm2"),
        Session(id: "s3", state: "idle", ts: now - 7_300, cwd: "/Users/dev/code/homebrew-ccbeacon",
                transcriptPath: "", totalTokens: 52_300, inputTokens: 4_100, outputTokens: 2_900,
                cacheTokens: 45_300, model: "claude-sonnet-4-6", tty: "", terminal: ""),
    ]
    let active = sessions.filter { $0.state != "idle" }
    let idle   = sessions.filter { $0.state == "idle" }

    for (suffix, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        var itemViews: [NSView] = [delegate.headerItem(active: active, idle: idle).view!]
        for s in sessions {
            if s.state == "idle" { itemViews.append(delegate.sectionLabel("Idle").view!) }
            itemViews.append(delegate.sessionRow(s).view!)
        }

        let width  = delegate.menuW
        let height = itemViews.reduce(CGFloat(16)) { $0 + $1.frame.height }
        let container = MenuBackdropView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - 8
        for v in itemViews {
            y -= v.frame.height
            v.setFrameOrigin(NSPoint(x: 0, y: y))
            container.addSubview(v)
        }

        let window = NSWindow(contentRect: container.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { continue }
        rep.size = NSSize(width: width, height: height)
        container.cacheDisplay(in: container.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let path = dir + "/menu-\(suffix).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print(path)
        }
    }
}
