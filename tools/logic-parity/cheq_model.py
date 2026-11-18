# Clean-room model of Logic Channel EQ parametric band (Q-Couple off), derived from black-box renders.
import numpy as np
def q_display(q):
    """Snap a stored Q to the 128-step knob's displayed values (2 significant digits); ties go to the lower value."""
    vals = []
    for i in range(128):
        v = 10 ** (-1 + 3 * i / 127); vals.append(float(f'{v:.2g}'))
    best = min(range(128), key=lambda i: (abs(vals[i] - q), i)); return vals[best]
def q_eff(q):
    return 10 ** (round(300 * np.log10(q_display(q))) / 300)
# Gain-Q coupling: mode (param 42) -> (strength, cut multiplier). 3..7 behave as Medium.
COUPLE_MODES = {0: (0.5, 1.0), 1: (1.0, 1.0), 2: (2.0, 1.0), -1: (1.0, 3.0), -2: (2.0, 3.0), -3: (0.5, 3.0)}
def couple_scale(gain_db, mode):
    strength, asym = COUPLE_MODES.get(int(mode), (1.0, 1.0))
    s = strength if gain_db >= 0 else strength * asym
    g = abs(gain_db)
    return 1 + s * g * (0.06 + 0.005625 * g)
def peak(f, gain_db, q, fs, couple=False, mode=-1):
    w = 2 * np.pi * f / fs; A = 10 ** (abs(gain_db) / 40)
    k = couple_scale(gain_db, mode) if couple else 1.0
    qtot = 10 ** (round(300 * np.log10(q_display(q) * k)) / 300)
    qe = qtot * (w / 2) / np.tan(w / 2)
    alpha = np.sin(w) / (2 * qe / A)          # bandwidth narrows with gain (Zoelzer-style symmetric peak)
    if gain_db >= 0: b = [1 + alpha * A, -2 * np.cos(w), 1 - alpha * A]; a = [1 + alpha / A, -2 * np.cos(w), 1 - alpha / A]
    else:            b = [1 + alpha / A, -2 * np.cos(w), 1 - alpha / A]; a = [1 + alpha * A, -2 * np.cos(w), 1 - alpha * A]
    return np.array(b) / a[0], np.array(a) / a[0]
