// C API facade over the C++ engine.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "atrium/atrium.h"
#include "engine.hpp"

#include <cstring>

using namespace atrium;

struct AtriumEngine {
    Engine impl;
    explicit AtriumEngine(double sr) : impl(sr) {}
};

struct AtriumMedia {
    std::shared_ptr<const Media> impl;
};

namespace {
void setErr(char *buf, size_t len, const std::string &msg) {
    if (!buf || len == 0) return;
    const size_t n = std::min(len - 1, msg.size());
    std::memcpy(buf, msg.data(), n);
    buf[n] = '\0';
}
} // namespace

extern "C" {

AtriumEngine *atrium_engine_create(double sample_rate) { return new AtriumEngine(sample_rate); }
void atrium_engine_destroy(AtriumEngine *e) { delete e; }

AtriumStatus atrium_engine_start_device(AtriumEngine *e, char *err, size_t err_len) {
    if (!e) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.startDevice(msg)) {
        setErr(err, err_len, msg);
        return ATRIUM_ERR_DEVICE;
    }
    return ATRIUM_OK;
}
void atrium_engine_stop_device(AtriumEngine *e) {
    if (e) e->impl.stopDevice();
}
bool atrium_engine_device_running(const AtriumEngine *e) { return e && e->impl.deviceRunning(); }
double atrium_engine_sample_rate(const AtriumEngine *e) { return e ? e->impl.sampleRate() : 0; }
void atrium_engine_collect_garbage(AtriumEngine *e) {
    if (e) e->impl.collectGarbage();
}

AtriumStatus atrium_media_load(const char *path, double sample_rate, AtriumMedia **out, char *err, size_t err_len) {
    if (!path || !out) return ATRIUM_ERR_INVALID_ARG;
    std::vector<std::vector<float>> ch;
    std::string msg;
    if (!decodeAudioFile(path, sample_rate, ch, msg)) {
        setErr(err, err_len, msg);
        return ATRIUM_ERR_IO;
    }
    *out = new AtriumMedia{std::make_shared<const Media>(std::move(ch), sample_rate)};
    return ATRIUM_OK;
}

AtriumMedia *atrium_media_from_samples(const float *const *channels, int32_t count, int64_t frames, double sr) {
    if (!channels || count < 1 || count > 2 || frames <= 0 || sr <= 0) return nullptr;
    std::vector<std::vector<float>> ch;
    for (int32_t c = 0; c < count; ++c) ch.emplace_back(channels[c], channels[c] + frames);
    return new AtriumMedia{std::make_shared<const Media>(std::move(ch), sr)};
}

void atrium_media_release(AtriumMedia *m) { delete m; }
int64_t atrium_media_frames(const AtriumMedia *m) { return m ? m->impl->frames() : 0; }
int32_t atrium_media_channels(const AtriumMedia *m) { return m ? m->impl->channelCount() : 0; }
double atrium_media_sample_rate(const AtriumMedia *m) { return m ? m->impl->sampleRate() : 0; }

int64_t atrium_media_peaks(const AtriumMedia *m, int32_t channel, int64_t start, double fpc, float *mins,
                           float *maxs, int64_t count) {
    if (!m || !mins || !maxs) return 0;
    return m->impl->peaks(channel, start, fpc, mins, maxs, count);
}

AtriumTrackId atrium_track_add(AtriumEngine *e, const char *name) {
    return e ? e->impl.addTrack(name ? name : "") : 0;
}
AtriumStatus atrium_track_remove(AtriumEngine *e, AtriumTrackId t) {
    return e && e->impl.removeTrack(t) ? ATRIUM_OK : ATRIUM_ERR_NOT_FOUND;
}
AtriumStatus atrium_track_set_gain_db(AtriumEngine *e, AtriumTrackId t, float db) {
    return e && e->impl.setGainDb(t, db) ? ATRIUM_OK : ATRIUM_ERR_NOT_FOUND;
}
AtriumStatus atrium_track_set_pan(AtriumEngine *e, AtriumTrackId t, float pan) {
    return e && e->impl.setPan(t, pan) ? ATRIUM_OK : ATRIUM_ERR_NOT_FOUND;
}
AtriumStatus atrium_track_set_mute(AtriumEngine *e, AtriumTrackId t, bool muted) {
    return e && e->impl.setMute(t, muted) ? ATRIUM_OK : ATRIUM_ERR_NOT_FOUND;
}

AtriumClipId atrium_clip_add(AtriumEngine *e, AtriumTrackId t, AtriumMedia *m, int64_t start, int64_t offset,
                             int64_t length) {
    if (!e || !m) return 0;
    return e->impl.addClip(t, m->impl, start, offset, length);
}
AtriumStatus atrium_clip_remove(AtriumEngine *e, AtriumClipId c) {
    return e && e->impl.removeClip(c) ? ATRIUM_OK : ATRIUM_ERR_NOT_FOUND;
}
int64_t atrium_session_length(const AtriumEngine *e) { return e ? e->impl.sessionLength() : 0; }

void atrium_transport_play(AtriumEngine *e) {
    if (e) e->impl.play();
}
void atrium_transport_pause(AtriumEngine *e) {
    if (e) e->impl.pause();
}
void atrium_transport_seek(AtriumEngine *e, int64_t frame) {
    if (e) e->impl.seek(frame);
}
bool atrium_transport_is_playing(const AtriumEngine *e) { return e && e->impl.playing(); }
int64_t atrium_transport_position(const AtriumEngine *e) { return e ? e->impl.position() : 0; }

AtriumStatus atrium_render_offline(AtriumEngine *e, int64_t start, int64_t frames, float *l, float *r) {
    return e && e->impl.renderOffline(start, frames, l, r) ? ATRIUM_OK : ATRIUM_ERR_INVALID_ARG;
}
AtriumStatus atrium_render_to_wav(AtriumEngine *e, const char *path, int64_t start, int64_t frames, int32_t bits,
                                  char *err, size_t err_len) {
    if (!e || !path) return ATRIUM_ERR_INVALID_ARG;
    std::string msg;
    if (!e->impl.renderToWav(path, start, frames, bits, msg)) {
        setErr(err, err_len, msg);
        return ATRIUM_ERR_IO;
    }
    return ATRIUM_OK;
}

void atrium_engine_stats(const AtriumEngine *e, AtriumStats *out) {
    if (e && out) e->impl.stats(*out);
}
void atrium_engine_reset_stats(AtriumEngine *e) {
    if (e) e->impl.resetStats();
}

} // extern "C"
