"""Scripted local responses for the promotional demo; actual tools run in EchoTerm."""
import json,time,re
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
ROOT=Path(__file__).resolve().parent.parent
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def event(self,x):
  self.wfile.write(('data: '+(x if isinstance(x,str) else json.dumps(x,ensure_ascii=False))+'\n\n').encode());self.wfile.flush()
 def do_POST(self):
  try:
   b=json.loads(self.rfile.read(int(self.headers['Content-Length'])));messages=b.get('messages',[])
   system=next((m.get('content','') for m in messages if m.get('role')=='system'),'')
   q=next((m.get('content','') for m in reversed(messages) if m.get('role')=='user'),'')
   if '快速意图分类器' in system:
    result={'intents':[{'title':'解读结果','question':'这些测试结果说明了什么？'},{'title':'下一步','question':'接下来可以检查什么？'}]}
    self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps({'choices':[{'message':{'role':'assistant','content':json.dumps(result,ensure_ascii=False)},'finish_reason':'stop'}]}).encode());return
   if '终端会话命名器' in system:
    self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'choices':[{'message':{'content':'{"title":"Aurora"}'},'finish_reason':'stop'}]}).encode());return
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers();self.wfile.flush()
   # Only results after the latest user request belong to this tool loop.
   start=max([i for i,m in enumerate(messages) if m.get('role')=='user'] or [0])
   results=[m for m in messages[start:] if m.get('role')=='tool']
   nav='会话' in q or '端口' in q or '跳' in q
   call=None
   if nav:
    if len(results)==0:
     text='我先查看另一个会话中的服务配置。'
     call=('read_block',dict(session_index=1,block_index=3,offset=0,limit=16000))
    elif len(results)==1:
     payload=json.loads(results[-1]['content']);content=payload.get('content','')
     assert '4317' in content,content
     text='找到了，服务端口是 **4317**。现在带你回到那条命令。'
     call=('jump_to_block',dict(session_index=1,block_index=3))
    else:text='已定位到 **Session 1 · Block 03**。\n\n`config/server.toml` 中设置了 `port = 4317`。'
   else:text='**4 项测试全部通过。**\n\n健康检查、版本号、路由和端口配置均符合预期。\n\n下一步可以验证 `/health` 接口，继续检查实际服务。'
   time.sleep(1.8 if not results else .65)
   for i in range(0,len(text),2):
    self.event({'choices':[{'delta':{'content':text[i:i+2]}}]});time.sleep(.055)
   if call:
    name,args=call
    self.event({'choices':[{'delta':{'tool_calls':[{'index':0,'id':'film-'+str(len(results)),'type':'function','function':{'name':name,'arguments':json.dumps(args)}}]},'finish_reason':'tool_calls'}]})
   else:self.event({'choices':[{'delta':{},'finish_reason':'stop'}]})
   self.event('[DONE]')
   with (ROOT/'source/demo-audit.jsonl').open('a') as f:f.write(json.dumps(dict(question=q,tool=call,results=results),ensure_ascii=False)+'\n')
  except (BrokenPipeError,ConnectionResetError):pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
(ROOT/'source/demo-port.txt').write_text(str(server.server_port))
server.serve_forever()
