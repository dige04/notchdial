// NotchDial — a half-circle app switcher that drops out of the MacBook notch.
// Knob right = F13, knob left = F14, knob press = F15 (map these in NuPhy Console / VIA).
// Fallback hotkeys: ⌃⌥⌘→ / ⌃⌥⌘← / ⌃⌥⌘↩.
// CLI (while running): NotchDial next | prev | commit | show | reload | quit
// Dev:  NotchDial --render out.png <offset> <reveal> [ring]   ·   NotchDial --demo <framesDir>

import Cocoa
import Carbon.HIToolbox

let kCommand = Notification.Name("dev.notchdial.command")

// MARK: - Config

struct AppItem {
    let name: String
    let url: URL
    let bundleID: String?
    let icon: NSImage
}

enum Config {
    static let dir = ("~/.config/notchdial" as NSString).expandingTildeInPath
    static var file: String { dir + "/config.json" }
    static let defaultApps = ["Finder", "Safari", "Mail", "Calendar", "Notes", "Music", "System Settings"]

    struct File: Codable {
        var apps: [String]
        var commitDelay: Double?
    }

    static func load() -> (items: [AppItem], delay: Double) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: file) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try? enc.encode(File(apps: defaultApps, commitDelay: 0.7)).write(to: URL(fileURLWithPath: file))
        }
        var names = defaultApps
        var delay = 0.7
        if let raw = fm.contents(atPath: file) {
            do {
                let f = try JSONDecoder().decode(File.self, from: raw)
                names = f.apps
                delay = f.commitDelay ?? delay
            } catch {
                NSLog("NotchDial: bad config \(error)")
            }
        }
        return (names.compactMap(resolve), max(0.2, delay))
    }

    /// Accepts an app name ("Google Chrome"), a bundle id ("com.google.Chrome") or a full path.
    static func resolve(_ s: String) -> AppItem? {
        let ws = NSWorkspace.shared
        let fm = FileManager.default
        var url: URL?
        if s.hasPrefix("/") || s.hasPrefix("~") {
            url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        } else if !s.contains(" "), s.split(separator: ".").count >= 3,
                  let u = ws.urlForApplication(withBundleIdentifier: s) {
            url = u
        } else {
            let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                        "/Applications/Utilities", NSHomeDirectory() + "/Applications",
                        "/System/Library/CoreServices"]
            for d in dirs where fm.fileExists(atPath: "\(d)/\(s).app") {
                url = URL(fileURLWithPath: "\(d)/\(s).app")
                break
            }
        }
        guard let u = url, fm.fileExists(atPath: u.path) else {
            NSLog("NotchDial: cannot find app \"\(s)\"")
            return nil
        }
        var name = fm.displayName(atPath: u.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        name = name.replacingOccurrences(of: " (Beta)", with: "")
        let icon = ws.icon(forFile: u.path)
        icon.size = NSSize(width: 128, height: 128)
        return AppItem(name: name, url: u, bundleID: Bundle(url: u)?.bundleIdentifier, icon: icon)
    }
}

// MARK: - Math helpers

@inline(__always) func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
@inline(__always) func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t)
}
@inline(__always) func posMod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
func easeOutBack(_ t: CGFloat) -> CGFloat {
    let c1: CGFloat = 1.15, c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}
func easeInCubic(_ t: CGFloat) -> CGFloat { t * t * t }

// MARK: - Panel

final class DialPanel: NSPanel {
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r } // allow covering the menu bar
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Dial view

final class DialView: NSView {
    var items: [AppItem] = []
    var running: Set<String> = []

    // geometry
    var notchW: CGFloat = 200
    var notchH: CGFloat = 32
    let R: CGFloat = 150          // radius of the bowl
    let fillet: CGFloat = 14      // concave corner where the shape meets the top edge
    let sidePad: CGFloat = 50     // room for the shadow
    let bottomPad: CGFloat = 50
    let step: CGFloat = 0.5       // radians between neighbours
    var iconRadius: CGFloat { R - 42 }

    // animation state
    var offset: CGFloat = 0
    var velocity: CGFloat = 0
    var target: CGFloat = 0
    var reveal: CGFloat = 0
    private var revealFrom: CGFloat = 0
    var revealTo: CGFloat = 0
    private var revealStart: CFTimeInterval = 0
    var lastInput: CFTimeInterval = 0
    var commitDelay: CFTimeInterval = 0.7
    var onHidden: (() -> Void)?

