// Migration knowledge shared by onboarding, the command palette, the concept
// guide and import reports: other DAWs' vocabulary, keyboard-shortcut presets,
// and plain-language explanations of what an import couldn't bring over.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum SourceDAW: String, CaseIterable {
    case logic, ableton, reaper

    var title: String {
        switch self {
        case .logic: "Logic Pro"
        case .ableton: "Ableton Live"
        case .reaper: "REAPER"
        }
    }
    var fileExtensions: [String] {
        switch self {
        case .logic: ["logicx"]
        case .ableton: ["als"]
        case .reaper: ["rpp"]
        }
    }
    var symbol: String {
        switch self {
        case .logic: "pianokeys"
        case .ableton: "square.grid.3x3"
        case .reaper: "slider.horizontal.3"
        }
    }

    /// The DAW the user said they're coming from (first-run choice).
    static var preferred: SourceDAW? {
        get { UserDefaults.standard.string(forKey: "comingFrom").flatMap(SourceDAW.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "comingFrom") }
    }
}

enum FeatureStatus: Equatable {
    case available, partial(String), planned(String)
    var label: String {
        switch self {
        case .available: "Available"
        case .partial(let s): "Partial — \(s)"
        case .planned(let s): "Planned — \(s)"
        }
    }
}

struct Concept {
    let daw: SourceDAW
    let term: String          // their word
    let dalnok: String        // our equivalent (menu command title when it exists)
    let status: FeatureStatus
    var note: String = ""
}

enum Migration {
    // MARK: Concept map (also feeds palette aliases and "planned" entries)

    static let concepts: [Concept] = [
        // Logic Pro
        Concept(daw: .logic, term: "Region", dalnok: "Clip", status: .available, note: "Audio regions are clips; MIDI regions arrive with MIDI."),
        Concept(daw: .logic, term: "Bounce Project or Section", dalnok: "Export Mix…", status: .available),
        Concept(daw: .logic, term: "Split Regions at Playhead", dalnok: "Split at Playhead", status: .available, note: "Same shortcut: ⌘T"),
        Concept(daw: .logic, term: "New Tracks", dalnok: "New Track", status: .available, note: "⌥⌘N"),
        Concept(daw: .logic, term: "Region Gain", dalnok: "Clip gain", status: .available),
        Concept(daw: .logic, term: "Fade Tool / Crossfade", dalnok: "Clip fade handles", status: .available, note: "Drag a clip's top corners."),
        Concept(daw: .logic, term: "Consolidate Project", dalnok: "Copy Audio into Project on Save", status: .available),
        Concept(daw: .logic, term: "Project Audio Browser", dalnok: "Relink Missing Audio…", status: .partial("relink only")),
        Concept(daw: .logic, term: "Take Folders / Quick Swipe Comping", dalnok: "Comping", status: .planned("Phase 4")),
        Concept(daw: .logic, term: "Flex Time", dalnok: "Time stretch (⌥-drag a clip's end)", status: .partial("whole-clip; flex markers later")),
        Concept(daw: .logic, term: "Time Stretch Region", dalnok: "⌥-drag a clip's end, or Clip ▸ Double/Half Speed", status: .available),
        Concept(daw: .logic, term: "Region Transpose", dalnok: "Clip ▸ Transpose Up/Down a Semitone", status: .available),
        Concept(daw: .logic, term: "Flex Pitch", dalnok: "Pitch editing", status: .planned("Phase 5")),
        Concept(daw: .logic, term: "Track Stacks", dalnok: "Groups", status: .planned("Phase 4")),
        Concept(daw: .logic, term: "Smart Controls", dalnok: "Generic plugin panel + macros", status: .planned("Phase 4–5")),
        Concept(daw: .logic, term: "Piano Roll", dalnok: "Piano roll", status: .planned("Phase 3")),
        Concept(daw: .logic, term: "Live Loops", dalnok: "Clip launcher on every track", status: .planned("Phase 5")),
        Concept(daw: .logic, term: "Key Commands", dalnok: "Logic shortcut preset + ⌘K", status: .partial("preset, no editor yet")),
        // Ableton Live
        Concept(daw: .ableton, term: "Clip (Arrangement)", dalnok: "Clip", status: .available),
        Concept(daw: .ableton, term: "Export Audio/Video", dalnok: "Export Mix…", status: .available),
        Concept(daw: .ableton, term: "Split", dalnok: "Split at Playhead", status: .available, note: "Ableton preset maps it to ⌘E"),
        Concept(daw: .ableton, term: "Insert Audio Track", dalnok: "New Track", status: .available),
        Concept(daw: .ableton, term: "Track Activator", dalnok: "Mute Track", status: .available),
        Concept(daw: .ableton, term: "Collect All and Save", dalnok: "Copy Audio into Project on Save", status: .available),
        Concept(daw: .ableton, term: "Session View", dalnok: "Clip launcher on every track", status: .planned("Phase 5")),
        Concept(daw: .ableton, term: "Warping", dalnok: "Time stretch", status: .partial("imported warp markers play correctly; warp-marker editing later")),
        Concept(daw: .ableton, term: "Re-Pitch warp mode", dalnok: "Preserve Pitch off (varispeed)", status: .available),
        Concept(daw: .ableton, term: "Clip Transpose", dalnok: "Clip ▸ Transpose Up/Down a Semitone", status: .available),
        Concept(daw: .ableton, term: "Racks", dalnok: "Racks", status: .planned("Phase 5")),
        Concept(daw: .ableton, term: "Take Lanes / Comping", dalnok: "Comping", status: .planned("Phase 4")),
        Concept(daw: .ableton, term: "Group Track", dalnok: "Groups", status: .planned("Phase 4")),
        Concept(daw: .ableton, term: "Return Track / Sends", dalnok: "Buses and sends", status: .planned("Phase 4")),
        Concept(daw: .ableton, term: "Device View parameters", dalnok: "Generic plugin panel", status: .planned("Phase 4")),
        // REAPER
        Concept(daw: .reaper, term: "Item", dalnok: "Clip", status: .available),
        Concept(daw: .reaper, term: "Render", dalnok: "Export Mix…", status: .available),
        Concept(daw: .reaper, term: "Split items at cursor", dalnok: "Split at Playhead", status: .available, note: "REAPER preset maps it to S"),
        Concept(daw: .reaper, term: "Insert new track", dalnok: "New Track", status: .available),
        Concept(daw: .reaper, term: "Item volume", dalnok: "Clip gain", status: .available),
        Concept(daw: .reaper, term: "Action List", dalnok: "Command Palette…", status: .available, note: "⌘K; scripting through the command catalog"),
        Concept(daw: .reaper, term: "ReaScript", dalnok: "Command catalog (JSON) + dalnok-cli", status: .partial("no embedded language yet")),
        Concept(daw: .reaper, term: "Folder tracks", dalnok: "Groups", status: .planned("Phase 4")),
        Concept(daw: .reaper, term: "Takes", dalnok: "Comping", status: .planned("Phase 4")),
        Concept(daw: .reaper, term: "Item playrate / Alt-drag edge", dalnok: "⌥-drag a clip's end (time stretch)", status: .available),
        Concept(daw: .reaper, term: "Preserve pitch when changing rate", dalnok: "Clip ▸ Preserve Pitch When Stretching", status: .available),
        Concept(daw: .reaper, term: "Routing matrix", dalnok: "Routing", status: .planned("Phase 4")),
    ]

