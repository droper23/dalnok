// Keyboard shortcuts: one registry for every command.
// Menu items are Dalnok's commands (the palette, buttons and menus all run them through the same selectors), so the
// registry reads the main menu, gives each command a stable id, category, description and context, and writes the
// effective shortcuts back onto the menu items. Key presses are resolved here first (MainMenu), which adds what menu
// key equivalents can't do: several shortcuts per command, keypad keys, and contextual reuse (the same key doing one
// thing in the piano roll and another in the arrangement). Presets approximate other DAWs; the owner's changes are
// stored as overrides on top of the chosen preset.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// MARK: Key combinations

struct KeyCombo: Hashable, Comparable, CustomStringConvertible {
    /// A lowercase character ("t", "=", "1") or a named key ("space", "return", "left", "f9", "kp*").
    let key: String
    let mods: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    init(_ key: String, _ mods: NSEvent.ModifierFlags = []) {
        self.key = key.lowercased()
        self.mods = mods.intersection(Self.relevant)
    }
    func hash(into h: inout Hasher) { h.combine(key); h.combine(mods.rawValue) }
    static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.mods == b.mods }
    static func < (a: Self, b: Self) -> Bool { a.storage < b.storage }

    static let keyCodes: [UInt16: String] = [
        49: "space", 36: "return", 76: "enter", 51: "delete", 117: "forwarddelete", 53: "escape", 48: "tab",
        123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
        103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        67: "kp*", 65: "kp.", 69: "kp+", 78: "kp-", 75: "kp/", 81: "kp=",
        82: "kp0", 83: "kp1", 84: "kp2", 85: "kp3", 86: "kp4", 87: "kp5", 88: "kp6", 89: "kp7", 91: "kp8", 92: "kp9",
    ]
    /// The combination a key-down event represents (shifted symbols keep their base key: ⇧= not "+").
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        if let named = Self.keyCodes[event.keyCode] { self.init(named, event.modifierFlags); return }
        guard let base = event.characters(byApplyingModifiers: [])?.lowercased(), let c = base.first, !c.isWhitespace else { return nil }
        self.init(String(c), event.modifierFlags)
    }

    // Menu key equivalents
    private static let menuSpecials: [String: String] = [
        "space": " ", "return": "\r", "delete": "\u{8}", "forwarddelete": "\u{7f}", "escape": "\u{1b}", "tab": "\t",
        "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
        "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!),
        "home": String(UnicodeScalar(NSHomeFunctionKey)!), "end": String(UnicodeScalar(NSEndFunctionKey)!),
        "pageup": String(UnicodeScalar(NSPageUpFunctionKey)!), "pagedown": String(UnicodeScalar(NSPageDownFunctionKey)!),
    ]
    init?(menuItem it: NSMenuItem) {
        let k = it.keyEquivalent
        guard !k.isEmpty else { return nil }
        if let named = Self.menuSpecials.first(where: { $0.value == k })?.key { self.init(named, it.keyEquivalentModifierMask); return }
        if k == "\u{7f}" { self.init("delete", it.keyEquivalentModifierMask); return }
        if let u = k.unicodeScalars.first?.value, u >= UInt32(NSF1FunctionKey), u <= UInt32(NSF15FunctionKey) {
            self.init("f\(u - UInt32(NSF1FunctionKey) + 1)", it.keyEquivalentModifierMask); return
        }
        var mods = it.keyEquivalentModifierMask
        if k != k.lowercased() { mods.insert(.shift) } // "T" means ⇧T
        self.init(k, mods)
    }
    /// The menu item form, when a menu can show and match it (keypad keys and shifted symbols can't: those are
    /// dispatched by the registry and shown in the menu as their nearest form only if representable).
    var menuEquivalent: (String, NSEvent.ModifierFlags)? {
        if key.hasPrefix("kp") { return nil }
        if let s = Self.menuSpecials[key] { return (s, mods) }
        if key.count > 1, key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...15).contains(n) {
            return (String(UnicodeScalar(UInt32(NSF1FunctionKey) + UInt32(n - 1))!), mods)
        }
        guard key.count == 1 else { return nil }
        if mods.contains(.shift), !(key.first!.isLetter) { return nil }
        return (key, mods)
    }

    // Text forms
    private static let display: [String: String] = [
        "space": "Space", "return": "↩", "enter": "⌤", "delete": "⌫", "forwarddelete": "⌦", "escape": "⎋", "tab": "⇥",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]
    var description: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        if let d = Self.display[key] { return s + d }
        if key.hasPrefix("kp") { return s + "Keypad " + key.dropFirst(2) }
        if key.hasPrefix("f"), key.count > 1, Int(key.dropFirst()) != nil { return s + key.uppercased() }
        return s + key.uppercased()
    }
    /// Stable, ASCII form for settings and exported files: "cmd+shift+t", "kp*", "ctrl+space".
    var storage: String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }
    /// Parses the storage form or a symbol form ("⇧⌘T", "cmd t", "Ctrl+Space").
    init?(parsing text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for (sym, m) in [("⌃", NSEvent.ModifierFlags.control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)] where t.contains(sym) {
            mods.insert(m); t = t.replacingOccurrences(of: sym, with: "")
        }
        let lower = t.lowercased()
        var parts = lower.components(separatedBy: CharacterSet(charactersIn: "+ ")).filter { !$0.isEmpty }
        if lower == "+" || lower.hasSuffix("++") || lower.hasSuffix(" +") { parts.append("+") }
        var key: String?
        for p in parts {
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default: key = p
            }
        }
        guard var k = key, !k.isEmpty else { return nil }
        let aliases = ["↩": "return", "⌤": "enter", "⌫": "delete", "⌦": "forwarddelete", "⎋": "escape", "esc": "escape", "⇥": "tab",
                       "←": "left", "→": "right", "↑": "up", "↓": "down", "↖": "home", "↘": "end", "⇞": "pageup", "⇟": "pagedown",
                       "backspace": "delete", "enter": "enter", "keypad*": "kp*", "numpad*": "kp*"]
        k = aliases[k] ?? k
        if k.hasPrefix("keypad") { k = "kp" + k.dropFirst(6) }
        guard k.count == 1 || Self.keyCodes.values.contains(k) || k == "forwarddelete" else { return nil }
        self.init(k, mods)
    }
}

