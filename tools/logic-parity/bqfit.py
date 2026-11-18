import numpy as np, warnings, sys, json
from scipy.io import wavfile
warnings.filterwarnings('ignore')
S, run = sys.argv[1], sys.argv[2]; tracks = sys.argv[3:]
rd = lambda p: wavfile.read(p)[1].astype(np.float64)
xr, yr = rd(f'{S}/renders/bypass/Audio 10_1.wav'), rd(f'{S}/renders/{run}/Audio 10_1.wav'); G = (xr[:,0]@yr[:,0])/(xr[:,0]@xr[:,0])
fs = 44100; seg = slice(int(5*fs), int(58*fs)); out = {}
for t in tracks:
    x, y = rd(f'{S}/renders/bypass/{t}_1.wav')[:, 0], rd(f'{S}/renders/{run}/{t}_1.wav')[:, 0] / G
    n = min(len(x), len(y)); x, y = x[:n], y[:n]
    X = np.stack([x[seg], np.roll(x, 1)[seg], np.roll(x, 2)[seg], -np.roll(y, 1)[seg], -np.roll(y, 2)[seg]], 1)
    c, *_ = np.linalg.lstsq(X, y[seg], rcond=None); r = y[seg] - X @ c
    b0, b1, b2, a1, a2 = c
    # peaking-form decomposition: a = [1, -2cos(w)/D, (1-aA^-1)/D], D = 1 + alpha/A
    aoa = (1 - a2) / (1 + a2); D = 1 + aoa; cw = -a1 * D / 2; w = np.arccos(np.clip(cw, -1, 1))
    aA = b0 * D - 1; A = np.sqrt(max(aA / aoa, 1e-12)); alpha = np.sqrt(max(aA * aoa, 0))
    q_rbj = np.sin(w) / (2 * alpha) if alpha > 0 else float('nan')
    out[t] = dict(b=[b0, b1, b2], a=[1, a1, a2], f=w*fs/(2*np.pi), gain_db=40*np.log10(A), q_rbj=q_rbj)
    print(f'{t:8s} resid {10*np.log10((r@r)/(y[seg]@y[seg])):7.1f} dB  f={w*fs/(2*np.pi):9.3f} Hz gain={40*np.log10(A):7.3f} dB  RBJ-Q={q_rbj:.5f}  (export scale {20*np.log10(G):.3f} dB)')
json.dump(out, open(f'{S}/renders/{run}/fit.json', 'w'), indent=1)
