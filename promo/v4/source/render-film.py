"""EchoTerm / Lightfield. 30 seconds, deterministic 60 fps.
Real application capture plates + production Swift pixel animation + motion design.
The spatial session map and flying pixels are explanatory compositing, not app UI.
"""
import sys, math, json, hashlib, subprocess, functools
from pathlib import Path
import cv2, numpy as np
from PIL import Image, ImageDraw
ROOT=Path(__file__).resolve().parent.parent
OLD=ROOT.parent
W,H,FPS,D=1920,1080,60,30
INK=(29,40,58); MUTED=(100,118,139); BLUE=(54,119,216); LIGHT=(230,240,253)
cv2.setNumThreads(4)
def cl(x): return max(0.,min(1.,float(x)))
def sm(x): x=cl(x); return x*x*(3-2*x)
def ease(x): x=cl(x); return x*x*x*(x*(x*6-15)+10)
def mix(a,b,u): return np.asarray(a)+(np.asarray(b)-np.asarray(a))*u
@functools.lru_cache(None)
def tx(s,size=50,color=INK,bold=False,latin=False,tracking=0):
 key=hashlib.sha1(repr((s,size,color,bold,latin,tracking)).encode()).hexdigest()
 folder=ROOT/'assets/type';folder.mkdir(exist_ok=True)
 p=folder/(key+'.png')
 if not p.exists():
  subprocess.run([str(ROOT/'source/text-render'),s,str(size),''.join(f'{int(c):02x}' for c in color),'1' if bold else '0','2' if latin==2 else ('1' if latin else '0'),str(tracking),str(p)],check=True)
 return np.array(Image.open(p).convert('RGBA'))
def over(c,im,x,y,a=1):
 if a<=0:return
 x=int(round(x));y=int(round(y));h,w=im.shape[:2];ch,cw=c.shape[:2]
 x0=max(0,x);y0=max(0,y);x1=min(cw,x+w);y1=min(ch,y+h)
 if x1<=x0 or y1<=y0:return
 s=im[y0-y:y1-y,x0-x:x1-x];al=s[:,:,3:4].astype(np.float32)*(a/255)
 c[y0:y1,x0:x1,:3]=(c[y0:y1,x0:x1,:3]*(1-al)+s[:,:,:3]*al).astype(np.uint8)
def text(c,s,x,y,size=50,color=INK,a=1,bold=False,center=False,latin=False,tracking=0):
 im=tx(s,size,tuple(color),bold,latin,tracking)
 if center:x-=im.shape[1]/2
 over(c,im,x,y,a)
 return im.shape[:2]
def rounded(im,r=20):
 h,w=im.shape[:2];mask=Image.new('L',(w,h));d=ImageDraw.Draw(mask);d.rounded_rectangle((0,0,w-1,h-1),r,fill=255)
 return np.dstack([im[:,:,:3],np.array(mask)])
def fill(c,rect,color,a=1,r=0):
 x,y,w,h=map(int,rect)
 im=Image.new('RGBA',(max(1,w),max(1,h)));d=ImageDraw.Draw(im);d.rounded_rectangle((0,0,w-1,h-1),r,fill=(*color,int(a*255)))
 over(c,np.array(im),x,y)
# Light cyclorama, just enough colour to reveal the glass edges.
y,x=np.mgrid[0:H,0:W].astype(np.float32)
b=np.zeros((H,W,3),np.float32);b[:]=[249,249,247]
b+=np.exp(-((x-1540)**2/650**2+(y-740)**2/470**2))[:,:,None]*np.array([-30,-12,5])
b+=np.exp(-((x-290)**2/750**2+(y-950)**2/400**2))[:,:,None]*np.array([-10,-5,3])
b+=np.exp(-((x-1300)**2/740**2+(y-80)**2/360**2))[:,:,None]*np.array([4,-2,-8])
BASE=np.uint8(np.clip(b,0,255))
# Captures retain product glyphs. Re-composite the isolated window's neutral matte
# over the blurred set. The application was captured at 25%, Clear, Mist Blue.
rawback=np.array(Image.open(OLD/'stills/backdrop.jpg').convert('RGB'))
back=cv2.resize(rawback,(1170,768));back=cv2.GaussianBlur(back,(0,0),35).astype(np.float32)
PLATE=np.clip(back*.68+np.array([65,77,91]),0,255)*.75+np.array([24,29,38])*.25
@functools.lru_cache(None)
def cap(name):
 path=OLD/name;raw=np.array(Image.open(path).convert('RGB')).astype(np.float32)
 delta=raw-[97,100,107];plate=cv2.resize(PLATE,(raw.shape[1],raw.shape[0]))
 rgb=np.uint8(np.clip(plate+np.where(delta>0,delta*2.05,delta*.48),0,255))
 return rgb
