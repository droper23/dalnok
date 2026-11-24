// Render compiler: model -> RenderState snapshot (A-06). See render_compiler.cpp.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "model.hpp"
#include "plugin_service.hpp"
#include "render.hpp"
#include "stretch_cache.hpp"
#include "tempo_map.hpp"

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace dalnok {

StretchKey stretchKeyOf(const ClipState &c);

/// What a compile reads. Live compiles pass the engine's own plug-in instances and master runtime; offline renders
/// pass their own instances and get fresh delay lines and a separate master runtime.
struct CompileInputs {
    const Model &model;
    const std::map<DalnokMediaId, PoolEntry> &pool;
    const StretchCache &stretch;
    const TempoMap &tempo;
    double sampleRate;
    const std::shared_ptr<TrackRuntime> &master;
    const PluginHostService::PluginMap &plugins;
};

class RenderCompiler {
public:
    using PluginMap = PluginHostService::PluginMap;
    /// `live`: reuse and update the cached per-track content and delay lines (the snapshot the audio thread plays).
    std::unique_ptr<RenderState> compile(const CompileInputs &inputs, std::vector<StretchJob> *needed, bool live);
    /// Tracks whose reused content differs from a fresh build (tests).
    int32_t mismatches(const CompileInputs &inputs);
    void clear() { content_.clear(); delays_.clear(); }

private:
    // Per-track content cache for incremental compilation (A-04). A key records every clip input the content
    // build reads; it holds the media and note lists strongly, so a pointer match can never be a reused address.
    struct ClipKey {
        DalnokClipId id = 0;
        int32_t slot = -1, follow = 0, followLoops = 1, fadeCurve = 0;
        bool muted = false, alt = false, preservePitch = true;
        NoteList notes;
        CCList controllers;
        int64_t loopLength = 0, loopPhase = 0;
        DalnokMediaId mediaId = 0;
        std::shared_ptr<const Media> media, derived; // resolved pool media; finished stretch (stretched clips)
        int64_t start = 0, offset = 0, length = 0, fadeIn = 0, fadeOut = 0;
        float gainDb = 0, pitch = 0;
        double rate = 1.0;
        WarpMap warp;
    };
    struct ContentEntry {
        bool instrument = false;
        std::vector<ClipKey> clips;
        std::shared_ptr<const TrackContent> content;
        std::vector<StretchJob> needed; // stretch jobs this content is waiting for
    };
    const PoolEntry *pool(DalnokMediaId id) const;
    const Media *resolvedMedia(const ClipState &c);
    std::shared_ptr<const Media> resolvedStretch(const ClipState &c, const Media *media);
    bool sameInputs(const ClipKey &k, const ClipState &c);
    std::shared_ptr<const TrackContent> buildContent(const std::vector<const ClipState *> &clips, bool instrument,
                                                     std::vector<StretchJob> &needed);

    const CompileInputs *in_ = nullptr; // during a call
    std::map<DalnokTrackId, ContentEntry> content_;
    std::map<std::string, std::shared_ptr<DelayLine>> delays_;
};

} // namespace dalnok
