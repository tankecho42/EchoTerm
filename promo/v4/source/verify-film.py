import sys, json, subprocess, hashlib, math
from pathlib import Path
import cv2, numpy as np
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parent.parent
video=ROOT/'output/EchoTerm-Promo-v4-30s.mp4'
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',str(video)]))
v=next(s for s in probe['streams'] if s['codec_type']=='video');a=next(s for s in probe['streams'] if s['codec_type']=='audio')
assert (v['width'],v['height'])==(1920,1080)
assert v['r_frame_rate']=='60/1' and int(v['nb_read_frames'])==1800
assert abs(float(probe['format']['duration'])-30)<.04
assert a['sample_rate']=='48000' and a['channels']==2
subprocess.run(['ffmpeg','-v','error','-i',str(video),'-f','null','-'],check=True)
# Extract the encoded result, not just uncompressed source previews.
times=[.45,1.15,2.15,2.65,3.55,4.45,5.8,6.7,7.75,8.4,9.7,10.4,12.0,13.8,14.65,15.85,17.6,18.6,20.85,22.3,22.8,23.5,24.3,24.7,25.1,25.6,26.7,28.65,29.5]
board=Image.new('RGB',(1920,math.ceil(len(times)/4)*297),(242,245,249));d=ImageDraw.Draw(board)
cap=cv2.VideoCapture(str(video))
for i,t in enumerate(times):
 cap.set(cv2.CAP_PROP_POS_FRAMES,round(t*60));ok,frame=cap.read();assert ok
 im=Image.fromarray(cv2.cvtColor(frame,cv2.COLOR_BGR2RGB))
 if t in [1.15,3.55,6.7,7.75,18.6,22.8,24.3,24.7,25.1,25.6,28.65,29.5]:im.save(ROOT/f'previews/encoded-{t:05.2f}.png')
 if t==7.75:im.save(ROOT/'output/EchoTerm-Promo-v4-poster.png')
 im.thumbnail((478,269));x=i%4*480;y=i//4*297
 board.paste(im,(x,y+26));d.text((x+10,y+7),f'{t:.2f} s',fill=(30,50,70))
cap.release();board.save(ROOT/'previews/encoded-contact.jpg')
# Native sprite data must be complete and deterministic at 60 Hz.
pixels=json.loads((ROOT/'assets/echo-60fps.json').read_text())
assert len(pixels)==1800
assert all(math.isfinite(x) for frame in pixels for p in frame for x in p)
proof={'file':str(video),'duration_seconds':float(probe['format']['duration']), 'width':v['width'],'height':v['height'],'frame_rate':v['r_frame_rate'],'decoded_frames':int(v['nb_read_frames']),'video_codec':v['codec_name'],'pixel_format':v['pix_fmt'],'audio_codec':a['codec_name'],'audio_hz':int(a['sample_rate']),'audio_channels':a['channels'],'full_decode':'passed','native_pixel_frames':len(pixels),'sha256':hashlib.sha256(video.read_bytes()).hexdigest(),'production_pixel_source_sha256':hashlib.sha256((ROOT.parent.parent/'Sources/EchoTerm/EchoIdentity.swift').read_bytes()).hexdigest(),'method':'Actual UI capture plates; scripted AI demonstration; 60fps Swift pixel animation; composited glass, session map and camera. No claim of live 60fps screen recording.'}
(ROOT/'source/media-check.json').write_text(json.dumps(proof,indent=2,ensure_ascii=False))
print(json.dumps(proof,indent=2,ensure_ascii=False))
