// Generated test projects: deterministic audio and MIDI, no external files.
// Used for UI checks, screenshots, benchmarks and bug reports (never the owner's material).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation

enum TestProject {
    static let presets = ["demo", "band", "midi", "states", "large"]

    /// Writes a mono or stereo 32-bit float WAV.
    static func writeWav(_ url: URL, _ channels: [[Float]], rate: Int) throws {
        let frames = channels.first?.count ?? 0, ch = channels.count
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * ch * 4)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(3); u16(UInt16(ch)); u32(UInt32(rate)); u32(UInt32(rate * ch * 4)); u16(UInt16(ch * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * ch * 4))
        d.reserveCapacity(d.count + frames * ch * 4)
        for i in 0..<frames { for c in 0..<ch { u32(channels[c][i].bitPattern) } }
        try d.write(to: url)
    }

    /// Small deterministic noise source (xorshift), so every run is identical.
    struct Noise {
        var s: UInt32 = 0x9E37_79B9
        mutating func next() -> Float { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Float(s) / Float(UInt32.max) * 2 - 1 }
    }

    // MARK: Instruments for generated stems

    static func kick(rate: Double, beats: Int, bpm: Double) -> [Float] {
        let beat = Int(rate * 60 / bpm), n = beat * beats
        var out = [Float](repeating: 0, count: n)
        for b in 0..<beats {
            var phase = 0.0
            for i in 0..<min(Int(rate * 0.35), n - b * beat) {
                let t = Double(i) / rate
                phase += 2 * .pi * (45 + 110 * exp(-t * 30)) / rate
                out[b * beat + i] = Float(sin(phase) * exp(-t * 9) * 0.8)
            }
        }
        return out
    }

    static func hats(rate: Double, beats: Int, bpm: Double) -> [Float] {
        let step = Int(rate * 60 / bpm / 2), n = step * beats * 2
        var out = [Float](repeating: 0, count: n), noise = Noise(), hp: Float = 0, prev: Float = 0
        for s in 0..<(beats * 2) {
            let accent: Float = s % 2 == 0 ? 0.35 : 0.2
            for i in 0..<min(Int(rate * 0.06), n - s * step) {
                let x = noise.next()
                hp = 0.92 * (hp + x - prev); prev = x // crude high-pass
                out[s * step + i] = hp * accent * Float(exp(-Double(i) / rate * 60))
            }
        }
        return out
    }

    static func bass(rate: Double, notes: [Int], beatsPerNote: Int, bpm: Double) -> [Float] {
        let len = Int(rate * 60 / bpm) * beatsPerNote
        var out: [Float] = [], phase = 0.0
        for midi in notes {
            let f = 440 * pow(2, Double(midi - 69) / 12)
            for i in 0..<len {
                phase += 2 * .pi * f / rate
                let env = min(1, Double(i) / (rate * 0.005)) * min(1, Double(len - i) / (rate * 0.02))
                out.append(Float((sin(phase) + 0.3 * sin(2 * phase)) * 0.45 * env))
            }
        }
        return out
    }

    static func pad(rate: Double, chords: [[Int]], beatsPerChord: Int, bpm: Double) -> [[Float]] {
        let len = Int(rate * 60 / bpm) * beatsPerChord
        var l: [Float] = [], r: [Float] = []
        var phases = [Double](repeating: 0, count: 8)
        for chord in chords {
            for i in 0..<len {
                var vl = 0.0, vr = 0.0
                for (k, midi) in chord.enumerated() {
                    let f = 440 * pow(2, Double(midi - 69) / 12) * (k % 2 == 0 ? 1.002 : 0.998)
                    phases[k] += 2 * .pi * f / rate
                    let v = sin(phases[k]) / Double(chord.count)
                    vl += v * (k % 2 == 0 ? 0.8 : 0.4); vr += v * (k % 2 == 0 ? 0.4 : 0.8)
                }
                let env = min(1, Double(i) / (rate * 0.3)) * min(1, Double(len - i) / (rate * 0.3))
                l.append(Float(vl * 0.5 * env)); r.append(Float(vr * 0.5 * env))
            }
        }
        return [l, r]
    }

    static func tone(rate: Double, seconds: Double, hz: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(2 * .pi * hz * Double($0) / rate) * 0.25) }
    }

    // MARK: Building

    struct Builder {
        let e: OpaquePointer
        let audio: URL
        let rate: Double
        func add(_ name: String, _ channels: [[Float]]) throws -> DalnokMediaId {
            let url = audio.appendingPathComponent("\(name).wav")
            try TestProject.writeWav(url, channels, rate: Int(rate))
            var media: OpaquePointer?
            var err = [CChar](repeating: 0, count: 256)
            guard dalnok_media_load(url.path, rate, &media, &err, 256) == DALNOK_OK, let media else { fail(cstr(err)) }
            defer { dalnok_media_release(media) }
            return dalnok_pool_add(e, media, url.path)
        }
        func notes(_ clip: DalnokClipId, _ list: [(beat: Double, beats: Double, pitch: Int, velocity: Int)], bpm: Double) {
            let beat = rate * 60 / bpm
            var n = list.map { DalnokNote(start: Int64($0.beat * beat), length: Int64($0.beats * beat), pitch: UInt8($0.pitch), velocity: UInt8($0.velocity)) }
            _ = dalnok_midi_clip_set_notes(e, clip, &n, Int32(n.count))
        }
    }

    static func make(folder: URL, preset: String, rate: Double, bpm: Double, tracks: Int, seconds: Double) throws -> URL {
        let fm = FileManager.default
        let audio = folder.appendingPathComponent("Audio Files", isDirectory: true)
        try fm.createDirectory(at: audio, withIntermediateDirectories: true)
        guard let e = dalnok_engine_create(rate) else { fail("engine creation failed") }
        defer { dalnok_engine_destroy(e) }
        _ = dalnok_tempo_set(e, bpm, 4, 4)
        let b = Builder(e: e, audio: audio, rate: rate)
        let beat = rate * 60 / bpm, bar = Int64(beat * 4)
        let chords = [[60, 64, 67, 71], [57, 60, 64, 67], [53, 57, 60, 64], [55, 59, 62, 65]]

        func melody(_ clip: DalnokClipId, bars: Int) {
            let line = [72, 74, 76, 79, 76, 74, 72, 67]
            b.notes(clip, (0..<(bars * 8)).map { (Double($0) / 2, 0.45, line[$0 % line.count], 80 + ($0 % 4) * 10) }, bpm: bpm)
        }
        func chordNotes(_ clip: DalnokClipId, bars: Int) {
            var list: [(Double, Double, Int, Int)] = []
            for i in 0..<bars { for p in chords[i % 4] { list.append((Double(i * 4), 3.9, p, 85)) } }
            b.notes(clip, list, bpm: bpm)
        }

        switch preset {
        case "demo", "band":
            let bars = preset == "band" ? 16 : 8
            let drums = dalnok_track_add(e, "Kick")
            dalnok_clip_add(e, drums, try b.add("Kick", [kick(rate: rate, beats: bars * 4, bpm: bpm)]), 0, 0, 0)
            let hat = dalnok_track_add(e, "Hats")
            dalnok_clip_add(e, hat, try b.add("Hats", [hats(rate: rate, beats: bars * 4, bpm: bpm)]), 0, 0, 0)
            dalnok_track_set_pan(e, hat, 0.3)
            let bassTrack = dalnok_track_add(e, "Bass")
            let bassLine = (0..<bars).map { [36, 33, 29, 31][$0 % 4] }
            let bassClip = dalnok_clip_add(e, bassTrack, try b.add("Bass", [bass(rate: rate, notes: bassLine, beatsPerNote: 4, bpm: bpm)]), 0, 0, 0)
            dalnok_clip_set_fades(e, bassClip, Int64(rate * 0.01), Int64(rate * 0.5), DALNOK_FADE_EQUAL_POWER)
            let padTrack = dalnok_track_add(e, "Pad")
            let padMedia = try b.add("Pad", pad(rate: rate, chords: (0..<bars).map { chords[$0 % 4] }, beatsPerChord: 4, bpm: bpm))
            let half = Int64(bars / 2) * bar
            let p1 = dalnok_clip_add(e, padTrack, padMedia, 0, 0, half + Int64(beat))
            let p2 = dalnok_clip_add(e, padTrack, padMedia, half, half, 0) // overlaps p1 by one beat: crossfade
            dalnok_clip_set_fades(e, p2, Int64(beat), Int64(beat * 2), DALNOK_FADE_EQUAL_POWER)
            _ = p1
            dalnok_track_set_gain_db(e, padTrack, -4)
            let keys = dalnok_track_add_instrument(e, "Keys")
            chordNotes(dalnok_midi_clip_add(e, keys, 0, Int64(bars) * bar), bars: bars)
            let lead = dalnok_track_add_instrument(e, "Lead")
            melody(dalnok_midi_clip_add(e, lead, 2 * bar, Int64(bars - 2) * bar), bars: bars - 2)
            let vocal = dalnok_track_add(e, "Vocal") // empty, armed: ready to record
            dalnok_track_set_armed(e, vocal, true)
            if preset == "band" {
                let gtr = dalnok_track_add(e, "Guitar")
                let g = dalnok_clip_add(e, gtr, try b.add("Guitar", [bass(rate: rate, notes: (0..<(bars * 4)).map { [64, 67, 69, 71][$0 % 4] }, beatsPerNote: 1, bpm: bpm)]), 4 * bar, 0, 0)
                dalnok_clip_set_gain_db(e, g, -6)
                dalnok_clip_set_stretch(e, g, Int64(Double(clipInfoLength(e, g)) * 1.25), 0.8, 0, true)
            }
        case "midi":
            for (i, name) in ["Piano", "Strings", "Arp"].enumerated() {
                let t = dalnok_track_add_instrument(e, name)
                for c in 0..<3 {
                    let clip = dalnok_midi_clip_add(e, t, Int64(c * 4) * bar + Int64(i) * bar, 3 * bar)
                    i == 2 ? melody(clip, bars: 3) : chordNotes(clip, bars: 3)
                }
            }
        case "states":
            // Every visual state at once: muted, soloed, custom color, offline, clip gain, stretched, fades.
            let m = try b.add("Tone A", [tone(rate: rate, seconds: 4, hz: 220)])
            let muted = dalnok_track_add(e, "Muted"); dalnok_clip_add(e, muted, m, 0, 0, 0); dalnok_track_set_mute(e, muted, true)
            let solo = dalnok_track_add(e, "Soloed"); dalnok_clip_add(e, solo, m, Int64(rate), 0, 0); dalnok_track_set_solo(e, solo, true)
            let colored = dalnok_track_add(e, "Custom Color"); dalnok_track_set_color(e, colored, 0xE0559B)
            let c = dalnok_clip_add(e, colored, m, 0, 0, 0); dalnok_clip_set_gain_db(e, c, -12)
            let stretched = dalnok_track_add(e, "Stretched"); let s = dalnok_clip_add(e, stretched, m, 0, 0, 0)
            dalnok_clip_set_stretch(e, s, Int64(rate * 6), 4.0 / 6, 3, true)
            let faded = dalnok_track_add(e, "Fades"); let f = dalnok_clip_add(e, faded, m, 0, 0, 0)
            dalnok_clip_set_fades(e, f, Int64(rate), Int64(rate * 1.5), DALNOK_FADE_LINEAR)
            let offline = dalnok_track_add(e, "Offline")
            dalnok_clip_add(e, offline, try b.add("Missing", [tone(rate: rate, seconds: 3, hz: 330)]), 0, 0, 0)
            let keys = dalnok_track_add_instrument(e, "Armed Keys")
            chordNotes(dalnok_midi_clip_add(e, keys, 0, 4 * bar), bars: 4)
            let long = dalnok_track_add(e, "A very long track name that has to truncate in the header")
            dalnok_clip_add(e, long, m, Int64(rate * 2), 0, 0)
        case "large":
            for i in 0..<tracks {
                let t = dalnok_track_add(e, "Track \(i + 1)")
                let m = try b.add("Tone \(i + 1)", [tone(rate: rate, seconds: seconds, hz: 110 * Double(i % 12 + 1))])
                dalnok_clip_add(e, t, m, 0, 0, 0)
            }
        default:
            fail("unknown preset '\(preset)' (choose from \(presets.joined(separator: ", ")))")
        }
        let project = folder.appendingPathComponent("\(preset).dalnok")
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_project_save(e, project.path, &err, 512) == DALNOK_OK else { fail(cstr(err)) }
        if preset == "states" { try? fm.removeItem(at: audio.appendingPathComponent("Missing.wav")) } // shows as offline
        return project
    }

    static func clipInfoLength(_ e: OpaquePointer, _ c: DalnokClipId) -> Int64 {
        var i = DalnokClipInfo()
        return dalnok_clip_info(e, c, &i) == DALNOK_OK ? i.length : 0
    }
}
