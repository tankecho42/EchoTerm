"""Original minimal electronic score and transition sounds, generated for this film."""
import sys
import numpy as np,wave
from pathlib import Path
S=48000;D=30;out=np.zeros((S*D,2),dtype=np.float64);rng=np.random.default_rng(43)
def put(w,start,gain=1,pan=0):
 a=int(start*S);b=min(len(out),a+len(w));w=w[:b-a]*gain
 if a<0 or b<=a:return
 out[a:b,0]+=w*np.sqrt((1-pan)/2);out[a:b,1]+=w*np.sqrt((1+pan)/2)
def tone(freq,length,attack=.025,release=.25):
 t=np.arange(int(length*S))/S;env=np.minimum(1,t/attack)*np.minimum(1,(length-t)/release)
 return t,env
# Broad, breathy pads with slow harmonic movement.
chords=[[146.832,220,277.183,329.628],[123.471,185,246.942,293.665],[97.999,146.832,246.942,293.665],[110,164.814,220,329.628]]
for i,st in enumerate([0,4,8,12,16,20,24,27]):
 notes=chords[i%4] if st<27 else chords[0]
 length=min(5.4,30-st);t,e=tone(1,length,.8,1.5)
 for j,f in enumerate(notes):
  w=(np.sin(2*np.pi*f*t)+.27*np.sin(2*np.pi*f*2*t)+.1*np.sin(2*np.pi*f*3*t))*e
  w*=.8+.2*np.sin(2*np.pi*.18*t+j)
  put(w,st,.025,(j-1.5)/3)
# Sparse glass-like melodic notes. A 120 BPM grid leaves room for the interface.
notes=[587.330,739.989,880,1108.731,880,739.989,659.255,554.365]
for k,st in enumerate(np.arange(2.5,27,.5)):
 if k%8 in [3,6]:continue
 f=notes[k%8];t,e=tone(f,1.7,.005,.4)
 pluck=(np.sin(2*np.pi*f*t)+.18*np.sin(2*np.pi*f*2.002*t))*np.exp(-t*5)*e
 put(pluck,st,.12 if k%4==0 else .07,.45*np.sin(k*1.7))
 put(pluck,st+.22,.019,-.45*np.sin(k*1.7))
# Low pulse / restrained kick, no aggressive percussion.
for k,st in enumerate(np.arange(3,27,.5)):
 t=np.arange(int(.4*S))/S
 kick=np.sin(2*np.pi*(49*t+55*.018*(1-np.exp(-t/.018))))*np.exp(-t*13)*np.minimum(1,t/.003)
 put(kick,st,.17 if k%4==0 else .10)
 if k%2==1:
  n=rng.normal(size=int(.045*S));n=np.r_[0,np.diff(n)];n*=np.exp(-np.arange(len(n))/S*100)
  put(n,st+.25,.006,.3 if k%4 else -.3)
# Airy transitions aligned to camera changes.
for st in [2.5,8.5,14.5,22.5,26.5]:
 t=np.arange(int(.9*S))/S
 n=rng.normal(size=len(t));n=np.convolve(n,np.ones(13)/13,mode='same')
 env=np.sin(np.pi*np.minimum(1,t/.9))**2
 put(n*env,st,.075,-.35);put(n[::-1]*env,st+.06,.035,.35)
 t=np.arange(int(1.7*S))/S
 put(np.sin(2*np.pi*73.416*t)*np.exp(-t*5),st+.5,.18)
# Final clean sonic signature.
for f,st in [(587.33,27.2),(880,27.45),(1174.66,27.7)]:
 t,e=tone(f,2.25,.008,.7);put(np.sin(2*np.pi*f*t)*np.exp(-t*2)*e,st,.11)
fade=np.minimum(1,np.arange(len(out))/S/.45)*np.minimum(1,(len(out)-1-np.arange(len(out)))/S/1.2)
out*=fade[:,None];out=np.tanh(out*1.4)*.82
p=Path(__file__).resolve().parent.parent/'source/score.wav'
with wave.open(str(p),'wb') as w:w.setnchannels(2);w.setsampwidth(2);w.setframerate(S);w.writeframes((out*32767).astype('<i2').tobytes())
print(p)
