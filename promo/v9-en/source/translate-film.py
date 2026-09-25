from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
p=ROOT/'source/render-film.py';s=(ROOT.parent/'v8/source/render-film.py').read_text()
translations={
 '每条命令，自成一':'Every command. Its own ',
 'S2  ·  开发笔记':'S2  ·  Dev Notes',
 '找一下另一个会话里':'Find the server port setting',
 '服务端口的配置，并跳过去。':'in another session, and jump to it.',
 '从已有会话开始查找':'Searching existing sessions',
 '这些测试结果说明了什么？':'What do these test results mean?',
 '4 项测试全部通过。':'All 4 tests passed.',
 '健康检查、版本号、路由和端口配置均符合预期。':'Health checks, routes, version and port configuration look good.',
 '下一步可以验证 /health 接口，继续检查实际服务。':'Next, try /health to check the running service.',
 '自动识别':'Auto Detect',
 'EchoTerm · AI Native 终端':'EchoTerm · AI-native terminal',
 '命令与问答，一个入口。':'Commands. Questions. One prompt.',
 '自动识别，无需切换。命令与 AI 无感衔接。':'Just type. Echo knows what to do.',
 '命令、回答、上下文，都清晰有序。':'Commands, answers and context. Clearly organized.',
 '端口为 4317，已定位到配置。':'Port 4317. Configuration found.',
 '正在查找会话中的相关记录…':'Searching your session history…',
 '读取已有上下文':'Reading existing context',
 '不用记住，在哪个会话。':'Every session. Within reach.',
 'Echo 沿着上下文，找到你要的信息。':'Echo finds the context, wherever you left it.',
 '跨会话，直达答案。':'Across sessions. Straight to answers.',
 '上下文，始终连在一起。':'Your context stays connected.',
 '从当前问题，直达另一个会话里的答案。':'From this question to the right block in another session.',
 '已定位  S1 / Block 03':'Located · S1 / Block 03',
 '轻到，只留下专注。':'Less interface. More focus.',
 '透明度与毛玻璃可调，多款主题可选。':'Adjust opacity and glass. Choose your colors.',
 '鸢尾':'Iris','琥珀':'Amber','雾蓝':'Mist Blue',
 '透明度':'Opacity','毛玻璃':'Glass','通透':'Clear','柔和':'Soft','磨砂':'Frosted',
 '命令与 AI，无感衔接。':'Commands and AI. In one flow.',
 'AI Native 终端 · 为 macOS 而设计':'AI-native terminal. Made for macOS.',
 '完成':'Complete','回答中':'Replying','思考中':'Thinking','已收到':'Received',
 '问答':'Chat',
}
# Long phrases first, so small UI labels never modify a headline prematurely.
for a,b in sorted(translations.items(),key=lambda kv:-len(kv[0])):s=s.replace(a,b)
s=s.replace('import sys, math, json, hashlib, subprocess, functools','import sys, math, json, hashlib, subprocess, functools, os')
s=s.replace('def tx(s,size=50,color=INK,bold=False,latin=False,tracking=0):','def tx(s,size=50,color=INK,bold=False,latin=True,tracking=0):')
s=s.replace('center=False,latin=False,tracking=0):','center=False,latin=True,tracking=0):')
s=s.replace("if not p.exists():\n  subprocess.run", "if not p.exists():\n  pending=p.with_name(p.stem+f'.{os.getpid()}.tmp.png')\n  subprocess.run",1)
s=s.replace('str(tracking),str(p)],check=True)','str(tracking),str(pending)],check=True)\n  pending.replace(p)',1)
s=s.replace("path=OLD/name;raw=np.array(Image.open(path).convert('RGB')).astype(np.float32)","path=ROOT/'assets/blocks-en.png' if name=='stills/blocks.jpg' else OLD/name\n raw=np.array(Image.open(path).convert('RGB')).astype(np.float32)")
s=s.replace("GLASS_RAW=np.array(Image.open(OLD/'stills/blocks.jpg')", "GLASS_RAW=np.array(Image.open(ROOT/'assets/blocks-en.png')")
# Use SF for English copy, preserving the explicit monospaced terminal font.
s=s.replace("mask=tx(s,size,INK,True,s=='E')", "mask=tx(s,size,INK,True,True)")
s=s.replace("PREFIX=tx('Every command. Its own ',82,INK,True)\nPX=(W-PREFIX.shape[1]-108)/2\nGLYPH=glyph_points('块',98,PX+PREFIX.shape[1]-3,112,7)", "PREFIX=tx('Every command. Its own ',76,INK,True,True)\nBLOCK_WORD=tx('block.',76,INK,True,True)\nPX=(W-PREFIX.shape[1]-BLOCK_WORD.shape[1]+10)/2\nGLYPH=glyph_points('block.',76,PX+PREFIX.shape[1]-10,122,7)")
s=s.replace("'Commands. Questions. One prompt.',960,109,82", "'Commands. Questions. One prompt.',960,109,76")
s=s.replace("'Across sessions. Straight to answers.',960,103,78", "'Across sessions. Straight to answers.',960,103,72")
s=s.replace("'in another session, and jump to it.',33,175,33", "'in another session, and jump to it.',33,175,31")
s=s.replace("'in another session, and jump to it.',33,181,34", "'in another session, and jump to it.',33,181,31")
s=s.replace("np.abs(xy[:,0]-cx)-40", "np.abs(xy[:,0]-cx)-65")
s=s.replace('EchoTerm-Promo-v8-46s.mp4','EchoTerm-Promo-English-46s.mp4')
s=s.replace("'-metadata','title=EchoTerm — Commands and AI. In one flow.'", "'-metadata','title=EchoTerm — Commands and AI. In one flow.','-metadata:s:v:0','language=eng','-metadata:s:a:0','language=zxx'")
s=s.replace('latin=False):','latin=True):').replace('latin=False)','latin=True)').replace('latin=answer)','latin=True)')
p.write_text(s)
# Localize the optional subtitle track without altering its approved timing.
srt=(ROOT.parent/'v8/output/EchoTerm-Promo-v8-46s.srt').read_text()
srt=srt.replace('每条命令，自成一块。','Every command. Its own block.')
for a,b in sorted(translations.items(),key=lambda kv:-len(kv[0])):srt=srt.replace(a,b)
(ROOT/'output/EchoTerm-Promo-English-46s.srt').write_text(srt)
p=ROOT/'source/verify-film.py';s=(ROOT.parent/'v8/source/verify-film.py').read_text().replace('EchoTerm-Promo-v8-46s.mp4','EchoTerm-Promo-English-46s.mp4').replace('EchoTerm-Promo-v8-poster.png','EchoTerm-Promo-English-poster.png')
s=s.replace("'file':str(video)", "'file':str(video),'language':'English','localized_capture':'assets/blocks-en.png'")
p.write_text(s)