// MARK: Actions

enum ShortcutContext: String, CaseIterable {
    case global, arrangement, pianoRoll
    var title: String { self == .global ? "Everywhere" : self == .arrangement ? "Arrangement" : "Piano Roll" }
    /// Whether a command in `self` can run where one in `o` runs.
    func overlaps(_ o: ShortcutContext) -> Bool { self == o || self == .global || o == .global }
    /// Two commands conflict only in the same context. A context-specific command sharing a key with a global one
    /// overrides it there (Return inserts a note in the piano roll and goes to the start elsewhere).
    func clashes(_ o: ShortcutContext) -> Bool { self == o }
}

@MainActor
final class ShortcutAction {
    let id: String
    let title: String
    let category: String
    let detail: String
    let keywords: [String]
    let context: ShortcutContext
    let defaults: [KeyCombo]
    /// The menu item that runs it (nil for view-handled actions such as piano-roll editing keys).
    weak var item: NSMenuItem?
    let menuPath: String
    init(id: String, title: String, category: String, detail: String, keywords: [String], context: ShortcutContext,
         defaults: [KeyCombo], item: NSMenuItem?, menuPath: String) {
        self.id = id; self.title = title; self.category = category; self.detail = detail; self.keywords = keywords
        self.context = context; self.defaults = defaults; self.item = item; self.menuPath = menuPath
    }
}

