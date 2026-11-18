import numpy as np, warnings, sys
from scipy.io import wavfile
from scipy.signal import lfilter
sys.path.insert(0, sys.argv[1]); from cheq_model import peak
warnings.filterwarnings('ignore')
S = sys.argv[1]; rd = lambda p: wavfile.read(p)[1].astype(np.float64); T = ['Audio 1','Audio 6','Audio 7','Audio 8','Audio 9']
def runs():
    yield 'eqA', [(1000,12,1,-1),(1000,6,1,-1),(1000,-12,1,-1),(1000,12,4,-1),(10000,12,1,-1)]
    for r, gs in [('c1',[1,3,6,9,18]),('c2',[-1,-3,-6,-9,-18]),('c3',[24,-24,.5,-.5,15])]: yield r, [(1000,g,1,-1) for g in gs]
    yield 'cf1', [(f,12,1,-1) for f in [100,3000,6000,15000,20000]]
    for r, g, ms in [('m1',12,[0,1,2,3,4]),('m2',12,[5,6,7,-1,-2]),('m3',-12,[0,1,2,3,4]),('m4',-12,[5,6,7,-1,-2])]: yield r, [(1000,g,1,m) for m in ms]
worst = -999
for run, items in runs():
    xr, yr = rd(f'{S}/renders/bypass/Audio 10_1.wav'), rd(f'{S}/renders/{run}/Audio 10_1.wav'); G = (xr[:,0]@yr[:,0])/(xr[:,0]@xr[:,0])
    for t, (f, g, q, m) in zip(T, items):
        x, y = rd(f'{S}/renders/bypass/{t}_1.wav'), rd(f'{S}/renders/{run}/{t}_1.wav') / G
        n = min(len(x), len(y)); b, a = peak(f, g, q, 44100, True, m if m in (0,1,2,-1,-2,-3) else 1); e = y[:n] - lfilter(b, a, x[:n], axis=0)
        null = 10*np.log10((e**2).sum()/(y[:n]**2).sum()); worst = max(worst, null)
        print(f'{run:4s} f={f:6} g={g:5} Q={q} mode={m:2}  null {null:7.1f} dB')
print('worst', round(worst, 1))
