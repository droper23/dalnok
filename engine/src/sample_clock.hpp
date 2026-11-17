// Detect missing or discontinuous device sample timestamps on one callback thread.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "rt.hpp"
#include <cmath>
#include <cstdint>
namespace dalnok {
class SampleClock {
public:
    void reset() DALNOK_NONBLOCKING { haveTime_ = false; expected_ = 0; }
    bool accept(bool valid, double time, uint32_t frames) DALNOK_NONBLOCKING {
        if (!valid || !std::isfinite(time)) return false;
        if (haveTime_) {
            const double delta = time - expected_;
            if (delta < -0.5 || delta > 0.5) return false;
        }
        expected_ = time + frames;
        haveTime_ = true;
        return true;
    }
private:
    bool haveTime_ = false;
    double expected_ = 0;
};
}
