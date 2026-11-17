// Recording take journals: scanning and crash recovery (see record.cpp).
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "engine.hpp"
#include <string>
namespace dalnok {
// Lists the take journals in a folder (unfinished, failed and recovered takes), each with "journal" set.
json::Value scanTakes(const std::string &directory);
// Converts an unfinished take's spool to "<name> (recovered).wav" without modifying the spool.
// Repeated recovery reports the existing file. Fills `out` with the journal plus "path".
bool recoverTake(const std::string &journal, json::Value &out, std::string &err);
}
