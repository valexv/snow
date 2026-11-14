import AppKit
import SwiftUI

/// The guest's display. Also takes the keyboard and mouse input for the guest.
struct ScreenView: NSViewRepresentable {
    let model: EmulatorModel
    /// How the display is shown
    var video: VideoSettings
    /// The CRT effect's settings, or nil to show the display without it
    var crtParameters: [Float]?
    /// How many of the emulated screen's pixels there were to the inch, for showing it
    /// at its real size, or nil if it isn't known
    var screenPixelsPerInch: Double?
    /// Width of the strip along the trailing edge that a panel covers. The mouse
    /// there is the panel's, not the guest's.
    var coveredTrailingWidth: CGFloat = 0

    func makeNSView(context: Context) -> EmulatorScreenNSView {
        let view = EmulatorScreenNSView()
        view.model = model
        view.coveredTrailingWidth = coveredTrailingWidth
        view.video = video
        view.crtParameters = crtParameters
        view.screenPixelsPerInch = screenPixelsPerInch
        return view
    }

    func updateNSView(_ view: EmulatorScreenNSView, context: Context) {
        view.model = model
        view.coveredTrailingWidth = coveredTrailingWidth
        view.video = video
        view.crtParameters = crtParameters
        view.screenPixelsPerInch = screenPixelsPerInch
    }
}

