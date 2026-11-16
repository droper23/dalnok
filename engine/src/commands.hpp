// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include "engine.hpp"

namespace atrium {

struct CommandDef {
    const char *name;  // stable identifier, e.g. "clip.move"
    const char *title; // human-readable, for menus and the command palette
    const char *args;  // argument summary
    AtriumStatus (*run)(Engine &, const json::Value &args, json::Value &result, std::string &err);
};

const CommandDef *commandCatalog(int32_t &count);
AtriumStatus runCommand(Engine &e, const std::string &name, const std::string &argsJson, std::string &resultJson);

} // namespace atrium
