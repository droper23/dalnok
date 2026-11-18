// CLAP plug-in hosting (ADR-0009): loads a .clap bundle in this process behind PluginProcessor, like VST3.
// Main-thread work (init, activate, parameters' text, state, GUI) happens on the control thread; process()
// runs on the audio thread and is the one call into plugin code there.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plugin_host.hpp"
#include "rt.hpp"

#include <clap/clap.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace dalnok {
namespace {

struct ParamChange { clap_id id; double value; }; // plain values

class ClapProcessor final : public PluginProcessor {
public:
    ~ClapProcessor() override {
        closeEditor();
        if (plugin_) {
            if (active_) plugin_->deactivate(plugin_);
            plugin_->destroy(plugin_);
        }
        if (entry_) entry_->deinit();
        if (bundle_) CFRelease(bundle_);
    }

    bool open(const std::string &path, const std::string &wantedId, double rate, int maxBlock, std::string &err) {
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path.c_str()),
                                                               static_cast<CFIndex>(path.size()), true);
        bundle_ = url ? CFBundleCreate(nullptr, url) : nullptr;
        if (url) CFRelease(url);
        if (!bundle_ || !CFBundleLoadExecutable(bundle_)) { err = "cannot load the CLAP bundle"; return false; }
        entry_ = static_cast<const clap_plugin_entry_t *>(CFBundleGetDataPointerForName(bundle_, CFSTR("clap_entry")));
        if (!entry_ || !clap_version_is_compatible(entry_->clap_version) || !entry_->init(path.c_str())) {
            entry_ = nullptr;
            err = "not a compatible CLAP plug-in";
            return false;
        }
        auto *factory = static_cast<const clap_plugin_factory_t *>(entry_->get_factory(CLAP_PLUGIN_FACTORY_ID));
        if (!factory || factory->get_plugin_count(factory) == 0) { err = "the CLAP bundle has no plug-ins"; return false; }
        const clap_plugin_descriptor_t *desc = nullptr;
        for (uint32_t i = 0; i < factory->get_plugin_count(factory); ++i) {
            const auto *d = factory->get_plugin_descriptor(factory, i);
            if (d && (wantedId.empty() || wantedId == d->id)) { desc = d; break; }
        }
        if (!desc) { err = "no such plug-in in the CLAP bundle"; return false; }
        host_.clap_version = CLAP_VERSION;
        host_.host_data = this;
        host_.name = "Dalnok";
        host_.vendor = "Dalnok";
        host_.url = "";
        host_.version = "1";
        host_.get_extension = [](const clap_host_t *h, const char *id) -> const void * {
            auto *self = static_cast<ClapProcessor *>(h->host_data);
            if (!std::strcmp(id, CLAP_EXT_GUI)) return &self->hostGui_;
            if (!std::strcmp(id, CLAP_EXT_LATENCY)) return &self->hostLatency_;
            if (!std::strcmp(id, CLAP_EXT_PARAMS)) return &self->hostParams_;
            return nullptr;
        };
        host_.request_restart = [](const clap_host_t *) {};
        host_.request_process = [](const clap_host_t *) {};
        host_.request_callback = [](const clap_host_t *h) {
            auto *self = static_cast<ClapProcessor *>(h->host_data);
            dispatch_async_f(dispatch_get_main_queue(), self->alive_.get(), [](void *ctx) {
                auto *alive = static_cast<Alive *>(ctx);
                if (alive->self && alive->self->plugin_) alive->self->plugin_->on_main_thread(alive->self->plugin_);
            });
        };
        hostGui_.resize_hints_changed = [](const clap_host_t *) {};
        hostGui_.request_resize = [](const clap_host_t *h, uint32_t w, uint32_t hh) {
            auto *self = static_cast<ClapProcessor *>(h->host_data);
            if (self->onResize_) self->onResize_(self->resizeCtx_, static_cast<int32_t>(w), static_cast<int32_t>(hh));
            return true;
        };
        hostGui_.request_show = [](const clap_host_t *) { return false; };
        hostGui_.request_hide = [](const clap_host_t *) { return false; };
        hostGui_.closed = [](const clap_host_t *, bool) {};
        hostLatency_.changed = [](const clap_host_t *) {};
        hostParams_.rescan = [](const clap_host_t *, clap_param_rescan_flags) {};
        hostParams_.clear = [](const clap_host_t *, clap_id, clap_param_clear_flags) {};
        hostParams_.request_flush = [](const clap_host_t *) {};
        alive_ = std::make_shared<Alive>();
        alive_->self = this;