/// Command metadata keyed by selector name: stable id, category, description and search words.
/// Commands not listed still get an id ("menu.selector") and their menu's category.
private struct Spec { let id: String; let category: String; let detail: String; var keywords: [String] = []; var context: ShortcutContext = .global }
private let specs: [String: Spec] = [
    // Transport
    "togglePlay": Spec(id: "transport.play_pause", category: "Transport", detail: "Start or pause playback at the playhead.", keywords: ["start", "stop", "play"]),
    "goToStart": Spec(id: "transport.return_to_start", category: "Transport", detail: "Move the playhead to the beginning of the project.", keywords: ["home", "rewind", "zero"]),
    "toggleRecord:": Spec(id: "transport.record", category: "Recording", detail: "Start recording on the armed tracks, or stop.", keywords: ["capture"]),
    "toggleMetronome:": Spec(id: "transport.metronome", category: "Transport", detail: "Turn the click on or off.", keywords: ["click"]),
    "toggleCycle:": Spec(id: "transport.loop", category: "Transport", detail: "Turn cycle (loop) playback on or off.", keywords: ["loop", "repeat"]),
    "setCycleToSelection:": Spec(id: "transport.loop_to_selection", category: "Transport", detail: "Set the cycle range to the selected clips.", keywords: ["loop"]),
    "toggleCountIn:": Spec(id: "recording.count_in", category: "Recording", detail: "Play one bar of clicks before recording starts.", keywords: ["pre-roll", "precount"]),
    "toggleAutopunch:": Spec(id: "recording.autopunch", category: "Recording", detail: "Record only inside the punch range.", keywords: ["punch in", "punch out"]),
    "setPunchToCycle:": Spec(id: "recording.punch_to_cycle", category: "Recording", detail: "Set the punch range to the cycle range."),
    "editTempo:": Spec(id: "transport.edit_tempo", category: "Transport", detail: "Focus the tempo field.", keywords: ["bpm"]),
    "addTempoChange:": Spec(id: "transport.add_tempo_change", category: "Transport", detail: "Add a tempo change at the playhead.", keywords: ["bpm", "tempo map"]),
    "addMeterChange:": Spec(id: "transport.add_meter_change", category: "Transport", detail: "Add a time signature change at the playhead.", keywords: ["meter", "signature"]),
    "removeTempoChange:": Spec(id: "transport.remove_tempo_change", category: "Transport", detail: "Remove the tempo change at the playhead."),
    "removeMeterChange:": Spec(id: "transport.remove_meter_change", category: "Transport", detail: "Remove the time signature change at the playhead."),
    "toggleInputMonitoring:": Spec(id: "recording.input_monitoring", category: "Recording", detail: "Armed tracks play their input (auto input monitoring).", keywords: ["monitor"]),
    "toggleGroupClutch:": Spec(id: "track.group_clutch", category: "Tracks", detail: "Suspend every track group (group clutch) until pressed again.", keywords: ["group", "clutch", "link"]),
    "toggleSelectedInputMonitor:": Spec(id: "track.input_monitor", category: "Tracks", detail: "Input Monitoring (I): hear the selected track's input now, recording or not.", keywords: ["monitor", "hear input", "live"]),
    // Tracks
    "newTrack:": Spec(id: "track.create_audio", category: "Tracks", detail: "Add an audio track after the selected one.", keywords: ["add", "insert"]),
    "newInstrumentTrack:": Spec(id: "track.create_midi", category: "Tracks", detail: "Add an instrument (MIDI) track.", keywords: ["software instrument", "midi"]),
    "newBus:": Spec(id: "track.create_bus", category: "Tracks", detail: "Add a bus track for sends and submixes.", keywords: ["aux", "return", "group"]),
    "createTrackStack:": Spec(id: "track.create_stack", category: "Tracks", detail: "Put the selected tracks into a summing stack.", keywords: ["folder", "group"]),
    "ungroupTrackStack:": Spec(id: "track.ungroup_stack", category: "Tracks", detail: "Dissolve the selected track stack."),
    "renameTrack:": Spec(id: "track.rename", category: "Tracks", detail: "Rename the selected track.", keywords: ["name"]),
    "deleteTrack:": Spec(id: "track.delete", category: "Tracks", detail: "Delete the selected track (undoable).", keywords: ["remove"]),
    "moveTrackUp:": Spec(id: "track.move_up", category: "Tracks", detail: "Move the selected track up one place.", keywords: ["reorder"]),
    "moveTrackDown:": Spec(id: "track.move_down", category: "Tracks", detail: "Move the selected track down one place.", keywords: ["reorder"]),
    "toggleMuteTrack:": Spec(id: "track.mute", category: "Tracks", detail: "Mute or unmute the selected track."),
    "toggleSoloTrack:": Spec(id: "track.solo", category: "Tracks", detail: "Solo or unsolo the selected track."),
    "toggleArmTrack:": Spec(id: "track.arm", category: "Tracks", detail: "Arm or disarm the selected track for recording.", keywords: ["record enable"]),
    "recolorTracksAsGradient:": Spec(id: "track.recolor_gradient", category: "Tracks", detail: "Recolour all tracks as a gradient.", keywords: ["color"]),
    "selectPreviousTrack:": Spec(id: "track.select_previous", category: "Timeline and Navigation", detail: "Select the track above.", keywords: ["move between tracks"], context: .arrangement),
    "selectNextTrack:": Spec(id: "track.select_next", category: "Timeline and Navigation", detail: "Select the track below.", keywords: ["move between tracks"], context: .arrangement),
    // Automation
    "clearAutomation:": Spec(id: "automation.clear", category: "Automation", detail: "Remove the selected track's automation."),
    "automationRead:": Spec(id: "automation.mode_read", category: "Automation", detail: "Automation plays back; moving controls doesn't record."),
    "automationTouch:": Spec(id: "automation.mode_touch", category: "Automation", detail: "Record while a control is held, then return to the lane."),
    "automationLatch:": Spec(id: "automation.mode_latch", category: "Automation", detail: "Record from the first touch until playback stops."),
    "toggleAutomation:": Spec(id: "automation.show", category: "Automation", detail: "Show or hide automation lanes.", keywords: ["lanes"]),
    "automateVolume:": Spec(id: "automation.volume", category: "Automation", detail: "Show the selected track's volume lane."),
    "automatePan:": Spec(id: "automation.pan", category: "Automation", detail: "Show the selected track's pan lane."),
    // Editing
    "undo:": Spec(id: "edit.undo", category: "Editing", detail: "Undo the last change."),
    "redo:": Spec(id: "edit.redo", category: "Editing", detail: "Redo the last undone change."),
    "delete:": Spec(id: "edit.delete", category: "Editing", detail: "Delete the selected clips or notes.", keywords: ["remove", "erase"]),
    "splitAtPlayhead": Spec(id: "edit.split_at_playhead", category: "Editing", detail: "Split the selected clip at the playhead.", keywords: ["cut", "separate", "razor", "scissors"]),
    "nudgeClipsLeft:": Spec(id: "edit.nudge_left", category: "Editing", detail: "Move the selected clips left by one grid step.", context: .arrangement),
    "nudgeClipsRight:": Spec(id: "edit.nudge_right", category: "Editing", detail: "Move the selected clips right by one grid step.", context: .arrangement),
    "copy:": Spec(id: "edit.copy", category: "Editing", detail: "Copy the selected clips.", context: .arrangement),
    "cut:": Spec(id: "edit.cut", category: "Editing", detail: "Cut the selected clips.", context: .arrangement),
    "paste:": Spec(id: "edit.paste", category: "Editing", detail: "Paste clips at the playhead on the selected track.", context: .arrangement),
    "duplicateClips:": Spec(id: "edit.duplicate", category: "Editing", detail: "Place a copy of the selected clips right after them.", keywords: ["repeat"], context: .arrangement),
    "selectAll:": Spec(id: "edit.select_all", category: "Editing", detail: "Select every clip.", context: .arrangement),
    // Clips and MIDI
    "newMidiClip:": Spec(id: "midi.new_clip", category: "MIDI Editing", detail: "Add an empty MIDI clip at the playhead."),
    "openPianoRoll:": Spec(id: "view.piano_roll", category: "Views and Windows", detail: "Open the piano roll for the selected MIDI clip.", keywords: ["editor", "notes"]),
    "quantizeClip:": Spec(id: "midi.quantize_clip", category: "MIDI Editing", detail: "Quantize the selected MIDI clip."),
    "openTakeFolder:": Spec(id: "clip.open_takes", category: "Clips", detail: "Open the selected take folder for comping."),
    "makeTakeFolder:": Spec(id: "clip.make_take_folder", category: "Clips", detail: "Make a take folder from the selected clips."),
    "addShortFades:": Spec(id: "clip.short_fades", category: "Clips", detail: "Add short fades to the selected clip."),
    "toggleClipMute:": Spec(id: "clip.toggle_mute", category: "Clips", detail: "Mute or unmute the selected clip."),
    "removeFades:": Spec(id: "clip.remove_fades", category: "Clips", detail: "Remove the selected clip's fades."),
    "doubleSpeed:": Spec(id: "clip.double_speed", category: "Clips", detail: "Play the selected clip twice as fast."),
    "halfSpeed:": Spec(id: "clip.half_speed", category: "Clips", detail: "Play the selected clip half as fast."),
    "transposeUp:": Spec(id: "clip.transpose_up", category: "Clips", detail: "Raise the selected clip a semitone."),
    "transposeDown:": Spec(id: "clip.transpose_down", category: "Clips", detail: "Lower the selected clip a semitone."),
    // Project
    "newDocument:": Spec(id: "project.new", category: "Project", detail: "Start a new project."),
    "openDocument:": Spec(id: "project.open", category: "Project", detail: "Open a project."),
    "saveDocument:": Spec(id: "project.save", category: "Project", detail: "Save the project."),
    "saveDocumentAs:": Spec(id: "project.save_as", category: "Project", detail: "Save the project under a new name."),
    "importAudio": Spec(id: "project.import_audio", category: "Project", detail: "Import audio files as new tracks."),
    "exportMix:": Spec(id: "project.export_mix", category: "Project", detail: "Render the mix to an audio file.", keywords: ["bounce", "render", "mixdown"]),
    // Views
    "showCommandPalette:": Spec(id: "view.command_palette", category: "Views and Windows", detail: "Search every command.", keywords: ["find", "search", "actions"]),
    "zoomIn": Spec(id: "view.zoom_in", category: "Timeline and Navigation", detail: "Zoom the arrangement in horizontally."),
    "zoomOut": Spec(id: "view.zoom_out", category: "Timeline and Navigation", detail: "Zoom the arrangement out horizontally."),
    "addMarker:": Spec(id: "transport.add_marker", category: "Timeline and Navigation", detail: "Add a marker at the playhead.", keywords: ["locator", "cue"]),
    "previousMarker:": Spec(id: "transport.previous_marker", category: "Timeline and Navigation", detail: "Move the playhead to the previous marker.", keywords: ["jump", "locator"]),
    "nextMarker:": Spec(id: "transport.next_marker", category: "Timeline and Navigation", detail: "Move the playhead to the next marker.", keywords: ["jump", "locator"]),
    "renameMarkerAtPlayhead:": Spec(id: "transport.rename_marker", category: "Timeline and Navigation", detail: "Rename the marker at the playhead."),
    "deleteMarkerAtPlayhead:": Spec(id: "transport.delete_marker", category: "Timeline and Navigation", detail: "Delete the marker at the playhead."),
    "hideTrack:": Spec(id: "track.hide", category: "Tracks", detail: "Hide the selected track (it keeps playing).", keywords: ["hide", "visibility"]),
    "showAllTracks:": Spec(id: "track.show_all", category: "Tracks", detail: "Show every hidden track.", keywords: ["unhide", "visibility"]),
    "duplicateTrack:": Spec(id: "track.duplicate", category: "Tracks", detail: "Duplicate the selected track with its clips, plug-ins and settings.", keywords: ["copy track"]),
    "zoomToSelection:": Spec(id: "view.zoom_to_selection", category: "Timeline and Navigation", detail: "Fit the selected clips in the window."),
    "tallerTracks:": Spec(id: "view.taller_tracks", category: "Timeline and Navigation", detail: "Vertical zoom in: taller tracks.", keywords: ["vertical zoom", "track height"]),
    "shorterTracks:": Spec(id: "view.shorter_tracks", category: "Timeline and Navigation", detail: "Vertical zoom out: shorter tracks.", keywords: ["vertical zoom", "track height"]),
    "zoomToFit": Spec(id: "view.zoom_to_fit", category: "Timeline and Navigation", detail: "Fit the whole project in the window.", keywords: ["fit project"]),
    "toggleMixer:": Spec(id: "mixer.toggle", category: "Mixer", detail: "Show or hide the mixer.", keywords: ["console"]),
    "toggleDevicePanel:": Spec(id: "view.device_panel", category: "Plug-ins", detail: "Show or hide the selected track's plug-ins.", keywords: ["effects", "pedalboard", "inserts"]),
    "toggleLauncher:": Spec(id: "view.clip_launcher", category: "Views and Windows", detail: "Show or hide the clip launcher.", keywords: ["session"]),
    "showPlugins:": Spec(id: "plugin.open_browser", category: "Plug-ins", detail: "Browse and insert plug-ins.", keywords: ["insert", "effect", "instrument"]),
    "toggleTrackBypass:": Spec(id: "plugin.bypass_track", category: "Plug-ins", detail: "Bypass (or turn back on) every plug-in on the selected track.", keywords: ["bypass", "disable", "footswitch"]),
    "showSettings:": Spec(id: "app.settings", category: "Views and Windows", detail: "Open Settings.", keywords: ["preferences"]),
    "showKeyboardShortcuts:": Spec(id: "app.keyboard_shortcuts", category: "Views and Windows", detail: "Edit keyboard shortcuts.", keywords: ["key commands", "keymap", "hotkeys"]),
    "toggleAnalogStyle:": Spec(id: "view.toggle_analog_mode", category: "Views and Windows", detail: "Switch between Graphite and Warm Analog.", keywords: ["theme", "appearance", "analog"]),
    "showTapeDeck:": Spec(id: "view.tape_deck", category: "Views and Windows", detail: "Show the tape machine (Analog Mode transport).", keywords: ["analog", "reels", "tape"]),
    "toggleFullScreen:": Spec(id: "view.full_screen", category: "Views and Windows", detail: "Enter or leave full screen."),
]

