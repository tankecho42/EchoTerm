"""Render EchoTerm's 30-second film from actual application-window frame captures.
The isolated window capture omits the desktop. Its neutral backdrop is composited
with the separately captured blue workspace; UI content is never re-typeset.
"""
import sys,math,json,subprocess,functools
from pathlib import Path
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFont
ROOT=Path(__file__).resolve().parent.parent
W,H=1920,1080;FPS=60;DURATION=30
FONT='/System/Library/PrivateFrameworks/FontServices.framework/Resources/Reserved/PingFangUI.ttc'
SF='/System/Library/Fonts/SFNS.ttf'
MONO='/System/Library/Fonts/SFNSMono.ttf'
cv2.setNumThreads(4)
def clamp(x):return max(0.,min(1.,x))
def smooth(x):x=clamp(x);return x*x*(3-2*x)
def out(x):return 1-(1-clamp(x))**3
def mix(a,b,t):return a+(b-a)*t
@functools.lru_cache(None)
def font(size,bold=False,latin=False):
 f=ImageFont.truetype(SF if latin else FONT,size,index=0)
 if latin:
  try:f.set_variation_by_name('Bold' if bold else 'Regular')
  except Exception:pass
 return f
@functools.lru_cache(None)
def text_asset(text,size,color=(241,245,251),bold=False,latin=False,tracking=0):
 import hashlib
 key=hashlib.sha1(repr((text,size,color,bold,latin,tracking)).encode()).hexdigest()
 folder=ROOT/'source/type';folder.mkdir(exist_ok=True)
 path=folder/(key+'.png')
 if not path.exists():
  rgb=''.join(f'{c:02x}' for c in color)
  subprocess.run([str(ROOT/'source/text-render'),text,str(size),rgb,'1' if bold else '0','1' if latin else '0',str(tracking),str(path)],check=True)
 return np.array(Image.open(path).convert('RGBA'))

def overlay(canvas,layer,x,y,alpha=1):
 if alpha<=0:return
 x=int(x);y=int(y);h,w=layer.shape[:2]
 x0=max(0,x);y0=max(0,y);x1=min(W,x+w);y1=min(H,y+h)
 if x1<=x0 or y1<=y0:return
 src=layer[y0-y:y1-y,x0-x:x1-x];a=src[:,:,3:4].astype(np.float32)/255*alpha
 dst=canvas[y0:y1,x0:x1]
 dst[:]=(dst*(1-a)+src[:,:,:3]*a).astype(np.uint8)
def text(canvas,txt,x,y,size=60,color=(241,245,251),alpha=1,bold=False,center=False,latin=False,tracking=0):
 a=text_asset(txt,size,color,bold,latin,tracking)
 if center:x-=a.shape[1]/2
 overlay(canvas,a,x,y,alpha)
Y,X=np.mgrid[0:H,0:W].astype(np.float32)
base=np.zeros((H,W,3),np.float32);base[:]=[5,9,17]
glow=np.exp(-((X-1350)**2/(2*690**2)+(Y-550)**2/(2*520**2)))[:,:,None]
base+=glow*np.array([10,23,43],np.float32)
base+=np.exp(-((X-420)**2/(2*700**2)+(Y-1050)**2/(2*310**2)))[:,:,None]*np.array([5,9,18],np.float32)
BASE=np.uint8(base)
backdrop=np.array(Image.open(ROOT/'stills/backdrop.jpg').convert('RGB'))
BACK=cv2.resize(backdrop,(W,H),interpolation=cv2.INTER_CUBIC)
# A background plate matching the set. The UI capture has an opaque neutral matte.
rawSize=Image.open(ROOT/'stills/blocks.jpg').size
SW,SH=rawSize
backplate=cv2.resize(backdrop,(SW,SH),interpolation=cv2.INTER_CUBIC)
backplate=cv2.GaussianBlur(backplate,(0,0),24).astype(np.float32)
BLUE_PLATE=backplate*.60*.75+np.array([24,29,38],np.float32)*.25
MATTE=np.array([97,100,107],np.float32)
@functools.lru_cache(maxsize=160)
def ui(path):
 a=np.array(Image.open(path).convert('RGB')).astype(np.float32)
 plate=cv2.resize(BLUE_PLATE,(a.shape[1],a.shape[0]))
 delta=a-MATTE
 # Restore foreground contrast from the neutral capture matte; retain real pixel text and motion.
 adjusted=plate+np.where(delta>=0,delta*1.52,delta*.48)
 rgb=np.uint8(np.clip(adjusted,0,255))
 mask=Image.new('L',(a.shape[1],a.shape[0]),0);dr=ImageDraw.Draw(mask);dr.rounded_rectangle((0,0,a.shape[1]-1,a.shape[0]-1),radius=13,fill=255)
 return np.dstack([rgb,np.array(mask)])
