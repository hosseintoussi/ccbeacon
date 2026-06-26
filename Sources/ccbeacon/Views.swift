import Cocoa

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

// Draws a filled green circle with a white checkmark via NSBezierPath — avoids NSTextField
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
        // Checkmark in AppKit y-up coords: left-middle → dip → upper-right
        ck.move(to: NSPoint(x: w * 0.22, y: h * 0.46))
        ck.line(to: NSPoint(x: w * 0.42, y: h * 0.26))
        ck.line(to: NSPoint(x: w * 0.78, y: h * 0.66))
        NSColor.white.setStroke()
        ck.stroke()
    }
}
