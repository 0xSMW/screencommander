import AppKit
import QuartzCore

/// The cursor art: a neutral glass arrowhead.
///
/// Built from public AppKit only, back to front:
/// - a tight and a soft shadow falling straight down, masked to outside the
///   arrow so they never darken the glass,
/// - an `NSVisualEffectView` (light `.popover` material, behind-window
///   blending) masked to the arrow, so the body is frosted and picks up
///   whatever is underneath,
/// - a faint white body fill, a gradient along the axis that is clear at the
///   tip and near-white at the tail, a shimmer band for the loading state, a
///   thin bright rim with a soft inner glow, and a barely perceptible hairline
///   outside the outline. Sessions after the first get a faint tint in
///   the rim and a soft glow outside the edge. Slot 0 is plain glass.
///
/// Everything sits in one container view that is shifted by the sub-point art
/// offset, squashed around the tip on press, and dimmed when paused.
final class CursorArtView: NSView {
    private let container = NSView()
    private let shadowView = LayerHostingView()
    private let glassView = NSVisualEffectView()
    private let finishView = LayerHostingView()

    private let shadowGroup = CALayer()
    private let tightShadow = CALayer()
    private let softShadow = CALayer()
    private let bodyLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let highlightLayer = CAGradientLayer()
    private let shimmerLayer = CAGradientLayer()
    private let rimLayer = CAShapeLayer()

    /// Arrow outline in container coordinates (y up).
    private let arrowPath: CGPath
    /// Tip in container coordinates.
    private let tip: CGPoint

    init(colorIndex: Int) {
        let size = CursorGeometry.windowSize
        let bounds = CGRect(origin: .zero, size: size)
        tip = CGPoint(x: CursorGeometry.hotspot.x, y: size.height - CursorGeometry.hotspot.y)
        var toView = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: tip.x, ty: tip.y)
        arrowPath = CursorGeometry.arrowPath().copy(using: &toView) ?? CursorGeometry.arrowPath()
        super.init(frame: bounds)

        container.frame = bounds
        container.wantsLayer = true
        addSubview(container)
        for view in [shadowView, glassView, finishView] as [NSView] {
            view.frame = bounds
            container.addSubview(view)
        }

        buildShadow(bounds: bounds)
        buildGlass(size: size)
        buildFinish(tint: CursorPalette.tint(at: colorIndex))
        updateScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    /// Sub-point shift that keeps the tip exact when the window origin is rounded.
    func setArtOffset(_ offset: CGPoint) {
        guard container.frame.origin != offset else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.setFrameOrigin(offset)
        CATransaction.commit()
    }

    func apply(state: CursorState) {
        shimmerLayer.removeAnimation(forKey: "shimmer")
        shimmerLayer.opacity = 0
        let alpha: CGFloat

        switch state {
        case .idle:
            alpha = 1
        case .loading:
            alpha = 1
            shimmerLayer.opacity = 1
            let sweep = CABasicAnimation(keyPath: "locations")
            sweep.fromValue = [-0.6, -0.3, 0.0]
            sweep.toValue = [1.0, 1.3, 1.6]
            sweep.duration = 1.25
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmerLayer.add(sweep, forKey: "shimmer")
        case .paused:
            alpha = 0.42
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            container.animator().alphaValue = alpha
        }
    }

    /// A quick squash around the tip, once per click.
    func press(count: Int) {
        guard let layer = container.layer else {
            return
        }
        // Scale about the tip, whatever anchor AppKit gave the backing layer.
        let anchor = CGPoint(x: layer.anchorPoint.x * layer.bounds.width, y: layer.anchorPoint.y * layer.bounds.height)
        let pivot = CGPoint(x: tip.x - anchor.x, y: tip.y - anchor.y)
        func scaled(_ factor: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
            transform = CATransform3DScale(transform, factor, factor, 1)
            transform = CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
            return NSValue(caTransform3D: transform)
        }

        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [scaled(1), scaled(0.8), scaled(1.04), scaled(1)]
        squash.keyTimes = [0, 0.35, 0.75, 1]
        squash.duration = 0.18
        squash.repeatCount = Float(max(1, count))
        squash.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        layer.add(squash, forKey: "press")
    }

    // MARK: Construction

    /// Shadows fall straight down, no sideways offset, and are masked to
    /// outside the arrow so they never darken the glass.
    private func buildShadow(bounds: CGRect) {
        tightShadow.shadowPath = arrowPath
        tightShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        tightShadow.shadowOpacity = 0.3
        tightShadow.shadowRadius = 0.8
        tightShadow.shadowOffset = CGSize(width: 0, height: -0.6)

        softShadow.shadowPath = arrowPath
        softShadow.shadowColor = CGColor(gray: 0, alpha: 1)
        softShadow.shadowOpacity = 0.14
        softShadow.shadowRadius = 2
        softShadow.shadowOffset = CGSize(width: 0, height: -1.2)

        shadowGroup.frame = bounds
        shadowGroup.addSublayer(softShadow)
        shadowGroup.addSublayer(tightShadow)
        shadowGroup.mask = outsideMask(bounds: bounds)
        shadowView.hostedLayer.addSublayer(shadowGroup)
    }

    /// Frosted body. The appearance is pinned to light so the material looks
    /// the same in light and dark mode and on any background, instead of
    /// turning into a gray slab over white under the dark appearance.
    private func buildGlass(size: CGSize) {
        glassView.appearance = NSAppearance(named: .aqua)
        glassView.material = .popover
        glassView.blendingMode = .behindWindow
        // The presence app is never active; without this the material goes flat.
        glassView.state = .active
        glassView.isEmphasized = false
        let path = arrowPath
        glassView.maskImage = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
    }

