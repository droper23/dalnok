// The Inspector's Clip section (Logic's Region Inspector): the selected clip's name, place and length, and its
// settings — gain, transpose, fades, loop and mute — edited in place, each change one undo step.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

final class ClipInspector: NSStackView {
    let session: Session
    var positionText: (Int64) -> String = { "\($0)" }
    var clip: DalnokClipId? { didSet { reload() } }

    let head = PanelHead("Clip")
    let name = NSTextField(labelWithString: "")
    let place = NSTextField(labelWithString: "")
    let gain = NSSlider(value: 0, minValue: -24, maxValue: 24, target: nil, action: nil)
    let gainValue = NSTextField(labelWithString: "")
    let transpose = NSStepper()
    let transposeValue = NSTextField(labelWithString: "")
    let fadeIn = NSTextField(string: ""), fadeOut = NSTextField(string: "")
    let loop = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    let mute = NSButton(checkboxWithTitle: "Mute", target: nil, action: nil)
    let follow = NSButton(checkboxWithTitle: "Follow Tempo", target: nil, action: nil)
    private var fadeRow: NSView!
    private var gainRow: NSView!

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clip")
        name.font = Theme.ui(12, .semibold); name.textColor = Theme.text; name.lineBreakMode = .byTruncatingTail
        place.font = Theme.mono(10); place.textColor = Theme.textDim
        for f in [gainValue, transposeValue] { f.font = Theme.mono(10); f.textColor = Theme.textDim; f.alignment = .right }
        gain.controlSize = .small
        gain.target = self; gain.action = #selector(gainMoved(_:)); gain.isContinuous = true
        gain.setAccessibilityLabel("Clip gain"); gain.toolTip = "Clip gain, before the track's fader (double-click the value to reset)"
        transpose.minValue = -24; transpose.maxValue = 24; transpose.increment = 1; transpose.valueWraps = false
        transpose.target = self; transpose.action = #selector(transposed(_:))
        transpose.setAccessibilityLabel("Transpose"); transpose.toolTip = "Transpose in semitones (MIDI: the notes; audio: pitch, keeping time)"
        for (f, l) in [(fadeIn, "Fade in"), (fadeOut, "Fade out")] {
            f.controlSize = .small; f.font = Theme.mono(10); f.alignment = .right; f.placeholderString = "0 ms"
            f.target = self; f.action = #selector(fadesTyped(_:)); f.setAccessibilityLabel(l + " (ms)"); f.toolTip = l + " length in milliseconds"
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        for b in [loop, mute, follow] { b.controlSize = .small; b.font = Theme.ui(11); b.target = self }
        follow.action = #selector(followClicked(_:))
        follow.toolTip = "Tempo changes keep this audio on its beats and time-stretch it, pitch kept (Ableton's warp)"
        loop.action = #selector(loopClicked(_:)); loop.toolTip = "Repeat the clip when its end is dragged out (L)"
        mute.action = #selector(muteClicked(_:)); mute.toolTip = "Keep the clip but silence it"

        func row(_ title: String, _ views: [NSView]) -> NSView {
            let l = NSTextField(labelWithString: title)
            l.font = Theme.ui(11); l.textColor = Theme.textDim
            l.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let r = NSStackView(views: [l] + views)
            r.spacing = 6
            return r
        }
        gainRow = row("Gain", [gain, gainValue])
        gainValue.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let transposeRow = row("Transpose", [transpose, transposeValue])
        fadeRow = row("Fades", [fadeIn, fadeOut])
        let toggles = NSStackView(views: [loop, mute, follow]); toggles.spacing = 12
        for v in [head, name, place, gainRow!, transposeRow, fadeRow!, toggles] as [NSView] { addArrangedSubview(v) }
        setCustomSpacing(2, after: name)
        head.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var current: ClipView? { clip.flatMap { session.clip($0) } }
    private var rate: Double { session.engine.sampleRate }

    func reload() {
        guard let c = current else { isHidden = true; return }
        isHidden = false
        name.stringValue = c.name + (c.isMidi ? "  ·  \(c.noteCount) notes" : "")
        place.stringValue = "\(positionText(c.start)) – \(positionText(c.end))  ·  \(String(format: "%.2f", Double(c.length) / rate)) s"
        gain.isEnabled = !c.isMidi; gainRow.isHidden = c.isMidi
        let g = c.gainDb.isFinite ? Double(c.gainDb) : -24
        if !gain.isHighlighted { gain.doubleValue = g }
        gainValue.stringValue = c.gainDb.isFinite ? String(format: "%+.1f dB", c.gainDb).replacingOccurrences(of: "-", with: "−") : "−∞ dB"
        transpose.integerValue = c.isMidi ? 0 : Int(c.pitch.rounded())
        transposeValue.stringValue = c.isMidi ? "notes" : String(format: "%+d st", Int(c.pitch.rounded())).replacingOccurrences(of: "-", with: "−")
        fadeRow.isHidden = c.isMidi
        if window?.firstResponder !== fadeIn.currentEditor() { fadeIn.stringValue = "\(Int((Double(c.fadeIn) / rate * 1000).rounded())) ms" }
        if window?.firstResponder !== fadeOut.currentEditor() { fadeOut.stringValue = "\(Int((Double(c.fadeOut) / rate * 1000).rounded())) ms" }
        loop.state = c.loopLength > 0 ? .on : .off
        loop.isEnabled = c.isMidi || (c.rate == 1 && c.pitch == 0 && c.warp.isEmpty) || c.loopLength > 0
        mute.state = c.muted ? .on : .off
        follow.isHidden = c.isMidi // MIDI always follows tempo
        follow.state = c.followsTempo ? .on : .off
        follow.isEnabled = c.preservePitch
    }
    @objc private func followClicked(_ b: NSButton) {
        guard let c = current else { return }
        _ = dalnok_clip_set_follow_tempo(session.engine.handle, c.id, b.state == .on)
        session.refresh()
        reload()
    }

    @objc private func gainMoved(_ s: NSSlider) {
        guard let c = current else { return }
        let db = (s.doubleValue * 2).rounded() / 2 // half-dB steps
        if NSApp.currentEvent?.type == .leftMouseDown { session.engine.beginGroup("Clip Gain") }
        dalnok_clip_set_gain_db(session.engine.handle, c.id, Float(db))
        if NSApp.currentEvent?.type == .leftMouseUp { session.engine.endGroup() }
        session.refresh()
    }
    @objc private func transposed(_ s: NSStepper) {
        guard let c = current else { return }
        if c.isMidi { // the stepper moves by one each click: transpose every note by that
            let delta = s.integerValue
            s.integerValue = 0
            let notes = c.notes.map { DalnokNote(start: $0.start, length: $0.length, pitch: UInt8(max(0, min(127, Int($0.pitch) + delta))), velocity: $0.velocity) }
            session.setNotes(c.id, notes)
        } else {
            session.setStretch(c.id, length: c.length, rate: c.rate, pitch: Float(s.integerValue), preservePitch: true)
        }
        reload()
    }
    @objc private func fadesTyped(_ f: NSTextField) {
        guard let c = current else { return }
        func frames(_ t: NSTextField) -> Int64 {
            let ms = Double(t.stringValue.filter { $0.isNumber || $0 == "." }) ?? 0
            return Int64((ms / 1000 * rate).rounded())
        }
        var fi = frames(fadeIn), fo = frames(fadeOut)
        fi = min(fi, c.length); fo = min(fo, c.length - fi)
        session.setFades(c.id, fadeIn: fi, fadeOut: fo, curve: DalnokFadeCurve(rawValue: UInt32(c.fadeCurve)))
        reload()
    }
    @objc private func loopClicked(_ b: NSButton) {
        guard let c = current else { return }
        if dalnok_clip_set_loop(session.engine.handle, c.id, b.state == .on) != DALNOK_OK {
            session.onMessage?("Time-stretched or quantized audio can't loop (reset its speed first)")
        }
        session.refresh()
        reload()
    }
    @objc private func muteClicked(_ b: NSButton) {
        guard let c = current else { return }
        session.setClipMuted(c.id, b.state == .on)
        reload()
    }
}
