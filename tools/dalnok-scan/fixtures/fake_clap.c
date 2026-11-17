/* Test-only CLAP module for scripts/ci/plugin-scan.sh: one instrument descriptor. */
/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "clap/clap.h"
#include <string.h>

static const char *const features[] = {CLAP_PLUGIN_FEATURE_INSTRUMENT, CLAP_PLUGIN_FEATURE_SYNTHESIZER, NULL};
static const clap_plugin_descriptor_t descriptor = {
    CLAP_VERSION_INIT, "org.dalnok.test-synth", "Dalnok Test Synth", "Dalnok Tests", "", "", "", "0.1.0", "test", features};
static uint32_t count(const clap_plugin_factory_t *f) { (void)f; return 1; }
static const clap_plugin_descriptor_t *describe(const clap_plugin_factory_t *f, uint32_t i) { (void)f; return i == 0 ? &descriptor : NULL; }
static const clap_plugin_t *create(const clap_plugin_factory_t *f, const clap_host_t *h, const char *id) { (void)f; (void)h; (void)id; return NULL; }
static const clap_plugin_factory_t factory = {count, describe, create};
static bool init(const char *path) { (void)path; return true; }
static void deinit(void) {}
static const void *get_factory(const char *id) { return strcmp(id, CLAP_PLUGIN_FACTORY_ID) == 0 ? &factory : NULL; }
CLAP_EXPORT const clap_plugin_entry_t clap_entry = {CLAP_VERSION_INIT, init, deinit, get_factory};
