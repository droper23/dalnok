import numpy as np, json, sys
from scipy.io import wavfile
SR = 48000; out = sys.argv[1]
n = int(130 * SR); x = np.zeros((n, 2), np.float64); t = lambda s: int(round(s * SR)); rng = np.random.default_rng(1234); marks = {}
x[t(1.0), :] = 0.5; marks['impulse'] = [t(1.0), 0.5]
def sweep(at, db, dur=8.0, f1=10.0, f2=23000.0):
    k = np.arange(t(dur)) / SR; L = dur / np.log(f2 / f1)
    s = 10 ** (db / 20) * np.sin(2 * np.pi * f1 * L * (np.exp(k / L) - 1))
    fade = t(0.005); s[:fade] *= np.linspace(0, 1, fade); s[-fade:] *= np.linspace(1, 0, fade)
    x[t(at):t(at) + len(s), :] = s[:, None]
for i, db in enumerate([-30, -18, -6, -1]):
    sweep(6 + i * 13, db); marks[f'sweep{db}'] = [t(6 + i * 13), db]
at = t(60); marks['stairs'] = [at]
for lv in list(range(-40, 1, 2)) + list(range(0, -41, -4)):
    k = np.arange(t(0.5)); x[at:at + len(k), :] = (10 ** (lv / 20) * np.sin(2 * np.pi * 1000 * k / SR))[:, None]; at += len(k)
at = t(95); marks['bursts'] = [at]
for _ in range(4):
    for lv, d in [(0, 1.0), (-30, 2.0)]:
        k = np.arange(t(d)); x[at:at + len(k), :] = (10 ** (lv / 20) * np.sin(2 * np.pi * 440 * k / SR))[:, None]; at += len(k)
at = t(110); marks['noise'] = [at]
x[at:at + t(5)] = 10 ** (-12 / 20) * rng.standard_normal((t(5), 2)) / 3
x[t(120), 0] = 0.5; x[t(125), 1] = 0.5; marks['impulseL'] = [t(120)]; marks['impulseR'] = [t(125)]
x = np.clip(x, -1, 1).astype(np.float32)
for i in range(1, 9): wavfile.write(f'{out}/sig{i}.wav', SR, x)
np.save(f'{out}/sig.npy', x); json.dump({'sr': SR, 'marks': marks}, open(f'{out}/marks.json', 'w'))
print('ok', x.shape)