    private var link: CADisplayLink?
    /// injectable clock so the demo renderer can drive animation deterministically
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private var lastTick: CFTimeInterval = 0

    var offscreen = false
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    var preferredSize: NSSize {
        NSSize(width: 2 * (R + fillet + sidePad), height: notchH + R + bottomPad)
    }

    func setReveal(_ to: CGFloat) {
        revealFrom = reveal
        revealTo = to
        revealStart = clock()
        if !offscreen { startLink() }
    }

    func startLink() {
        if link == nil {
            lastTick = 0
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func revealValue(_ now: CFTimeInterval) -> CGFloat {
        let opening = revealTo > revealFrom
        let dur: CGFloat = opening ? 0.46 : 0.26
        let t = clamp01(CGFloat(now - revealStart) / dur)
        let e = opening ? easeOutBack(t) : easeInCubic(t)
        return revealFrom + (revealTo - revealFrom) * e
    }

    @objc private func tick(_ l: CADisplayLink) { advance() }

    func advance() {
        let now = clock()
        var dt = lastTick == 0 ? 1.0 / 120 : now - lastTick
        lastTick = now
        dt = min(dt, 1.0 / 30)

        // slightly under-damped spring for the rotation
        var rest = dt
        while rest > 0 {
            let h = min(rest, 1.0 / 480)
            let a = 320 * (target - offset) - 30 * velocity
            velocity += a * CGFloat(h)
            offset += velocity * CGFloat(h)
            rest -= h
        }
        reveal = revealValue(now)
        needsDisplay = true

        let revealDone = now - revealStart > 0.5
        let springDone = abs(target - offset) < 0.0005 && abs(velocity) < 0.001
        if revealDone && springDone {
            offset = target
            velocity = 0
            if revealTo == 0 {
                reveal = 0
                stopLink()
                onHidden?()
            }
            // while visible keep ticking so the commit ring animates
        }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let e = max(0, reveal)
        if e <= 0.001 { return }

        let cx = bounds.midX
        let cy = notchH
        let startHalf = max(20, notchW / 2 - 8)
        let halfW = startHalf + (R - startHalf) * e
        let rv = max(0.5, R * e)
        let f = fillet * min(1, e * 1.4)

        // --- shape: notch-black slab + half ellipse bowl, with concave top fillets
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: cx - halfW - f, y: 0))
        shape.addQuadCurve(to: CGPoint(x: cx - halfW, y: f), control: CGPoint(x: cx - halfW, y: 0))
        shape.addLine(to: CGPoint(x: cx - halfW, y: max(f, cy)))
        let ellipse = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: halfW, y: rv)
        shape.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true, transform: ellipse)
        shape.addLine(to: CGPoint(x: cx + halfW, y: f))
        shape.addQuadCurve(to: CGPoint(x: cx + halfW + f, y: 0), control: CGPoint(x: cx + halfW, y: 0))
        shape.closeSubpath()

        // shadow + fill
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 34,
                      color: NSColor.black.withAlphaComponent(0.42 * clamp01(e)).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()

        // faint inner light pooling at the bottom of the bowl
        let space = CGColorSpaceCreateDeviceRGB()
        if let glow = CGGradient(colorsSpace: space,
                                 colors: [NSColor(white: 1, alpha: 0.075).cgColor,
                                          NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                 locations: [0, 1]) {
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy + rv), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy + rv), endRadius: R * 0.95,
                                   options: [])
        }

        let ca = clamp01((e - 0.4) / 0.6) // content alpha
        if ca > 0 && !items.isEmpty {
            drawTicks(ctx, cx: cx, cy: cy, alpha: ca)
            drawIcons(ctx, cx: cx, cy: cy, alpha: ca)
        }
        ctx.restoreGState()

        // hairline rim on the bowl
        let rim = CGMutablePath()
        rim.addArc(center: .zero, radius: 1, startAngle: .pi * 0.98, endAngle: .pi * 0.02,
                   clockwise: true, transform: ellipse)
        ctx.saveGState()
        ctx.addPath(rim)
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let rimGrad = CGGradient(colorsSpace: space,
                                    colors: [NSColor(white: 1, alpha: 0).cgColor,
                                             NSColor(white: 1, alpha: 0.16 * clamp01(e)).cgColor] as CFArray,
                                    locations: [0, 1]) {
            ctx.drawLinearGradient(rimGrad, start: CGPoint(x: cx, y: cy), end: CGPoint(x: cx, y: cy + rv), options: [])
        }
        ctx.restoreGState()
    }

    private func point(_ cx: CGFloat, _ cy: CGFloat, _ theta: CGFloat, _ r: CGFloat) -> CGPoint {
        CGPoint(x: cx + r * cos(theta), y: cy + r * sin(theta))
    }

    private func drawTicks(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, alpha: CGFloat) {
        let sub: CGFloat = 4
        let outer = R - 9
        let lo = Int(floor((offset - 4) * sub)), hi = Int(ceil((offset + 4) * sub))
        ctx.setLineCap(.round)
        for k in lo...hi {
            let d = CGFloat(k) / sub - offset
            let theta = .pi / 2 - d * step
            let dev = abs(theta - .pi / 2)
            if dev > .pi / 2 - 0.16 { continue }
            let major = k % Int(sub) == 0
            let len: CGFloat = major ? 6 : 3
            let fade = pow(cos(dev), 2.2)
            ctx.setStrokeColor(NSColor(white: 1, alpha: (major ? 0.42 : 0.2) * fade * alpha).cgColor)
            ctx.setLineWidth(major ? 1.3 : 1)
            ctx.move(to: point(cx, cy, theta, outer))
            ctx.addLine(to: point(cx, cy, theta, outer - len))
            ctx.strokePath()
        }
        // fixed indicator at the bottom
        let ind = CGRect(x: cx - 1.25, y: cy + outer - 13, width: 2.5, height: 7)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.95 * alpha).cgColor)
        ctx.addPath(CGPath(roundedRect: ind, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
        ctx.fillPath()
    }

    private func drawIcons(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, alpha: CGFloat) {
        let n = items.count
        let maxD = min(2.9, CGFloat(n) / 2 - 0.05)
        let r = iconRadius
        let lo = Int(floor(offset - maxD)), hi = Int(ceil(offset + maxD))
        let space = CGColorSpaceCreateDeviceRGB()

        // soft spotlight under the selected slot
        let sel = point(cx, cy, .pi / 2, r)
        if let g = CGGradient(colorsSpace: space,
                              colors: [NSColor(white: 1, alpha: 0.13 * alpha).cgColor,
                                       NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: sel, startRadius: 0, endCenter: sel, endRadius: 50, options: [])
        }

        // draw far icons first so the centre one sits on top
        let ks = (lo...hi).sorted { abs(CGFloat($0) - offset) > abs(CGFloat($1) - offset) }
        for k in ks {
            let d = CGFloat(k) - offset
            if abs(d) > maxD { continue }
            let item = items[posMod(k, n)]
            let theta = .pi / 2 - d * step
            let p = point(cx, cy, theta, r)
            let focus = exp(-d * d * 1.8)
            let size = 32 + 22 * focus
            var a = 1 - smoothstep(maxD - 1.1, maxD, abs(d))
            a *= 0.5 + 0.5 * focus
            a *= alpha
            if a <= 0.01 { continue }
            let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            item.icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: a,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])

            if let bid = item.bundleID, running.contains(bid) {
                // little dot on the inner side of the icon = app is running
                let q = point(cx, cy, theta, r - size / 2 - 5)
                ctx.setFillColor(NSColor(white: 1, alpha: 0.7 * a * (1 - focus)).cgColor)
                ctx.fillEllipse(in: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2))
            }
        }

        // name of the focused app, cross-fading while spinning
        let nearest = Int(offset.rounded())
        let frac = abs(offset - CGFloat(nearest))
        let la = alpha * clamp01(1 - frac * 2.4)
        if la > 0.01 {
            let item = items[posMod(nearest, n)]
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let lift = (1 - la) * 4
            let title = NSAttributedString(string: item.name, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.95 * la),
                .paragraphStyle: para,
            ])
            let isRunning = item.bundleID.map { running.contains($0) } ?? false
            let caption = NSAttributedString(
                string: "\(isRunning ? "Running" : "Launch")  ·  \(posMod(nearest, n) + 1)/\(n)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor(white: 1, alpha: 0.38 * la),
                    .paragraphStyle: para,
                    .kern: 0.3,
                ])
            let th = title.size().height
            let ty = cy + 44 + lift
            title.draw(in: CGRect(x: cx - 100, y: ty, width: 200, height: th))
            caption.draw(in: CGRect(x: cx - 100, y: ty + th + 1, width: 200, height: 14))
        }

        // commit countdown: a thin ring that closes around the focused icon
        if revealTo == 1, lastInput > 0 {
            let t = clamp01(CGFloat((clock() - lastInput) / commitDelay))
            if t > 0.02 && t < 1 {
                let ringR: CGFloat = 31
                let path = CGMutablePath()
                path.addArc(center: sel, radius: ringR, startAngle: -.pi / 2,
                            endAngle: -.pi / 2 + .pi * 2 * t, clockwise: false)
                ctx.addPath(path)
                ctx.setStrokeColor(NSColor(white: 1, alpha: 0.32 * alpha * (1 - t * t)).cgColor)
                ctx.setLineWidth(1.2)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }
    }
}

