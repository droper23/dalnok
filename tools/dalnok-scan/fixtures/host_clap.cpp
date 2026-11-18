// Test CLAP plug-in: stereo gain with state and a sidechain input that ducks the main input.
// SPDX-License-Identifier: GPL-3.0-or-later
#include <clap/clap.h>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <cstdio>

namespace {
struct Gain {
    clap_plugin_t plugin;
    const clap_host_t *host;
    double gain = 0.5;
};

const clap_plugin_descriptor_t kDesc = {CLAP_VERSION, "org.dalnok.test-gain", "Dalnok Test CLAP Gain", "Dalnok Tests", "", "", "", "1.0", "",
                                        (const char *[]){CLAP_PLUGIN_FEATURE_AUDIO_EFFECT, nullptr}};

Gain *self(const clap_plugin_t *p) { return static_cast<Gain *>(p->plugin_data); }

uint32_t portsCount(const clap_plugin_t *, bool isInput) { return isInput ? 2 : 1; }
bool portsGet(const clap_plugin_t *, uint32_t index, bool isInput, clap_audio_port_info_t *info) {
    if (index >= (isInput ? 2u : 1u)) return false;
    info->id = isInput ? index : 2;
    std::snprintf(info->name, sizeof info->name, "%s", index == 1 ? "Sidechain" : (isInput ? "In" : "Out"));
    info->flags = index == 0 ? CLAP_AUDIO_PORT_IS_MAIN : 0;
    info->channel_count = 2;
    info->port_type = CLAP_PORT_STEREO;
    info->in_place_pair = CLAP_INVALID_ID;
    return true;
}
const clap_plugin_audio_ports_t kPorts = {portsCount, portsGet};

uint32_t paramsCount(const clap_plugin_t *) { return 1; }
bool paramsInfo(const clap_plugin_t *, uint32_t index, clap_param_info_t *info) {
    if (index != 0) return false;
    std::memset(info, 0, sizeof *info);
    info->id = 7;
    info->flags = CLAP_PARAM_IS_AUTOMATABLE;
    std::snprintf(info->name, sizeof info->name, "Gain");
    info->min_value = 0;
    info->max_value = 1;
    info->default_value = 0.5;
    return true;
}
bool paramsValue(const clap_plugin_t *p, clap_id id, double *v) { if (id != 7) return false; *v = self(p)->gain; return true; }
bool paramsToText(const clap_plugin_t *, clap_id, double v, char *out, uint32_t size) { std::snprintf(out, size, "%.0f %%", v * 100); return true; }
bool paramsFromText(const clap_plugin_t *, clap_id, const char *, double *) { return false; }
void paramsFlush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *) {
    for (uint32_t i = 0; in && i < in->size(in); ++i) {
        const auto *h = in->get(in, i);
        if (h->type == CLAP_EVENT_PARAM_VALUE) self(p)->gain = reinterpret_cast<const clap_event_param_value_t *>(h)->value;
    }
}
const clap_plugin_params_t kParams = {paramsCount, paramsInfo, paramsValue, paramsToText, paramsFromText, paramsFlush};

bool stateSave(const clap_plugin_t *p, const clap_ostream_t *s) { return s->write(s, &self(p)->gain, sizeof(double)) == sizeof(double); }
bool stateLoad(const clap_plugin_t *p, const clap_istream_t *s) { return s->read(s, &self(p)->gain, sizeof(double)) == sizeof(double); }
const clap_plugin_state_t kState = {stateSave, stateLoad};

clap_process_status process(const clap_plugin_t *p, const clap_process_t *pr) {
    paramsFlush(p, pr->in_events, nullptr);
    const float g = static_cast<float>(self(p)->gain);
    for (uint32_t c = 0; c < 2; ++c)
        for (uint32_t i = 0; i < pr->frames_count; ++i) {
            const float side = pr->audio_inputs_count > 1 ? std::abs(pr->audio_inputs[1].data32[c][i]) : 0.0f;
            pr->audio_outputs[0].data32[c][i] = pr->audio_inputs[0].data32[c][i] * g * (1.0f - std::min(1.0f, side));
        }
    return CLAP_PROCESS_CONTINUE;
}

const void *extension(const clap_plugin_t *, const char *id) {
    if (!std::strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &kPorts;
    if (!std::strcmp(id, CLAP_EXT_PARAMS)) return &kParams;
    if (!std::strcmp(id, CLAP_EXT_STATE)) return &kState;
    return nullptr;
}

const clap_plugin_t *create(const clap_plugin_factory_t *, const clap_host_t *host, const char *id) {
    if (std::strcmp(id, kDesc.id)) return nullptr;
    auto *g = new Gain();
    g->host = host;
    g->plugin = {&kDesc, g, [](const clap_plugin_t *) { return true; }, [](const clap_plugin_t *p) { delete self(p); },
                 [](const clap_plugin_t *, double, uint32_t, uint32_t) { return true; }, [](const clap_plugin_t *) {},
                 [](const clap_plugin_t *) { return true; }, [](const clap_plugin_t *) {}, [](const clap_plugin_t *) {},
                 process, extension, [](const clap_plugin_t *) {}};
    return &g->plugin;
}

const clap_plugin_factory_t kFactory = {[](const clap_plugin_factory_t *) -> uint32_t { return 1; },
                                        [](const clap_plugin_factory_t *, uint32_t i) -> const clap_plugin_descriptor_t * { return i == 0 ? &kDesc : nullptr; },
                                        create};
} // namespace

extern "C" CLAP_EXPORT const clap_plugin_entry_t clap_entry = {
    CLAP_VERSION, [](const char *) { return true; }, [] {},
    [](const char *id) -> const void * { return !std::strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? &kFactory : nullptr; }};
