// Plug-in categories: what a plug-in is for, from what it declares (VST3 subcategories, CLAP features, Audio Unit
// type and subtype codes) and, failing that, words in its name. Used by the plug-in browser's sidebar and search.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum PluginGroup: String, CaseIterable {
    case instruments = "Instruments", effects = "Audio Effects", midi = "MIDI Effects"
    var categories: [String] {
        switch self {
        case .instruments: ["Synthesizers", "Samplers", "Pianos", "Keyboards", "Drums", "Bass", "Orchestral", "Other Instruments"]
        case .effects: ["EQ", "Compression", "Limiting", "Gate / Expander", "Distortion / Saturation", "Reverb", "Delay / Echo",
                        "Chorus / Flanger / Phaser", "Modulation", "Pitch / Time", "Filtering", "Stereo Imaging", "Spatial Audio",
                        "Restoration / Noise Reduction", "Utility / Gain", "Metering / Analysis", "Other Effects"]
        case .midi: ["Arpeggiators", "Chord Tools", "Sequencers", "Transposition", "Velocity", "MIDI Utilities"]
        }
    }
}

enum PluginTaxonomy {
    /// Words a plug-in declares or is named with, lowercased and split at non-letters (so "amp" doesn't match "sample").
    static func words(_ text: [String]) -> Set<String> {
        var out = Set<String>()
        for t in text {
            let lower = t.lowercased()
            out.insert(lower)
            for w in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where !w.isEmpty { out.insert(String(w)) }
        }
        return out
    }
    /// Whole-word matches, prefix matches for keys ending in "*", and, for distinctive keys of six letters or more,
    /// matches inside a word (vendor-prefixed names such as "MFlanger" or "MCompressor").
    private static func has(_ w: Set<String>, _ keys: [String]) -> Bool {
        keys.contains { k in
            w.contains(k) || (k.hasSuffix("*") && w.contains { $0.hasPrefix(k.dropLast()) })
                || (k.count >= 6 && !k.hasSuffix("*") && k.allSatisfy(\.isLetter) && w.contains { $0.count > k.count && $0.contains(k) })
        }
    }

    /// Apple Audio Unit subtypes (the four-character codes after "aufx:").
    private static let auSubtypes: [String: String] = [
        "dely": "Delay / Echo", "sdly": "Delay / Echo", "mcmp": "Compression", "dcmp": "Compression", "lmtr": "Limiting",
        "nbeq": "EQ", "greq": "EQ", "pmeq": "EQ", "hpas": "Filtering", "lpas": "Filtering", "bpas": "Filtering",
        "hshf": "Filtering", "lshf": "Filtering", "filt": "Filtering", "mrev": "Reverb", "rvb2": "Reverb", "dist": "Distortion / Saturation",
        "tmpt": "Pitch / Time", "nutp": "Pitch / Time", "rogr": "Pitch / Time", "raac": "Utility / Gain", "nsnd": "Utility / Gain",
        "smpl": "Samplers", "samp": "Samplers", "dls ": "Synthesizers", "msyn": "Synthesizers",
    ]

    static func classify(name: String, kind: String, format: String, path: String, categories: [String]) -> (group: PluginGroup, category: String) {
        let au = format.uppercased() == "AU" ? path.split(separator: ":").map(String.init) : []
        let auType = au.first ?? "", auSub = au.count > 1 ? au[1] : ""
        let w = words(categories + [name])
        let group: PluginGroup
        if auType == "aumi" || has(w, ["note-effect", "midi-effect", "midi"]) && kind != "instrument" && !has(w, ["instrument"]) && auType != "aumu" {
            group = .midi
        } else if kind == "instrument" || auType == "aumu" || has(w, ["instrument", "synth", "synthesizer"]) && auType != "aufx" {
            group = .instruments
        } else {
            group = .effects
        }
        if let c = auSubtypes[auSub], group.categories.contains(c) { return (group, c) }
        switch group {
        case .instruments:
            if has(w, ["drum", "drums", "drum-machine", "percussion", "beat*", "kit"]) { return (group, "Drums") }
            if has(w, ["piano", "pianos", "grand", "upright"]) { return (group, "Pianos") }
            if has(w, ["organ", "keys", "keyboard", "rhodes", "wurli*", "clav*", "ep"]) { return (group, "Keyboards") }
            if has(w, ["bass"]) { return (group, "Bass") }
            if has(w, ["orchestra*", "strings", "string", "brass", "woodwind*", "choir", "symphon*", "ensemble"]) { return (group, "Orchestral") }
            if has(w, ["sampler", "sample*", "rompler", "granular"]) { return (group, "Samplers") }
            if has(w, ["synth", "synthesizer", "synthesiser", "generator", "oscillator", "wavetable", "fm", "analog"]) { return (group, "Synthesizers") }
            return (group, "Other Instruments")
        case .midi:
            if has(w, ["arp*"]) { return (group, "Arpeggiators") }
            if has(w, ["chord*", "harmon*"]) { return (group, "Chord Tools") }
            if has(w, ["sequenc*", "step", "pattern"]) { return (group, "Sequencers") }
            if has(w, ["transpos*", "scale", "pitch"]) { return (group, "Transposition") }
            if has(w, ["velocity"]) { return (group, "Velocity") }
            return (group, "MIDI Utilities")
        case .effects:
            let rules: [(String, [String])] = [
                ("Metering / Analysis", ["analyzer", "analyser", "analysis", "meter", "metering", "scope", "spectrum", "loudness", "tuner"]),
                ("Restoration / Noise Reduction", ["restoration", "denoise*", "noise", "declick*", "de-click", "dehum", "repair"]),
                ("Limiting", ["limiter", "limiting", "maximizer", "maximiser", "clipper"]),
                ("Gate / Expander", ["gate", "expander", "noisegate"]),
                ("Compression", ["compressor", "compression", "comp", "dynamics", "de-esser", "deesser", "transient-shaper", "transient", "leveler"]),
                ("EQ", ["eq", "equalizer", "equaliser", "equalizer"]),
                ("Reverb", ["reverb", "verb", "rvb", "hall", "plate", "room", "convolution"]),
                ("Delay / Echo", ["delay", "echo", "tape-delay"]),
                ("Chorus / Flanger / Phaser", ["chorus", "flanger", "phaser"]),
                ("Pitch / Time", ["pitch", "pitch-shifter", "pitch-correction", "tune", "autotune", "stretch", "varispeed", "vocoder", "phase-vocoder", "harmonizer"]),
                ("Distortion / Saturation", ["distortion", "saturation", "saturator", "overdrive", "fuzz", "drive", "amp", "amps", "amplifier", "bitcrush*", "crush*", "lofi", "lo-fi", "tube", "tape", "decimat*"]),
                ("Modulation", ["modulation", "tremolo", "vibrato", "rotary", "ringmod", "frequency-shifter", "glitch", "auto-pan", "autopan"]),
                ("Filtering", ["filter", "wah", "formant", "lowpass", "highpass", "bandpass"]),
                ("Spatial Audio", ["spatial", "spatializer", "ambisonic", "ambisonics", "binaural", "panner3d"]),
                ("Stereo Imaging", ["width", "imager", "widener", "panner", "mid-side", "stereo-imager", "stereoizer"]),  // "Stereo" alone is a channel layout tag
                ("Utility / Gain", ["utility", "gain", "trim", "tools", "tool", "mixing", "mastering", "phase"]),
            ]
            for (c, keys) in rules where has(w, keys) { return (group, c) }
            return (group, "Other Effects")
        }
    }
}
