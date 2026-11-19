// Editor windows owned by the plug-in host process (ADR-0015). Host main thread only.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <string>

namespace dalnok {
class PluginProcessor;
namespace hostui {

struct EditorWindow {
    bool visible = false, open = false;              // on screen / opened by the user (hidden while Dalnok is inactive)
    double x = 0, y = 0, width = 0, height = 0;      // window frame, AppKit screen coordinates
    double contentWidth = 0, contentHeight = 0;      // the editor's area
    int64_t windowNumber = 0, level = 0;
};

bool appStarted();
void startApp();
void runApp();
// Opens the plug-in's editor in the host's window (or brings it front). x, y: top-left in screen coordinates; NaN centers.
bool showEditor(PluginProcessor &plugin, const std::string &title, double x, double y, int32_t &width, int32_t &height,
                std::string &err);
void closeEditor();
EditorWindow editorWindow();
bool snapshot(const std::string &pngPath); // the editor's pixels as the window shows them

} // namespace hostui
} // namespace dalnok
