"""EchoTerm / Lightfield. 46 seconds, deterministic 60 fps.
Real application capture plates + production Swift pixel animation + motion design.
The spatial session map and flying pixels are explanatory compositing, not app UI.
"""
import sys, math, json, hashlib, subprocess, functools, os
from pathlib import Path
import cv2, numpy as np
from timing import DURATION, FRAME_COUNT, LEAD_IN, presentation_time, source_time
from PIL import Image, ImageDraw
from pixel_type import layout as pixel_word_layout, SQUARE as BLOCK_PIXEL_SIZE
ROOT=Path(__file__).resolve().parent.parent
OLD=ROOT.parent
W,H,FPS,D=1920,1080,60,DURATION
INK=(29,40,58); MUTED=(100,118,139); BLUE=(54,119,216); LIGHT=(230,240,253)
cv2.setNumThreads(4)
def cl(x): return max(0.,min(1.,float(x)))
def sm(x): x=cl(x); return x*x*(3-2*x)
def ease(x): x=cl(x); return x*x*x*(x*(x*6-15)+10)
def mix(a,b,u): return np.asarray(a)+(np.asarray(b)-np.asarray(a))*u
@functools.lru_cache(None)
def tx(s,size=50,color=INK,bold=False,latin=True,tracking=0):
 key=hashlib.sha1(repr((s,size,color,bold,latin,tracking)).encode()).hexdigest()
 folder=ROOT/'assets/type';folder.mkdir(exist_ok=True)
 p=folder/(key+'.png')
 if not p.exists():
  pending=p.with_name(p.stem+f'.{os.getpid()}.tmp.png')
  subprocess.run([str(ROOT/'source/text-render'),s,str(size),''.join(f'{int(c):02x}' for c in color),'1' if bold else '0','2' if latin==2 else ('1' if latin else '0'),str(tracking),str(pending)],check=True)
  pending.replace(p)
 return np.array(Image.open(p).convert('RGBA'))
def over(c,im,x,y,a=1):
 if a<=0:return
 x=int(round(x));y=int(round(y));h,w=im.shape[:2];ch,cw=c.shape[:2]
 x0=max(0,x);y0=max(0,y);x1=min(cw,x+w);y1=min(ch,y+h)
 if x1<=x0 or y1<=y0:return
 s=im[y0-y:y1-y,x0-x:x1-x];al=s[:,:,3:4].astype(np.float32)*(a/255)
 c[y0:y1,x0:x1,:3]=(c[y0:y1,x0:x1,:3]*(1-al)+s[:,:,:3]*al).astype(np.uint8)
def text(c,s,x,y,size=50,color=INK,a=1,bold=False,center=False,latin=True,tracking=0):
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
 path=ROOT/'assets/blocks-en.png' if name=='stills/blocks.jpg' else OLD/name
 raw=np.array(Image.open(path).convert('RGB')).astype(np.float32)
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
PIX_ARRAYS=[np.asarray(f,np.float64) for f in PIX]
BLINK_CUTS={66,75,1716,1725}
def pixels(t):
 # Retimed motion is evaluated at subframes; blink gestures stay discrete.
 f=float(np.clip(t*60,0,len(PIX_ARRAYS)-1));i=int(f);j=min(i+1,len(PIX_ARRAYS)-1)
 a,b=PIX_ARRAYS[i],PIX_ARRAYS[j];u=f-i
 if u<1e-7 or j in BLINK_CUTS:return a.copy()
 if a.shape==b.shape and np.array_equal(a[:,0],b[:,0]):return mix(a,b,u)
 aa={int(p[0]):p for p in a};bb={int(p[0]):p for p in b};out=[]
 for ident in sorted(aa.keys()|bb.keys()):
  pa=aa.get(ident,bb.get(ident)).copy();pb=bb.get(ident,aa.get(ident)).copy()
  if ident not in aa:pa[6]=0
  if ident not in bb:pb[6]=0
  out.append(mix(pa,pb,u))
 return np.asarray(out)
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
 patch=np.zeros((m,m,4),np.uint8);patch[:,:,:3]=np.uint8(col)
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
 mask=tx(s,size,INK,True,True)[:,:,3];pts=[]
 for yy in range(0,mask.shape[0],step):
  for xx in range(0,mask.shape[1],step):
   if mask[yy:yy+step,xx:xx+step].mean()>92:pts.append([xx+x+step/2,yy+y+step/2])
 return np.array(pts,np.float64)
PREFIX=tx('Every command. Its own ',76,INK,True,True)
PX,GLYPH,BLOCK_LETTERS=pixel_word_layout(PREFIX,W)
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
  if len(pts1)<n and i>=len(pts1):al*=1-sm((u-.50)/.30)
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
 text(im,'S2  ·  Dev Notes',31,19,21,(223,235,250),latin=True)
 cv2.line(im,(0,61),(979,61),(139,161,188),1)
 text(im,'01  /private/tmp/Aurora',31,82,16,(181,201,225),latin=True)
 text(im,'Find the server port setting',33,127,33,(248,250,255),bold=True)
 text(im,'in another session, and jump to it.',33,175,31,(248,250,255),bold=True)
 cv2.line(im,(0,258),(979,258),(139,161,188),1)
 text(im,'ECHO',112,297,17,(181,205,237),latin=True,tracking=2)
 text(im,'Searching existing sessions',112,333,28,(247,250,255))
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
 def line(s,yy,size=25,color=(242,247,254),bold=False,xx=79,latin=True):
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
  state='Complete' if t>=7.10 else ('Replying' if t>=6.0 else ('Thinking' if t>=5.4 else 'Received'))
  line('02  ECHO  Chat  ·  '+state if received else '02  /private/tmp/Aurora',388,17,(181,208,243),xx=40)
  question='What do these test results mean?';n=int(cl((t-2.96)/.77)*len(question))
  line('✦' if received else '›',428,31,(172,208,253),xx=38)
  line(question[:n],430,29)
  if not received and t>2.94:
   wi=tx(question[:n],29,(242,247,254)).shape[1]
   cv2.line(im,(79+wi,int(58+437-scroll)),(79+wi,int(58+462-scroll)),(223,236,254),2)
  if received:
   cv2.line(im,(1,int(58+367-scroll)),(1,int(58+627-scroll)),(139,188,253),3,cv2.LINE_AA)
  answer=['All 4 tests passed.','Health checks, routes, version and port configuration look good.','Next, try /health to check the running service.']
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
 text(im,'Auto Detect',1250,14,18,(199,220,249))
 return rounded(im,14)