BLOCKS=cap('stills/blocks.jpg').copy()
# Static titlebar Echo is replaced by its native 60-fps pixel stage.
BLOCKS[7:30,1050:1080]=BLOCKS[7:30,1018:1048]
BLOCKS=rounded(BLOCKS,14)
TARGET=rounded(cap('stills/navigation-target.jpg'),14)
AIFINAL=cap('footage/ai/0042.jpg')
B1=rounded(cap('stills/blocks.jpg')[42:173,184:1125],10)
B2=rounded(cap('stills/blocks.jpg')[175:339,184:1125],10)
B3=rounded(cap('stills/blocks.jpg')[343:670,184:1125],10)
TEST=rounded(AIFINAL[42:387,184:1125],12)
# Crop the real reply. Reveal its actual text progressively at display refresh rate.
AI_FINAL=AIFINAL[395:546,184:1128].copy()
AI_EMPTY=AI_FINAL.copy()
for yy in range(AI_EMPTY.shape[0]):
 AI_EMPTY[yy,8:]=AI_EMPTY[yy,880]
AI_EMPTY[:,0:2]=[134,183,241]
# Original output text: line reveal, no repeated low-FPS capture frames.
# input x=36,y=40; output x=64,y=77 /101 /125.

PIX=json.loads((ROOT/'assets/echo-60fps.json').read_text())
def pixels(t):return np.array(PIX[min(1799,max(0,int(round(t*60))))],np.float64)
IDLE=pixels(0)

def proj(cx,cy,width,ih,iw,ry=0,rx=0,rz=0):
 height=width*ih/iw
 pts=np.array([[-width/2,-height/2,0],[width/2,-height/2,0],[width/2,height/2,0],[-width/2,height/2,0]],np.float64)
 ax,ay,az=map(math.radians,(rx,ry,rz))
 RX=np.array([[1,0,0],[0,math.cos(ax),-math.sin(ax)],[0,math.sin(ax),math.cos(ax)]])
 RY=np.array([[math.cos(ay),0,math.sin(ay)],[0,1,0],[-math.sin(ay),0,math.cos(ay)]])
 RZ=np.array([[math.cos(az),-math.sin(az),0],[math.sin(az),math.cos(az),0],[0,0,1]])
 pts=pts@(RZ@RY@RX).T
 dest=pts[:,:2]*(2500/(2500+pts[:,2]))[:,None]+[cx,cy]
 return dest

