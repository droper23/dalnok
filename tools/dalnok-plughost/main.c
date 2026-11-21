// dalnok-plughost: runs one plug-in instance in its own process for the engine (ADR-0014).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "dalnok/dalnok.h"

#include <dlfcn.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    // Tests only: DALNOK_TEST_AU names the test Audio Unit dylib, which registers itself in this process
    // (AudioComponentRegister), so isolated hosts can load it like the test process does.
    const char *testAU = getenv("DALNOK_TEST_AU");
    if (testAU && *testAU) {
        void *lib = dlopen(testAU, RTLD_NOW);
        int (*reg)(void) = lib ? (int (*)(void))dlsym(lib, "dalnok_test_au_register") : 0;
        if (reg) reg();
    }
    return dalnok_plughost_main(argc, argv);
}
