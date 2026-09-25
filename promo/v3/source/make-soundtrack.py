"""Original bright electronic score and frame-timed pixel / camera sound design.
No samples, stock tracks, model-generated music or external recordings.
"""
import sys,math,wave
from pathlib import Path
import numpy as np
SR=48000;D=30;root=Path(__file__).resolve().parent
out=np.zeros((SR*D,2),np.float64);rng=np.random.default_rng(219)
def put(w,start,gain=1,pan=0):
 a=int(start*SR);b=min(len(out),a+len(w))
 if a<0 or b<=a:return
 w=w[:b-a]*gain;out[a:b,0]+=w*math.sqrt((1-pan)/2);out[a:b,1]+=w*math.sqrt((1+pan)/2)
def bell(f,length=1.8):
 t=np.arange(int(SR*length))/SR
 w=(np.sin(2*np.pi*f*t)*np.exp(-t*3.4)+.22*np.sin(2*np.pi*f*2.001*t)*np.exp(-t*8)+.05*np.sin(2*np.pi*f*3.99*t)*np.exp(-t*13))
 return w*np.minimum(1,t/.006)*np.minimum(1,(length-t)/.1)
def note(f,st,gain=.09,pan=0):
 b=bell(f);put(b,st,gain,pan);put(b,st+.225,gain*.22,-pan);put(b,st+.45,gain*.08,pan)
# Dmaj9 / Bm9 / Gmaj9 / Asus4: warm, bright, spacious; no dramatic trailer brass.
chords=[[146.832,220,277.183,329.628],[123.471,185,246.942,293.665],[97.999,146.832,220,293.665],[110,164.814,246.942,329.628]]
for idx,st in enumerate([0,4,8,12,16,20,24,27]):
 length=min(5.2,30-st);t=np.arange(int(SR*length))/SR
 env=np.minimum(1,t/.85)*np.minimum(1,(length-t)/1.4)
 for j,f in enumerate(chords[idx%4] if st<27 else chords[0]):
  w=(np.sin(2*np.pi*f*t)+.24*np.sin(2*np.pi*(f*2+.14)*t))*env
  put(w,st,.023,.75*(j-1.5)/1.5)
# Rising glass arpeggio with deliberate pauses for the pixel shape changes.
mel=[587.33,739.989,880,1174.659,1108.731,880,739.989,659.255]
for k,st in enumerate(np.arange(1.0,26.6,.5)):
 if k%8 in [3,7] or 16.8<st<18.5:continue
 note(mel[k%8],float(st),.075 if k%4==0 else .038,.55*math.sin(k*1.7))
# Soft syncopated low pulse. Spacious rather than pounding.
for k,st in enumerate(np.arange(2.0,26,.5)):
 t=np.arange(int(SR*.36))/SR
 kick=np.sin(2*np.pi*(52*t+44*.024*(1-np.exp(-t/.024))))*np.exp(-t*14)*np.minimum(1,t/.005)
 put(kick,float(st),.105 if k%4==0 else .051)
 if k%2==1:
  n=rng.normal(size=int(SR*.07));n=np.r_[0,np.diff(n)]*np.exp(-np.arange(len(n))/SR*75)
  put(n,float(st+.25),.0028,.45)
# Camera roll whooshes travel across the stereo field.
for idx,cut in enumerate([8.4,11.2,21.7,25.8]):
 length=.92;t=np.arange(int(SR*length))/SR
 n=rng.normal(size=len(t));low=np.convolve(n,np.ones(21)/21,mode='same')
 env=np.sin(np.pi*t/length)**2
 tone=np.sin(2*np.pi*(260*t+680*t*t))*np.exp(-((t-.44)/.24)**2)
 w=low*env*.75+tone*.05
 put(w,cut-.50,.12,-.8 if idx%2==0 else .8)
 put(w[::-1],cut-.39,.07,.8 if idx%2==0 else -.8)
 t=np.arange(int(SR*.8))/SR
 put(np.sin(2*np.pi*73.416*t)*np.exp(-t*9),cut+.05,.09)
# Fine grains accompany the pixels leaving the window and becoming typography.
for start,end in [(1.45,2.1),(3.85,4.4),(7.85,9.5),(13.45,15.3),(25.15,27.1)]:
 for j,st in enumerate(np.linspace(start,end,10)):
  f=1174.659*(2**((j%5)/12));w=bell(f,.16)*np.exp(-np.arange(int(SR*.16))/SR*19)
  put(w,float(st),.016,.7*math.sin(j*.55))
# Selection then two restrained confirmation pulses, aligned with the target.
note(880,15.22,.035,.65)
note(1174.659,17.55,.085,.15)
note(1479.978,18.18,.038,.35)
# A three-note end mark with a natural 2-second tail.
for f,st,g in [(587.33,27.20,.10),(880,27.43,.085),(1174.659,27.67,.075)]:
 note(f,st,g)
fade=np.minimum(1,np.arange(len(out))/SR/.35)*np.minimum(1,(len(out)-1-np.arange(len(out)))/SR/.9)
out=np.tanh(out*1.3)*fade[:,None]
with wave.open(str(root/'score.wav'),'wb') as w:
 w.setnchannels(2);w.setsampwidth(2);w.setframerate(SR);w.writeframes(np.int16(np.clip(out,-1,1)*32767).astype('<i2').tobytes())
print(root/'score.wav')
