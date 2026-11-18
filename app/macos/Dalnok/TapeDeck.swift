// View ▸ Tape Machine (⇧⌘T): Analog Mode's transport, drawn as a two-track studio tape recorder. It is another view
// of the same project and transport: its keys run the same commands as the main window (Play, Record, Cycle, Go to
// Start), rewind and fast-forward really wind the playhead, the reels turn from the real position (ReelModel:
// ω = v / r on a spiral pack), the counter shows the playhead, the VU meters show the master signal the main window
// reads each frame, and the lamps follow the record-armed tracks. It changes nothing in the sound.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

/// What the tape keys do, shared by the Tape Machine window and the tape strip in the control bar, so both behave
/// the same: every key runs the main window's commands; winding moves the real playhead; Stop returns to where
/// playback started.
@MainActor
final class TapeTransport {
    weak var main: MainWindowController?
    private(set) var winding = 0
    private(set) var playStart: Int64 = 0
    private var wasPlaying = false
    private var last = CACurrentMediaTime()
    static let windSpeed = 12.0 // × real time
    init(main: MainWindowController) { self.main = main }
    private var engine: Engine? { main?.session.engine }
    private func command(_ sel: Selector) { if let main { NSApp.sendAction(sel, to: main, from: nil) } }
    func play() { if engine?.isPlaying == false { command(#selector(MainWindowController.togglePlay)) } }
    func pause() { if engine?.isPlaying == true { command(#selector(MainWindowController.togglePlay)) } }
    func stop() {
        guard let e = engine else { return }
        winding = 0
        if e.isRecording { command(#selector(MainWindowController.toggleRecord(_:))) }
        if e.isPlaying { command(#selector(MainWindowController.togglePlay)) }
        e.seek(playStart)
    }
    func returnToZero() { command(#selector(MainWindowController.goToStart)) }
    func record() { command(#selector(MainWindowController.toggleRecord(_:))) }
    func loop() { command(#selector(MainWindowController.toggleCycle(_:))) }
    func beginWind(_ d: Int) {
        if engine?.isRecording == true { return NSSound.beep() }
        pause()
        winding = d
    }
    func endWind() { winding = 0 }
    /// Winds while a key is held and notes where playback started. Safe to call from several views each frame:
    /// it measures its own time step.
    func advance(dt explicit: Double? = nil) {
        let now = CACurrentMediaTime(), dt = explicit ?? min(0.1, now - last)
        last = now
        guard let e = engine else { return }
        if winding != 0 {
            let next = max(0, Double(e.position) + Double(winding) * Self.windSpeed * dt * e.sampleRate)
            e.seek(Int64(next))
            if next == 0 { winding = 0 }
        }
        if e.isPlaying && !wasPlaying { playStart = e.position }
        wasPlaying = e.isPlaying
    }
    /// For tests: wind as if a key were held for `seconds`.
    func wind(_ d: Int, seconds: Double) { winding = d; advance(dt: seconds); winding = 0 }
}

/// Warm Analog: the tape transport in the control bar (reels, keys and lamps at the bar's height), so the
/// Tape Machine window is optional.
@MainActor
final class TapeStrip: NSView {
    let reels: TapeReels
    let rtz = DeckKey("RTZ", symbol: "⏮", help: "Return to zero (Return)")
    let rew = DeckKey("REW", symbol: "◀◀", help: "Hold to rewind")
    let ffwd = DeckKey("FF", symbol: "▶▶", help: "Hold to fast-forward")
    let stop = DeckKey("STOP", symbol: "■", help: "Stop and return to where playback started")
    let play = DeckKey("PLAY", symbol: "▶", help: "Play / Pause (Space)")
    let rec = DeckKey("REC", symbol: "●", help: "Record (R)")
    let loop = DeckKey("LOOP", symbol: "↻", help: "Cycle (C)")
    var keys: [DeckKey] { [rtz, rew, ffwd, stop, play, rec, loop] }
    weak var transport: TapeTransport? { didSet { wire() } }

    init(reels: TapeReels) {
        self.reels = reels
        super.init(frame: .zero)
        rec.lampColor = Theme.recordOn
        loop.lampColor = Theme.hex(0xF0B43C)
        rew.momentary = true; ffwd.momentary = true
        let row = NSStackView(views: [reels] + keys)
        row.spacing = 3
        row.setCustomSpacing(10, after: reels)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            reels.widthAnchor.constraint(equalToConstant: 104), reels.heightAnchor.constraint(equalToConstant: 42),
        ])
        for k in keys {
            k.translatesAutoresizingMaskIntoConstraints = false
            k.widthAnchor.constraint(equalToConstant: 30).isActive = true
            k.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tape transport")
    }
    required init?(coder: NSCoder) { fatalError() }
    private func wire() {
        rtz.onPress = { [weak self] in self?.transport?.returnToZero() }
        play.onPress = { [weak self] in
            guard let t = self?.transport, let e = t.main?.session.engine else { return }
            e.isPlaying ? t.pause() : t.play()
        }
        stop.onPress = { [weak self] in self?.transport?.stop() }
        rec.onPress = { [weak self] in self?.transport?.record() }
        loop.onPress = { [weak self] in self?.transport?.loop() }
        rew.onPress = { [weak self] in self?.transport?.beginWind(-1) }
        ffwd.onPress = { [weak self] in self?.transport?.beginWind(1) }
        rew.onRelease = { [weak self] in self?.transport?.endWind() }
        ffwd.onRelease = { [weak self] in self?.transport?.endWind() }
    }
    /// Lamps follow the real state (called every UI tick).
    func refresh(playing: Bool, recording: Bool, cycle: Bool, winding: Int) {
        play.lit = playing
        rec.lit = recording
        loop.lit = cycle
        rew.lit = winding < 0; ffwd.lit = winding > 0
    }
}

/// A transport key: a lit-cap piano key (momentary for wind keys).
@MainActor
final class DeckKey: NSControl {
    let label: String
    let symbol: String
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }
    var lampColor = Theme.hex(0x67D16F)
    var momentary = false
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    private(set) var pressed = false { didSet { needsDisplay = true } }
    init(_ label: String, symbol: String, help: String) {
        self.label = label; self.symbol = symbol
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label.capitalized)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true; if momentary { onPress?() } }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if momentary { onRelease?() } else if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?(); if momentary { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onRelease?() } }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2).offsetBy(dx: 0, dy: pressed ? 1.5 : 0)
        // Key body: cream plastic with a darker lower lip (shorter when pressed).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: pressed ? 1 : 3), blur: pressed ? 2 : 4, color: NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(Theme.hex(0xD9D0BC).cgColor); ctx.fillPath()
        ctx.restoreGState()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [Theme.hex(0xF4EEE0).cgColor, Theme.hex(0xD3C8B0).cgColor, Theme.hex(0xA79C86).cgColor] as CFArray, locations: [0, 0.7, 1]) {
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
            ctx.restoreGState()
        }
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor); ctx.setLineWidth(0.8)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.strokePath()
        // Lamp window at the top of the key.
        let lamp = r.height < 50 ? CGRect(x: r.midX - 7, y: r.minY + 4, width: 14, height: 4) : CGRect(x: r.midX - 9, y: r.minY + 6, width: 18, height: 5)
        ctx.setFillColor((lit ? lampColor : lampColor.blended(withFraction: 0.82, of: .black) ?? .black).cgColor)
        ctx.fill(lamp)
        if lit {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: lampColor.withAlphaComponent(0.9).cgColor)
            ctx.fill(lamp); ctx.restoreGState()
        }
        let ink = Theme.hex(0x2A2620)
        let sym = symbol as NSString, lab = label as NSString
        let compact = r.height < 50 // the control-bar strip: symbol and lamp only (the name is in the tooltip)
        let sa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: compact ? 10 : 13, weight: .bold), .foregroundColor: ink]
        let la: [NSAttributedString.Key: Any] = [.font: Theme.ui(7.5, .bold), .foregroundColor: ink.withAlphaComponent(0.8), .kern: 0.8]
        let ss = sym.size(withAttributes: sa), ls = lab.size(withAttributes: la)
        if compact {
            sym.draw(at: CGPoint(x: r.midX - ss.width / 2, y: r.minY + 13), withAttributes: sa)
        } else {
            sym.draw(at: CGPoint(x: r.midX - ss.width / 2, y: r.minY + 15), withAttributes: sa)
            lab.draw(at: CGPoint(x: r.midX - ls.width / 2, y: r.maxY - ls.height - 4), withAttributes: la)
        }
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(2)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1, dy: -1), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.strokePath()
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { _ = accessibilityPerformPress() } else { super.keyDown(with: event) }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

/// The machine's top plate: reels, tape path, heads, capstan, counter and lamps.
@MainActor
final class TapeDeckView: NSView {
    weak var main: MainWindowController?
    var session: Session? { main?.session }
    private(set) var model = ReelModel()
    let leftVU = NeedleMeter(), rightVU = NeedleMeter()
    let keys: [DeckKey]
    let rtz = DeckKey("RTZ", symbol: "⏮", help: "Return to zero: the playhead goes to the start (Return)")
    let rew = DeckKey("REWIND", symbol: "◀◀", help: "Hold to wind backwards")
    let ffwd = DeckKey("F.FWD", symbol: "▶▶", help: "Hold to wind forwards")
    let stop = DeckKey("STOP", symbol: "■", help: "Stop and return to where playback started")
    let pause = DeckKey("PAUSE", symbol: "❚❚", help: "Pause here (the playhead stays)")
    let play = DeckKey("PLAY", symbol: "▶", help: "Play (Space)")
    let rec = DeckKey("REC", symbol: "●", help: "Record on the armed tracks (R)")
    let loop = DeckKey("LOOP", symbol: "↻", help: "Cycle on or off (C)")
    let speedSwitch = NSSegmentedControl(labels: ["7½", "15", "30"], trackingMode: .selectOne, target: nil, action: nil)
    /// The shared key behaviour (also used by the control bar's tape strip).
    var transport: TapeTransport? { main?.tapeTransport }
    /// While a wind key is held: −1 rewind, +1 fast forward.
    var winding: Int { transport?.winding ?? 0 }
    var playStartForTests: Int64 { transport?.playStart ?? 0 }
    private var last = CACurrentMediaTime()
    private var link: CADisplayLink?
    static let windSpeed = TapeTransport.windSpeed
    var counterText = "00:00.0"

    override init(frame: NSRect) {
        keys = [rtz, rew, ffwd, stop, pause, play, rec, loop]
        super.init(frame: frame)
        wantsLayer = true
        rec.lampColor = Theme.recordOn
        loop.lampColor = Theme.hex(0xF0B43C)
        for k in keys { addSubview(k) }
        rew.momentary = true; ffwd.momentary = true
        rtz.onPress = { [weak self] in self?.transport?.returnToZero() }
        play.onPress = { [weak self] in self?.transport?.play() }
        pause.onPress = { [weak self] in self?.transport?.pause() }
        stop.onPress = { [weak self] in self?.transport?.stop() }
        rec.onPress = { [weak self] in self?.transport?.record() }
        loop.onPress = { [weak self] in self?.transport?.loop() }
        rew.onPress = { [weak self] in self?.transport?.beginWind(-1) }
        ffwd.onPress = { [weak self] in self?.transport?.beginWind(1) }
        rew.onRelease = { [weak self] in self?.transport?.endWind() }
        ffwd.onRelease = { [weak self] in self?.transport?.endWind() }
        for m in [leftVU, rightVU] { addSubview(m) }
        speedSwitch.selectedSegment = [0.5, 1, 2].firstIndex(of: Double(UserDefaults.standard.object(forKey: "tapeSpeed") as? Double ?? 1)) ?? 1
        speedSwitch.target = self; speedSwitch.action = #selector(speedChanged)
        speedSwitch.controlSize = .small
        speedSwitch.toolTip = "Tape speed (inches per second): how fast the reels turn and how much tape the project uses. Display only; the sound is unchanged."
        addSubview(speedSwitch)
        speedChanged()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tape machine")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// For tests: wind as if a key were held for `seconds`.
    func wind(_ d: Int, seconds: Double) { transport?.wind(d, seconds: seconds); step(dt: seconds) }
    @objc private func speedChanged() {
        model.speedFactor = [0.5, 1, 2][max(0, speedSwitch.selectedSegment)]
        UserDefaults.standard.set(Double(model.speedFactor), forKey: "tapeSpeed")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func frame(_ l: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.1, now - last)
        last = now
        step(dt: dt)
    }
    /// One frame: wind if a key is held, follow the playhead, refresh lamps and the counter.
    func step(dt: Double) {
        guard let s = session else { return }
        let e = s.engine, sr = e.sampleRate
        transport?.advance()
        let end = s.tracks.flatMap(\.clips).map(\.end).max() ?? 0
        model.length = max(60, Double(end) / sr * 1.1)
        // A wind moves the tape directly (no easing): the reels spin at winding speed.
        let pos = Double(e.position) / sr
        let moved = model.advance(to: pos, dt: dt, reduced: Motion.reduced, windRate: winding != 0 ? 1e9 : 9)
        play.lit = e.isPlaying && !e.isRecording || e.isRecording
        rec.lit = e.isRecording
        loop.lit = s.cycle.on
        pause.lit = !e.isPlaying && e.position != 0
        rew.lit = winding < 0; ffwd.lit = winding > 0
        let t = max(0, pos)
        let text = String(format: "%02d:%02d.%d", Int(t) / 60, Int(t) % 60, Int((t * 10).truncatingRemainder(dividingBy: 10)))
        if moved || text != counterText || armedSignature != lastArmed { counterText = text; lastArmed = armedSignature; needsDisplay = true }
    }
    private var lastArmed = ""
    private var armedSignature: String { (session?.tracks.filter(\.armed).map { "\($0.id)" } ?? []).joined(separator: ",") + "\(session?.engine.isRecording == true)" }

    // MARK: Layout and drawing

    var reelRadius: CGFloat { min(bounds.width * 0.2, bounds.height * 0.3) }
    var leftCenter: CGPoint { CGPoint(x: bounds.width * 0.26, y: reelRadius + 34) }
    var rightCenter: CGPoint { CGPoint(x: bounds.width * 0.74, y: reelRadius + 34) }
    private var scale: CGFloat { reelRadius / ReelModel.full }
    private var plateTop: CGFloat { leftCenter.y + reelRadius + 34 }

    override func layout() {
        super.layout()
        let y = plateTop + 16
        leftVU.frame = CGRect(x: 40, y: y, width: 150, height: 92)
        rightVU.frame = CGRect(x: 198, y: y, width: 150, height: 92)
        let keyW: CGFloat = 54, keyH: CGFloat = 62, gap: CGFloat = 6
        let total = CGFloat(keys.count) * keyW + CGFloat(keys.count - 1) * gap
        let x0 = bounds.width - 40 - total
        for (i, k) in keys.enumerated() { k.frame = CGRect(x: x0 + CGFloat(i) * (keyW + gap), y: y + 40, width: keyW, height: keyH) }
        speedSwitch.frame = CGRect(x: bounds.midX + 100, y: plateTop - 27, width: 120, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Cabinet: walnut cheeks around a brushed, dark-champagne top plate; a darker lower control panel.
        Analog.walnut.setFill(); bounds.fill()
        let plate = bounds.insetBy(dx: 18, dy: 10)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [Theme.hex(0x3A3631).cgColor, Theme.hex(0x2A2724).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: plate.maxY), options: [])
        }
        var rnd = PedalRandom("deck-plate")
        var y = plate.minY
        while y < plateTop { // brushed metal grain
            ctx.setFillColor(NSColor(white: rnd.unit() < 0.5 ? 1 : 0, alpha: rnd.range(0.015, 0.05)).cgColor)
            ctx.fill(CGRect(x: plate.minX, y: y, width: plate.width, height: 0.6)); y += rnd.range(0.6, 1.6)
        }
        let lower = CGRect(x: plate.minX, y: plateTop, width: plate.width, height: plate.maxY - plateTop)
        ctx.setFillColor(Theme.hex(0x1D1B19).cgColor); ctx.fill(lower)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); ctx.fill(CGRect(x: plate.minX, y: plateTop, width: plate.width, height: 1))
        ctx.restoreGState()
        for p in [CGPoint(x: plate.minX + 10, y: plate.minY + 10), CGPoint(x: plate.maxX - 10, y: plate.minY + 10),
                  CGPoint(x: plate.minX + 10, y: plateTop - 10), CGPoint(x: plate.maxX - 10, y: plateTop - 10)] { Analog.screw(ctx, at: p, radius: 3.5) }

        let (rs, rt) = model.radii
        let L = leftCenter, R = rightCenter
        let packL = rs * scale, packR = rt * scale
        // Tape path: supply pack → tension arm roller → guide → heads → capstan/pinch roller → guide → take-up pack.
        let headY = plateTop - 52
        let armL = CGPoint(x: L.x + reelRadius * 0.95, y: headY - 6), armR = CGPoint(x: R.x - reelRadius * 0.95, y: headY - 6)
        let guideL = CGPoint(x: bounds.midX - 120, y: headY), guideR = CGPoint(x: bounds.midX + 130, y: headY)
        let capstan = CGPoint(x: bounds.midX + 92, y: headY)
        let rollerR: CGFloat = 9
        // Supply pack winds off its right side (tape goes clockwise to the arm); take-up winds on its left.
        let tapeColor = Theme.hex(0x7A5236).cgColor
        ctx.setStrokeColor(tapeColor); ctx.setLineWidth(3)
        let t1 = Self.tangent(from: L, packL, to: armL, rollerR, outside: true)
        let t2 = Self.tangent(from: armR, rollerR, to: R, packR, outside: true)
        ctx.move(to: t1.0); ctx.addLine(to: t1.1)
        ctx.move(to: CGPoint(x: armL.x, y: armL.y + rollerR)); ctx.addLine(to: CGPoint(x: guideL.x, y: guideL.y + rollerR))
        ctx.addLine(to: CGPoint(x: guideR.x, y: guideR.y + rollerR))
        ctx.addLine(to: CGPoint(x: armR.x, y: armR.y + rollerR))
        ctx.move(to: t2.0); ctx.addLine(to: t2.1)
        ctx.strokePath()
        // Reels (drawn after the tape so the tape leaves from under the flange).
        reel(ctx, at: L, pack: packL, angle: model.angles.0)
        reel(ctx, at: R, pack: packR, angle: model.angles.1)
        for p in [armL, armR, guideL, guideR] { roller(ctx, p, rollerR) }
        // Head block: erase, record, play heads on a machined plate, under a hinged cover.
        let block = CGRect(x: bounds.midX - 96, y: headY - 34, width: 172, height: 44)
        ctx.setFillColor(Theme.hex(0x15130F).cgColor)
        ctx.addPath(CGPath(roundedRect: block, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        for (i, name) in ["ERASE", "REC", "PLAY"].enumerated() {
            let hx = block.minX + 28 + CGFloat(i) * 52
            let head = CGRect(x: hx - 12, y: headY - 8, width: 24, height: 18)
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor(white: 0.92, alpha: 1).cgColor, NSColor(white: 0.5, alpha: 1).cgColor] as CFArray, locations: [0, 1]) {
                ctx.saveGState(); ctx.addPath(CGPath(roundedRect: head, cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: head.minX, y: head.minY), end: CGPoint(x: head.maxX, y: head.maxY), options: [])
                ctx.restoreGState()
            }
            ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor); ctx.fill(CGRect(x: hx - 0.5, y: head.minY + 2, width: 1, height: head.height - 4))
            let a: [NSAttributedString.Key: Any] = [.font: Theme.ui(6.5, .bold), .foregroundColor: Theme.hex(0xBFB59F), .kern: 0.6]
            let rr = session?.engine.isRecording == true && name == "REC"
            (name as NSString).draw(at: CGPoint(x: hx - (name as NSString).size(withAttributes: a).width / 2, y: block.minY + 4), withAttributes: a)
            if rr { Analog.led(ctx, in: CGRect(x: hx - 3, y: block.minY + 14, width: 6, height: 6), color: Theme.recordOn, lit: true) }
        }
        // Capstan (steel shaft) and the rubber pinch roller pressing the tape against it while playing.
        ctx.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: capstan.x - 4, y: capstan.y + rollerR - 4, width: 8, height: 8))
        let engaged = session?.engine.isPlaying == true
        let pinch = CGPoint(x: capstan.x, y: capstan.y + rollerR + (engaged ? 13 : 22))
        ctx.setFillColor(Theme.hex(0x111111).cgColor); ctx.fillEllipse(in: CGRect(x: pinch.x - 11, y: pinch.y - 11, width: 22, height: 22))
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: pinch.x - 3, y: pinch.y - 3, width: 6, height: 6))
        // Counter: mechanical drum digits in a recessed window.
        let cw = CGRect(x: bounds.midX - 80, y: plateTop - 26, width: 160, height: 22)
        ctx.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: cw, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        let digits: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium), .foregroundColor: Theme.hex(0xF1E9D6)]
        let ds = (counterText as NSString).size(withAttributes: digits)
        (counterText as NSString).draw(at: CGPoint(x: cw.midX - ds.width / 2, y: cw.midY - ds.height / 2), withAttributes: digits)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 0, alpha: 0.6).cgColor, NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.6).cgColor] as CFArray, locations: [0, 0.5, 1]) {
            ctx.saveGState(); ctx.clip(to: cw); ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: cw.minY), end: CGPoint(x: 0, y: cw.maxY), options: []); ctx.restoreGState()
        }
        // Nameplate.
        let np: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Futura-Medium", size: 13) ?? Theme.ui(13, .medium), .foregroundColor: Theme.hex(0xC9BFA8), .kern: 4]
        ("DALNOK  TWO-TRACK" as NSString).draw(at: CGPoint(x: plate.minX + 26, y: plate.minY + 12), withAttributes: np)
        // Track lamps: amber = armed (record ready), red = recording.
        if let s = session {
            let lx0 = 360.0, ly = plateTop + 20
            let la: [NSAttributedString.Key: Any] = [.font: Theme.ui(7, .bold), .foregroundColor: Theme.hex(0xA79C86)]
            ("TRACK READY" as NSString).draw(at: CGPoint(x: lx0, y: ly - 2), withAttributes: la)
            for (i, t) in s.tracks.filter({ !$0.isBus && !$0.isStack }).prefix(16).enumerated() {
                let r = CGRect(x: lx0 + Double(i % 8) * 20, y: ly + 12 + Double(i / 8) * 18, width: 9, height: 9)
                let color = s.engine.isRecording && t.armed ? Theme.recordOn : Theme.hex(0xF0A030)
                Analog.led(ctx, in: r, color: color, lit: t.armed)
                ("\(i + 1)" as NSString).draw(at: CGPoint(x: r.maxX + 1, y: r.minY), withAttributes: la)
            }
        }
        let vu: [NSAttributedString.Key: Any] = [.font: Theme.ui(7, .bold), .foregroundColor: Theme.hex(0xA79C86), .kern: 1]
        ("LEFT" as NSString).draw(at: CGPoint(x: leftVU.frame.midX - 9, y: leftVU.frame.maxY + 3), withAttributes: vu)
        ("RIGHT" as NSString).draw(at: CGPoint(x: rightVU.frame.midX - 11, y: rightVU.frame.maxY + 3), withAttributes: vu)
        ("IPS" as NSString).draw(at: CGPoint(x: speedSwitch.frame.maxX + 6, y: speedSwitch.frame.minY + 6), withAttributes: vu)
    }

    /// An outer tangent between two circles on the same side (the tape leaving one reel or roller for the next).
    static func tangent(from c1: CGPoint, _ r1: CGFloat, to c2: CGPoint, _ r2: CGFloat, outside: Bool) -> (CGPoint, CGPoint) {
        let dx = c2.x - c1.x, dy = c2.y - c1.y, d = max(1e-6, hypot(dx, dy))
        let base = atan2(dy, dx), off = acos(max(-1, min(1, (r1 - r2) / d)))
        let a = base + off // the lower side in a flipped view
        return (CGPoint(x: c1.x + r1 * cos(a), y: c1.y + r1 * sin(a)), CGPoint(x: c2.x + r2 * cos(a), y: c2.y + r2 * sin(a)))
    }

    private func roller(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - r * 0.35, y: c.y - r * 0.35, width: r * 0.7, height: r * 0.7))
    }

    private func reel(_ ctx: CGContext, at c: CGPoint, pack: CGFloat, angle: CGFloat) {
        TapeArt.reel(ctx, at: c, radius: reelRadius, hub: ReelModel.hub * scale, pack: pack, angle: angle)
    }
}

