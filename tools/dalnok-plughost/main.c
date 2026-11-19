// dalnok-plughost: runs one plug-in instance in its own process for the engine (ADR-0014).
// SPDX-License-Identifier: GPL-3.0-or-later
#include "dalnok/dalnok.h"

int main(int argc, char **argv) { return dalnok_plughost_main(argc, argv); }
