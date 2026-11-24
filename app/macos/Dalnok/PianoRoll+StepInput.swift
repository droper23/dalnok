// Step input (Logic's Step Input, Ableton's step recording): with Clip ▸ Step Input on, each note played on a MIDI
// keyboard is written at the playhead with the quantize value's length, and the playhead moves on one step when the
// keys are released. Keys pressed together make a chord on one step. A step past the clip's end lengthens the clip.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension PianoRollView {
    /// One step in frames from `frame` (the quantize value, following the tempo map).
    func stepLength(at frame: Int64) -> Int64 {
        let b = session.frameToBeat(Double(frame))
        return max(1, Int64(session.beatToFrame(b + QuantizeSetting.grid).rounded()) - frame)
    }

    /// Takes the notes played since the last tick (called on the display tick while step input is on).
    func stepTick() {
        var buf = [DalnokInputNote](repeating: DalnokInputNote(), count: 64)
        let n = Int(dalnok_midi_take_input_notes(session.engine.handle, &buf, 64))
        for e in buf.prefix(n) { stepNote(pitch: e.pitch, velocity: e.velocity, on: e.on) }
    }

    func stepNote(pitch: UInt8, velocity: UInt8, on: Bool) {
        guard let c = clip else { return }
        if on {
            if stepHeld.isEmpty { stepAt = max(0, session.engine.position) }
            stepHeld.insert(pitch)
            let len = stepLength(at: stepAt)
            if stepAt + len > c.start + c.length { // grow the clip to hold the step
                session.setRegion(c.id, start: c.start, offset: c.offset, length: stepAt + len - c.start)
            }
            guard stepAt >= c.start, let now = clip else { session.onMessage?("Step input writes from the clip's start onward"); return }
            let note = DalnokNote(start: stepAt - now.start + now.offset, length: len, pitch: pitch, velocity: max(1, velocity))
            commit(now.notes.filter { key($0) != key(note) } + [note], select: Set(selection).union([key(note)]))
        } else {
            stepHeld.remove(pitch)
            guard stepHeld.isEmpty else { return }
            let next = stepAt + stepLength(at: stepAt)
            session.engine.seek(next)
            selection = []
        }
    }
}
