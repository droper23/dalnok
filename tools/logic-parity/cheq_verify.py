import numpy as np, warnings, sys
from scipy.io import wavfile
from scipy.signal import lfilter
sys.path.insert(0, sys.argv[1]); from cheq_model import peak
warnings.filterwarnings('ignore')
S = sys.argv[1]; rd = lambda p: wavfile.read(p)[1].astype(np.float64)
runs = {  # run: [(track, f, gain, Q)]
 'u1': [('Audio 1',1000,12,.1),('Audio 6',1000,12,.5),('Audio 7',1000,12,2),('Audio 8',1000,12,4),('Audio 9',1000,12,10)],
 'u2': [('Audio 1',1000,3,1),('Audio 6',1000,6,1),('Audio 7',1000,-12,1),('Audio 8',1000,-6,1),('Audio 9',1000,24,1)],
 'u3': [('Audio 1',100,12,1),('Audio 6',3000,12,1),('Audio 7',6000,12,1),('Audio 8',15000,12,1),('Audio 9',20000,12,1)],
 'qd2': [('Audio 1',100,12,.2),('Audio 6',100,12,.3),('Audio 7',100,12,.4),('Audio 8',100,12,.6),('Audio 9',100,12,.8)],
 'qd4': [('Audio 1',100,12,2.9),('Audio 6',100,12,2.95),('Audio 7',100,12,3.05),('Audio 8',100,12,3.1),('Audio 9',100,12,3.2)],
 'q100': [('Audio 1',100,12,.5),('Audio 6',100,12,.7),('Audio 7',100,12,2),('Audio 8',100,12,3),('Audio 9',100,12,4)],
}
worst = -999
for run, items in runs.items():
    xr, yr = rd(f'{S}/renders/bypass/Audio 10_1.wav'), rd(f'{S}/renders/{run}/Audio 10_1.wav'); G = (xr[:,0]@yr[:,0])/(xr[:,0]@xr[:,0])
    for t, f, g, q in items:
        x, y = rd(f'{S}/renders/bypass/{t}_1.wav'), rd(f'{S}/renders/{run}/{t}_1.wav') / G
        n = min(len(x), len(y)); b, a = peak(f, g, q, 44100); p = lfilter(b, a, x[:n], axis=0); e = y[:n] - p
        null = 10*np.log10((e**2).sum() / (y[:n]**2).sum()); worst = max(worst, null)
        print(f'{run:5s} {t:8s} f={f:6} g={g:4} Q={q:5}  null {null:7.1f} dB')
print('worst', round(worst, 1))