        plugin_ = factory->create_plugin(factory, &host_, desc->id);
        if (!plugin_ || !plugin_->init(plugin_)) { err = "the CLAP plug-in failed to start"; if (plugin_) plugin_->destroy(plugin_); plugin_ = nullptr; return false; }
        name_ = desc->name ? desc->name : "CLAP";
        vendor_ = desc->vendor ? desc->vendor : "";
        classId_ = desc->id;
        for (const char *const *f = desc->features; f && *f; ++f) categories_ += (categories_.empty() ? "" : "|") + std::string(*f);
        params_ = static_cast<const clap_plugin_params_t *>(plugin_->get_extension(plugin_, CLAP_EXT_PARAMS));
        state_ = static_cast<const clap_plugin_state_t *>(plugin_->get_extension(plugin_, CLAP_EXT_STATE));
        latency_ = static_cast<const clap_plugin_latency_t *>(plugin_->get_extension(plugin_, CLAP_EXT_LATENCY));
        gui_ = static_cast<const clap_plugin_gui_t *>(plugin_->get_extension(plugin_, CLAP_EXT_GUI));
        const auto *ports = static_cast<const clap_plugin_audio_ports_t *>(plugin_->get_extension(plugin_, CLAP_EXT_AUDIO_PORTS));
        const auto *notes = static_cast<const clap_plugin_note_ports_t *>(plugin_->get_extension(plugin_, CLAP_EXT_NOTE_PORTS));
        inputs_ = ports ? ports->count(plugin_, true) : 0;
        const uint32_t outputs = ports ? ports->count(plugin_, false) : 0;
        if (outputs < 1) { err = "the CLAP plug-in has no audio output"; return false; }
        hasNotes_ = notes && notes->count(plugin_, true) > 0;
        instrument_ = inputs_ == 0 && hasNotes_;
        // A second input port that isn't the main one is the sidechain.
        if (inputs_ >= 2) {
            clap_audio_port_info_t info{};
            sidechain_ = ports->get(plugin_, 1, true, &info) && !(info.flags & CLAP_AUDIO_PORT_IS_MAIN);
        }
        if (!plugin_->activate(plugin_, rate, 1, static_cast<uint32_t>(maxBlock))) { err = "the CLAP plug-in could not be activated"; return false; }
        active_ = true;
        inL_.assign(static_cast<size_t>(maxBlock), 0.0f);
        inR_.assign(static_cast<size_t>(maxBlock), 0.0f);
        silence_.assign(static_cast<size_t>(maxBlock), 0.0f);
        // Parameter ranges for automation and normalized values.
        for (uint32_t i = 0; params_ && i < params_->count(plugin_); ++i) {
            clap_param_info_t info{};
            if (params_->get_info(plugin_, i, &info)) ranges_[info.id] = {info.min_value, info.max_value};
        }
        return true;
    }

    bool instrument() const override { return instrument_; }
    uint32_t latency() const override { return latency_ ? latency_->get(plugin_) : 0; }
    const std::string &name() const override { return name_; }
    const std::string &vendor() const override { return vendor_; }
    const std::string &classId() const override { return classId_; }
    bool hasSidechain() const override { return sidechain_; }

    void process(float *left, float *right, int frames, const PluginNote *notes, int noteCount) DALNOK_NONBLOCKING override {
        // Input events: queued parameter changes, automation, then notes (sorted by time already).
        eventCount_ = 0;
        ParamChange c;
        while (changes_.pop(c)) pushParam(c.id, c.value, 0);
        for (int i = 0; i < autoCount_; ++i) pushParam(autoQueue_[i].id, autoQueue_[i].value, 0);
        autoCount_ = 0;
        for (int i = 0; i < noteCount && eventCount_ < kMaxEvents; ++i) {
            Event &e = events_[eventCount_++];
            e.note = clap_event_note_t{};
            e.note.header = {sizeof(clap_event_note_t), static_cast<uint32_t>(notes[i].offset), CLAP_CORE_EVENT_SPACE_ID,
                             static_cast<uint16_t>(notes[i].on ? CLAP_EVENT_NOTE_ON : CLAP_EVENT_NOTE_OFF), 0};
            e.note.note_id = -1;
            e.note.port_index = 0;
            e.note.channel = 0;
            e.note.key = notes[i].pitch;
            e.note.velocity = notes[i].on ? notes[i].velocity / 127.0 : 0.0;
        }
        // Stable order by time (parameter changes are at 0).
        for (int i = 1; i < eventCount_; ++i) {
            Event e = events_[i];
            int j = i - 1;
            while (j >= 0 && events_[j].header().time > e.header().time) { events_[j + 1] = events_[j]; --j; }
            events_[j + 1] = e;
        }
        for (int i = 0; i < frames; ++i) { inL_[static_cast<size_t>(i)] = left[i]; inR_[static_cast<size_t>(i)] = right[i]; }
        float *inPtr[2] = {inL_.data(), inR_.data()};
        float *scPtr[2] = {const_cast<float *>(scL_ ? scL_ : silence_.data()), const_cast<float *>(scR_ ? scR_ : silence_.data())};
        float *outPtr[2] = {left, right};
        clap_audio_buffer_t ins[2] = {{inPtr, nullptr, 2, 0, 0}, {scPtr, nullptr, 2, 0, 0}};
        clap_audio_buffer_t out = {outPtr, nullptr, 2, 0, 0};
        clap_input_events_t in = {this, [](const clap_input_events_t *l) -> uint32_t { return static_cast<uint32_t>(static_cast<const ClapProcessor *>(l->ctx)->eventCount_); },
                                  [](const clap_input_events_t *l, uint32_t i) -> const clap_event_header_t * { return &static_cast<const ClapProcessor *>(l->ctx)->events_[i].header(); }};
        clap_output_events_t outEvents = {this, [](const clap_output_events_t *, const clap_event_header_t *) { return true; }};
        clap_process_t p{};
        p.steady_time = -1;
        p.frames_count = static_cast<uint32_t>(frames);
        p.audio_inputs = inputs_ > 0 ? ins : nullptr;
        p.audio_inputs_count = inputs_ == 0 ? 0 : (sidechain_ ? 2 : 1);
        p.audio_outputs = &out;
        p.audio_outputs_count = 1;
        p.in_events = &in;
        p.out_events = &outEvents;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
        // Plugin code (ADR-0009): the one unverifiable call on the audio thread.
        if (!processing_) processing_ = plugin_->start_processing(plugin_);
        if (plugin_->process(plugin_, &p) == CLAP_PROCESS_ERROR) for (int i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
#pragma clang diagnostic pop
    }

    bool getState(std::string &bytes) override {
        if (!state_) return false;
        bytes.clear();
        clap_ostream_t s{&bytes, [](const clap_ostream_t *st, const void *buf, uint64_t size) -> int64_t {
                             static_cast<std::string *>(st->ctx)->append(static_cast<const char *>(buf), static_cast<size_t>(size));
                             return static_cast<int64_t>(size);
                         }};
        return state_->save(plugin_, &s);
    }
    bool setState(const std::string &bytes) override {
        if (!state_) return bytes.empty();
        struct Reader { const std::string *b; size_t at; } r{&bytes, 0};
        clap_istream_t s{&r, [](const clap_istream_t *st, void *buf, uint64_t size) -> int64_t {
                             auto *rd = static_cast<Reader *>(st->ctx);
                             const size_t n = std::min<size_t>(static_cast<size_t>(size), rd->b->size() - rd->at);
                             std::memcpy(buf, rd->b->data() + rd->at, n);
                             rd->at += n;
                             return static_cast<int64_t>(n);
                         }};
        return state_->load(plugin_, &s);
    }

    std::string categories() const override { return categories_; }
    int32_t parameterCount() override { return params_ ? static_cast<int32_t>(params_->count(plugin_)) : 0; }
    bool parameter(int32_t index, PluginParameter &out) override {
        clap_param_info_t info{};
        if (!params_ || index < 0 || !params_->get_info(plugin_, static_cast<uint32_t>(index), &info)) return false;
        double value = info.default_value;
        if (auto it = touched_.find(info.id); it != touched_.end()) value = it->second;
        else params_->get_value(plugin_, info.id, &value);
        const double span = info.max_value - info.min_value;
        out.id = info.id;
        out.title = info.name;
        out.value = span > 0 ? (value - info.min_value) / span : 0;
        out.defaultValue = span > 0 ? (info.default_value - info.min_value) / span : 0;
        out.stepCount = (info.flags & CLAP_PARAM_IS_STEPPED) ? static_cast<int32_t>(span) : 0;
        out.automatable = info.flags & CLAP_PARAM_IS_AUTOMATABLE;
        out.readOnly = info.flags & CLAP_PARAM_IS_READONLY;
        out.hidden = info.flags & CLAP_PARAM_IS_HIDDEN;
        char text[128] = {};
        if (params_->value_to_text(plugin_, info.id, value, text, sizeof text)) out.display = text;
        return true;
    }
    bool parameterText(uint32_t id, double normalized, std::string &out) override {
        auto it = ranges_.find(id);
        if (!params_ || it == ranges_.end()) return false;
        const double plain = it->second.first + std::clamp(normalized, 0.0, 1.0) * (it->second.second - it->second.first);
        char text[128] = {};
        if (!params_->value_to_text(plugin_, id, plain, text, sizeof text)) return false;
        out = text;
        return true;
    }
    bool setParameter(uint32_t id, double normalized) override {
        auto it = ranges_.find(id);
        if (it == ranges_.end() || !(normalized >= 0 && normalized <= 1)) return false;
        const double plain = it->second.first + normalized * (it->second.second - it->second.first);
        std::lock_guard<std::mutex> g(producer_);
        touched_[id] = plain;
        return changes_.push(ParamChange{id, plain});
    }
    void touchedParameters(std::vector<std::pair<uint32_t, double>> &out) override {
        std::lock_guard<std::mutex> g(producer_);
        out.clear();
        for (const auto &[id, plain] : touched_) {
            const auto r = ranges_[id];
            out.push_back({id, r.second > r.first ? (plain - r.first) / (r.second - r.first) : 0});
        }
    }
    uint64_t editCount() const override { return 0; }
    bool automationRange(uint32_t id, double &lo, double &hi) override {
        auto it = ranges_.find(id);
        if (it == ranges_.end()) return false;
        lo = it->second.first; hi = it->second.second;
        return true;
    }

    bool hasEditor() override { return gui_ && gui_->is_api_supported(plugin_, CLAP_WINDOW_API_COCOA, false); }
    bool openEditor(void *parent, int32_t &width, int32_t &height, void (*onResize)(void *, int32_t, int32_t), void *ctx,
                    std::string &err) override {
        closeEditor();
        if (!hasEditor() || !gui_->create(plugin_, CLAP_WINDOW_API_COCOA, false)) { err = "this CLAP plug-in has no editor"; return false; }
        guiOpen_ = true;
        onResize_ = onResize;
        resizeCtx_ = ctx;
        uint32_t w = 640, h = 400;
        gui_->get_size(plugin_, &w, &h);
        clap_window_t window{CLAP_WINDOW_API_COCOA, {}};
        window.cocoa = parent;
        if (!gui_->set_parent(plugin_, &window)) { closeEditor(); err = "the CLAP editor could not attach"; return false; }
        gui_->show(plugin_);
        width = static_cast<int32_t>(w);
        height = static_cast<int32_t>(h);
        return true;
    }
    void closeEditor() override {
        if (guiOpen_ && gui_) { gui_->hide(plugin_); gui_->destroy(plugin_); }
        guiOpen_ = false;
        onResize_ = nullptr;
    }

private:
    struct Alive { ClapProcessor *self = nullptr; };
    union Event {
        clap_event_note_t note;
        clap_event_param_value_t param;
        const clap_event_header_t &header() const { return note.header; }
    };
    void pushParam(clap_id id, double value, uint32_t time) DALNOK_NONBLOCKING {
        if (eventCount_ >= kMaxEvents) return;
        Event &e = events_[eventCount_++];
        e.param = clap_event_param_value_t{};
        e.param.header = {sizeof(clap_event_param_value_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0};
        e.param.param_id = id;
        e.param.note_id = -1;
        e.param.port_index = -1;
        e.param.channel = -1;
        e.param.key = -1;
        e.param.value = value;
    }

    CFBundleRef bundle_ = nullptr;
    const clap_plugin_entry_t *entry_ = nullptr;
    const clap_plugin_t *plugin_ = nullptr;
    clap_host_t host_{};
    clap_host_gui_t hostGui_{};
    clap_host_latency_t hostLatency_{};
    clap_host_params_t hostParams_{};
    std::shared_ptr<Alive> alive_;
    const clap_plugin_params_t *params_ = nullptr;
    const clap_plugin_state_t *state_ = nullptr;
    const clap_plugin_latency_t *latency_ = nullptr;
    const clap_plugin_gui_t *gui_ = nullptr;
    uint32_t inputs_ = 0;
    bool hasNotes_ = false, instrument_ = false, sidechain_ = false, active_ = false, processing_ = false, guiOpen_ = false;
    std::string name_, vendor_, classId_;
    std::string categories_;
    std::vector<float> inL_, inR_, silence_;
    static constexpr int kMaxEvents = 1024;
    Event events_[kMaxEvents]{};
    int eventCount_ = 0;
    SpscQueue<ParamChange, 1024> changes_;
    std::mutex producer_;
    std::map<uint32_t, double> touched_; // plain values set from the control thread
    std::map<uint32_t, std::pair<double, double>> ranges_;
    void (*onResize_)(void *, int32_t, int32_t) = nullptr;
    void *resizeCtx_ = nullptr;
};

} // namespace

std::unique_ptr<PluginProcessor> loadClap(const std::string &path, const std::string &id, double sampleRate, int maxBlock,
                                          std::string &err) {
    auto p = std::make_unique<ClapProcessor>();
    if (!p->open(path, id, sampleRate, maxBlock, err)) return nullptr;
    return p;
}

} // namespace dalnok