// MARK: - Controller

final class Controller: NSObject, NSApplicationDelegate {
    var panel: DialPanel!
    var view: DialView!
    var items: [AppItem] = []
    var delay: Double = 0.7
    var commitTimer: Timer?
    var visible = false
    var hotKeyRefs: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        view = DialView(frame: .zero)
        panel = DialPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.onHidden = { [weak self] in
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
        }
        reload()
        registerHotKeys()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(onCommand(_:)), name: kCommand, object: nil,
            suspensionBehavior: .deliverImmediately)
        NSLog("NotchDial ready with \(items.count) apps")
    }

    func reload() {
        let c = Config.load()
        items = c.items
        delay = c.delay
        view.items = items
        view.commitDelay = delay
    }

    @objc func onCommand(_ n: Notification) {
        switch n.object as? String {
        case "next": step(1)
        case "prev": step(-1)
        case "commit": press()
        case "show": if !visible { show(firstStep: 0) }
        case "reload": reload()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    func layoutPanel() {
        let screens = NSScreen.screens
        let screen = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens[0]
        var notchW: CGFloat = 0
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchW = screen.frame.width - l.width - r.width
        }
        view.notchW = notchW > 0 ? notchW : 160
        view.notchH = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 0
        let size = view.preferredSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: false)
        view.frame = NSRect(origin: .zero, size: size)
    }

    func refreshRunning() {
        view.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    func show(firstStep: Int) {
        guard !items.isEmpty else { return }
        layoutPanel()
        refreshRunning()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let base: Int
        if let i = items.firstIndex(where: { $0.bundleID != nil && $0.bundleID == front }) {
            base = i
        } else {
            base = firstStep > 0 ? -1 : 0
        }
        view.offset = CGFloat(base)
        view.target = CGFloat(base)
        view.velocity = 0
        visible = true
        panel.orderFrontRegardless()
        view.setReveal(1)
        scheduleCommit()
    }

    func step(_ d: Int) {
        guard !items.isEmpty else { return }
        if !visible { show(firstStep: d) }
        view.target += CGFloat(d)
        view.startLink()
        scheduleCommit()
    }

    func press() {
        if visible { commit() } else { show(firstStep: 0) }
    }

    func scheduleCommit() {
        commitTimer?.invalidate()
        view.lastInput = CACurrentMediaTime()
        commitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.commit()
        }
    }

    func commit() {
        guard visible, !items.isEmpty else { return }
        commitTimer?.invalidate()
        let item = items[posMod(Int(view.target.rounded()), items.count)]
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: cfg) { app, _ in
            DispatchQueue.main.async { app?.activate(options: [.activateAllWindows]) }
        }
        visible = false
        view.lastInput = 0
        view.setReveal(0)
    }

    // MARK: hotkeys (Carbon — no Accessibility permission needed)

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ud in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let c = Unmanaged<Controller>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async {
                switch hk.id {
                case 1, 4: c.step(1)
                case 2, 5: c.step(-1)
                default: c.press()
                }
            }
            return noErr
        }, 1, &spec, me, nil)

        let hyper = UInt32(controlKey | optionKey | cmdKey)
        let keys: [(UInt32, Int, UInt32)] = [
            (1, kVK_F13, 0), (2, kVK_F14, 0), (3, kVK_F15, 0),
            (4, kVK_RightArrow, hyper), (5, kVK_LeftArrow, hyper), (6, kVK_Return, hyper),
        ]
        for (id, code, mods) in keys {
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: OSType(0x4E44_4C31), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st != noErr { NSLog("NotchDial: hotkey \(id) failed (\(st))") }
            hotKeyRefs.append(ref)
        }
    }
}

