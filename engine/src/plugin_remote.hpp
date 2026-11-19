// Out-of-process plug-in hosting (ADR-0014): a proxy PluginProcessor in the engine and the host process's main.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "plugin_host.hpp"

#include <string>

namespace dalnok {

// Starts `hostPath` (dalnok-plughost), which loads the plug-in in its own process, and returns a proxy that
// processes audio through shared memory and forwards control calls over a socket. Null with `err` on failure,
// including a host that crashes, hangs (loadTimeoutMs) or fails while loading.
std::unique_ptr<PluginProcessor> loadRemotePlugin(const std::string &hostPath, const std::string &format,
                                                  const std::string &path, const std::string &classId,
                                                  double sampleRate, int maxBlock, bool offline, int loadTimeoutMs,
                                                  std::string &err);

// The host process: `dalnok-plughost --shm <name> --format <f> --path <p> --class <id> --rate <hz> --block <n>
// [--offline]`, with the control socket on fd 3. Returns the exit status.
int plughostMain(int argc, char **argv);

} // namespace dalnok