shots={n:ui(str(ROOT/'stills'/n)) for n in ['blocks.jpg','ai-input.jpg','navigation-input.jpg','navigation-target.jpg']}
class Sequence:
 def __init__(self,name):
  self.folder=ROOT/'footage'/name;self.frames=json.loads((self.folder/'frames.json').read_text());self.times=np.array([f['time'] for f in self.frames])
 def at(self,t):
  i=max(0,min(len(self.frames)-1,int(np.searchsorted(self.times,t,side='right')-1)))
  return ui(str(self.folder/self.frames[i]['file']))
AI=Sequence('ai');NAV=Sequence('navigation')

def plane(canvas,img,cx,cy,width,ry=0,rx=0,rz=0,opacity=1,shadow=True):
 ih,iw=img.shape[:2];height=width*ih/iw
 pts=np.array([[-width/2,-height/2,0],[width/2,-height/2,0],[width/2,height/2,0],[-width/2,height/2,0]],np.float64)
 ax,ay,az=map(math.radians,(rx,ry,rz))
 RX=np.array([[1,0,0],[0,math.cos(ax),-math.sin(ax)],[0,math.sin(ax),math.cos(ax)]])
 RY=np.array([[math.cos(ay),0,math.sin(ay)],[0,1,0],[-math.sin(ay),0,math.cos(ay)]])
 RZ=np.array([[math.cos(az),-math.sin(az),0],[math.sin(az),math.cos(az),0],[0,0,1]])
 pts=pts@(RZ@RY@RX).T;factor=2200/(2200+pts[:,2]);dest=pts[:,:2]*factor[:,None]+[cx,cy]
 if shadow:
  sm=np.zeros((H//2,W//2),np.uint8);poly=(dest/2+[0,13]).astype(np.int32);cv2.fillConvexPoly(sm,poly,145)
  sm=cv2.GaussianBlur(sm,(0,0),13);sm=cv2.resize(sm,(W,H)).astype(np.float32)[:,:,None]/255*opacity
  canvas[:]=(canvas*(1-sm)).astype(np.uint8)
 x0=max(0,int(np.floor(dest[:,0].min()))-2);y0=max(0,int(np.floor(dest[:,1].min()))-2)
 x1=min(W,int(np.ceil(dest[:,0].max()))+2);y1=min(H,int(np.ceil(dest[:,1].max()))+2)
 if x1>x0 and y1>y0:
  matrix=cv2.getPerspectiveTransform(np.float32([[0,0],[iw,0],[iw,ih],[0,ih]]),(dest-[x0,y0]).astype(np.float32))
  warped=cv2.warpPerspective(img,matrix,(x1-x0,y1-y0),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
  overlay(canvas,warped,x0,y0,opacity)
 if opacity>.02:
  line=(np.array([130,175,225])*opacity).astype(int).tolist();cv2.polylines(canvas,[dest.astype(np.int32)],True,line,1,cv2.LINE_AA)
 return dest

def footer(c,n,alpha=1):
 text(c,'EchoTerm',115,983,24,(153,169,190),alpha,latin=True)
 text(c,f'{n:02d} / 04',1748,987,18,(106,127,155),alpha,latin=True,tracking=1)
def badge(c,label,x,y,w,alpha=1):
 im=Image.new('RGBA',(w,48),(0,0,0,0));d=ImageDraw.Draw(im);d.rounded_rectangle((0,0,w-1,47),radius=24,fill=(92,138,194,24),outline=(137,185,245,66),width=1)
 overlay(c,np.array(im),x,y,alpha);text(c,label,x+w/2,y+7,22,(168,201,242),alpha,center=True)

ICON=np.array(Image.open(ROOT.parent/'assets/EchoTerm.png').convert('RGBA'))

def scene(idx,t):
 c=BASE.copy()
 if idx==0:
  a=smooth(t/.55);lift=24*(1-out(t/.8))
  text(c,'INTRODUCING',W/2,314+lift,21,(132,167,210),a,center=True,latin=True,tracking=7)
  text(c,'EchoTerm',W/2,388+lift,150,(247,249,252),a,True,True,True)
  text(c,'终端，重新清晰。',W/2,592+lift,48,(191,209,233),smooth((t-.35)/.7),center=True)
  span=220*smooth((t-.55)/1.0);cv2.line(c,(int(W/2-span),713),(int(W/2+span),713),(55,91,140),1,cv2.LINE_AA)
  # A small moving pulse hints at the cursor without adding a decorative motif.
  x=int(mix(W/2-210,W/2+210,smooth((t-.65)/1.5)));cv2.line(c,(x,713),(x+18,713),(173,210,255),2,cv2.LINE_AA)
 elif idx==1:
  enter=out(t/.95);text(c,'01   /   BLOCKS',118,100,22,(132,167,210),smooth(t/.5),latin=True,tracking=3)
  text(c,'每条命令，\n自成一块。',112,252+20*(1-enter),86,alpha=enter,bold=True)
  text(c,'输入与输出，一眼对应。',117,525,28,(157,177,202),smooth((t-.3)/.6))
  img=shots['blocks.jpg']
  if t>2.6:
   # Continuous dolly into the actual Block boundaries.
   z=smooth((t-2.6)/.65)
   top=int(mix(0,174,z)); bottom=int(mix(SH,671,z))
   left=int(mix(0,183,z)); right=int(mix(SW,1122,z))
   img=img[top:bottom,left:right].copy()
  # Slow dolly and an eight-degree orbit give the genuine app window depth.
  width=mix(1050,1275,smooth(t/6))
  plane(c,img,mix(1490,1350,enter),545+26*math.sin(t*.28),width,ry=mix(-17,-6,enter),rx=4,rz=-1.8,opacity=enter)
  if t>2.4:badge(c,'命令  ＋  输出',123,660,228,smooth((t-2.4)/.5))
  footer(c,1,enter)
 elif idx==2:
  a=out(t/.7);text(c,'02   /   INLINE AI',118,100,22,(132,167,210),a,latin=True,tracking=3)
  text(c,'直接问。\n接着做。',112,252+18*(1-a),86,alpha=a,bold=True)
  text(c,'同一行输入，自动识别意图。',118,523,27,(157,177,202),a)
  text(c,'像素 Echo · 流式回答',118,571,22,(118,148,184),a)
  # Start at the actual input, then carry through the received/thinking/reply states.
  if t<1.0:img=shots['ai-input.jpg']
  else:img=AI.at((t-1)*1.12)
  crop=img[386:555,183:903].copy()
  # White-space is intentional: the AI stays inside the terminal's Block.
  plane(c,crop,mix(1450,1300,a),480,1130,ry=-3,rx=1,rz=-.5,opacity=a)
  # The original command output sits quietly above the focused answer.
  upper=shots['ai-input.jpg'][48:330,183:1122].copy()
  plane(c,upper,1320,160,1010,ry=-3,rx=1,rz=-.5,opacity=.19*a,shadow=False)
  badge(c,'命令 / 问题，自然切换',118,679,310,a)
  footer(c,2,a)
 elif idx==3:
  a=out(t/.7)
  text(c,'03   /   CONNECTED CONTEXT',W/2,74,21,(132,167,210),a,center=True,latin=True,tracking=4)
  text(c,'跨越会话，直达上下文。',W/2,127+15*(1-a),71,alpha=a,bold=True,center=True)
  text(c,'读取历史 Block，再跳转到原始记录。',W/2,235,26,(157,177,202),a,center=True)
  # Replay captured read_block -> jump_to_block, including the actual session switch.
  st=(t-1.0)*.99
  img=shots['navigation-input.jpg'] if t<1 else NAV.at(st)
  crop=img[:375,:].copy()
  plane(c,crop,W/2,593+25*(1-a),1605,ry=mix(5,0,smooth(t/3)),rx=2,opacity=a)
  if st<3.8:badge(c,'S2 · 开发笔记',285,884,235,a)
  else:
   badge(c,'S1 · Block 03',285,884,245,a)
   text(c,'port = 4317',1130,884,30,(177,213,255),smooth((st-3.8)/.5),latin=True)
  footer(c,3,a)
 elif idx==4:
  a=out(t/.7)
  # The separately captured workspace becomes visible behind the isolated window.
  back=cv2.GaussianBlur(BACK,(0,0),1.4)
  c=np.uint8(back*.57+BASE*.43)
  # Title scrim stays subtle and leaves both background prop windows visible.
  dark=np.maximum(0,1-Y/390)[:,:,None]*.58;c=np.uint8(c*(1-dark))
  text(c,'轻盈，看得见。',W/2,64,76,alpha=a,bold=True,center=True)
  text(c,'雾蓝主题 · 通透毛玻璃 · 25% 不透明度',W/2,170,27,(174,201,233),a,center=True)
  plane(c,shots['blocks.jpg'],1050,654,1110+20*math.sin(t*.5),ry=mix(9,-2,smooth(t/4.5)),rx=3,rz=-1.3,opacity=a)
  text(c,'25%',143,416,76,(230,241,254),a,bold=True,latin=True)
  text(c,'背景不透明度',145,515,22,(171,197,228),a)
  text(c,'通透',143,636,44,(230,241,254),a)
  text(c,'毛玻璃材质',145,707,22,(171,197,228),a)
  footer(c,4,a)
 else:
  a=out(t/.75);lift=35*(1-a)
  icon=cv2.resize(ICON,(290,290),interpolation=cv2.INTER_AREA);overlay(c,icon,W/2-145,203+lift,a)
  text(c,'EchoTerm',W/2,512+lift,103,(247,249,252),a,True,True,True)
  text(c,'专注命令，连接上下文。',W/2,665+lift,34,(166,192,224),smooth((t-.2)/.65),center=True)
  text(c,'为 macOS 而设计',W/2,758,21,(107,133,165),smooth((t-.4)/.6),center=True)
  text(c,'演示情境 · AI 文案为脚本，终端与导航为实际操作；窗口背景经后期合成。',W/2,1002,17,(92,111,137),smooth((t-.4)/.5),center=True)
 return c
CUTS=[0,2.8,8.8,14.8,22.3,26.8,30]
def frame(t):
 idx=min(5,int(np.searchsorted(CUTS,t,side='right')-1));local=t-CUTS[idx]
 c=scene(idx,local)
 trans=.45
 if idx>0 and local<trans:
  u=smooth(local/trans);prev=scene(idx-1,CUTS[idx]-CUTS[idx-1]+local)
  # A short defocused dolly makes cuts feel like one continuous camera movement.
  mat=cv2.getRotationMatrix2D((W/2,H/2),0,1+.075*u);prev=cv2.warpAffine(prev,mat,(W,H))
  if u>.02:prev=cv2.GaussianBlur(prev,(0,0),.2+5*u)
  mat=cv2.getRotationMatrix2D((W/2,H/2),0,1+.035*(1-u));c=cv2.warpAffine(c,mat,(W,H))
  c=cv2.addWeighted(prev,1-u,c,u,0)
 if t>DURATION-.45:c=np.uint8(c*(1-smooth((t-(DURATION-.45))/.45)))
 return c

def previews():
 times=[1.5,4.5,7.5,10.5,13,16.5,19.5,21.4,24.5,28.5]
 board=Image.new('RGB',(1920,5*300),(9,14,23));d=ImageDraw.Draw(board)
 for i,t in enumerate(times):
  im=Image.fromarray(frame(t));im.save(ROOT/f'stills/frame-{t:04.1f}.png');im.thumbnail((950,260));x=(i%2)*960;y=(i//2)*300
  board.paste(im,(x,y+30));d.text((x+12,y+8),f'{t:.1f}s',fill='white')
 board.save(ROOT/'stills/film-contact.jpg')
 print('Previews ready',flush=True)
def render():
 outfile=ROOT/'output/EchoTerm-Promo-30s.mp4'
 cmd=['ffmpeg','-hide_banner','-loglevel','warning','-y','-f','rawvideo','-vcodec','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-','-i',str(ROOT/'source/soundtrack.wav'),'-map','0:v','-map','1:a','-c:v','libx264','-preset','fast','-crf','17','-pix_fmt','yuv420p','-c:a','aac','-b:a','256k','-ar','48000','-movflags','+faststart','-t',str(DURATION),'-metadata','title=EchoTerm — 终端，重新清晰。','-metadata','comment=Actual EchoTerm UI capture; scripted local AI demo; composited window background; original generated score.',str(outfile)]
 p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 for n in range(DURATION*FPS):
  p.stdin.write(frame(n/FPS).tobytes())
  if n%(FPS*2)==0:print(f'Rendered {n/FPS:.0f}/{DURATION}s',flush=True)
 p.stdin.close();rc=p.wait();assert rc==0,rc
 print(outfile,flush=True)
if __name__=='__main__':
 if '--render' in sys.argv:render()
 else:previews()