    /// Extra search words per command title (beyond concept terms).
    static let aliases: [String: [String]] = [
        "Export Mix…": ["bounce", "render", "export audio", "mixdown", "print"],
        "Split at Playhead": ["cut", "split", "razor", "scissors", "split items", "split regions"],
        "Import Audio…": ["add file", "import file", "add audio"],
        "New Track": ["create track", "insert track", "add track", "audio track"],
        "Delete Track": ["remove track"],
        "Mute Track": ["deactivate", "track activator"],
        "Solo Track": ["listen", "isolate"],
        "Add Short Fades": ["declick", "fade", "crossfade", "auto fade"],
        "Remove Fades": ["clear fades"],
        "Relink Missing Audio…": ["locate", "missing files", "manage files", "find media"],
        "Copy Audio into Project on Save": ["collect all and save", "consolidate project", "save with media"],
        "Command Palette…": ["actions", "action list", "find command"],
        "Double Speed": ["stretch", "time stretch", "playrate", "faster", "flex"],
        "Half Speed": ["stretch", "time stretch", "playrate", "slower", "flex"],
        "Transpose Up a Semitone": ["pitch", "transpose", "pitch shift"],
        "Transpose Down a Semitone": ["pitch", "transpose", "pitch shift"],
        "Preserve Pitch When Stretching": ["varispeed", "re-pitch", "tape speed"],
        "Reset Speed and Pitch": ["unstretch", "original speed", "unwarp"],
        "Import Project from Another DAW…": ["open logic", "open ableton", "open reaper", "migrate", "convert"],
    ]

    /// Their nouns -> ours, applied to palette queries.
    static let synonyms: [String: String] = ["region": "clip", "regions": "clip", "item": "clip", "items": "clip",
                                             "set": "project", "session": "project", "song": "project"]

    // MARK: Import report reasons