def plane(c,im,cx,cy,width,ry=0,rx=0,rz=0,a=1,shadow=True,edge=True):
 ih,iw=im.shape[:2];dest=proj(cx,cy,width,ih,iw,ry,rx,rz)
 if a<=0:return dest
 if shadow:
  x0=max(0,int(dest[:,0].min())-75);x1=min(W,int(dest[:,0].max())+75)
  y0=max(0,int(dest[:,1].min())-55);y1=min(H,int(dest[:,1].max())+90)
  if x1>x0 and y1>y0:
   sh=np.zeros(((y1-y0+1)//2,(x1-x0+1)//2),np.uint8)
   cv2.fillConvexPoly(sh,((dest-[x0,y0]+[0,19])/2).astype(np.int32),255)
   sh=cv2.GaussianBlur(sh,(0,0),15);sh=cv2.resize(sh,(x1-x0,y1-y0)).astype(np.float32)[:,:,None]*(.14*a/255)
   c[y0:y1,x0:x1]=(c[y0:y1,x0:x1]*(1-sh)+np.array([78,103,138])*sh).astype(np.uint8)
 x0=max(0,int(np.floor(dest[:,0].min()))-2);y0=max(0,int(np.floor(dest[:,1].min()))-2)
 x1=min(W,int(np.ceil(dest[:,0].max()))+2);y1=min(H,int(np.ceil(dest[:,1].max()))+2)
 if x1>x0 and y1>y0:
  mat=cv2.getPerspectiveTransform(np.float32([[0,0],[iw,0],[iw,ih],[0,ih]]),(dest-[x0,y0]).astype(np.float32))
  im2=cv2.warpPerspective(im,mat,(x1-x0,y1-y0),flags=cv2.INTER_LINEAR)
  over(c,im2,x0,y0,a)
 if edge and a>.05:
  # Soft inner light along the bevel; no heavy window border.
  lay=np.zeros((H,W,4),np.uint8);cv2.polylines(lay,[dest.astype(np.int32)],True,(245,249,255,int(130*a)),1,cv2.LINE_AA);over(c,lay,0,0)
 return dest

def onplane(dest,imsize,pos):
 iw,ih=imsize
 mat=cv2.getPerspectiveTransform(np.float32([[0,0],[iw,0],[iw,ih],[0,ih]]),dest.astype(np.float32))
 return cv2.perspectiveTransform(np.array([[pos]],np.float32),mat)[0,0].astype(float)

def sq(c,xx,yy,s,col,al=1,rot=0):
 if al<=.005 or s<.2:return
 # Small supersampled square patch preserves smooth subpixel particle trajectories.
 m=int(s*1.5+4);x0=int(xx-m/2);y0=int(yy-m/2)
 if x0>W or y0>H or x0+m<0 or y0+m<0:return
 p=np.array([[-s/2,-s/2],[s/2,-s/2],[s/2,s/2],[-s/2,s/2]])
 r=rot;rr=np.array([[math.cos(r),-math.sin(r)],[math.sin(r),math.cos(r)]])
 p=p@rr.T+[xx-x0,yy-y0]
 patch=np.zeros((m,m,4),np.uint8)
 cv2.fillConvexPoly(patch,(p*256).astype(np.int32),tuple(map(int,(*col,255*cl(al)))),lineType=cv2.LINE_AA,shift=8)
 over(c,patch,x0,y0)
def bear(c,t,center,size,a=1,blue=0,rot=0):
 pp=pixels(t);step=size/14
 for p in pp:
  dx=(p[1]-6.5)*step;dy=(p[2]-6.5)*step
  xx=center[0]+dx*math.cos(rot)-dy*math.sin(rot);yy=center[1]+dx*math.sin(rot)+dy*math.cos(rot)
  col=mix(p[3:6]*255,BLUE,blue)
  sq(c,xx,yy,step*.89,col,a*p[6],rot)

def pathpoint(a,b,u,arc=160):
 u=cl(u);a=np.asarray(a);b=np.asarray(b)
 p=mix(a,b,u);p[1]-=math.sin(math.pi*u)*arc
 return p

def glyph_points(s,size,x,y,step=8):
 mask=tx(s,size,INK,True,s=='E')[:,:,3];pts=[]
 for yy in range(0,mask.shape[0],step):
  for xx in range(0,mask.shape[1],step):
   if mask[yy:yy+step,xx:xx+step].mean()>92:pts.append([xx+x+step/2,yy+y+step/2])
 return np.array(pts,np.float64)
PREFIX=tx('每条命令，自成一',82,INK,True)
PX=(W-PREFIX.shape[1]-108)/2
GLYPH=glyph_points('块',98,PX+PREFIX.shape[1]-3,112,7)
SUFFIX=tx('choTerm',156,INK,True,True)
EMASK=tx('E',156,INK,True,True)
WORD_X=(W-SUFFIX.shape[1]-EMASK.shape[1]+2)/2
EGLYPH=glyph_points('E',156,WORD_X,420,8)

def morph(c,pts0,pts1,u,size0=5,size1=7,arc=170,c0=None,c1=BLUE,alpha=1,stagger=.24):
 n=max(len(pts0),len(pts1));u=cl(u)
 for i in range(n):
  a=pts0[i%len(pts0)];b=pts1[i%len(pts1)]
  delay=((i*37)%n)/max(1,n-1)*stagger
  p=ease((u-delay)/(1-stagger))
  xx,yy=pathpoint(a,b,p,arc*(.45+.55*math.sin(i*1.8)**2))
  xx+=math.sin(math.pi*p)*math.sin(i*2.4)*50
  targetcol=np.asarray(c1)[i%len(c1)] if np.asarray(c1).ndim==2 else np.asarray(c1)
  col=mix(BLUE if c0 is None else c0[i%len(c0)],targetcol,sm(p*1.8))
  sz=float(mix(size0,size1,p));al=alpha
  if len(pts0)<n and i>=len(pts0):al*=sm(u/.18)
  if len(pts1)<n and i>=len(pts1):al*=1-sm((u-.65)/.35)
  sq(c,xx,yy,sz,col,al,math.sin(math.pi*p)*math.sin(i)*.8)

def bearpoints(t,center,size):
 pp=pixels(t);pp=pp[pp[:,6]>.03];return pp[:,1:3]*size/14+np.asarray(center)-6.5*size/14,pp[:,3:6]*255

def dotline(c,pts,color=BLUE,a=1,thickness=2):
 lay=np.zeros((H,W,4),np.uint8);cv2.polylines(lay,[np.int32(pts)],False,(*color,int(255*a)),thickness,cv2.LINE_AA);over(c,lay,0,0)

# Airy props behind the product: a design notes window and a file browser.
def prop(kind):
 im=np.zeros((420,620,3),np.uint8);im[:]=[232,237,243] if kind==0 else [244,239,232]
 text(im,'Aurora / notes' if kind==0 else 'Aurora',29,21,21,MUTED,latin=True)
 cv2.line(im,(0,64),(620,64),(211,221,233),1)
 if kind==0:
  for i,w in enumerate([300,425,260,370,210,330,290]):
   fill(im,(35,103+i*36,w,7),[(138,166,201),(170,188,209),(183,194,210)][i%3],.75,3)
 else:
  for i,label in enumerate(['config','src','tests']):
   fill(im,(44,108+i*93,57,39),(138,179,221),1,6);text(im,label,127,105+i*93,24,MUTED,latin=True)
 return rounded(im,17)
PROPS=[prop(0),prop(1)]

# Compact, faithful product-style source question panel for the explanatory map.
def source_panel():
 im=cv2.resize(cap('stills/navigation-input.jpg'),(980,640))
 # Small plate reproduces the app's in-flow input/reply rather than a chat bubble.
 # Re-typeset for legibility of the spatial explanation. The underlying story is recorded.
 im[:]=cv2.resize(PLATE,(980,640)).astype(np.uint8)
 text(im,'S2  ·  开发笔记',31,19,21,(223,235,250),latin=False)
 cv2.line(im,(0,61),(979,61),(139,161,188),1)
 text(im,'01  /private/tmp/Aurora',31,82,16,(181,201,225),latin=True)
 text(im,'找一下另一个会话里',33,127,33,(248,250,255),bold=True)
 text(im,'服务端口的配置，并跳过去。',33,175,33,(248,250,255),bold=True)
 cv2.line(im,(0,258),(979,258),(139,161,188),1)
 text(im,'ECHO',112,297,17,(181,205,237),latin=True,tracking=2)
 text(im,'从已有会话开始查找',112,333,28,(247,250,255))
 text(im,'S1  /  Aurora',112,410,22,(184,213,249),latin=True)
 fill(im,(0,259,3,299),(145,190,244))
 cv2.line(im,(0,558),(979,558),(139,161,188),1)
 text(im,'›',28,582,33,(173,208,251),latin=True)
 return rounded(im,16)
SOURCE=source_panel()
# Different block crops are existing app records, placed in a single Session map.
def session_plate():
 im=cv2.resize(PLATE,(980,760)).astype(np.uint8)
 text(im,'S1  ·  Aurora',30,18,22,(231,239,251),latin=True)
 text(im,'3 BLOCKS',810,25,14,(193,213,239),latin=True,tracking=1)
 cv2.line(im,(0,62),(980,62),(139,161,188),1)
 y=75
 for block,hh in [(B1,134),(B2,166),(B3,333)]:
  rb=cv2.resize(block,(950,hh));over(im,rb,15,y);y+=hh+10
 return rounded(im,16)
SESSION=session_plate()
# Selected block crop is exact recorded config, with local locator annotation outside.


def unified_pose(t):
 u=ease(t/1.0)
 return (960.,665.,float(mix(1530,1620,u)),float(mix(-11,-2,u)),float(mix(7,1,u)),float(mix(-3,0,u)))

def unified_input(t):
 # One continuous terminal viewport. A completed command scrolls upwards and
 # the next prompt lands at the same visual anchor, with no mode choice at all.
 im=cv2.resize(PLATE,(1400,590)).astype(np.uint8)
 scroll=356*ease((t-2.3)/.62)
 def line(s,yy,size=25,color=(242,247,254),bold=False,xx=79,latin=False):
  text(im,s,xx,58+yy-scroll,size,color,bold=bold,latin=latin)
 def border(yy,color=(142,165,194)):
  cv2.line(im,(0,int(58+yy-scroll)),(1399,int(58+yy-scroll)),color,1,cv2.LINE_AA)
 line('01  /private/tmp/Aurora',32,17,(178,202,232),xx=40,latin=2)
 command='python3 -m unittest -v';n=int(cl((t-.25)/.94)*len(command))
 line('›',70,36,(172,208,253),xx=38,latin=2)
 line(command[:n],75,29,(178,226,208),latin=2)
 if t<1.36:
  wi=tx(command[:n],29,(178,226,208),False,2).shape[1]
  cv2.line(im,(79+wi,int(58+82-scroll)),(79+wi,int(58+107-scroll)),(223,236,254),2)
 tests=['test_health ... ok','test_port ... ok','test_routes ... ok','test_version ... ok']
 for i,ln in enumerate(tests):
  n=int(cl((t-1.39-i*.14)/.15)*len(ln))
  if n:line(ln[:n],126+i*32,23,(226,237,250),latin=2)
 if t>=2.0:
  line('Ran 4 tests   ·   OK',281,25,(191,233,214),latin=2)
 if t>=2.32:border(365)
 if t>=2.32:
  received=t>=3.85
  state='完成' if t>=7.10 else ('回答中' if t>=6.0 else ('思考中' if t>=5.4 else '已收到'))
  line('02  ECHO  问答  ·  '+state if received else '02  /private/tmp/Aurora',388,17,(181,208,243),xx=40)
  question='这些测试结果说明了什么？';n=int(cl((t-2.96)/.77)*len(question))
  line('✦' if received else '›',428,31,(172,208,253),xx=38)
  line(question[:n],430,29)
  if not received and t>2.94:
   wi=tx(question[:n],29,(242,247,254)).shape[1]
   cv2.line(im,(79+wi,int(58+437-scroll)),(79+wi,int(58+462-scroll)),(223,236,254),2)
  if received:
   cv2.line(im,(1,int(58+367-scroll)),(1,int(58+627-scroll)),(139,188,253),3,cv2.LINE_AA)
  answer=['4 项测试全部通过。','健康检查、版本号、路由和端口配置均符合预期。','下一步可以验证 /health 接口，继续检查实际服务。']
  for j,ln in enumerate(answer):
   n=int(cl((t-6.04-j*.27)/.44)*len(ln))
   if n:line(ln[:n],496+j*38,25,(241,247,255),j==0,xx=122)
  if t>=7.1:
   border(637)
   line('03  /private/tmp/Aurora',657,17,(178,202,232),xx=40,latin=2)
   line('›',696,35,(172,208,253),xx=38,latin=2)
   command='curl localhost:4317/health';n=int(cl((t-7.26)/.87)*len(command))
   line(command[:n],699,29,(178,226,208),latin=2)
   wi=tx(command[:n],29,(178,226,208),False,2).shape[1]
   if int(t*2)%2==0:cv2.line(im,(79+wi,int(58+706-scroll)),(79+wi,int(58+731-scroll)),(223,236,254),2)
 # Toolbar is drawn after the scrolled body so content never paints over it.
 im[:58]=cv2.resize(PLATE,(1400,590))[:58].astype(np.uint8)
 cv2.line(im,(0,57),(1399,57),(147,168,195),1)
 text(im,'S2  ·  Aurora — bash',35,14,19,(220,234,252),latin=2)
 text(im,'自动识别',1250,14,18,(199,220,249))
 return rounded(im,14)

def unified_anchor(t):
 pose=unified_pose(t);dest=proj(*pose[:3],590,1400,*pose[3:])
 scroll=356*ease((t-2.3)/.62)
 return onplane(dest,(1400,590),(60,58+528-scroll))

def intro(c,t):
 plane(c,PROPS[0],400,677,650,ry=12,rz=-8,a=.31,shadow=False)
 plane(c,PROPS[1],1545,698,660,ry=-15,rz=9,a=.33,shadow=False)
 plane(c,unified_input(t),*unified_pose(t))
 # The primary proposition is readable from the very first beat.
 a=.6+.4*sm(t/.4)
 text(c,'EchoTerm · AI Native 终端',960,43,25,MUTED,a,center=True)
 text(c,'命令与问答，一个入口。',960,109,82,INK,a,True,True)
 text(c,'自动识别，无需切换。命令与 AI 无感衔接。',960,231,29,MUTED,a,center=True)
 if 3.85<=t<7.85:bear(c,t,unified_anchor(t),82)

# Block organisation is the second point, after the unified input experience.
def block_pose(t):
 u=ease((t-8.35)/2.6)
 return (1000.,710.,float(mix(1250,1120,u)),float(mix(10,-7,u)),4.,float(mix(3,-2,u)))
def ai(c,t):
 plane(c,PROPS[0],560,716,650,ry=12,rz=-8,a=.5,shadow=False)
 plane(c,PROPS[1],1495,644,630,ry=-15,rz=9,a=.5,shadow=False)
 dest=plane(c,BLOCKS,*block_pose(t))
 a=sm((t-8.1)/.5)
 over(c,PREFIX,PX,122,a)
 text(c,'命令、回答、上下文，都清晰有序。',960,249,28,MUTED,a,center=True)
 if t>=9.6:
  for xx,yy in GLYPH:sq(c,xx,yy,6.3,BLUE)
 for yy,delay in [(173,0),(341,.22),(672,.44)]:
  q=sm((t-8.8-delay)/.42)
  if q>0:
   l=onplane(dest,(1170,768),(184,yy));r=onplane(dest,(1170,768),(1125,yy))
   dotline(c,[l,mix(l,r,q)],(194,223,255),.66,2)

# Camera coordinates for the continuous two-session search. Both sessions remain
# in the same world; the close-up is a camera move, never a replacement slide.
def cam(t):
 if t<12.45:return (-570.,15.,1.50,0.)
 if t<13.6:
  u=ease((t-12.45)/1.15);return tuple(mix([-570,15,1.5,0],[0,20,.81,-2],u))
 if t<19.65:return (0.,20.,.81,-2+2*sm((t-13.6)/1.3))
 u=ease((t-19.65)/1.3);return tuple(mix([0,20,.81,0],[100,25,.79,3],u))
def wp(p,t):
 cx,cy,z,r=cam(t);a=math.radians(r);v=(np.array(p)-[cx,cy])*z
 return np.array([v[0]*math.cos(a)-v[1]*math.sin(a)+960,v[0]*math.sin(a)+v[1]*math.cos(a)+607])
def world_plane(c,im,pos,width,t,alpha=1):
 center=wp(pos,t);z=cam(t)[2];r=cam(t)[3]
 return plane(c,im,*center,width*z,ry=0,rx=0,rz=r,a=alpha)
def worldtext(c,s,pos,t,size=24,color=INK,a=1,latin=False,bold=False,center=False):
 p=wp(pos,t);im=tx(s,size,tuple(color),bold,latin)
 z=cam(t)[2];res=cv2.resize(im,None,fx=z,fy=z,interpolation=cv2.INTER_LINEAR)
 if center:p[0]-=res.shape[1]/2
 over(c,res,*p,a)
def cross(c,t):
 zoom=ease((t-16.3)/1.3)*(1-ease((t-19.65)/1.25))
 mapalpha=1-zoom*.88
 left=world_plane(c,SOURCE,(-570,20),850,t,mapalpha)
 right=world_plane(c,SESSION,(580,20),850,t,mapalpha)
 if t>12.7:
  worldtext(c,'当前会话',(-570,-349),t,26,MUTED,a=mapalpha*sm((t-12.7)/.5),center=True)
  worldtext(c,'另一个会话', (580,-392),t,26,MUTED,a=mapalpha*sm((t-12.7)/.5),center=True)
 a0=np.array([-932.,26.]);target=np.array([138.,122.])
 # Scan the real block index, then bring the matching block forward out of it.
 for i,yy in enumerate([-235,-95,133]):
  p=wp((995,yy),t);z=cam(t)[2]
  active=(i==0 and 14.0<t<14.6) or (i==1 and 14.6<=t<15.2) or (i==2 and t>=15.2)
  rr=(11 if active else 6)*z
  if mapalpha>.4:cv2.circle(c,tuple(np.int32(p)),int(rr),BLUE if active else (174,189,207),-1,cv2.LINE_AA)
  if 13.4<t<17.1:worldtext(c,f'{i+1:02d}',(1016,yy-13),t,22,BLUE if active else MUTED,a=mapalpha,latin=True)
 if t>=13.3:
  travel=sm((t-13.3)/2.0)
  arr=np.array([wp(pathpoint(a0,target,float(q),140),t) for q in np.linspace(0,travel,100)])
  dotline(c,arr,BLUE,.25*mapalpha,2)
 # Continuous detached Block move: starts exactly atop its place in Session 1.
 near=None
 if zoom>0:
  base=wp((580,178),t);pos=mix(base,[960,588],zoom)
  width=float(mix(824*cam(t)[2],1480,zoom))
  near=plane(c,B3,*pos,width,ry=-13*math.sin(zoom*math.pi),rx=4*math.sin(zoom*math.pi),rz=-7*math.sin(zoom*math.pi),a=1)
  if t>17.5:
   pulse=(.5+.5*math.cos((t-17.5)*2*math.pi/.63)) if t<18.76 else .18
   lay=np.zeros((H,W,4),np.uint8);cv2.polylines(lay,[near.astype(np.int32)],True,(*BLUE,int(95+130*pulse)),3,cv2.LINE_AA);over(c,lay,0,0)
 if t<13.25:
  bear(c,t,wp(a0,t),cam(t)[2]*68)
 elif t<15.45:
  u=(t-13.25)/2.2
  start,col=bearpoints(13.25,wp(a0,t),cam(t)[2]*68)
  end,_=bearpoints(15.45,wp(target,t),cam(t)[2]*68)
  morph(c,start,end,u,4.6,4.6,180,None,BLUE,stagger=.43)
 else:
  anchor=wp(target,t)
  if near is not None:
   edge=onplane(near,(941,327),(-34,50))
   anchor=mix(anchor,edge,zoom)
  bear(c,t,anchor,float(mix(cam(t)[2]*68,88,zoom)),blue=.45 if t<17.8 else .06)
 # Headings are above all moving geometry, never obscured by a close-up.
 if t<14.5:
  text(c,'不用记住，在哪个会话。',960,98,73,INK,sm((t-11.1)/.65),True,True)
  text(c,'直接问 Echo。',960,214,29,MUTED,sm((t-11.3)/.6),center=True)
 elif t<17.0:
  text(c,'跨 Session 查找。跨 Block 直达。',960,98,65,INK,sm((t-14.4)/.5),True,True)
  text(c,'从会话概览，读取 Block 03。',960,209,28,MUTED,1,center=True)
 elif t<19.9:
  text(c,'找到了。就在 Block 03。',960,98,76,INK,sm((t-17)/.35),True,True)
  text(c,'S1  /  Aurora  /  config/server.toml',960,212,25,MUTED,1,center=True,latin=True)
 else:
  text(c,'上下文，始终连在一起。',960,98,72,INK,sm((t-19.9)/.5),True,True)
  text(c,'从当前问题，直达另一个会话里的答案。',960,214,28,MUTED,sm((t-20)/.5),center=True)
 if 17.6<t<19.8:
  a=sm((t-17.6)/.45)*(1-sm((t-19.45)/.35))
  text(c,'port = 4317',1436,629,43,(230,242,255),a,True,True,True)
  text(c,'已定位原始输出',1436,701,22,(182,208,241),a,center=True)
 if t>=20.0:
  u=cl((t-20.05)/1.05)
  for i in range(18):
   p=wp(pathpoint(target,a0,sm((u-i*.012)/.8),-115),t)
   sq(c,p[0],p[1],5,BLUE,sm(u/.2)*(1-sm((u-.8)/.2)))
  worldtext(c,'4317',(-706,192),t,52,(221,238,255),a=sm((t-20.65)/.4),latin=True,bold=True)
 # One understated route, a visual explanation rather than fictional controls.
 labels=['提问','查找会话','读取 Block','跳转高亮']
 step=0 if t<13.3 else (1 if t<15.2 else (2 if t<17.5 else 3))
 for i,lbl in enumerate(labels if t>=13.1 else []):
  xx=550+i*272
  if i>0:cv2.line(c,(xx-196,982),(xx-40,982),(193,205,222),1,cv2.LINE_AA)
  col=BLUE if i==step else (106,130,159) if i<step else (176,186,200)
  cv2.circle(c,(xx,951),4,col,-1,cv2.LINE_AA)
  text(c,lbl,xx,969,23,col,center=True)
 return wp(target,t)

# The captured UI glyphs stay sharp while the optical layer changes beneath them.
# Theme colours follow EchoTerm's Mist / Iris / Amber palettes. This is motion
# design showing real appearance options, not a recording of a new settings UI.
GLASS_RAW=np.array(Image.open(OLD/'stills/blocks.jpg').convert('RGB')).astype(np.float32)
GLASS_RAW[7:30,1050:1080]=GLASS_RAW[7:30,1018:1048]
GLASS_DELTA=GLASS_RAW-[97,100,107]
GLASS_BACKS=[cv2.GaussianBlur(cv2.resize(rawback,(1170,768)),(0,0),sigma).astype(np.float32) for sigma in [8,28,58]]
THEME_RGB=[(145,187,242),(192,162,239),(228,183,117)]
THEME_BASE=[(24,29,38),(32,28,43),(37,32,25)]

def appearance(t):
 # Opacity breathes, then glass moves through Clear / Soft / Frosted.
 density=.23+.37*sm((t-22.15)/.72)-.29*sm((t-23.2)/.85)
 material=2*sm((t-23.0)/1.6)
 return density,material

def glass_ui(theme,density,material):
 lo=min(1,int(material));f=cl(material-lo)
 backdrop=mix(GLASS_BACKS[lo],GLASS_BACKS[lo+1],f)
 tint=np.asarray(THEME_RGB[theme]);base=np.asarray(THEME_BASE[theme])
 bg=np.clip(backdrop*.56+tint*.34+22,0,255)*(1-density)+base*density
 # Retain source text / separators and tint only the blue UI accent contribution.
 delta=GLASS_DELTA.copy()
 if theme:
  blue=np.maximum(0,delta[:,:,2]-delta[:,:,0])
  delta+=blue[:,:,None]*(tint-np.asarray(THEME_RGB[0]))[None,None,:]/100
 rgb=np.uint8(np.clip(bg+np.where(delta>0,delta*2.05,delta*.48),0,255))
 return rounded(rgb,14)

def glass_pose(t):
 u=ease((t-21.65)/1.30)
 return (960,628,float(mix(1100,810,u)),float(mix(24,-5,ease((t-21.65)/3.3))),5.,float(mix(7,-2,u)))

def glass_anchor(t):
 pose=glass_pose(t)
 return onplane(proj(*pose[:3],768,1170,*pose[3:]),(1170,768),(1065,19))

def glass(c,t):
 enter=sm((t-21.7)/.5);fan=ease((t-21.95)/1.10)
 text(c,'轻到，只留下专注。',960,103,80,INK,enter,True,True)
 text(c,'透明度与毛玻璃可调，多款主题可选。',960,224,29,MUTED,sm((t-21.85)/.6),center=True)
 # Quiet background windows give the glass something tangible to refract.
 plane(c,PROPS[0],480,640,620,ry=16,rx=5,rz=-9,a=.50)
 plane(c,PROPS[1],1470,665,600,ry=-13,rx=-3,rz=8,a=.50)
 density,material=appearance(t)
 for theme,side in [(1,-1),(2,1)]:
  xx=960+side*float(mix(120,600,fan))
  dest=plane(c,glass_ui(theme,.30,material),xx,633,610,ry=-side*13,rx=5,rz=side*7,a=fan)
  # Theme names are outside the product and stay legible during the camera move.
  text(c,['','鸢尾','琥珀'][theme],xx,858,24,tuple(int(v*.67) for v in THEME_RGB[theme]),fan,center=True)
 pose=glass_pose(t)
 dest=plane(c,glass_ui(0,density,material),*pose)
 anchor=onplane(dest,(1170,768),(1065,19))
 if t<25.05:bear(c,t,anchor,33*pose[2]/1130)
 text(c,'雾蓝',960,919,24,BLUE,fan,center=True)
 # Value-free editorial controls explain adjustability, without inventing a
 # pixel-radius control: the application offers three named glass materials.
 controls=sm((t-22.30)/.5)
 layer=c.copy()
 text(layer,'透明度',443,977,23,MUTED)
 fill(layer,(551,996,270,3),(201,212,227),1,1)
 knob=551+270*cl((density-.12)/.58)
 fill(layer,(551,996,knob-551,3),BLUE,1,1)
 cv2.circle(layer,(int(knob),997),8,(255,255,255),-1,cv2.LINE_AA)
 cv2.circle(layer,(int(knob),997),8,BLUE,2,cv2.LINE_AA)
 text(layer,'毛玻璃',935,977,23,MUTED)
 fill(layer,(1048+material*108,973,99,48),(221,233,249),1,16)
 for i,label in enumerate(['通透','柔和','磨砂']):
  text(layer,label,1097+i*108,982,22,BLUE if abs(i-material)<.5 else MUTED,center=True)
 c[:]=cv2.addWeighted(c,1-controls,layer,controls,0)
 # One restrained sweep ties the three glass surfaces to the existing lighting.
 if 22.4<t<24.9:
  xx=1170*sm((t-22.4)/2.5)
  pts=[onplane(dest,(1170,768),p) for p in [(xx-65,0),(xx+60,0),(xx-135,768),(xx-260,768)]]
  lay=np.zeros((H,W,4),np.uint8);cv2.fillConvexPoly(lay,np.int32(pts),(246,252,255,16));over(c,lay,0,0)
 return anchor

def endcard(c,t):
 over(c,SUFFIX,WORD_X+EMASK.shape[1]-2,420,sm((t-26.25)/.65))
 if t>=27.3:
  for xx,yy in EGLYPH:sq(c,xx,yy,7.2,BLUE)
 text(c,'命令与 AI，无感衔接。',960,663,39,MUTED,sm((t-27.0)/.65),center=True)
 text(c,'AI Native 终端 · 为 macOS 而设计',960,805,21,(140,155,173),sm((t-27.5)/.6),center=True)
 if t>27.65:bear(c,t,[960,328],94)

def travelling_pixels(c,t):
 # A separate optical layer escapes the glass and remains physically continuous
 # while the camera underneath rolls between the two scenes.
 if 7.85<=t<9.6:
  anchor=unified_anchor(7.85)
  pts,col=bearpoints(7.85,anchor,82)
  morph(c,pts,GLYPH,(t-7.85)/1.75,5.2,6.3,250,col,BLUE,stagger=.23)
 if 25.05<=t<27.3:
  pose=glass_pose(25.05);anchor=glass_anchor(25.05)
  start,col=bearpoints(25.05,anchor,33*pose[2]/1130)
  morph(c,start,EGLYPH,(t-25.05)/2.25,33*pose[2]/1130/14*.89,7.2,225,col,stagger=.27)

# Full-frame roll transitions. Frames are overscanned to keep the white studio
# continuous, while particles can move independently of the frame.
CUTS=[8.4,11.2,21.7,25.8]
def stage(idx,t):
 c=BASE.copy()
 if idx==0:intro(c,t)
 elif idx==1:ai(c,t)
 elif idx==2:cross(c,t)
 elif idx==3:glass(c,t)
 else:endcard(c,t)
 return c

def roll(im,angle,scale,dx=0,dy=0,blur=0):
 m=cv2.getRotationMatrix2D((W/2,H/2),angle,scale);m[:,2]+=[dx,dy]
 ans=cv2.warpAffine(im,m,(W,H),flags=cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=(248,249,249))
 if blur>0.1:ans=cv2.GaussianBlur(ans,(0,0),blur)
 return ans

def frame(t):
 idx=int(np.searchsorted(CUTS,t,side='right'))
 # Deliberate 90-degree whole-scene barrel rolls, near/far push at the midpoint.
 # For the final shot a longer pullback carries the last pixel into the name.
 for j,cut in enumerate(CUTS):
  dur=.92 if j!=2 else 1.10
  if cut-dur/2<=t<cut+dur/2:
   q=(t-cut+dur/2)/dur;u=ease(q);sign=[-1,1,-1,1][j]
   a=stage(j,t);b=stage(j+1,t)
   outa=sign*92*u;ina=sign*(-92+92*u)
   scaleA=1+.90*u;scaleB=1+.85*(1-u)
   # Faster middle, nearly still endpoints. No black edges or exposure flashes.
   aa=roll(a,outa,scaleA,blur=3.8*math.sin(math.pi*q)**6)
   bb=roll(b,ina,scaleB,blur=3.8*math.sin(math.pi*q)**6)
   blend=sm((q-.41)/.18)
   ans=cv2.addWeighted(aa,1-blend,bb,blend,0)
   travelling_pixels(ans,t)
   return ans
 ans=stage(idx,t);travelling_pixels(ans,t);return ans

def previews():
 times=[.45,1.15,2.15,2.65,3.55,4.45,5.8,6.7,7.75,8.4,9.7,10.4,12.0,14.8,18.6,22.8,26.8,28.7]
 board=Image.new('RGB',(1920,math.ceil(len(times)/3)*390),(237,241,246));d=ImageDraw.Draw(board)
 for i,t in enumerate(times):
  im=Image.fromarray(frame(t));im.save(ROOT/f'previews/frame-{t:04.1f}.png');im.thumbnail((632,356))
  x=(i%3)*640;y=(i//3)*390;board.paste(im,(x,y+27));d.text((x+12,y+6),f'{t:.1f}s',fill=(30,50,70))
 board.save(ROOT/'previews/contact.jpg');print('Previews ready',flush=True)
def render():
 path=ROOT/'output/EchoTerm-Promo-v4-30s.mp4'
 cmd=['ffmpeg','-hide_banner','-loglevel','warning','-y','-f','rawvideo','-vcodec','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r','60','-i','-','-i',str(ROOT/'source/soundtrack.wav'),'-map','0:v','-map','1:a','-c:v','libx264','-preset','fast','-crf','16','-pix_fmt','yuv420p','-c:a','aac','-b:a','256k','-ar','48000','-movflags','+faststart','-t','30','-metadata','title=EchoTerm — 命令与 AI，无感衔接。','-metadata','comment=Product film: real UI capture plates, Swift-native pixel animation, composited glass and explanatory session map. Scripted AI demo, original score.',str(path)]
 p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 for n in range(1800):
  p.stdin.write(frame(n/60).tobytes())
  if n%120==0:print(f'Rendered {n/60:.0f}/30 s',flush=True)
 p.stdin.close();assert p.wait()==0
 print(path,flush=True)
if __name__=='__main__':
 if '--render' in sys.argv:render()
 elif '--frame' in sys.argv:
  t=float(sys.argv[-1]);Image.fromarray(frame(t)).save(ROOT/'previews/check.png')
 else:previews()