def unified_anchor(t):
 pose=unified_pose(t);dest=proj(*pose[:3],590,1400,*pose[3:])
 scroll=356*ease((t-2.3)/.62)
 return onplane(dest,(1400,590),(60,58+528-scroll))

def intro(c,t):
 plane(c,PROPS[0],400,677,650,ry=12,rz=-8,a=.31,shadow=False)
 plane(c,PROPS[1],1545,698,660,ry=-15,rz=9,a=.33,shadow=False)
 plane(c,unified_input(t),*unified_pose(t))
 # The headline emerges only after the continuous product entrance.
 a=sm((t+.45)/.90)
 text(c,'EchoTerm · AI-native terminal',960,43,25,MUTED,a,center=True)
 text(c,'Commands. Questions. One prompt.',960,109,76,INK,a,True,True)
 text(c,'Just type. Echo knows what to do.',960,231,29,MUTED,a,center=True)
 if 3.85<=t<7.85:bear(c,t,unified_anchor(t),82)

# A quiet five-second overture. The very same empty terminal plane arrives at
# unified_pose(0), so the first command begins without an inserted cut or zoom.
OPEN_GRID=[]
for yy in range(9):
 xx=3+min(yy,8-yy)
 for dx in (0,1):OPEN_GRID.append((xx+dx,yy))
for yy in (8,9):
 for xx in range(11,18):OPEN_GRID.append((xx,yy))
OPEN_GRID=np.asarray(OPEN_GRID,float)
OPEN_GLYPH=(OPEN_GRID-[10,4.5])*14+[960,441]
OPEN_EMPTY=unified_input(0)

def opening_pose(t):
 q=ease((t-2.35)/(LEAD_IN-2.35))
 return tuple(mix([1080,670,780,-42,13,-11],unified_pose(0),q))

def opening_pixels(t):
 # One stable set of squares gathers into a minimal terminal prompt (> _).
 # Extra squares peel away from each glyph cell only during the edge tracing.
 count=len(OPEN_GLYPH);n=count*3;ids=np.arange(n);base=ids%count
 f=base/max(1,count-1);group=ids//count
 glyph=OPEN_GLYPH[base]
 seed=glyph+np.column_stack([-480-130*np.sin(f*5),170*np.cos(f*math.pi*2)+110])
 u=np.clip((t-.10-f*.16)/.72,0,1);u=u*u*u*(10-15*u+6*u*u)
 q=u[:,None]
 cp1=seed+np.array([180,-175]);cp2=glyph+np.column_stack([-125+30*f,-115-35*f])
 xy=(1-q)**3*seed+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*glyph
 alpha=np.clip((t-.06-f*.12)/.32,0,1)*(group==0)
 size=np.full(n,10.7);colour=np.tile(np.asarray(BLUE,float),(n,1))
 if t>=2.35:
  # Follow the actual perspective of the incoming glass, then pour into its
  # empty prompt. All endpoint geometry is derived from that live plane.
  dest=proj(*opening_pose(t)[:3],590,1400,*opening_pose(t)[3:])
  path=np.array([[22,2],[1378,2],[1398,22],[1398,568],[1378,588],[22,588],[2,568],[2,22],[22,2]],float)
  dist=np.r_[0,np.cumsum(np.linalg.norm(np.diff(path,axis=0),axis=1))];dist/=dist[-1]
  phase=(ids/n+(t-2.35)*.085)%1
  ix=np.minimum(len(path)-2,np.searchsorted(dist,phase,side='right')-1)
  local=mix(path[ix],path[ix+1],((phase-dist[ix])/(dist[ix+1]-dist[ix]))[:,None])
  matrix=cv2.getPerspectiveTransform(np.float32([[0,0],[1400,0],[1400,590],[0,590]]),dest.astype(np.float32))
  edge=cv2.perspectiveTransform(local[None].astype(np.float32),matrix)[0].astype(float)
  u=np.clip((t-2.35-(ids/n)*.24)/1.02,0,1);u=u*u*(3-2*u);q=u[:,None]
  cp1=glyph+np.column_stack([120+80*np.sin(ids*.9),-155-45*np.cos(ids*.3)])
  cp2=edge+np.column_stack([np.full(n,65),-75+35*np.sin(ids*.25)])
  xy=(1-q)**3*glyph+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*edge
  alpha=np.where(group==0,1.,sm((t-2.35)/.32))*np.ones(n)
  size=10.7*(1-u)+3.1*u
  enter=np.clip((t-3.90-(ids/n)*.13)/.80,0,1);enter=enter*enter*(3-2*enter);q=enter[:,None]
  cursor_local=np.column_stack([np.full(n,79.),140+(ids%8)*3.])
  cursor=cv2.perspectiveTransform(cursor_local[None].astype(np.float32),matrix)[0].astype(float)
  cp1=xy+np.column_stack([-45*np.ones(n),70+20*np.cos(ids*.3)])
  cp2=cursor+np.column_stack([95+45*np.sin(ids*.2),np.full(n,-45)])
  xy=(1-q)**3*xy+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*cursor
  size=mix(size,np.full(n,1.65),enter)
  colour=mix(colour,np.tile([194,221,254.],(n,1)),enter[:,None])
  alpha*=1-sm((t-4.57)/.38)
 return xy,size,colour,alpha

