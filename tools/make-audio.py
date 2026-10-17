"""Rizz Academy: muziek en geluidseffecten maken met echte instrumenten (FluidR3 GM, MIT-licentie).
Gebruik: python3 tools/make-audio.py audio   (nodig: fluidsynth, fluid-soundfont-gm, ffmpeg, numpy, mido)
Schrijft MIDI, laat FluidSynth inspelen, bewerkt met numpy en maakt mp3's met ffmpeg."""
import os, random, subprocess, sys, wave
import numpy as np
import mido

SF2 = '/usr/share/sounds/sf2/FluidR3_GM.sf2'
SR = 44100
OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'
TMP = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tmp')
os.makedirs(TMP, exist_ok=True); os.makedirs(os.path.join(OUT, 'music'), exist_ok=True); os.makedirs(os.path.join(OUT, 'sfx'), exist_ok=True)
TPB = 480


# ---------------------------------------------------------------- MIDI
class Song:
    def __init__(self, bpm):
        self.bpm = bpm; self.notes = []; self.progs = {}; self.cc = []
    def prog(self, ch, p, vol=100, pan=64, rev=40, cho=0):
        self.progs[ch] = (p, vol, pan, rev, cho)
    def n(self, ch, beat, dur, pitch, vel):
        self.notes.append((beat, dur, ch, int(pitch), max(1, min(127, int(vel)))))
    def bend(self, ch, beat, value):
        self.cc.append((beat, ch, value))
    def twice(self, bars):
        # alles nog eens na 'bars' maten: voor een naadloze lus (zie loop_cut)
        off = bars * 4
        self.notes += [(b + off, d, c, p, v) for b, d, c, p, v in self.notes]
        self.cc += [(b + off, c, v) for b, c, v in self.cc]
    def save(self, path):
        mid = mido.MidiFile(ticks_per_beat=TPB)
        tr = mido.MidiTrack(); mid.tracks.append(tr)
        ev = [(0, 0, mido.MetaMessage('set_tempo', tempo=mido.bpm2tempo(self.bpm)))]
        for ch, (p, vol, pan, rev, cho) in self.progs.items():
            if ch != 9: ev.append((0, 1, mido.Message('program_change', channel=ch, program=p)))
            for c, v in ((7, vol), (10, pan), (91, rev), (93, cho)):
                ev.append((0, 1, mido.Message('control_change', channel=ch, control=c, value=v)))
        for beat, ch, val in self.cc:
            ev.append((int(beat * TPB), 2, mido.Message('pitchwheel', channel=ch, pitch=val)))
        for beat, dur, ch, p, v in self.notes:
            t0 = max(0, int(round(beat * TPB))); t1 = max(t0 + 1, int(round((beat + dur) * TPB)))
            ev.append((t0, 4, mido.Message('note_on', channel=ch, note=p, velocity=v)))
            ev.append((t1, 3, mido.Message('note_off', channel=ch, note=p, velocity=0)))
        ev.sort(key=lambda e: (e[0], e[1]))
        last = 0
        for t, _, m in ev:
            tr.append(m.copy(time=t - last)); last = t
        mid.save(path)


def render(song, name, gain=0.5):
    mp = os.path.join(TMP, name + '.mid'); wp = os.path.join(TMP, name + '.wav')
    song.save(mp)
    subprocess.run(['fluidsynth', '-ni', '-q', '-g', str(gain), '-r', str(SR), '-o', 'synth.reverb.room-size=0.55',
                    '-o', 'synth.reverb.width=0.9', '-o', 'synth.reverb.level=0.7', '-F', wp, SF2, mp], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with wave.open(wp) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
        a = a.reshape(-1, w.getnchannels())
    return a


def to_mp3(a, path, kbps=112, mono=False):
    wp = path + '.wav'
    a = np.clip(a, -1, 1)
    if mono: a = a.mean(axis=1, keepdims=True)
    with wave.open(wp, 'wb') as w:
        w.setnchannels(a.shape[1]); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((a * 32767).astype(np.int16).tobytes())
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wp, '-codec:a', 'libmp3lame', '-b:a', f'{kbps}k', path], check=True)
    os.remove(wp)


def normalize(a, peak=0.89):
    m = np.abs(a).max()
    return a * (peak / m) if m > 0 else a


def soft_comp(a, drive=1.6):
    # zachte limiter: lijmt de mix samen en maakt hem voller
    return np.tanh(a * drive) / np.tanh(drive)


