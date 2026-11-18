# iirfit.py <dir> <run> <track>...  — find the lowest IIR order that explains each render (equation-error fit)
import numpy as np, warnings, sys, json
from scipy.io import wavfile
warnings.filterwarnings('ignore')
S, run = sys.argv[1], sys.argv[2]; tracks = sys.argv[3:]
rd = lambda p: wavfile.read(p)[1].astype(np.float64)
xr, yr = rd(f'{S}/renders/bypass/Audio 10_1.wav'), rd(f'{S}/renders/{run}/Audio 10_1.wav'); G = (xr[:,0]@yr[:,0])/(xr[:,0]@xr[:,0])
fs = 44100; seg = slice(int(5*fs), int(40*fs)); out = {}
for t in tracks:
    x, y = rd(f'{S}/renders/bypass/{t}_1.wav')[:, 0], rd(f'{S}/renders/{run}/{t}_1.wav')[:, 0] / G
    n = min(len(x), len(y)); x, y = x[:n], y[:n]
    for N in range(1, 11):
        X = np.stack([np.roll(x, k)[seg] for k in range(N + 1)] + [-np.roll(y, k)[seg] for k in range(1, N + 1)], 1)
        c, *_ = np.linalg.lstsq(X, y[seg], rcond=None); r = y[seg] - X @ c
        res = 10*np.log10((r@r)/(y[seg]@y[seg]))
        print(t, N, round(res,1)) if "-v" in sys.argv[0:0] else None
        if res < float(__import__("os").environ.get("THR", "-120")): break
    b, a = c[:N+1], np.r_[1, c[N+1:]]
    out[t] = dict(order=N, b=list(b), a=list(a), resid=res)
    p = np.roots(a); z = np.roots(b)
    print(f'{t:8s} order {N} resid {res:7.1f} dB  poles |r|,f: ' + ', '.join(f'{abs(q):.5f}@{abs(np.angle(q))*fs/2/np.pi:.1f}' for q in p if q.imag >= 0))
json.dump(out, open(f'{S}/renders/{run}/iir.json', 'w'), indent=1)