/// Actions handled inside a view (no menu item): the piano roll's editing keys.
private let viewActions: [(id: String, title: String, detail: String, keys: [KeyCombo])] = [
    ("midi.quantize", "Quantize Selected Notes", "Snap the selected notes to the grid.", [KeyCombo("q")]),
    ("midi.select_all", "Select All Notes", "Select every note in the clip.", [KeyCombo("a", .command)]),
    ("midi.transpose_up", "Transpose Notes Up", "Raise the selected notes a semitone.", [KeyCombo("up")]),
    ("midi.transpose_down", "Transpose Notes Down", "Lower the selected notes a semitone.", [KeyCombo("down")]),
    ("midi.transpose_octave_up", "Transpose Notes Up an Octave", "Raise the selected notes an octave.", [KeyCombo("up", .shift)]),
    ("midi.transpose_octave_down", "Transpose Notes Down an Octave", "Lower the selected notes an octave.", [KeyCombo("down", .shift)]),
    ("midi.nudge_left", "Nudge Notes Left", "Move the selected notes left by one grid step.", [KeyCombo("left")]),
    ("midi.nudge_right", "Nudge Notes Right", "Move the selected notes right by one grid step.", [KeyCombo("right")]),
    ("midi.step_insert", "Step Entry: Insert Note", "Insert a note at the step cursor (⌥ arrows move the cursor).", [KeyCombo("return"), KeyCombo("enter")]),
]