def loop_cut(a, bars, bpm):
    # twee keer gerenderd: neem de tweede keer, zodat de galm van het einde al in het begin zit -> naadloze lus
    L = int(round(bars * 4 * 60 / bpm * SR)); n = int(.06 * SR)
    out = a[L:2 * L].copy()
    if len(a) >= 2 * L + n:  # korte overvloeier: het einde loopt naadloos over in het begin
        r = np.linspace(0, 1, n)[:, None]
        out[:n] = a[L:L + n] * r + a[2 * L:2 * L + n] * (1 - r)
    return out


def level(a, rms_db=-15.0, ceil=.84):
    # op dezelfde luidheid brengen (enkel de luide stukken tellen), daarna zacht begrenzen
    m = a.mean(axis=1) if a.ndim == 2 else a
    fr = np.array([np.sqrt((m[i:i + 2048] ** 2).mean()) for i in range(0, max(1, len(m) - 2048), 1024)] or [1e-9])
    top = np.sort(fr)[-max(1, len(fr) // 3):].mean()
    a = a * (10 ** (rms_db / 20) / (top + 1e-9))
    return np.tanh(a / ceil) * ceil


R = random.Random(7)
def hum(v, s=8): return v + R.uniform(-s, s)
def tim(b, s=0.012): return b + R.uniform(-s, s)


# ---------------------------------------------------------------- MUZIEK
def campus():
    """Lofi: Rhodes, warme bas, zachte drums, vibrafoon. 78 bpm."""
    s = Song(78)
    s.prog(0, 4, 92, 54, 70, 30)    # Rhodes
    s.prog(1, 33, 100, 64, 20)      # fingered bass
    s.prog(2, 11, 70, 80, 90, 20)   # vibrafoon
    s.prog(3, 89, 45, 44, 100, 60)  # warme pad
    s.prog(9, 0, 82, 64, 30)
    chords = [[53, 57, 60, 64], [52, 55, 59, 62], [50, 53, 57, 60], [48, 52, 55, 59],
              [46, 50, 53, 57], [45, 48, 52, 55], [43, 46, 50, 53], [48, 53, 55, 58]]
    roots = [41, 40, 38, 36, 34, 33, 31, 36]
    mel = [  # (beat in bar, dur, noot) per maat
        [(0.5, 1, 72), (1.5, .5, 69), (2, 1.5, 67)], [(0.5, .5, 67), (1, .5, 69), (1.5, 2, 71)],
        [(0, 1, 72), (1.5, .5, 74), (2, 1.5, 72)], [(1, .5, 67), (1.5, 2.5, 64)],
        [(0.5, 1, 65), (1.5, .5, 67), (2, 1.5, 69)], [(0.5, .5, 72), (1, 1, 71), (2, 2, 67)],
        [(0, 1.5, 70), (2, .5, 69), (2.5, 1.5, 65)], [(1, 3, 67)]]
    for rep in range(1):
        for pass_ in range(2):
            for i, ch in enumerate(chords):
                b0 = (rep * 16 + pass_ * 8 + i) * 4
                # Rhodes: lofi-ritme met lichte strum
                for (off, dur, vel) in [(0, 1.4, 62), (1.5, .9, 52), (3.25, .7, 48)]:
                    for k, p in enumerate(ch):
                        s.n(0, tim(b0 + off + k * .015), dur, p + 12, hum(vel))
                # bas
                r = roots[i]
                for (off, dur, p, vel) in [(0, 1.5, r, 88), (2, .75, r + 7, 70), (2.75, .5, r + 12, 62), (3.5, .5, r + 10, 60)]:
                    s.n(1, tim(b0 + off, .006), dur, p, hum(vel, 6))
                # pad heel zacht
                s.n(3, b0, 4, ch[0] + 12, 34); s.n(3, b0, 4, ch[2] + 12, 30)
                # drums (licht geswingd)
                for off, p, vel in [(0, 36, 92), (1.75, 36, 58), (2.5, 36, 80), (1, 38, 62), (3, 38, 66)]:
                    s.n(9, tim(b0 + off, .008), .2, p, hum(vel, 6))
                for e in range(8):
                    sw = .07 if e % 2 else 0
                    s.n(9, tim(b0 + e * .5 + sw, .006), .1, 42, hum(38 if e % 2 else 50, 6))
                if i % 4 == 3: s.n(9, b0 + 3.5, .4, 46, 40)
                # melodie in de tweede helft van elke ronde
                if pass_ == 1:
                    for off, dur, p in mel[i]:
                        s.n(2, tim(b0 + off), dur, p + (12 if rep == 1 and i >= 4 else 0), hum(70))
    s.twice(16)
    a = render(s, 'campus', .55)
    a = loop_cut(a, 16, 78)
    # vinylruis
    crackle = np.zeros(len(a)); idx = np.random.default_rng(1).integers(0, len(a), len(a) // 2500)
    crackle[idx] = np.random.default_rng(2).uniform(-.08, .08, len(idx))
    hiss = np.random.default_rng(3).normal(0, .0025, len(a))
    a = a + (crackle + hiss)[:, None]
    return level(soft_comp(normalize(a, .8), 1.3), -14.5)


def casino():
    """Lounge-jazz: walking bass, piano, brushes, tenorsax. 118 bpm, swing."""
    bpm = 118; s = Song(bpm)
    s.prog(0, 0, 88, 50, 55)      # piano
    s.prog(1, 32, 110, 64, 25)    # contrabas
    s.prog(2, 66, 92, 78, 70, 10) # tenorsax
    s.prog(9, 0, 80, 64, 35)
    SW = .17  # swing: tweede achtste later
    prog_ = [('Bb', 'maj7'), ('G', 'm7'), ('C', 'm7'), ('F', '7'), ('D', 'm7'), ('G', '7'), ('C', 'm7'), ('F', '7'),
             ('Eb', 'maj7'), ('E', 'dim7'), ('D', 'm7'), ('G', '7'), ('C', 'm7'), ('F', '7'), ('Bb', '6'), ('F', '7')]
    NOTE = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11, 'Bb': 10, 'Eb': 3}
    Q = {'maj7': [0, 4, 7, 11], 'm7': [0, 3, 7, 10], '7': [0, 4, 7, 10], 'dim7': [0, 3, 6, 9], '6': [0, 4, 7, 9]}
    mel = [  # 16 maten sax-melodie (beat, dur, noot)
        [(0, 1.5, 74), (1.5 + SW, .5 - SW, 72), (2, 2, 69)], [(0.5 + SW, .5, 70), (1, 1, 74), (2, 2, 77)],
        [(0, 1, 75), (1, .5, 74), (1.5 + SW, .5, 72), (2, 2, 70)], [(0, 3, 69), (3.5 + SW, .5, 70)],
        [(0, 1.5, 72), (1.5 + SW, .5, 74), (2, 1, 77), (3, 1, 76)], [(0, 2, 74), (2.5 + SW, 1.5, 71)],
        [(0, 1, 70), (1, 1, 72), (2, 1, 75), (3, 1, 74)], [(0, 3.5, 72)],
        [(0, 1.5, 70), (1.5 + SW, .5, 67), (2, 2, 74)], [(0.5 + SW, .5, 73), (1, 2, 70)],
        [(0, 1, 69), (1, 1, 72), (2, 2, 77)], [(0, 1, 76), (1, 1, 74), (2, 2, 71)],
        [(0, 1.5, 72), (1.5 + SW, .5, 75), (2, 1, 74), (3, 1, 70)], [(0, 2, 69), (2.5 + SW, 1.5, 72)],
        [(0, 4, 70)], [(1, .5, 65), (1.5 + SW, .5, 67), (2, .5, 69), (2.5 + SW, .5, 72), (3, 1, 74)]]
    for rep in range(2):
        for i, (root, q) in enumerate(prog_):
            b0 = (rep * 16 + i) * 4
            r = 36 + NOTE[root]
            if r > 43: r -= 12
            tones = [r + x for x in Q[q]]
            nxt = 36 + NOTE[prog_[(i + 1) % 16][0]]
            if nxt > 43: nxt -= 12
            walk = [tones[0], tones[1] + (0 if R.random() < .6 else 12), tones[2], nxt + (1 if R.random() < .5 else -1)]
            for k, p in enumerate(walk): s.n(1, tim(b0 + k, .01), .95, p, hum(92 if k == 0 else 80, 6))
            # piano: shell-voicings (3 en 7 + 9), charleston-ritme
            sh = [r + 12 + Q[q][1], r + 12 + Q[q][3], r + 24 + 2]
            for off, dur, vel in ([(0, .6, 58), (1.5 + SW, .4, 52)] if i % 2 == 0 else [(.5 + SW, .4, 50), (2.5 + SW, .6, 55)]):
                for k, p in enumerate(sh): s.n(0, tim(b0 + off + k * .01), dur, p + 12, hum(vel))
            # drums: ride-patroon, hihat op 2 en 4, zachte bassdrum
            for off in [0, 1, 1.5 + SW, 2, 3, 3.5 + SW]: s.n(9, tim(b0 + off, .006), .3, 51, hum(62 if off in (1, 3) else 48, 5))
            for off in [1, 3]: s.n(9, tim(b0 + off, .006), .2, 44, hum(55, 5))
            for off in range(4): s.n(9, b0 + off, .2, 36, 24)
            if R.random() < .35: s.n(9, b0 + 2.5 + SW, .2, 38, 28)
            if rep == 1:
                for off, dur, p in mel[i]: s.n(2, tim(b0 + off, .01), dur * .95, p - 12, hum(80, 6))
    s.twice(32)
    a = render(s, 'casino', .55)
    a = loop_cut(a, 32, bpm)
    return level(soft_comp(normalize(a, .82), 1.3), -14.5)


def battle():
    """Episch: staccato strijkers, koper, pauken, grote drums, koor. 132 bpm, A mineur."""
    bpm = 132; s = Song(bpm)
    s.prog(0, 48, 105, 52, 50)   # strijkers (staccato)
    s.prog(1, 48, 90, 76, 60)    # lage strijkers lang
    s.prog(2, 61, 98, 64, 60)    # koper
    s.prog(3, 47, 110, 64, 60)   # pauken
    s.prog(4, 52, 70, 64, 90)    # koor
    s.prog(5, 60, 92, 40, 70)    # hoorns melodie
    s.prog(9, 0, 100, 64, 45)
    seq = [(57, 'm'), (53, 'M'), (48, 'M'), (55, 'M'), (57, 'm'), (53, 'M'), (50, 'm'), (52, 'M')]
    mel = [[(0, 2, 69), (2, 1, 72), (3, 1, 71)], [(0, 3, 69), (3, 1, 65)], [(0, 2, 67), (2, 2, 72)], [(0, 3, 71), (3, 1, 74)],
           [(0, 2, 76), (2, 1, 74), (3, 1, 72)], [(0, 3, 77), (3, 1, 76)], [(0, 2, 74), (2, 2, 72)], [(0, 4, 71)]]
    for rep in range(4):
        for i, (root, kind) in enumerate(seq):
            b0 = (rep * 8 + i) * 4
            third = 3 if kind == 'm' else 4
            tri = [root, root + third, root + 7]
            # staccato ostinato in achtsten
            pat = [0, 0, 7, 0, 12, 0, 7, third]
            for e, iv in enumerate(pat):
                s.n(0, b0 + e * .5, .32, root - 12 + iv + 12, 92 if e % 4 == 0 else 74)
            s.n(1, b0, 4, root - 24, 80); s.n(1, b0, 4, root - 12, 70)
            s.n(3, b0, .8, root - 24 + (12 if root - 24 < 41 else 0), 110)
            if i % 2 == 1: s.n(3, b0 + 3.5, .4, root - 24 + (12 if root - 24 < 41 else 0), 90)
            # koperstoten
            if rep >= 1:
                for off, dur in [(0, .5), (1.5, .4), (3, .8)]:
                    for p in tri: s.n(2, b0 + off, dur, p, 92)
            # koor in de tweede helft
            if rep >= 2:
                for p in tri: s.n(4, b0, 4, p + 12, 70)
            if rep == 3 or rep == 1:
                for off, dur, p in mel[i]: s.n(5, b0 + off, dur * .97, p, 100)
            # drums: groot en vooruit
            for off, p, v in [(0, 36, 118), (1.5, 36, 90), (2, 36, 108), (1, 38, 100), (3, 38, 104), (3.75, 38, 70)]:
                s.n(9, b0 + off, .2, p, v)
            for e in range(8): s.n(9, b0 + e * .5, .1, 42, 60 if e % 2 else 74)
            if i % 4 == 0: s.n(9, b0, 1, 49, 100)
            if i % 4 == 3:
                for k, tp in enumerate([50, 48, 47, 45, 43, 41]): s.n(9, b0 + 2.5 + k * .25, .2, tp, 96)
    s.twice(32)
    a = render(s, 'battle', .5)
    a = loop_cut(a, 32, bpm)
    return level(soft_comp(normalize(a, .85), 1.5), -14.5)


def bar():
    """Funky Food Truck: slapbas, gitaar, orgel, blazers. 104 bpm."""
    bpm = 104; s = Song(bpm)
    s.prog(0, 28, 82, 40, 25)    # gedempte gitaar
    s.prog(1, 36, 105, 64, 15)   # slapbas
    s.prog(2, 17, 60, 88, 50, 40)  # orgel
    s.prog(3, 61, 92, 64, 55)    # blazers
    s.prog(4, 65, 90, 70, 55)    # altsax
    s.prog(9, 0, 92, 64, 25)
    seq = [(52, [0, 3, 7, 10]), (57, [0, 4, 7, 10]), (52, [0, 3, 7, 10]), (57, [0, 4, 7, 10]),
           (48, [0, 4, 7, 11]), (47, [0, 4, 7, 10]), (52, [0, 3, 7, 10]), (57, [0, 4, 7, 10])]
    basspat = [(0, .4, 0, 100), (.75, .2, 12, 70), (1, .3, 10, 80), (1.5, .3, 7, 85), (2.25, .2, 0, 75), (2.5, .4, 12, 90), (3.5, .25, 10, 70), (3.75, .25, 7, 75)]
    mel = [[(0, .5, 79), (.5, .5, 76), (1, 1, 74), (2.5, 1, 71)], [(0, 2, 72), (2.5, .5, 74), (3, 1, 76)],
           [(0, .5, 79), (.5, .5, 76), (1, 1, 74), (2.5, 1, 79)], [(0, 3, 81)],
           [(0, .5, 76), (.5, .5, 74), (1, 1, 72), (2, 2, 71)], [(0, 1, 75), (1, 1, 74), (2, 2, 71)],
           [(0, .5, 74), (.5, .5, 76), (1, 1, 79), (2, 2, 76)], [(0, 4, 76)]]
    for rep in range(1):
        for pass_ in range(2):
            for i, (r, q) in enumerate(seq):
                b0 = (rep * 16 + pass_ * 8 + i) * 4
                for off, dur, iv, v in basspat: s.n(1, tim(b0 + off, .005), dur, r - 12 + iv, hum(v, 5))
                for e in range(16):
                    if e % 4 in (2,) or e in (7, 13):
                        for k, iv in enumerate(q[1:]): s.n(0, tim(b0 + e * .25 + k * .008, .004), .12, r + 12 + iv, hum(78))
                for iv in q: s.n(2, b0, 3.8, r + 12 + iv, 48)
                for off, p, v in [(0, 36, 110), (1.75, 36, 80), (2.5, 36, 96), (1, 38, 104), (3, 38, 106), (2.75, 38, 34), (3.75, 38, 30)]:
                    s.n(9, tim(b0 + off, .004), .2, p, hum(v, 5))
                for e in range(16): s.n(9, tim(b0 + e * .25, .004), .08, 42, hum(52 if e % 2 else 66, 6))
                if pass_ == 1:
                    for off, dur, p in mel[i]: s.n(4, tim(b0 + off, .006), dur * .9, p - 12, hum(86, 5))
                    if i % 2 == 1:
                        for p in [r + 12 + q[1], r + 12 + q[2], r + 24]: s.n(3, b0 + 3.5, .3, p, 92)
    s.twice(16)
    a = render(s, 'bar', .55)
    a = loop_cut(a, 16, bpm)
    return level(soft_comp(normalize(a, .82), 1.4), -14.5)


# ---------------------------------------------------------------- EFFECTEN
rng = np.random.default_rng(11)
def env(n, a=.002, d=None):
    t = np.arange(n) / SR; e = np.minimum(1, t / max(a, 1e-4))
    if d: e = e * np.exp(-t / d)
    return e
def bp_noise(dur, lo, hi):
    n = int(dur * SR); x = rng.normal(0, 1, n); X = np.fft.rfft(x); f = np.fft.rfftfreq(n, 1 / SR)
    X[(f < lo) | (f > hi)] = 0
    y = np.fft.irfft(X, n); return y / (np.abs(y).max() + 1e-9)
def sweep_noise(dur, f0, f1, q=6):
    # ruis met een meebewegend filter (blokken)
    n = int(dur * SR); y = np.zeros(n); blk = 512
    for i in range(0, n, blk):
        fr = f0 * (f1 / f0) ** (i / n); seg = bp_noise(blk / SR + .02, fr / (1 + 1 / q), fr * (1 + 1 / q))[:min(blk, n - i)]
        y[i:i + len(seg)] = seg
    return y
def place(buf, x, t, g=1.0):
    i = max(0, int(t * SR)); j = min(len(buf), i + len(x)); buf[i:j] += x[:j - i] * g
def reverb(x, size=.6, mix=.25):
    n = int(size * SR); ir = rng.normal(0, 1, n) * np.exp(-np.arange(n) / (n / 6)); ir /= np.abs(ir).sum() ** .5 * 6
    L = len(x) + n; y = np.fft.irfft(np.fft.rfft(x, L) * np.fft.rfft(ir, L), L)
    out = np.zeros(L); out[:len(x)] = x; return out * (1 - mix) + y * mix
def stereo(m): return np.stack([m, m], axis=1)
def trim(a, thr=.002):
    m = np.abs(a).max(axis=1) if a.ndim == 2 else np.abs(a)
    idx = np.where(m > thr)[0]
    if not len(idx): return a
    a = a[max(0, idx[0] - 20): idx[-1] + int(.03 * SR)]
    fade = min(len(a), int(.02 * SR)); a[-fade:] *= np.linspace(1, 0, fade)[:, None] if a.ndim == 2 else np.linspace(1, 0, fade)
    return a


def gm_fx(name, bpm, build, gain=.6):
    s = Song(bpm); build(s); a = render(s, 'fx_' + name, gain); return trim(a)


def mix(*parts, length=None):
    n = length or max(int(t * SR) + len(p) for p, t, g in parts)
    out = np.zeros((n, 2))
    for p, t, g in parts:
        if p.ndim == 1: p = stereo(p)
        i = int(t * SR); j = min(n, i + len(p)); out[i:j] += p[:j - i] * g
    return out


def sfx():
    S = {}
    # klik: zacht houtje
    S['click'] = gm_fx('click', 120, lambda s: (s.prog(9, 0, 70, 64, 10), s.n(9, 0, .1, 76, 52)), .5)
    S['tick'] = gm_fx('tick', 120, lambda s: (s.prog(9, 0, 100, 64, 20), s.n(9, 0, .1, 76, 100)), .6)
    # kaart: ruis-veeg zoals een kaart over vilt
    def swish(d, f0, f1, tap=True):
        x = sweep_noise(d, f0, f1, 3) * np.sin(np.linspace(0, np.pi, int(d * SR))) ** 1.5 * .55
        if tap: place(x, bp_noise(.03, 300, 3000) * env(int(.03 * SR), .001, .006) * .5, d * .85)
        return reverb(x, .3, .12)
    S['card'] = swish(.16, 2500, 6000); S['flip'] = swish(.11, 4000, 1800, False)
    # munten: glockenspiel + metalen tikjes
    def coins(s):
        s.prog(0, 9, 110, 50, 50); s.prog(1, 8, 90, 78, 50)
        for k, p in enumerate([88, 91, 95, 100, 96, 103]): s.n(0 if k % 2 else 1, k * .11, .6, p, 100 - k * 6)
    S['coins'] = gm_fx('coins', 120, coins, .6)
    def win(s):
        s.prog(0, 61, 110, 64, 60); s.prog(1, 9, 100, 64, 60)
        for k, p in enumerate([60, 64, 67]): s.n(0, k * .28, .28, p, 100)
        for p in [60, 64, 67, 72]: s.n(0, .84, 1.6, p, 110)
        s.n(1, .84, 1, 84, 90); s.n(1, .96, 1, 88, 80); s.n(1, 1.08, 1.2, 91, 80)
    S['win'] = gm_fx('win', 120, win, .55)
    def lose(s):
        s.prog(0, 57, 110, 64, 50)
        for k, p in enumerate([55, 54, 53]): s.n(0, k * .9, .8, p, 96)
        s.n(0, 2.7, 2.4, 52, 96)
        for k in range(10): s.bend(0, 2.9 + k * .2, (-1) ** k * 700)
        s.bend(0, 5, 0)
    S['lose'] = gm_fx('lose', 120, lose, .55)
    def epic(s):
        s.prog(0, 46, 105, 50, 60); s.prog(1, 48, 95, 64, 70); s.prog(2, 9, 90, 80, 70)
        for k, p in enumerate([60, 62, 64, 67, 69, 72, 74, 76, 79, 81, 84]): s.n(0, k * .045, .8, p, 80 + k * 2)
        for p in [57, 60, 64, 69]: s.n(1, .5, 1.6, p, 92)
        s.n(2, .55, 1.2, 93, 90); s.n(2, .7, 1.2, 96, 80)
    S['epic'] = gm_fx('epic', 120, epic, .55)
    def legendary(s):
        s.prog(0, 61, 115, 64, 70); s.prog(1, 47, 120, 64, 60); s.prog(2, 52, 90, 64, 90); s.prog(3, 46, 100, 50, 60); s.prog(9, 0, 110, 64, 60)
        for k in range(12): s.n(1, k * .06, .1, 43, 70 + k * 4)
        for k, p in enumerate([60, 64, 67, 72, 76, 79, 84, 88]): s.n(3, k * .04, .8, p, 90)
        for k, p in enumerate([60, 64, 67]): s.n(0, .8 + k * .2, .2, p, 110)
        for p in [60, 64, 67, 72]: s.n(0, 1.4, 2.4, p, 120); s.n(2, 1.4, 2.6, p + 12, 90)
        s.n(1, 1.4, .5, 36 + 7, 127); s.n(9, 1.4, 2, 49, 120); s.n(9, 1.4, .3, 36, 120)
    S['legendary'] = gm_fx('legendary', 120, legendary, .5)
    # envelop openscheuren: papier
    n = int(.42 * SR); rip = bp_noise(.42, 1200, 9000) * (rng.random(n) < .35) * env(n, .01) * np.linspace(1, .3, n)
    rip = rip + bp_noise(.42, 400, 2500) * .3 * np.sin(np.linspace(0, np.pi, n))
    S['pack'] = reverb(rip * .6, .3, .15)
    def stamp(s):
        s.prog(9, 0, 120, 64, 30); s.n(9, 0, .3, 36, 127); s.n(9, 0, .3, 41, 100); s.n(9, .01, .2, 39, 70)
    S['stamp'] = gm_fx('stamp', 120, stamp, .6)
    def fail(s):
        s.prog(0, 58, 110, 64, 50); s.n(0, 0, .35, 43, 100); s.n(0, .4, 1.1, 42, 100)
    S['fail'] = gm_fx('fail', 120, fail, .6)
    # hendel van de slotmachine: ratel + klak
    lev = np.zeros(int(.45 * SR))
    for k in range(9): place(lev, bp_noise(.012, 1500, 7000) * env(int(.012 * SR), .0005, .003), .02 + k * .028, .6 - k * .03)
    place(lev, bp_noise(.08, 80, 600) * env(int(.08 * SR), .001, .02), .3, .9)
    S['lever'] = reverb(lev, .25, .12)
    def reel(s): s.prog(9, 0, 110, 64, 25); s.n(9, 0, .2, 77, 110); s.n(9, 0, .2, 36, 70)
    S['reel'] = gm_fx('reel', 120, reel, .6)
    # roulette: rollend balletje dat vertraagt en stuitert
    n = int(4.3 * SR); roll = bp_noise(4.3, 2000, 7000) * .12 * (0.6 + .4 * np.sin(np.arange(n) / SR * 2 * np.pi * np.linspace(9, 3, n)))
    roll *= np.linspace(1, .2, n)
    t, gap = 2.6, .07
    while t < 4.1:
        place(roll, bp_noise(.015, 2500, 9000) * env(int(.015 * SR), .0005, .004), t, .5); t += gap; gap *= 1.35
    S['roulette'] = reverb(roll, .4, .15)
    def bell(s): s.prog(0, 14, 110, 64, 70); s.n(0, 0, 1.8, 72, 110); s.n(0, 0, 1.8, 79, 90)
    S['bell'] = gm_fx('bell', 120, bell, .55)
    # paarden: hoefgetrappel (hout) met wat ruis van de baan
    g = np.zeros(int(4.1 * SR))
    for i in range(22):
        for off, f, v in [(0, 500, .7), (.06, 650, .5), (.11, 420, .6)]:
            place(g, bp_noise(.04, f * .5, f * 2.5) * env(int(.04 * SR), .001, .01), i * .18 + off + rng.uniform(-.005, .005), v)
    g += bp_noise(4.1, 200, 1200) * .05
    S['gallop'] = reverb(g * .8, .5, .2)
    # klap: stoot met lage dreun
    def hit(s): s.prog(9, 0, 120, 64, 30); s.n(9, 0, .2, 36, 127); s.n(9, 0, .2, 40, 90)
    h = gm_fx('hit', 120, hit, .6); slap = bp_noise(.06, 800, 5000) * env(int(.06 * SR), .0005, .012)
    S['hit'] = mix((h, 0, 1), (slap, 0, .5))
    def ko(s):
        s.prog(0, 47, 120, 64, 60); s.prog(1, 55, 100, 64, 70); s.prog(9, 0, 120, 64, 70)
        s.n(9, 0, .3, 36, 127); s.n(9, 0, 2, 49, 120); s.n(9, 0, 2, 57, 100); s.n(0, 0, 1.5, 41, 127); s.n(1, 0, 1, 48, 110)
    S['ko'] = gm_fx('ko', 120, ko, .55)
    # pintje: drie slokken + "aaah"
    def glug(dur, f):
        n = int(dur * SR); t = np.arange(n) / SR
        bub = np.sin(2 * np.pi * (f + 350 * t / dur) * t) * env(n, .004, dur / 3)
        return bub * .6 + bp_noise(dur, 200, 1400) * env(n, .005, dur / 4) * .4
    gl = np.zeros(int(1.1 * SR))
    for k, (t, f) in enumerate([(0, 240), (.26, 220), (.52, 200)]): place(gl, glug(.18, f), t, .9)
    place(gl, bp_noise(.35, 300, 2500) * np.sin(np.linspace(0, np.pi, int(.35 * SR))) * .25, .78)
    S['gulp'] = reverb(gl, .25, .1)
    # shotje: glas tikt + één slok
    def clink():
        n = int(.6 * SR); t = np.arange(n) / SR
        return sum(np.sin(2 * np.pi * f * t) * np.exp(-t / d) * a for f, d, a in [(2637, .25, .5), (3951, .18, .35), (5274, .12, .25), (6950, .08, .15)])
    S['shot'] = reverb(mix((clink(), 0, .7), (glug(.18, 230), .32, .8))[:, 0], .3, .15)
    # Red Bull: blikje open (klik + psssht)
    n = int(.6 * SR); psst = bp_noise(.6, 1800, 7500) * env(n, .003, .18)
    can = mix((bp_noise(.02, 1500, 6000) * env(int(.02 * SR), .0005, .004), 0, .9), (psst, .015, .6))
    S['zap'] = reverb(can[:, 0], .2, .1)
    # kapsalon: krokante happen
    cr = np.zeros(int(1.2 * SR))
    for k in range(3):
        for j in range(7): place(cr, bp_noise(.02, 1500, 8000) * env(int(.02 * SR), .0005, .006), k * .38 + j * .022 + rng.uniform(0, .01), rng.uniform(.3, .7))
        place(cr, bp_noise(.12, 150, 900) * env(int(.12 * SR), .005, .04), k * .38, .4)
    S['nom'] = reverb(cr, .2, .08)
    # Rizz-poeder: belletjesboom + celesta
    def sparkle(s):
        s.prog(0, 8, 100, 40, 90); s.prog(1, 9, 90, 88, 90); s.prog(9, 0, 100, 64, 90)
        s.n(9, 0, 2, 84, 110)
        for k in range(14): s.n(k % 2, .05 + k * .07, .9, R.choice([84, 86, 88, 91, 93, 96, 98, 100]), 70 + R.randint(0, 30))
    S['sparkle'] = gm_fx('sparkle', 120, sparkle, .55)
    return S


if __name__ == '__main__':
    what = sys.argv[2] if len(sys.argv) > 2 else 'all'
    if what in ('all', 'music'):
        for name, fn in [('campus', campus), ('casino', casino), ('battle', battle), ('bar', bar)]:
            a = fn(); to_mp3(a, os.path.join(OUT, 'music', name + '.mp3'), 96)
            print(name, round(len(a) / SR, 2), 's')
    if what in ('all', 'sfx'):
        for name, a in sfx().items():
            if a.ndim == 1: a = stereo(a)
            a = level(a, -16.0 if name in ('click', 'tick', 'flip', 'card', 'reel') else -14.0, .9)
            to_mp3(a, os.path.join(OUT, 'sfx', name + '.mp3'), 96, mono=True)
            print(name, round(len(a) / SR, 2), 's')