final class EmulatorScreenNSView: NSView {
    weak var model: EmulatorModel?
    /// See ScreenView.coveredTrailingWidth
    var coveredTrailingWidth: CGFloat = 0 {
        didSet {
            if coveredTrailingWidth != oldValue {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    /// How the display is shown
    var video = VideoSettings.standard {
        didSet {
            guard video != oldValue else { return }
            if video.scaling != oldValue.scaling || video.integerScaling != oldValue.integerScaling
                || video.physicalSize != oldValue.physicalSize
            {
                window?.invalidateCursorRects(for: self)
                placeScreen()
            }
            needsDraw = true
        }
    }

    /// See ScreenView.crtParameters
    var crtParameters: [Float]? {
        didSet {
            if crtParameters != oldValue {
                needsDraw = true
            }
        }
    }

    /// See ScreenView.screenPixelsPerInch
    var screenPixelsPerInch: Double? {
        didSet {
            if screenPixelsPerInch != oldValue {
                window?.invalidateCursorRects(for: self)
                placeScreen()
            }
        }
    }

    private var displayLink: CADisplayLink?
    private var screenObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// Size of the guest's display in pixels
    private var frameSize = CGSize(width: 512, height: 342)
    /// Nil if Metal isn't available, which every Mac macOS 14 runs on has
    private let renderer = ScreenRenderer()
    /// The size to draw the display at, in pixels
    private var drawableSize = CGSize.zero
    /// The frame, the settings or the size changed since the last draw
    private var needsDraw = false

    private static let hiddenCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        // A display bigger than the view, at its actual size, is cut off at its edges
        layer?.masksToBounds = true
        if let renderer {
            renderer.layer.actions = Self.noAnimations
            layer?.addSublayer(renderer.layer)
        }
    }

    /// The screen moves and resizes with the view, without animating
    private static let noAnimations: [String: any CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "hidden": NSNull(),
    ]

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardown()
        guard let window else { return }

        let link = displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            guard let self, self.capturesKeyboard(event) else { return event }
            self.handleKey(event)
            return nil
        }

        // Keys held down while the window loses focus would otherwise stay down
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.releaseAllInputs()
            }
        }

        // At its real size, the display's size depends on the screen the window is on
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
                self.placeScreen()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private func teardown() {
        displayLink?.invalidate()
        displayLink = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let model else { return }
        model.tick()
        if let frame = model.takeFrame() {
            let size = CGSize(width: Int(frame.width), height: Int(frame.height))
            if size != frameSize {
                frameSize = size
                window?.invalidateCursorRects(for: self)
                placeScreen()
            }
            if renderer?.upload(width: Int(frame.width), height: Int(frame.height), pixels: frame.pixels)
                == true
            {
                needsDraw = true
            }
        }
        // Once per refresh of the screen, however often the frame, the settings or
        // the size changed since the last
        if needsDraw, let renderer {
            needsDraw = !renderer.draw(
                video.scalingAlgorithm, crtParameters: crtParameters, size: drawableSize)
        }
    }

    // MARK: Drawing

    /// Moves and sizes the screen's layer to where the display is drawn. The picture
    /// stretches to fit until the next draw, at the next refresh, renders it at the
    /// new size.
    private func placeScreen() {
        guard let renderer else { return }
        let rect = screenRect
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(
            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        guard renderer.layer.frame != rect || renderer.layer.contentsScale != scale
            || drawableSize != size
        else { return }
        drawableSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = rect
        renderer.layer.contentsScale = scale
        CATransaction.commit()
        needsDraw = true
    }

    override func layout() {
        super.layout()
        placeScreen()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        placeScreen()
    }

    // MARK: Keyboard

    /// Keys go to the guest while the screen has focus, except Control-Command
    /// shortcuts, which are left for the app's menus.
    private func capturesKeyboard(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.isKeyWindow,
            window.firstResponder === self, model?.isRunning == true
        else { return false }
        if event.type != .flagsChanged,
            event.modifierFlags.isSuperset(of: [.control, .command])
        {
            return false
        }
        return true
    }

    private func handleKey(_ event: NSEvent) {
        guard let model, let scancode = Keymap.scancode(forKeyCode: event.keyCode) else { return }
        switch event.type {
        case .keyDown where !event.isARepeat:
            model.key(scancode, down: true)
        case .keyUp:
            model.key(scancode, down: false)
        case .flagsChanged:
            if let down = Keymap.modifierIsDown(event) {
                model.key(scancode, down: down)
            }
        default:
            break
        }
    }

    // MARK: Mouse

    /// Space kept between the guest's display and the edges of the view
    private static let margin: CGFloat = 16

    /// Where the guest's display goes: the view, less the margin around it. Panels
    /// over the view, like the inspector, don't change it.
    private var displayArea: CGRect {
        let area = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        return area.isEmpty ? bounds : area
    }

    /// Points per pixel of the guest's display:
    /// - real size: the size of a pixel of the emulated screen, on the screen the
    ///   window is on. An area too small for it still fits the whole display, made
    ///   smaller.
    /// - scaling off: 1, its actual size
    /// - scaling: as large as fits the display area
    /// - integer scaling: the largest whole number that fits. An area too small for
    ///   the actual size still fits the whole display, made smaller.
    private var displayScale: CGFloat {
        guard frameSize.width > 0, frameSize.height > 0 else { return 1 }
        let area = displayArea
        let fit = min(area.width / frameSize.width, area.height / frameSize.height)
        if video.physicalSize, let emulated = screenPixelsPerInch, emulated > 0,
            let host = hostPointsPerInch
        {
            let real = host / CGFloat(emulated)
            return fit > 0 ? min(real, fit) : real
        }
        guard video.scaling else { return 1 }
        guard fit > 0 else { return 1 }
        if video.integerScaling, fit >= 1 {
            return fit.rounded(.down)
        }
        return fit
    }

    /// How many points there are to the inch on the screen the window is on, from its
    /// physical size, or nil if the screen doesn't say, as some projectors don't
    private var hostPointsPerInch: CGFloat? {
        guard let screen = window?.screen,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber
        else { return nil }
        let millimeters = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        guard millimeters.width > 0 else { return nil }
        // Points, not pixels: the view is laid out in points, whatever the resolution
        return screen.frame.width / (millimeters.width / 25.4)
    }

    /// Where the guest's display is drawn in the view: in the middle of the display
    /// area
    private var screenRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return bounds }
        let scale = displayScale
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        let area = displayArea
        let rect = CGRect(
            x: area.midX - size.width / 2, y: area.midY - size.height / 2,
            width: size.width, height: size.height)
        // On whole pixels, so a whole-number scale maps each of the display's pixels
        // to the same number of the screen's
        return backingAlignedRect(rect, options: .alignAllEdgesNearest)
    }

    /// The part of the view no panel covers
    private var uncoveredRect: CGRect {
        var rect = bounds
        rect.size.width = max(0, rect.width - coveredTrailingWidth)
        return rect
    }

    private func isUncovered(_ event: NSEvent) -> Bool {
        uncoveredRect.contains(convert(event.locationInWindow, from: nil))
    }

    private func sendMousePosition(_ event: NSEvent) {
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let x = ((p.x - rect.minX) / rect.width * frameSize.width).clamped(to: 0...(frameSize.width - 1))
        let y = ((p.y - rect.minY) / rect.height * frameSize.height).clamped(to: 0...(frameSize.height - 1))
        model?.mouseMoved(to: CGPoint(x: x, y: y))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    override func resetCursorRects() {
        // The guest draws its own cursor, except where a panel covers the screen
        let rect = screenRect.intersection(uncoveredRect)
        if !rect.isEmpty {
            addCursorRect(rect, cursor: Self.hiddenCursor)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
        placeScreen()
    }

    override func mouseMoved(with event: NSEvent) {
        // Moving over a panel moves the Mac's pointer, not the guest's. A drag that
        // started on the screen keeps going to the guest.
        if isUncovered(event) {
            sendMousePosition(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        model?.mouseButton(down: true)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        model?.mouseButton(down: false)
    }
}

extension Comparable {
    fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