def opening(t):
 c=BASE.copy()
 q=ease((t-2.35)/(LEAD_IN-2.35));reveal=sm((t-2.47)/1.1)
 # Gentle parallax gives the glass depth before the functional headline enters.
 plane(c,PROPS[0],400+85*(1-q),677+40*(1-q),650*(.72+.28*q),ry=12+8*(1-q),rz=-8-3*(1-q),a=.31*reveal,shadow=False)
 plane(c,PROPS[1],1545-90*(1-q),698+55*(1-q),660*(.72+.28*q),ry=-15-8*(1-q),rz=9+3*(1-q),a=.33*reveal,shadow=False)
 plane(c,OPEN_EMPTY,*opening_pose(t),a=reveal)
 brand=sm((t-.72)/.5)*(1-sm((t-2.32)/.47))
 text(c,'EchoTerm',960,577+8*(1-sm((t-.72)/.5)),37,INK,brand,False,True,True,tracking=1)
 xy,sizes,col,alpha=opening_pixels(t)
 for i,p in enumerate(xy):sq(c,*p,sizes[i],col[i],alpha[i],math.sin(i*.7)*.18*(1-sm((t-.35)/.65)))
 # Match the beginning of intro() exactly, including headline opacity.
 a=sm((t-LEAD_IN+.45)/.90)
 text(c,'EchoTerm · AI-native terminal',960,43,25,MUTED,a,center=True)
 text(c,'Commands. Questions. One prompt.',960,109,76,INK,a,True,True)
 text(c,'Just type. Echo knows what to do.',960,231,29,MUTED,a,center=True)
 return c

# Block organisation is the second point, after the unified input experience.
def block_pose(t):
 u=ease((t-8.35)/2.6)
 return (1000.,710.,float(mix(1250,1120,u)),float(mix(10,-7,u)),4.,float(mix(3,-2,u)))
def ai(c,t):
 plane(c,PROPS[0],560,716,650,ry=12,rz=-8,a=.5,shadow=False)
 plane(c,PROPS[1],1495,644,630,ry=-15,rz=9,a=.5,shadow=False)
 dest=plane(c,BLOCKS,*block_pose(t))
 a=sm((t-8.1)/.5)*(1-sm((t-10.15)/.7))
 over(c,PREFIX,PX,122,a)
 text(c,'Commands, answers and context. Clearly organized.',960,249,28,MUTED,a,center=True)
 if 9.6<=t<10.1:
  for xx,yy in GLYPH:sq(c,xx,yy,BLOCK_PIXEL_SIZE,BLUE)
 for yy,delay in [(173,0),(341,.22),(672,.44)]:
  q=sm((t-8.8-delay)/.42)
  if q>0:
   l=onplane(dest,(1170,768),(184,yy));r=onplane(dest,(1170,768),(1125,yy))
   dotline(c,[l,mix(l,r,q)],(194,223,255),.66,2)

# A single camera and a persistent cohort of square particles connect the search.
# World coordinates are shared by the windows, individual blocks and the flow.
FOCAL=1750.
JOURNEY_N=168
JI=np.arange(JOURNEY_N,dtype=np.float64)
JF=JI/(JOURNEY_N-1)

def spline(t,keys):
 times=np.array([k[0] for k in keys]);values=np.array([k[1] for k in keys],float)
 ts=np.asarray(t,float);idx=np.clip(np.searchsorted(times,ts,side='right')-1,0,len(times)-2)
 dt=times[idx+1]-times[idx];u=np.clip((ts-times[idx])/dt,0,1)
 slopes=np.zeros_like(values)
 slopes[1:-1]=(values[2:]-values[:-2])/(times[2:]-times[:-2])[:,None]
 u=u[...,None];dt=dt[...,None]
 return ((2*u**3-3*u**2+1)*values[idx]+(u**3-2*u**2+u)*dt*slopes[idx]
         +(-2*u**3+3*u**2)*values[idx+1]+(u**3-u**2)*dt*slopes[idx+1])

CAM_KEYS=[
 (10.8,[-570,0,90,1520,-5,-2,0]),(12.2,[-560,0,90,1560,-5,-2,0]),
 (13.7,[0,20,120,2130,7,-5,-2]),(15.1,[200,30,120,2120,-5,2,1.5]),
 (16.3,[460,75,10,1820,-10,-2,0]),(17.7,[620,10,-360,1580,3,-2,-1.5]),
 (19.1,[620,10,-360,1540,-3,0,0]),(20.4,[180,10,-40,2140,5,-4,1]),
 (21.8,[10,10,0,2270,-5,-3,0])]

def camera3(t):
 x,y,z,d,yaw,pitch,rollz=spline(t,CAM_KEYS)
 yaw,pitch,rollz=np.radians([yaw,pitch,rollz]);target=np.array([x,y,z])
 eye=target+d*np.array([math.sin(yaw)*math.cos(pitch),math.sin(pitch),-math.cos(yaw)*math.cos(pitch)])
 forward=target-eye;forward/=np.linalg.norm(forward)
 right=np.cross(forward,[0,-1,0]);right/=np.linalg.norm(right)
 down=np.cross(forward,right)
 r=right*math.cos(rollz)+down*math.sin(rollz)
 dwn=-right*math.sin(rollz)+down*math.cos(rollz)
 return eye,np.array([r,dwn,forward])

