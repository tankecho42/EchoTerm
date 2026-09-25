import sys, json, subprocess, hashlib, math
from pathlib import Path
import cv2, numpy as np
from PIL import Image,ImageDraw
from timing import DURATION, FRAME_COUNT, presentation_time, hold_report
ROOT=Path(__file__).resolve().parent.parent
video=ROOT/'output/EchoTerm-Promo-v6-41s.mp4'
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-count_frames','-show_streams','-show_format','-of','json',str(video)]))
v=next(s for s in probe['streams'] if s['codec_type']=='video');a=next(s for s in probe['streams'] if s['codec_type']=='audio')
assert (v['width'],v['height'])==(1920,1080)
assert v['r_frame_rate']=='60/1' and int(v['nb_read_frames'])==FRAME_COUNT
assert abs(float(probe['format']['duration'])-DURATION)<.04
assert a['sample_rate']=='48000' and a['channels']==2
subprocess.run(['ffmpeg','-v','error','-i',str(video),'-f','null','-'],check=True)
# Extract the encoded result, not just uncompressed source previews.
times=[.45,3.55,6.7,7.75,8.4,9.7,10.7,11.7,12.5,13.4,14.3,15.4,16.2,16.7,17.8,18.5,19.2,19.7,20.5,21.3,22.0,22.8,23.5,24.3,24.8,25.6,26.7,28.65,29.5]
board=Image.new('RGB',(1920,math.ceil(len(times)/4)*297),(242,245,249));d=ImageDraw.Draw(board)
cap=cv2.VideoCapture(str(video))
for i,source in enumerate(times):
 t=presentation_time(source)
 cap.set(cv2.CAP_PROP_POS_FRAMES,round(t*60));ok,frame=cap.read();assert ok
 im=Image.fromarray(cv2.cvtColor(frame,cv2.COLOR_BGR2RGB))
 im.save(ROOT/f'previews/encoded-{t:05.2f}.png')
 if source==7.75:im.save(ROOT/'output/EchoTerm-Promo-v6-poster.png')
 im.thumbnail((478,269));x=i%4*480;y=i//4*297
 board.paste(im,(x,y+26));d.text((x+10,y+7),f'{t:.2f} s',fill=(30,50,70))
cap.release();board.save(ROOT/'previews/encoded-contact.jpg')
# Native sprite data must be complete and deterministic at 60 Hz.
pixels=json.loads((ROOT/'assets/echo-60fps.json').read_text())
assert len(pixels)==1800
assert all(math.isfinite(x) for frame in pixels for p in frame for x in p)
proof={'file':str(video),'duration_seconds':float(probe['format']['duration']), 'width':v['width'],'height':v['height'],'frame_rate':v['r_frame_rate'],'decoded_frames':int(v['nb_read_frames']),'video_codec':v['codec_name'],'pixel_format':v['pix_fmt'],'audio_codec':a['codec_name'],'audio_hz':int(a['sample_rate']),'audio_channels':a['channels'],'full_decode':'passed','native_pixel_source_frames':len(pixels),'held_poses':hold_report(),'pacing':'C2 continuous retiming; interpolated native pixels; border circulation keeps presentation-time speed','sha256':hashlib.sha256(video.read_bytes()).hexdigest(),'production_pixel_source_sha256':hashlib.sha256((ROOT.parent.parent/'Sources/EchoTerm/EchoIdentity.swift').read_bytes()).hexdigest(),'method':'Actual UI capture plates; scripted AI demonstration; 60fps Swift pixel animation; composited glass, session map and camera. No claim of live 60fps screen recording.'}
(ROOT/'source/media-check.json').write_text(json.dumps(proof,indent=2,ensure_ascii=False))
print(json.dumps(proof,indent=2,ensure_ascii=False))
