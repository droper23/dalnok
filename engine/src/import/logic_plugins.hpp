// Logic Audio Unit plug-in interoperability; project-specific data stays in the imported document.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace dalnok::import {
class Builder;
struct Report;
struct LogicTrackBinding { uint32_t strip; int32_t track; bool instrument; };
void importLogicPlugins(const std::string &projectData, const std::vector<LogicTrackBinding> &tracks,
                        Builder &builder, Report &report);
}
