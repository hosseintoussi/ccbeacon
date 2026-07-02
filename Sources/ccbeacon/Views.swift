import Cocoa

// Rounded "card" behind each session row — the separation between sessions comes from
// these insets, not from separators. All fills are resolved in draw(_:) so they adapt
// to the menu's effective appearance (light/dark) automatically.
final class SessionCardView: NSView {
    enum Style { case waiting, working, idle }

    var style: Style = .idle
    var accent: NSColor = .controlAccentColor  // wash color for .waiting
    var onClick: (() -> Void)? { didSet { updateTrackingAreas() } }
    var onHoverChange: ((Bool) -> Void)?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard onClick != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true;  needsDisplay = true; onHoverChange?(true) }
    override func mouseExited(with event: NSEvent)  { hovered = false; needsDisplay = true; onHoverChange?(false) }
    // cursorUpdate (instead of push/pop) lets AppKit restore the arrow cursor itself.
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return }
        onClick()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8)
        let fill: NSColor?
        switch style {
        case .waiting: fill = accent.withAlphaComponent(hovered ? 0.18 : 0.11)
        case .working: fill = NSColor.labelColor.withAlphaComponent(hovered ? 0.09 : 0.05)
        case .idle:    fill = hovered ? NSColor.labelColor.withAlphaComponent(0.07) : nil
        }
        if let fill { fill.setFill(); card.fill() }
    }
}

// Small status dot for idle rows — drawn (not a layer color snapshot) so it follows
// the menu's appearance.
final class IdleDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

class SpinnerView: NSView {
    private let arcColor: NSColor
    init(size: CGFloat, color: NSColor = .controlAccentColor) {
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
        // Frame must match parent so anchorPoint (0.5,0.5) lands at center, not corner.
        arc.frame = CGRect(x: 0, y: 0, width: sz, height: sz)
        let path = CGMutablePath()
        // 240° arc leaves a clear gap so it reads as a spinner, not a full ring.
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
        // Frame must be set so scale animation expands from center, not corner.
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