// MARK: - main

let args = CommandLine.arguments

/// Debug: render one frame to a PNG on a fake desktop+notch backdrop.
/// NotchDial --render out.png <offset> <reveal> [ringProgress]
func renderPreview(_ out: String, offset: CGFloat, reveal: CGFloat, ring: CGFloat) {
    let v = DialView(frame: .zero)
    v.items = Config.load().items
    v.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    v.notchW = 186; v.notchH = 32
    v.frame = NSRect(origin: .zero, size: v.preferredSize)
    v.offset = offset; v.target = offset; v.reveal = reveal
    v.revealTo = 1
    if ring > 0 { v.commitDelay = 1; v.lastInput = v.clock() - Double(ring) }
    try! renderFrame(v).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

func renderFrame(_ v: DialView) -> NSBitmapImageRep {
    let W = v.bounds.width + 120, H = v.bounds.height + 40
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    // wallpaper
    let grad = NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.45, blue: 0.62, alpha: 1),
                                   NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.55, alpha: 1)])!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -70)
    // menu bar
    NSColor(white: 1, alpha: 0.22).setFill()
    NSRect(x: 0, y: H - 32, width: W, height: 32).fill()
    // notch
    NSColor.black.setFill()
    NSBezierPath(roundedRect: NSRect(x: W / 2 - 93, y: H - 32, width: 186, height: 40), xRadius: 9, yRadius: 9).fill()
    // dial rendered into its own transparent layer, then composited
    let vr = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale),
                              pixelsHigh: Int(v.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    vr.size = v.bounds.size
    let vg = NSGraphicsContext(bitmapImageRep: vr)!
    vg.cgContext.translateBy(x: 0, y: v.bounds.height)
    vg.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: vg.cgContext, flipped: true)
    v.draw(v.bounds)
    NSGraphicsContext.current = g
    vr.draw(in: NSRect(x: (W - v.bounds.width) / 2, y: H - v.bounds.height, width: v.bounds.width, height: v.bounds.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// NotchDial --demo <dir> : render a scripted spin as PNG frames (50 fps) for a GIF/video.
func renderDemo(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var now: CFTimeInterval = 0
    let v = DialView(frame: .zero)
    v.offscreen = true
    v.clock = { now }
    v.items = Config.load().items
    v.running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    v.notchW = 186; v.notchH = 32
    v.frame = NSRect(origin: .zero, size: v.preferredSize)
    v.commitDelay = 0.7
    let fps = 50.0
    // (time, action): +1/-1 = knob tick, 0 = open, 9 = commit
    var script: [(Double, Int)] = [(0.4, 0), (0.75, 1), (1.0, 1), (1.25, 1), (1.9, -1)]
    var lastStep = 0.0
    var frame = 0
    while now < 3.9 {
        if let (t, a) = script.first, now >= t {
            script.removeFirst()
            if a == 0 { v.setReveal(1) } else { v.target += CGFloat(a) }
            v.lastInput = now; lastStep = now
        }
        if v.revealTo == 1, lastStep > 0, now - lastStep >= v.commitDelay, script.isEmpty {
            v.lastInput = 0; v.setReveal(0); lastStep = 0
        }
        v.advance()
        let png = renderFrame(v).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", dir, frame)))
        frame += 1
        now += 1 / fps
    }
}

if args.count >= 3, args[1] == "--demo" { renderDemo(args[2]); exit(0) }

if args.count >= 5, args[1] == "--render" {
    renderPreview(args[2], offset: CGFloat(Double(args[3])!), reveal: CGFloat(Double(args[4])!),
                  ring: args.count > 5 ? CGFloat(Double(args[5])!) : 0)
    exit(0)
}

if args.count > 1 {
    DistributedNotificationCenter.default().postNotificationName(kCommand, object: args[1], userInfo: nil,
                                                                 deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