    private func buildFinish(tint: CGColor?) {
        let root = finishView.hostedLayer
        let bounds = CGRect(origin: .zero, size: CursorGeometry.windowSize)
        // Gradients run along the arrow's axis, apex to notch, in a square
        // layer so the unit-space gradient is not skewed by the aspect ratio.
        let box = arrowPath.boundingBox
        let side = max(box.width, box.height) + 2
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        let notch = notchPoint
        let start = CGPoint(x: (tip.x - square.minX) / side, y: (tip.y - square.minY) / side)
        let end = CGPoint(x: (notch.x - square.minX) / side, y: (notch.y - square.minY) / side)

        // A faint translucent fill so the body reads as filled glass on dark
        // backgrounds too, not as an outline.
        bodyLayer.path = arrowPath
        bodyLayer.fillColor = CGColor(gray: 1, alpha: 0.1)

        // Volume: clear and see-through toward the tip, near-white toward the tail.
        highlightLayer.frame = square
        highlightLayer.colors = [
            CGColor(gray: 1, alpha: 0.02),
            CGColor(gray: 1, alpha: 0.28),
            CGColor(gray: 1, alpha: 0.7)
        ]
        highlightLayer.locations = [0.1, 0.55, 1]
        highlightLayer.startPoint = start
        highlightLayer.endPoint = end
        highlightLayer.mask = arrowMask(in: square)

        shimmerLayer.frame = square
        shimmerLayer.colors = [
            CGColor(gray: 1, alpha: 0),
            CGColor(gray: 1, alpha: 0.6),
            CGColor(gray: 1, alpha: 0)
        ]
        shimmerLayer.locations = [-0.6, -0.3, 0]
        shimmerLayer.startPoint = start
        shimmerLayer.endPoint = end
        shimmerLayer.opacity = 0
        shimmerLayer.mask = arrowMask(in: square)

        // Thin bright rim on the inside of the outline, with a soft inner
        // glow from its shadow. A centered stroke clipped to the arrow, so it
        // never fattens the silhouette.
        rimLayer.path = arrowPath
        rimLayer.fillColor = nil
        rimLayer.lineWidth = 1.2
        rimLayer.lineJoin = .round
        rimLayer.strokeColor = tint.map { Self.blend(CGColor(gray: 1, alpha: 1), $0, amount: 0.4, alpha: 0.95) }
            ?? CGColor(gray: 1, alpha: 0.95)
        rimLayer.shadowColor = CGColor(gray: 1, alpha: 1)
        rimLayer.shadowOpacity = 0.7
        rimLayer.shadowRadius = 1.4
        rimLayer.shadowOffset = .zero
        rimLayer.mask = arrowMask(in: bounds)

        // A barely perceptible hairline outside the outline. It only registers
        // against white, where the bright glass would otherwise dissolve.
        edgeLayer.path = arrowPath
        edgeLayer.fillColor = nil
        edgeLayer.lineWidth = 0.8
        edgeLayer.lineJoin = .round
        edgeLayer.strokeColor = CGColor(gray: 0, alpha: 0.14)
        edgeLayer.mask = outsideMask(bounds: bounds)

        // Per-session tint: a faint glow just outside the edge. None for slot 0.
        if let tint {
            glowLayer.path = arrowPath
            glowLayer.fillColor = nil
            glowLayer.lineWidth = 1
            glowLayer.strokeColor = tint.copy(alpha: 0.5)
            glowLayer.shadowColor = tint
            glowLayer.shadowOpacity = 0.45
            glowLayer.shadowRadius = 1.2
            glowLayer.shadowOffset = .zero
            glowLayer.mask = outsideMask(bounds: bounds)
            root.addSublayer(glowLayer)
        }

        root.addSublayer(bodyLayer)
        root.addSublayer(highlightLayer)
        root.addSublayer(shimmerLayer)
        root.addSublayer(rimLayer)
        root.addSublayer(edgeLayer)
    }

    /// The tail notch vertex in container coordinates, the far end of the axis.
    private var notchPoint: CGPoint {
        let shape = CursorArrowShape()
        let local = shape.localVertices()[2]
        let placed = local.applying(shape.placementTransform(height: Double(CursorGeometry.arrowHeight)))
        return CGPoint(x: tip.x + placed.x, y: tip.y - placed.y)
    }

    /// Arrow-shaped mask for a layer whose frame is `box`.
    private func arrowMask(in box: CGRect) -> CAShapeLayer {
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let mask = CAShapeLayer()
        mask.path = arrowPath.copy(using: &shift)
        return mask
    }

    /// Everything except the arrow, for a layer framed at the view's bounds.
    private func outsideMask(bounds: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds.insetBy(dx: -8, dy: -8))
        path.addPath(arrowPath)
        mask.path = path
        mask.fillRule = .evenOdd
        return mask
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var layers: [CALayer] = [shadowGroup, tightShadow, softShadow, bodyLayer, edgeLayer, glowLayer, highlightLayer, shimmerLayer, rimLayer]
        layers += layers.compactMap(\.mask)
        layers += [shadowView.hostedLayer, finishView.hostedLayer]
        for layer in layers {
            layer.contentsScale = scale
        }
    }

    private static func blend(_ base: CGColor, _ tint: CGColor, amount: CGFloat, alpha: CGFloat) -> CGColor {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let a = base.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        let b = tint.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [1, 1, 1, 1]
        let mix = { (i: Int) in a[i] + (b[i] - a[i]) * amount }
        return CGColor(srgbRed: mix(0), green: mix(1), blue: mix(2), alpha: alpha)
    }
}

/// A view that owns its layer, so plain Core Animation layers can sit in the
/// view hierarchy next to an `NSVisualEffectView`.
private final class LayerHostingView: NSView {
    let hostedLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = hostedLayer
        wantsLayer = true
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