    static func explain(_ key: String) -> (title: String, detail: String) {
        switch key {
        case "midiClips", "midiRegions": ("MIDI clips", "MIDI tracks and the piano roll arrive in Phase 3; these will import then.")
        case "midiTracks": ("MIDI tracks", "Imported once MIDI support lands (Phase 3).")
        case "plugins", "devicesAndPlugins", "masterFx", "masterDevices": ("Plugins and devices", "Plugin hosting (VST3 first) arrives in Phase 4.")
        case "automationLanes": ("Automation", "Automation arrives in Phase 4.")
        case "sends", "returnTracks": ("Sends and return/bus tracks", "Buses and sends arrive in Phase 4.")
        case "groupTracks", "folderStructure": ("Groups and folders", "Tracks came over flat; groups arrive in Phase 4.")
        case "warpedClipsNeedingStretch", "playrateChanges": ("Time-stretched audio", "Older import reports only — stretching is now supported.")
        case "takeLaneClips", "extraTakes": ("Alternate takes", "Only the active take/comp result came over; comping arrives in Phase 4.")
        case "sessionClips": ("Session-view clips", "The clip launcher arrives in Phase 5.")
        case "tempoChanges": ("Tempo changes", "A single tempo was used for positions.")
        case "masterVolume": ("Master volume", "There's no master fader yet.")
        case "mutedItems", "disabledClips": ("Muted clips", "Muted/disabled clips were left out.")
        case "unplacedRegions": ("Unused regions", "Regions in the project's audio bin but not on the timeline.")
        case "unresolvedPlacements": ("Unreadable placements", "Some Logic region placements couldn't be decoded.")
        case "nonAudioItems", "videoOrTitles": ("Non-audio items", "Video, empty and click items were skipped.")
        case "compoundClipsFlattened": ("Compound clips", "Flattened onto tracks.")
        case "sectionOrReversedSources": ("Reversed/section items", "Imported without reverse/section processing.")
        case "fadesOnLoopedItems": ("Fades on looped items", "Looped items were expanded without their fades.")
        default: (key, "")
        }
    }

    // MARK: Keyboard shortcut presets

    struct Key { let key: String; let mods: NSEvent.ModifierFlags }
    /// Overrides keyed by menu action selector name. Unlisted actions keep Dalnok defaults.
    static func keymap(_ daw: SourceDAW?) -> [String: Key] {
        switch daw {
        case .logic?: [
            "toggleMuteTrack:": Key(key: "m", mods: []),
            "toggleSoloTrack:": Key(key: "s", mods: []),
            "importAudio": Key(key: "i", mods: [.command, .shift]),
        ]
        case .ableton?: [
            "splitAtPlayhead": Key(key: "e", mods: [.command]),
            "exportMix:": Key(key: "r", mods: [.command, .shift]),
            "newTrack:": Key(key: "t", mods: [.command]),
            "toggleMuteTrack:": Key(key: "0", mods: []),
        ]
        case .reaper?: [
            "splitAtPlayhead": Key(key: "s", mods: []),
            "exportMix:": Key(key: "r", mods: [.command, .option]),
            "newTrack:": Key(key: "t", mods: [.command]),
            "toggleMuteTrack:": Key(key: "m", mods: [.control]),
        ]
        case nil: [:]
        }
    }

    /// Applies a preset to the main menu, restoring Dalnok defaults for unlisted actions.
    @MainActor
    static func applyKeymap(_ daw: SourceDAW?, to menu: NSMenu?) {
        let map = keymap(daw)
        func visit(_ m: NSMenu) {
            for it in m.items {
                if let sub = it.submenu { visit(sub); continue }
                guard let action = it.action, it.target is MainWindowController else { continue }
                let name = NSStringFromSelector(action)
                let id = ObjectIdentifier(it)
                if defaults[id] == nil { defaults[id] = Key(key: it.keyEquivalent, mods: it.keyEquivalentModifierMask) }
                // Presets only re-key items that have a shortcut by default (e.g. not the Help copy of an item).
                let k = (defaults[id]!.key.isEmpty ? nil : map[name]) ?? defaults[id]!
                it.keyEquivalent = k.key
                it.keyEquivalentModifierMask = k.mods
            }
        }
        if let menu { visit(menu) }
    }
    @MainActor private static var defaults: [ObjectIdentifier: Key] = [:]

    /// Shortcut collisions in a menu (same key + modifiers on two items).
    @MainActor
    static func shortcutConflicts(_ menu: NSMenu?) -> [String] {
        var seen: [String: String] = [:], out: [String] = []
        func visit(_ m: NSMenu) {
            for it in m.items {
                if let sub = it.submenu { visit(sub); continue }
                // Only Dalnok's own commands (system-inserted items like Emoji & Symbols are AppKit's).
                guard !it.keyEquivalent.isEmpty, it.target is MainWindowController || it.target is NSApplication || it.target == nil,
                      it.action != #selector(NSApplication.orderFrontCharacterPalette(_:)) else { continue }
                let k = "\(it.keyEquivalentModifierMask.rawValue)-\(it.keyEquivalent.lowercased())"
                if let other = seen[k] { out.append("\(other) / \(it.title)") } else { seen[k] = it.title }
            }
        }
        if let menu { visit(menu) }
        return out
    }
}
