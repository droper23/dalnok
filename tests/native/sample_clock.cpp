// SPDX-License-Identifier: GPL-3.0-or-later
#include "sample_clock.hpp"
#include <cassert>
#include <limits>
int main() {
    dalnok::SampleClock clock;
    assert(clock.accept(true, 100, 512));
    assert(clock.accept(true, 612, 256));
    assert(!clock.accept(true, 870, 128)); // missing frames
    clock.reset();
    assert(clock.accept(true, 100, 512));
    assert(!clock.accept(true, 500, 128)); // time went backward
    clock.reset();
    assert(!clock.accept(false, 0, 1));
    assert(!clock.accept(true, std::numeric_limits<double>::quiet_NaN(), 1));
    assert(!clock.accept(true, std::numeric_limits<double>::infinity(), 1));
}