def project3(points,t):
 eye,basis=camera3(t);v=(np.asarray(points)-eye)@basis.T
 z=np.maximum(150,v[...,2]);return v[...,:2]*FOCAL/z[...,None]+[960,620],FOCAL/z

def corners3(center,width,height,ry=0,rz=0):
 pts=np.array([[-width/2,-height/2,0],[width/2,-height/2,0],[width/2,height/2,0],[-width/2,height/2,0]])
 a,b=np.radians([ry,rz]);rotY=np.array([[math.cos(a),0,math.sin(a)],[0,1,0],[-math.sin(a),0,math.cos(a)]])
 rotZ=np.array([[math.cos(b),-math.sin(b),0],[math.sin(b),math.cos(b),0],[0,0,1]])
 return pts@(rotZ@rotY).T+center

def plane3(c,im,center,width,t,ry=0,rz=0,alpha=1):
 ih,iw=im.shape[:2];corners=corners3(center,width,width*ih/iw,ry,rz);dest,_=project3(corners,t)
 if alpha<=.001:return dest
 x0=max(0,int(dest[:,0].min())-65);x1=min(W,int(dest[:,0].max())+65)
 y0=max(0,int(dest[:,1].min())-45);y1=min(H,int(dest[:,1].max())+75)
 if x1>x0 and y1>y0:
  sh=np.zeros(((y1-y0+1)//2,(x1-x0+1)//2),np.uint8)
  cv2.fillConvexPoly(sh,((dest-[x0,y0]+[0,17])/2).astype(np.int32),255)
  sh=cv2.GaussianBlur(sh,(0,0),13);sh=cv2.resize(sh,(x1-x0,y1-y0)).astype(np.float32)[:,:,None]*(.13*alpha/255)
  c[y0:y1,x0:x1]=np.uint8(c[y0:y1,x0:x1]*(1-sh)+np.array([64,90,125])*sh)
 x0=max(0,int(dest[:,0].min())-2);x1=min(W,int(dest[:,0].max())+2)
 y0=max(0,int(dest[:,1].min())-2);y1=min(H,int(dest[:,1].max())+2)
 if x1>x0 and y1>y0:
  mat=cv2.getPerspectiveTransform(np.float32([[0,0],[iw,0],[iw,ih],[0,ih]]),np.float32(dest-[x0,y0]))
  over(c,cv2.warpPerspective(im,mat,(x1-x0,y1-y0),flags=cv2.INTER_LINEAR),x0,y0,alpha)
 return dest

SRC_CENTER=np.array([-570,20,90.])
SRC_WIDTH=830.
SESSION_CENTER=np.array([650,10,280.])
SESSION_WIDTH=840.
BLOCK_CENTERS=[np.array([650,10+(yy/760-.5)*(840*760/980),245.]) for yy in [142,302,561.5]]
BLOCK_WIDTH=840*950/980

def source_avatar_world():
 return SRC_CENTER+np.array([(60/980-.5)*SRC_WIDTH,(332/640-.5)*SRC_WIDTH*640/980,-2])

def source_card(answer=False):
 im=cv2.resize(PLATE,(980,640)).astype(np.uint8)
 text(im,'S2  ·  Dev Notes',31,19,22,(230,240,253))
 cv2.line(im,(0,61),(979,61),(139,161,188),1)
 text(im,'01  /private/tmp/Aurora',31,85,17,(187,208,233),latin=True)
 text(im,'Find the server port setting',33,133,34,(248,250,255),bold=True)
 text(im,'in another session, and jump to it.',33,181,31,(248,250,255),bold=True)
 cv2.line(im,(0,263),(979,263),(139,161,188),1)
 fill(im,(0,264,3,295),(145,190,244))
 text(im,'ECHO',112,298,17,(185,210,240),latin=True,tracking=2)
 text(im,'Port 4317. Configuration found.' if answer else 'Searching your session history…',112,338,27,(248,250,255))
 text(im,'S1  /  Block 03' if answer else 'Reading existing context',112,410,23,(183,215,253),latin=True)
 cv2.line(im,(0,558),(979,558),(139,161,188),1)
 text(im,'›',28,582,33,(173,208,251),latin=True)
 return rounded(im,16)
FLOW_SOURCE=source_card();FLOW_ANSWER=source_card(True)

def session_shell():
 im=cv2.resize(PLATE,(980,760)).astype(np.uint8)
 text(im,'S1  ·  Aurora',30,18,23,(231,240,251),latin=True)
 text(im,'3 BLOCKS',804,24,16,(193,214,242),latin=True)
 cv2.line(im,(0,62),(979,62),(139,161,188),1)
 return rounded(im,16)
FLOW_SESSION=session_shell()

def selected_state(t):
 u=ease((t-15.7)/1.95)
 # This is always the same Block 03 plane, lifted from its real place in S1.
 return mix(BLOCK_CENTERS[2],[620,10,-360],u),float(mix(BLOCK_WIDTH,1070,u)),float(-5*math.sin(math.pi*u)),float(-2*math.sin(math.pi*u))

def selected_points(t,uv):
 center,width,ry,rz=selected_state(t)
 xy=(np.asarray(uv)-[.5,.5])*[width,width*327/941]
 a,b=np.radians([ry,rz]);rotY=np.array([[math.cos(a),0,math.sin(a)],[0,1,0],[-math.sin(a),0,math.cos(a)]])
 rotZ=np.array([[math.cos(b),-math.sin(b),0],[math.sin(b),math.cos(b),0],[0,0,1]])
 return np.column_stack([xy,np.full(len(xy),-3)])@(rotZ@rotY).T+center

def border_uv(t):
 # Rounded rectangular perimeter, with particles circulating instead of flashing.
 phase=(JF+(presentation_time(t)-presentation_time(17.15))*.055)%1
 path=np.array([[.018,.005],[.982,.005],[1.005,.045],[1.005,.955],[.982,.995],[.018,.995],[-.005,.955],[-.005,.045],[.018,.005]])
 dist=np.r_[0,np.cumsum(np.linalg.norm(np.diff(path,axis=0)*[941,327],axis=1))];dist/=dist[-1]
 ix=np.minimum(len(path)-2,np.searchsorted(dist,phase,side='right')-1)
 q=((phase-dist[ix])/(dist[ix+1]-dist[ix]))[:,None]
 return mix(path[ix],path[ix+1],q)

ROUTE=[(12.45,[-934,31,88]),(13.25,[-450,-42,-140]),(14.0,[300,-190,-160]),
       (14.5,[1124,-217,210]),(15.02,[1135,-55,200]),(15.55,[1110,170,165]),
       (16.05,[1010,214,-15]),(16.75,[920,190,-310])]
BACK_ROUTE=[(18.65,[620,10,-365]),(19.2,[300,350,-400]),(19.85,[-480,370,-230]),
            (20.45,[-900,145,30]),(20.8,source_avatar_world().tolist())]

def ribbon_world(t,returning=False):
 local=t-JF*.64
 center=spline(local,BACK_ROUTE if returning else ROUTE)
 # Three coherent filaments, bounded to the route's normal section.
 phase=JF*math.pi*3.2+(JI%3)*math.pi*2/3+(t-12.45)*1.8
 spread=np.sin(np.pi*JF)**.6
 center+=np.column_stack([np.sin(phase)*5,np.cos(phase)*11,np.sin(phase+.8)*17])*spread[:,None]
 return center

def repeat_points(points):
 return np.asarray(points)[np.floor(JF*(len(points)-1)).astype(int)]

def face_world(t):
 pp=pixels(t);pp=pp[pp[:,0]<196];pp=repeat_points(pp)
 size=66.;origin=source_avatar_world()
 pts=np.column_stack([(pp[:,1]-6.5)*size/14,(pp[:,2]-6.5)*size/14,np.zeros(JOURNEY_N)])+origin
 return pts,pp[:,3:6]*255

def focused_particles(t):
 uv=border_uv(t)
 active=(JI.astype(int)%4)==0
 q=sm((t-17.85)/.72)
 underline=np.column_stack([.038+JF*.128,np.full(JOURNEY_N,.437)])
 uv[active]=mix(uv[active],underline[active],q)
 return selected_points(t,uv)

def journey_state(t):
 # Screen-space transitions share their exact endpoints with the 3D journey.
 if t<11.7:
  start=repeat_points(GLYPH);dst,col=face_world(11.7);end,_=project3(dst,11.7)
  u=np.clip((t-10.1-JF*.20)/1.40,0,1);u=u*u*(3-2*u);q=u[:,None]
  cp1=np.column_stack([np.full(JOURNEY_N,1660),180+JF*36])
  cp2=np.column_stack([np.full(JOURNEY_N,1320),535+JF*18])
  xy=(1-q)**3*start+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*end
  recolor=np.clip((u-.6)/.4,0,1)[:,None]
  # Only one particle draws each cell at rest. Additional trail particles
  # emerge during departure, avoiding heavier edges from duplicate overdraw.
  index=np.floor(JF*(len(GLYPH)-1)).astype(int)
  primary=np.r_[True,np.diff(index)!=0]
  opacity=np.where(primary,1.,sm((t-10.1)/.35))
  size=BLOCK_PIXEL_SIZE+(5.1-BLOCK_PIXEL_SIZE)*u
  return xy,size,mix(np.tile(BLUE,(JOURNEY_N,1)),col,recolor),opacity

 if t<20.65:
  face,col=face_world(t)
  if t<12.45:
   world=face;colour=col;size=np.full(JOURNEY_N,4.4)
  elif t<16.2:
   u=ease((t-12.45)/.9);world=mix(face,ribbon_world(t),u)
   colour=mix(col,np.tile(BLUE,(JOURNEY_N,1)),u);size=mix(np.full(JOURNEY_N,4.4),3.8+1.7*np.sin(JF*math.pi)**2,u)
  elif t<17.15:
   u=np.clip((t-16.2-JF*.30)/.65,0,1);u=u*u*(3-2*u);q=u[:,None]
   start=ribbon_world(16.2);end=focused_particles(t)
   cp1=start+[0,-65,-160];cp2=end+[0,-60,-85]
   world=(1-q)**3*start+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*end
   colour=np.tile(BLUE,(JOURNEY_N,1));size=mix(3.8+1.7*np.sin(JF*math.pi)**2,np.full(JOURNEY_N,5.0),u)
  elif t<18.65:
   world=focused_particles(t);colour=np.tile(BLUE,(JOURNEY_N,1));size=np.full(JOURNEY_N,5.0)
  else:
   u=np.clip((t-18.65-JF*.40)/.72,0,1);u=u*u*(3-2*u);q=u[:,None]
   start=focused_particles(18.65);end=ribbon_world(t,True)
   cp1=start+[0,90,-110];cp2=end+[0,-70,-80]
   world=(1-q)**3*start+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*end
   reform=ease((t-19.85)/.80);world=mix(world,face,reform)
   colour=mix(np.tile(BLUE,(JOURNEY_N,1)),col,reform);size=np.full(JOURNEY_N,5.0-.6*reform)
  xy,scale=project3(world,t)
  return xy,size*scale,colour,np.ones(JOURNEY_N)
 # Stay a flowing ribbon throughout the theme scene, including both joins.
 return theme_journey(t)


def draw_journey(c,t):
 if not 10.1<=t<27.3:return
 xy,sizes,col,alpha=journey_state(t)
 # Bloom lives underneath the crisp squares, not on the text or window surfaces.
 if 12.6<t<20.3:
  glow=np.zeros((H//4,W//4,3),np.uint8)
  for i,p in enumerate(xy):
   if i%2==0 and 0<=p[0]<W and 0<=p[1]<H:cv2.circle(glow,tuple(np.int32(p/4)),2,(30,70,125),-1,cv2.LINE_AA)
  glow=cv2.GaussianBlur(glow,(0,0),2.5);glow=cv2.resize(glow,(W,H)).astype(np.float32)
  c[:]=np.uint8(np.clip(c.astype(float)+glow*.19,0,255))
 rotation=.10*(sm((t-10.1)/.30) if t<11.7 else 1)
 for i,p in enumerate(xy):
  sq(c,*p,sizes[i],col[i],alpha[i],math.sin((presentation_time(t)-LEAD_IN)*1.5+i*.13)*rotation)

def cross(c,t):
 answer=sm((t-19.75)/.55)
 source=np.uint8(mix(FLOW_SOURCE.astype(float),FLOW_ANSWER.astype(float),answer)) if answer>0 else FLOW_SOURCE
 source_a=1-.74*sm((t-16.2)/1.1)*(1-sm((t-19.3)/.9))
 selected=selected_state(t)
 background_alpha=1-.52*sm((t-16.2)/1.1)*(1-sm((t-19.3)/.9))
 planes=[(FLOW_SESSION,SESSION_CENTER,SESSION_WIDTH,0,0,background_alpha),
         (source,SRC_CENTER,SRC_WIDTH,0,0,source_a),
         (B1,BLOCK_CENTERS[0],BLOCK_WIDTH,0,0,background_alpha),(B2,BLOCK_CENTERS[1],BLOCK_WIDTH,0,0,background_alpha),
         (B3,*selected,1)]
 eye,basis=camera3(t)
 planes.sort(key=lambda item:float((np.asarray(item[1])-eye)@basis[2]),reverse=True)
 for im,center,width,ry,rz,alpha in planes:plane3(c,im,center,width,t,ry,rz,alpha)
 # A moving packet examines the index; it never becomes a disconnected stepper.
 for i,center in enumerate(BLOCK_CENTERS):
  pt,_=project3(np.array([1130,center[1],275]),t)
  a=sm((t-13.2)/.55)*(1-sm((t-16.2)/.55))
  text(c,f'{i+1:02d}',pt[0]+17,pt[1]-12,20,BLUE if 14.05+i*.5<t<14.85+i*.5 else MUTED,a,latin=True)
  for j in range(4):sq(c,pt[0]+(j%2)*5-3,pt[1]+(j//2)*5-3,3.4,BLUE,a*.65)
 # Dissolve the headline between ideas without snapping its layout.
 initial=1-sm((t-15.8)/.25);found=sm((t-16.05)/.35)*(1-sm((t-19.55)/.25));finish=sm((t-19.8)/.35)
 text(c,'Every session. Within reach.',960,103,73,INK,initial,True,True)
 text(c,'Echo finds the context, wherever you left it.',960,222,28,MUTED,initial,center=True)
 text(c,'Across sessions. Straight to answers.',960,103,72,INK,found,True,True)
 text(c,'S1  ·  Block 03  ·  config/server.toml',960,222,26,MUTED,found,center=True,latin=True)
 text(c,'Your context stays connected.',960,103,73,INK,finish,True,True)
 text(c,'From this question to the right block in another session.',960,222,28,MUTED,finish,center=True)
 # Pin the locator to the lifted block, leaving the original output unobscured.
 if 17.3<t<19.5:
  p,_=project3(selected_points(t,[[.5,1.18]]),t)
  text(c,'Located · S1 / Block 03',p[0,0],p[0,1],22,BLUE,sm((t-17.3)/.4)*(1-sm((t-19.1)/.4)),center=True)

# The captured UI glyphs stay sharp while the optical layer changes beneath them.
# Theme colours follow EchoTerm's Mist / Iris / Amber palettes. This is motion
# design showing real appearance options, not a recording of a new settings UI.
GLASS_RAW=np.array(Image.open(ROOT/'assets/blocks-en.png').convert('RGB')).astype(np.float32)
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

def theme_poses(t):
 fan=ease((t-21.95)/1.10)
 return [glass_pose(t)]+[(960+side*float(mix(120,600,fan)),633,610,-side*13,5,side*7) for side in (-1,1)]

# A single closed ribbon weaves around all three planes. Positions follow their
# live perspective, while arc-length travel uses real presentation seconds.
# The route stays near glass edges and crosses behind the readable interiors.
THEME_ROUTE=[
 (1,.04,.24),(1,.13,-.025),(1,.59,-.05),(1,.99,.17),
 (0,.16,.82),(0,.49,1.015),(0,.87,.83),
 (2,.03,.22),(2,.30,-.03),(2,.80,-.035),(2,1.045,.22),
 (2,1.035,.68),(2,.73,1.01),(2,.30,1.015),
 (0,.84,.20),(0,.53,-.035),(0,.14,.19),
 (1,.98,.79),(1,.60,1.015),(1,.15,1.015),(1,-.035,.72),(1,-.025,.36)]
FLOW_TINTS=np.array([BLUE,(153,117,206),(200,147,76)],float)

def theme_orbit(t):
 geometry_t=min(t,25.05)
 poses=theme_poses(geometry_t);matrices=[]
 for pose in poses:
  dest=proj(*pose[:3],768,1170,*pose[3:])
  matrices.append(cv2.getPerspectiveTransform(np.float32([[0,0],[1,0],[1,1],[0,1]]),dest.astype(np.float32)))
 anchors=[];tints=[]
 for theme,u,v in THEME_ROUTE:
  anchors.append(cv2.perspectiveTransform(np.float32([[[u,v]]]),matrices[theme])[0,0])
  tints.append(FLOW_TINTS[theme])
 points=np.asarray(anchors,float);colours=np.asarray(tints,float);count=len(points)
 # Periodic Catmull-Rom, densely resampled by arc length for constant flow speed.
 segment=np.repeat(np.arange(count),32);u=np.tile(np.arange(32)/32,count)[:,None]
 def curve(values):
  a,b,c,d=values[(segment-1)%count],values[segment],values[(segment+1)%count],values[(segment+2)%count]
  return .5*((2*b)+(-a+c)*u+(2*a-5*b+4*c-d)*u*u+(-a+3*b-3*c+d)*u*u*u)
 dense=curve(points);densecol=curve(colours)
 dense=np.vstack([dense,dense[0]]);densecol=np.vstack([densecol,densecol[0]])
 lengths=np.r_[0,np.cumsum(np.linalg.norm(np.diff(dense,axis=0),axis=1))];lengths/=lengths[-1]
 clock=presentation_time(t)-presentation_time(21.70)
 phase=(.82*JF+.020*np.sin(6*np.pi*JF)+clock*.043)%1
 xy=np.column_stack([np.interp(phase,lengths,dense[:,i]) for i in range(2)])
 colour=np.column_stack([np.interp(phase,lengths,densecol[:,i]) for i in range(3)])
 # A narrow, breathing filament; no face or other interim glyph is formed.
 xy[:,1]+=np.sin(JI*.72+clock*2.1)*2.1
 packet=np.sin(3*np.pi*JF)**2
 sizes=3.0+2.8*packet**3
 alpha=.38+.62*packet
 for matrix in matrices:
  local=cv2.perspectiveTransform(xy[None].astype(np.float32),np.linalg.inv(matrix))[0]
  depth=np.minimum.reduce([local[:,0]-.02,.98-local[:,0],(local[:,1]-.04)*.8,(.96-local[:,1])*.8])
  veil=np.clip(depth/.065,0,1);veil=veil*veil*(3-2*veil)
  alpha*=1-.74*veil
 # Give the theme names a clean margin as the ribbon passes their edges.
 for cx,cy in [(poses[1][0],877),(poses[2][0],877),(960,938)]:
  outside=np.maximum(np.abs(xy[:,0]-cx)-65,np.abs(xy[:,1]-cy)-22)
  clear=np.clip(outside/13,0,1);alpha*=clear*clear*(3-2*clear)
 return xy,sizes,np.clip(colour,0,255),alpha

def theme_journey(t):
 orbit,size,tint,alpha=theme_orbit(t)
 if t<22.30:
  start,col=face_world(20.65);start,scale=project3(start,20.65)
  u=np.clip((t-20.65-JF*.30)/1.35,0,1);u=u*u*u*(10-15*u+6*u*u);q=u[:,None]
  cp1=start+np.column_stack([np.full(JOURNEY_N,130),np.full(JOURNEY_N,-260)])
  cp2=orbit+np.column_stack([np.full(JOURNEY_N,-60),-70-45*np.sin(JF*math.pi)])
  xy=(1-q)**3*start+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*orbit
  return xy,mix(4.4*scale,size,u)+np.sin(np.pi*u)*1.1,mix(col,tint,q),mix(np.ones(JOURNEY_N),alpha,u)
 if t<25.05:return orbit,size,tint,alpha
 # Continue straight from the moving ribbons into the end mark. The source
 # remains in motion throughout the release, retaining its incoming velocity.
 n=max(JOURNEY_N,len(EGLYPH));ids=np.arange(n);fi=ids/max(1,n-1)
 idx=ids%JOURNEY_N;end=EGLYPH[ids%len(EGLYPH)]
 u=np.clip((t-25.05-fi*.27)/(2.25-.27),0,1);u=u*u*u*(10-15*u+6*u*u);q=u[:,None]
 start=orbit[idx];cp1=start+np.column_stack([-80*np.ones(n),-110-55*np.sin(fi*math.pi)])
 cp2=end+np.column_stack([90+80*np.sin(fi*2*math.pi),-115-65*np.cos(fi*math.pi)])
 xy=(1-q)**3*start+3*(1-q)**2*q*cp1+3*(1-q)*q*q*cp2+q**3*end
 a=mix(alpha[idx],np.ones(n),u)
 if n>JOURNEY_N:a[ids>=JOURNEY_N]*=sm((t-25.05)/.35)
 if n>len(EGLYPH):a[ids>=len(EGLYPH)]*=1-sm((t-26.8)/.5)
 return xy,mix(size[idx],np.full(n,7.2),u),mix(tint[idx],np.tile(BLUE,(n,1)),q),a

def glass(c,t):
 enter=sm((t-21.7)/.5);fan=ease((t-21.95)/1.10)
 text(c,'Less interface. More focus.',960,103,80,INK,enter,True,True)
 text(c,'Adjust opacity and glass. Choose your colors.',960,224,29,MUTED,sm((t-21.85)/.6),center=True)
 # Quiet background windows give the glass something tangible to refract.
 plane(c,PROPS[0],480,640,620,ry=16,rx=5,rz=-9,a=.50)
 plane(c,PROPS[1],1470,665,600,ry=-13,rx=-3,rz=8,a=.50)
 density,material=appearance(t)
 poses=theme_poses(t)
 for theme,side in [(1,-1),(2,1)]:
  xx=poses[theme][0]
  dest=plane(c,glass_ui(theme,.30,material),*poses[theme],a=fan)
  # Theme names are outside the product and stay legible during the camera move.
  text(c,['','Iris','Amber'][theme],xx,858,24,tuple(int(v*.67) for v in THEME_RGB[theme]),fan,center=True)
 pose=poses[0]
 dest=plane(c,glass_ui(0,density,material),*pose)
 anchor=onplane(dest,(1170,768),(1065,19))
 text(c,'Mist Blue',960,919,24,BLUE,fan,center=True)
 # Value-free editorial controls explain adjustability, without inventing a
 # pixel-radius control: the application offers three named glass materials.
 controls=sm((t-22.30)/.5)
 layer=c.copy()
 text(layer,'Opacity',443,977,23,MUTED)
 fill(layer,(551,996,270,3),(201,212,227),1,1)
 knob=551+270*cl((density-.12)/.58)
 fill(layer,(551,996,knob-551,3),BLUE,1,1)
 cv2.circle(layer,(int(knob),997),8,(255,255,255),-1,cv2.LINE_AA)
 cv2.circle(layer,(int(knob),997),8,BLUE,2,cv2.LINE_AA)
 text(layer,'Glass',935,977,23,MUTED)
 fill(layer,(1048+material*108,973,99,48),(221,233,249),1,16)
 for i,label in enumerate(['Clear','Soft','Frosted']):
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
 text(c,'Commands and AI. In one flow.',960,663,39,MUTED,sm((t-27.0)/.65),center=True)
 text(c,'AI-native terminal. Made for macOS.',960,805,21,(140,155,173),sm((t-27.5)/.6),center=True)
 if t>27.65:bear(c,t,[960,328],94)

def travelling_pixels(c,t):
 draw_journey(c,t)
 # A separate optical layer escapes the glass and remains physically continuous
 # while the camera underneath rolls between the two scenes.
 if 7.85<=t<9.6:
  anchor=unified_anchor(7.85)
  pts,col=bearpoints(7.85,anchor,82)
  morph(c,pts,GLYPH,(t-7.85)/1.75,5.2,BLOCK_PIXEL_SIZE,250,col,BLUE,stagger=.23)

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

def frame(presentation):
 if presentation<LEAD_IN:return opening(presentation)
 t=source_time(presentation)
 idx=int(np.searchsorted(CUTS,t,side='right'))
 # Deliberate 90-degree whole-scene barrel rolls, near/far push at the midpoint.
 # For the final shot a longer pullback carries the last pixel into the name.
 for j,cut in enumerate(CUTS):
  dur=.92 if j!=2 else 1.10
  if cut-dur/2<=t<cut+dur/2:
   q=(t-cut+dur/2)/dur;u=ease(q);sign=[-1,1,-1,1][j]
   a=stage(j,t);b=stage(j+1,t)
   degrees=92 if j in [0,3] else 18
   outa=sign*degrees*u;ina=sign*(-degrees+degrees*u)
   push=.90 if j in [0,3] else .14
   scaleA=1+push*u;scaleB=1+push*(1-u)
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
  im=Image.fromarray(frame(presentation_time(t)));im.save(ROOT/f'previews/frame-{t:04.1f}.png');im.thumbnail((632,356))
  x=(i%3)*640;y=(i//3)*390;board.paste(im,(x,y+27));d.text((x+12,y+6),f'{presentation_time(t):.1f}s',fill=(30,50,70))
 board.save(ROOT/'previews/contact.jpg');print('Previews ready',flush=True)
def render_bytes(n):
 return frame(n/60).tobytes()
def render_worker():
 cv2.setNumThreads(1)
def render():
 path=ROOT/'output/EchoTerm-Promo-English-v10-46s.mp4'
 cmd=['ffmpeg','-hide_banner','-loglevel','warning','-y','-f','rawvideo','-vcodec','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r','60','-i','-','-i',str(ROOT/'source/soundtrack.wav'),'-map','0:v','-map','1:a','-c:v','libx264','-preset','fast','-crf','16','-pix_fmt','yuv420p','-c:a','aac','-b:a','256k','-ar','48000','-movflags','+faststart','-t',str(D),'-metadata','title=EchoTerm — Commands and AI. In one flow.','-metadata:s:v:0','language=eng','-metadata:s:a:0','language=zxx','-metadata','comment=Product film: real UI capture plates, Swift-native pixel animation, composited glass and explanatory session map. Scripted AI demo, original score.',str(path)]
 p=subprocess.Popen(cmd,stdin=subprocess.PIPE)
 from concurrent.futures import ProcessPoolExecutor
 from collections import deque
 import multiprocessing
 # Bound frame buffering to eight frames; independent frames remain deterministic.
 with ProcessPoolExecutor(max_workers=4,mp_context=multiprocessing.get_context('spawn'),initializer=render_worker) as pool:
  pending=deque(pool.submit(render_bytes,n) for n in range(8));next_frame=8
  for n in range(FRAME_COUNT):
   p.stdin.write(pending.popleft().result())
   if next_frame<FRAME_COUNT:pending.append(pool.submit(render_bytes,next_frame));next_frame+=1
   if n%120==0:print(f'Rendered {n/60:.0f}/{D:g} s',flush=True)
 p.stdin.close();assert p.wait()==0
 print(path,flush=True)
if __name__=='__main__':
 if '--render' in sys.argv:render()
 elif '--frame' in sys.argv:
  t=float(sys.argv[-1]);Image.fromarray(frame(t)).save(ROOT/'previews/check.png')
 else:previews()