/// Drawing shared by the tape machine window and the tape strip in the control bar.
@MainActor
enum TapeArt {
    /// A metal (NAB-style) reel: oxide tape pack seen through three windows in a brushed aluminium flange.
    static func reel(_ ctx: CGContext, at c: CGPoint, radius R: CGFloat, hub hubR: CGFloat, pack: CGFloat, angle: CGFloat) {
        // Pack: dark oxide with faint winding rings and a satin edge.
        ctx.setFillColor(Theme.hex(0x3B2618).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - pack, y: c.y - pack, width: pack * 2, height: pack * 2))
        ctx.setStrokeColor(Theme.hex(0x6E4A30, 0.45).cgColor); ctx.setLineWidth(0.5)
        var r = hubR + 2
        while r < pack - 1 { ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); r += max(1.2, R / 50) }
        ctx.setStrokeColor(Theme.hex(0x8A6448, 0.8).cgColor); ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: c.x - pack, y: c.y - pack, width: pack * 2, height: pack * 2))
        // Flange with three windows, turning with the reel.
        let flange = CGMutablePath()
        flange.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        for k in 0..<3 {
            let a0 = angle + CGFloat(k) * 2 * .pi / 3 + 0.22, a1 = a0 + 2 * .pi / 3 - 0.44
            let inner = R * 0.36, outer = R * 0.88
            let w = CGMutablePath()
            w.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
            w.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
            w.closeSubpath()
            flange.addPath(w)
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: max(1, R / 40)), blur: max(2, R / 20), color: NSColor(white: 0, alpha: 0.7).cgColor)
        ctx.addPath(flange); ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(flange); ctx.clip(using: .evenOdd)
        // Brushed aluminium: a conic-looking sheen from two linear gradients, fixed to the light (not the reel).
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(white: 0.86, alpha: 1).cgColor, NSColor(white: 0.52, alpha: 1).cgColor, NSColor(white: 0.8, alpha: 1).cgColor, NSColor(white: 0.48, alpha: 1).cgColor] as CFArray,
                              locations: [0, 0.35, 0.6, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - R, y: c.y - R), end: CGPoint(x: c.x + R, y: c.y + R), options: [])
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor); ctx.setLineWidth(0.5)
        var rr = R * 0.2
        while rr < R { ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)); rr += max(1, R / 100) }
        ctx.restoreGState()
        ctx.addPath(flange); ctx.setStrokeColor(NSColor(white: 0.2, alpha: 0.8).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        // Hub: three drive slots and a centre cap.
        let hub = hubR * 0.8
        ctx.setFillColor(NSColor(white: 0.32, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
        ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        for k in 0..<3 {
            let a = angle + CGFloat(k) * 2 * .pi / 3
            let s = max(2, hub * 0.28); ctx.fillEllipse(in: CGRect(x: c.x + cos(a) * hub * 0.62 - s / 2, y: c.y + sin(a) * hub * 0.62 - s / 2, width: s, height: s))
        }
        let cap = max(2.5, hub * 0.35); ctx.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: cap * 2, height: cap * 2))
        ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor); ctx.setLineWidth(1.4)
        ctx.move(to: CGPoint(x: c.x + cos(angle) * cap * 0.75, y: c.y + sin(angle) * cap * 0.75)); ctx.addLine(to: CGPoint(x: c.x - cos(angle) * cap * 0.75, y: c.y - sin(angle) * cap * 0.75)); ctx.strokePath()
    }
}

@MainActor
final class TapeDeckController: NSWindowController, NSWindowDelegate {
    let deck = TapeDeckView()
    init(main: MainWindowController) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Tape Machine"
        w.minSize = NSSize(width: 860, height: 560)
        w.contentAspectRatio = NSSize(width: 980, height: 620)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        super.init(window: w)
        w.delegate = self
        deck.main = main
        w.contentView = deck
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The main window pushes the master levels it reads each frame (meters reset on read).
    func pushMaster(_ l: Float, _ r: Float) {
        guard window?.isVisible == true else { return }
        deck.leftVU.push(l, l); deck.rightVU.push(r, r)
    }
}