// MARK: Presets

struct ShortcutPreset {
    let id: String, title: String, note: String
    /// Bindings that replace the defaults for these actions (an empty list removes the default).
    let bindings: [String: [KeyCombo]]
    /// That DAW's well-known commands Dalnok doesn't have yet (shown in the editor; never bound).
    let unavailable: [String]

    private static func k(_ s: String) -> KeyCombo { KeyCombo(parsing: s)! }
    private static func b(_ pairs: [(String, [String])]) -> [String: [KeyCombo]] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1.map(k)) })
    }
    static let approximate = "Approximates commonly documented macOS defaults. Not verified against the application; check anything you rely on."
    static let all: [ShortcutPreset] = [
        ShortcutPreset(id: "dalnok", title: "Dalnok Default", note: "Dalnok's own layout.", bindings: [:], unavailable: []),
        ShortcutPreset(id: "logic", title: "Logic Pro", note: approximate, bindings: b([
            ("track.create_audio", ["opt+cmd+a"]), ("track.create_midi", ["opt+cmd+s"]), ("project.import_audio", ["shift+cmd+i"]),
            ("midi.quantize_clip", []), ("view.zoom_in", ["cmd+right"]), ("view.zoom_out", ["cmd+left"]),
        ]), unavailable: ["Smart Controls (B)", "Library (Y)", "Loop Browser (O)", "Flex View (⌘F)", "Toggle Region Mute (M)"]),
        ShortcutPreset(id: "ableton", title: "Ableton Live", note: approximate, bindings: b([
            ("edit.split_at_playhead", ["cmd+e"]), ("project.export_mix", ["shift+cmd+r"]), ("track.create_audio", ["cmd+t"]),
            ("track.create_midi", ["shift+cmd+t"]), ("track.mute", ["0"]), ("transport.record", ["f9"]),
            ("transport.loop_to_selection", ["cmd+l"]), ("view.clip_launcher", ["tab"]), ("track.rename", ["cmd+r"]),
            ("edit.duplicate", ["cmd+d"]),
        ]), unavailable: ["Key Map Mode (⌘K)", "MIDI Map Mode (⌘M)", "Consolidate (⌘J)", "Insert Silence (⌘I)"]),
        ShortcutPreset(id: "reaper", title: "REAPER", note: approximate, bindings: b([
            ("edit.split_at_playhead", ["s"]), ("project.export_mix", ["opt+cmd+r"]), ("track.create_audio", ["cmd+t"]),
            ("transport.record", ["cmd+r"]), ("transport.loop", ["r"]), ("mixer.toggle", ["cmd+m"]),
            ("transport.return_to_start", ["home", "w"]),
        ]), unavailable: ["Actions List (?)", "Item Properties (F2)", "Toggle Ripple Editing (⌥P)"]),
        ShortcutPreset(id: "protools", title: "Pro Tools", note: approximate, bindings: b([
            ("edit.split_at_playhead", ["cmd+e"]), ("edit.duplicate", ["cmd+d"]), ("track.create_audio", ["shift+cmd+n"]),
            ("mixer.toggle", ["cmd+="]), ("view.zoom_in", ["cmd+]"]), ("view.zoom_out", ["cmd+["]),
            ("transport.record", ["cmd+space", "f12"]), ("transport.loop", ["shift+cmd+l"]), ("project.export_mix", ["opt+cmd+b"]),
        ]), unavailable: ["Tab to Transient", "Zoom Presets (⌃1–5)", "Edit Modes (F1–F4)", "Memory Locations (⌘5)"]),
        ShortcutPreset(id: "cubase", title: "Cubase", note: approximate, bindings: b([
            ("edit.split_at_playhead", ["opt+x"]), ("transport.record", ["kp*"]), ("transport.loop", ["kp/"]),
            ("transport.return_to_start", ["kp.", "home"]), ("mixer.toggle", ["f3"]), ("transport.metronome", ["c"]),
            ("edit.duplicate", ["cmd+d"]),
        ]), unavailable: ["Key Editor (⌘E)", "Tool Keys (1–9)", "MixConsole 2/3 (F4/F5)"]),
        ShortcutPreset(id: "studioone", title: "Studio One", note: approximate, bindings: b([
            ("edit.split_at_playhead", ["opt+x"]), ("transport.record", ["kp*"]), ("transport.loop", ["kp/"]),
            ("mixer.toggle", ["f3"]), ("transport.metronome", ["c"]), ("edit.duplicate", ["cmd+d"]),
        ]), unavailable: ["Browser (F5)", "Add Tracks Dialog (T)", "Scratch Pads"]),
    ]
    static func named(_ id: String) -> ShortcutPreset { all.first { $0.id == id } ?? all[0] }
}

