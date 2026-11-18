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
def peak(f, gain_db, q, fs):
    w = 2 * np.pi * f / fs; A = 10 ** (abs(gain_db) / 40); qe = q_eff(q) * (w / 2) / np.tan(w / 2)
    alpha = np.sin(w) / (2 * qe / A)          # bandwidth narrows with gain (Zoelzer-style symmetric peak)
    if gain_db >= 0: b = [1 + alpha * A, -2 * np.cos(w), 1 - alpha * A]; a = [1 + alpha / A, -2 * np.cos(w), 1 - alpha / A]
    else:            b = [1 + alpha / A, -2 * np.cos(w), 1 - alpha / A]; a = [1 + alpha * A, -2 * np.cos(w), 1 - alpha * A]
    return np.array(b) / a[0], np.array(a) / a[0]