// MARK: Registry

@MainActor
final class ShortcutRegistry {
    static let shared = ShortcutRegistry()
    private(set) var actions: [ShortcutAction] = []
    private var byId: [String: ShortcutAction] = [:]
    /// Effective bindings: action id → combos (first is shown in the menu).
    private(set) var bindings: [String: [KeyCombo]] = [:]
    /// Set while the editor records a shortcut, so the key press reaches it and runs nothing.
    static var capturing = false
    var onChange: (() -> Void)?

    // Persistence (user defaults)
    static let presetKey = "shortcuts.preset", overridesKey = "shortcuts.overrides", userPresetsKey = "shortcuts.userPresets"
    var presetId: String {
        get { UserDefaults.standard.string(forKey: Self.presetKey) ?? SourceDAW.preferred?.presetId ?? "dalnok" }
        set { UserDefaults.standard.set(newValue, forKey: Self.presetKey) }
    }
    /// The owner's changes on top of the preset (id → combos; empty = shortcut removed).
    var overrides: [String: [KeyCombo]] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: [String]] ?? [:]
            return raw.mapValues { $0.compactMap(KeyCombo.init(parsing:)) }
        }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: Self.overridesKey) }
            else { UserDefaults.standard.set(newValue.mapValues { $0.map(\.storage) }, forKey: Self.overridesKey) }
        }
    }
    var userPresets: [String: [String: [String]]] {
        get { UserDefaults.standard.dictionary(forKey: Self.userPresetsKey) as? [String: [String: [String]]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.userPresetsKey) }
    }

    /// Reads every command from the menu (call after building it) and applies the effective shortcuts.
    func attach(_ menu: NSMenu?) {
        var list: [ShortcutAction] = [], seen = Set<String>()
        func visit(_ m: NSMenu, path: [String]) {
            for it in m.items where !it.isSeparatorItem {
                if let sub = it.submenu { visit(sub, path: path + [sub.title.isEmpty ? it.title : sub.title]); continue }
                guard let sel = it.action else { continue }
                let name = NSStringFromSelector(sel)
                let spec = specs[name]
                var id = spec?.id ?? "\((path.first ?? "app").lowercased()).\(name.replacingOccurrences(of: ":", with: ""))"
                if it.tag != 0 { id += ".\(it.tag)" }
                guard seen.insert(id).inserted else { continue } // the Help copy of an item is the same command
                let category = spec?.category ?? Self.category(forMenu: path.first ?? "")
                let title = path.count > 1 ? "\(path.dropFirst().joined(separator: " ▸ ")) ▸ \(it.title)" : it.title
                // A command's default is what the menu was built with, captured the first time it's seen (later
                // reads see menu items the registry has already re-keyed).
                if Self.builtDefaults[id] == nil { Self.builtDefaults[id] = KeyCombo(menuItem: it).map { [$0] } ?? [] }
                list.append(ShortcutAction(id: id, title: Self.baseTitle(title), category: category, detail: spec?.detail ?? "",
                                           keywords: spec?.keywords ?? [], context: spec?.context ?? .global,
                                           defaults: Self.builtDefaults[id]!, item: it, menuPath: path.joined(separator: " ▸ ")))
            }
        }
        if let menu { visit(menu, path: []) }
        for v in viewActions where seen.insert(v.id).inserted {
            list.append(ShortcutAction(id: v.id, title: v.title, category: "MIDI Editing", detail: v.detail, keywords: [], context: .pianoRoll,
                                       defaults: v.keys, item: nil, menuPath: "Piano Roll"))
        }
        actions = list
        byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        recompute()
    }
    private static var builtDefaults: [String: [KeyCombo]] = [:]
    /// "Undo Split" → "Undo": menu titles that change with state.
    private static func baseTitle(_ t: String) -> String { t.hasPrefix("Undo ") ? "Undo" : t.hasPrefix("Redo ") ? "Redo" : t }
    static func category(forMenu m: String) -> String {
        ["File": "Project", "Edit": "Editing", "Track": "Tracks", "Clip": "Clips", "Transport": "Transport", "Audio": "Recording",
         "View": "Views and Windows", "Window": "Views and Windows", "Help": "Help", "Dalnok": "Application"][m] ?? m
    }
    func action(_ id: String) -> ShortcutAction? { byId[id] }

    /// Bindings from the preset alone (before the owner's overrides).
    func presetBindings(_ preset: ShortcutPreset) -> [String: [KeyCombo]] {
        var out: [String: [KeyCombo]] = [:]
        for a in actions { out[a.id] = a.defaults }
        if preset.id.hasPrefix("user:"), let saved = userPresets[String(preset.id.dropFirst(5))] {
            for (id, keys) in saved where out[id] != nil { out[id] = keys.compactMap(KeyCombo.init(parsing:)) }
            return out
        }
        for (id, keys) in preset.bindings where out[id] != nil {
            // A preset's key wins: other commands lose that key in the same context.
            for k in keys { for (other, ks) in out where other != id && ks.contains(k) && clashes(other, id) { out[other] = ks.filter { $0 != k } } }
            out[id] = keys
        }
        return out
    }
    var currentPreset: ShortcutPreset {
        let id = presetId
        if id.hasPrefix("user:") { return ShortcutPreset(id: id, title: String(id.dropFirst(5)), note: "Your saved set.", bindings: [:], unavailable: []) }
        return ShortcutPreset.named(id)
    }
    private func clashes(_ a: String, _ b: String) -> Bool {
        guard let x = byId[a], let y = byId[b] else { return true }
        return x.context.clashes(y.context)
    }

    func recompute() {
        var out = presetBindings(currentPreset)
        for (id, keys) in overrides where out[id] != nil { out[id] = keys }
        bindings = out
        applyToMenu()
        onChange?()
    }

    /// Writes each command's first menu-representable shortcut onto its menu item (others are shown in the editor
    /// and the palette, and dispatched here).
    private func applyToMenu() {
        for a in actions {
            guard let it = a.item else { continue }
            let eq = (bindings[a.id] ?? []).lazy.compactMap(\.menuEquivalent).first
            it.keyEquivalent = eq?.0 ?? ""
            it.keyEquivalentModifierMask = eq?.1 ?? []
        }
    }
    func keys(_ id: String) -> [KeyCombo] { bindings[id] ?? [] }
    /// Whether any command (in any context) uses this key.
    func isBound(_ k: KeyCombo) -> Bool { bindings.values.contains { $0.contains(k) } }
    func display(_ id: String) -> String { keys(id).map(\.description).joined(separator: ", ") }

    // Editing
    func setKeys(_ id: String, _ keys: [KeyCombo]) {
        var o = overrides
        let base = presetBindings(currentPreset)[id] ?? []
        if keys == base { o[id] = nil } else { o[id] = keys }
        overrides = o
        recompute()
    }
    func add(_ k: KeyCombo, to id: String) { if !keys(id).contains(k) { setKeys(id, keys(id) + [k]) } }
    func remove(_ k: KeyCombo, from id: String) { setKeys(id, keys(id).filter { $0 != k }) }
    func restore(_ id: String) { var o = overrides; o[id] = nil; overrides = o; recompute() }
    func restoreAll() { overrides = [:]; recompute() }
    /// Gives `k` to `id`, taking it from every command that would conflict with it.
    func reassign(_ k: KeyCombo, to id: String) {
        for c in conflicts(for: k, in: byId[id]?.context ?? .global, excluding: id) { remove(k, from: c.id) }
        add(k, to: id)
    }
    func selectPreset(_ id: String) { presetId = id; overrides = [:]; recompute() }

    // Conflicts and reserved keys
    func conflicts(for k: KeyCombo, in context: ShortcutContext, excluding id: String? = nil) -> [ShortcutAction] {
        actions.filter { $0.id != id && $0.context.clashes(context) && keys($0.id).contains(k) }
    }
    /// Every pair of commands that share a key in overlapping contexts.
    /// Commands that this one overrides in its own context (or that override it), sharing `k`.
    func shadows(for k: KeyCombo, of a: ShortcutAction) -> [ShortcutAction] {
        actions.filter { $0.id != a.id && $0.context != a.context && $0.context.overlaps(a.context) && keys($0.id).contains(k) }
    }
    func allConflicts() -> [(KeyCombo, [ShortcutAction])] {
        var byKey: [KeyCombo: [ShortcutAction]] = [:]
        for a in actions { for k in keys(a.id) { byKey[k, default: []].append(a) } }
        var out: [(KeyCombo, [ShortcutAction])] = []
        for (k, as_) in byKey where as_.count > 1 {
            var clash: [ShortcutAction] = []
            for (i, a) in as_.enumerated() { for b in as_[(i + 1)...] where a.context.clashes(b.context) { clash += [a, b] } }
            if !clash.isEmpty { out.append((k, Array(Set(clash.map(\.id))).sorted().compactMap { byId[$0] })) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
    /// Shortcuts macOS keeps for itself (they never reach Dalnok, or would fight the system).
    static func reservedBySystem(_ k: KeyCombo) -> String? {
        let table: [String: String] = [
            "cmd+tab": "App switcher", "cmd+space": "Spotlight", "ctrl+space": "Input source", "opt+cmd+space": "Finder search",
            "cmd+`": "Cycle windows", "shift+cmd+3": "Screenshot", "shift+cmd+4": "Screenshot", "shift+cmd+5": "Screenshot", "opt+cmd+escape": "Force Quit",
            "ctrl+up": "Mission Control", "ctrl+down": "App windows", "ctrl+left": "Previous Space", "ctrl+right": "Next Space",
            "opt+cmd+d": "Dock", "ctrl+cmd+d": "Look Up", "ctrl+cmd+q": "Lock Screen",
        ]
        return table[k.storage]
    }

    // Dispatch

    /// A modal session, sheet or alert owns the keyboard (Return and Escape answer it); shortcuts stay out of its way.
    static var dialogInFront: Bool {
        if NSApp.modalWindow != nil { return true }
        if NSApp.windows.contains(where: { $0.isVisible && $0.attachedSheet != nil }) { return true }
        guard let key = NSApp.keyWindow else { return false }
        return key.isSheet || key.attachedSheet != nil || key is NSPanel && !(key is KeyPanel) && key.styleMask.contains(.titled) == false
            || String(describing: type(of: key)).contains("Alert")
    }
    /// The context the key press is in: the piano roll window, else the arrangement.
    static func activeContext() -> ShortcutContext {
        // The piano roll tracks its own focus (it stays "focused" even when the app is driven while inactive).
        if (NSApp.delegate as? AppDelegate)?.main?.pianoRollIsKey == true { return .pianoRoll }
        return (NSApp.keyWindow?.windowController is PianoRollController) ? .pianoRoll : .arrangement
    }
    /// The command bound to this key in the active context. Context-specific bindings win over global ones.
    func resolve(_ k: KeyCombo, context: ShortcutContext) -> ShortcutAction? {
        let hits = actions.filter { $0.context.overlaps(context) && keys($0.id).contains(k) }
        return hits.first { $0.context == context } ?? hits.first
    }
    /// Runs a key press: true if a command took it. Piano-roll commands are left to the piano roll's view.
    func handle(_ event: NSEvent) -> Bool {
        guard !Self.capturing, !Self.dialogInFront, let k = KeyCombo(event: event) else { return false }
        let context = Self.activeContext()
        guard let a = resolve(k, context: context) else { return false }
        if a.item == nil { return false } // a view-handled action: the focused view does it
        return perform(a)
    }
    /// Runs a command through its menu item (same validation and target as a click). Disabled commands swallow
    /// the key silently, as AppKit does.
    @discardableResult func perform(_ a: ShortcutAction) -> Bool {
        guard let it = a.item, let menu = it.menu else { return false }
        // Responder-chain commands (Cut, Copy, Paste, Select All): a text field being edited takes them first; when no
        // window in the chain takes them (the app driven while inactive), the arrangement does.
        if it.target == nil, let sel = it.action, NSApp.target(forAction: sel, to: nil, from: it) == nil,
           let main = (NSApp.delegate as? AppDelegate)?.main, main.responds(to: sel) {
            if main.validateMenuItem(it) { NSApp.sendAction(sel, to: main, from: it) }
            return true
        }
        menu.update()
        guard it.isEnabled else { return true }
        let i = menu.index(of: it)
        guard i >= 0 else { return false }
        menu.performActionForItem(at: i)
        return true
    }

    // Import / export

    func exportData() -> Data? {
        let doc: [String: Any] = ["format": "dalnok-shortcuts", "version": 1, "basedOn": presetId,
                                  "bindings": bindings.filter { !$0.value.isEmpty || overrides[$0.key] != nil }.mapValues { $0.map(\.storage) }]
        return try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }
    /// Imports a set as overrides on its base preset. Unknown commands and unreadable keys are skipped and counted.
    func importData(_ data: Data) throws -> (applied: Int, skipped: Int) {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any], doc["format"] as? String == "dalnok-shortcuts",
              let raw = doc["bindings"] as? [String: [String]] else {
            throw NSError(domain: "Dalnok", code: 1, userInfo: [NSLocalizedDescriptionKey: "This isn't a Dalnok keyboard shortcut file."])
        }
        let base = (doc["basedOn"] as? String).flatMap { id in ShortcutPreset.all.contains { $0.id == id } || id.hasPrefix("user:") ? id : nil } ?? "dalnok"
        presetId = base
        let preset = presetBindings(currentPreset)
        var o: [String: [KeyCombo]] = [:], skipped = 0
        for (id, list) in raw {
            guard byId[id] != nil else { skipped += 1; continue }
            let keys = list.compactMap(KeyCombo.init(parsing:))
            skipped += list.count - keys.count
            if keys != preset[id] { o[id] = keys }
        }
        overrides = o
        recompute()
        return (raw.count - skipped, skipped)
    }
    /// Saves the current bindings as a named set (shown with the presets).
    func saveUserPreset(_ name: String) {
        var u = userPresets
        u[name] = bindings.mapValues { $0.map(\.storage) }
        userPresets = u
        presetId = "user:" + name
        overrides = [:]
        recompute()
    }
}

extension SourceDAW {
    var presetId: String { self == .logic ? "logic" : self == .ableton ? "ableton" : "reaper" }
}
