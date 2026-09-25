#!/usr/bin/env python3
"""Local, credential-free SSE fixture for EchoTerm tests. Never executes commands itself."""
import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def event(self, payload):
        data = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
        encoded = ('data: ' + data + '\r\n\r\n').encode()
        # Split within UTF-8 characters as well as JSON tokens.
        for pos in range(0, len(encoded), 7):
            self.wfile.write(encoded[pos:pos + 7])
        self.wfile.flush()

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            system = body.get('instructions') or body.get('system') or next((m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'system'), '')
            if '快速意图分类器' in system or '终端会话命名器' in system:
                intent = json.dumps({'title': '检查终端环境'} if '终端会话命名器' in system else {'intents': [{'title': '解读命令输出', 'question': '帮我解释这条命令的输出和退出状态。'}, {'title': '检查当前环境', 'question': '根据这个命令，帮我检查当前环境是否符合预期。'}]}, ensure_ascii=False)
                if self.path.endswith('/responses'):
                    response = {'status': 'completed', 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': intent}]}]}
                elif self.path.endswith('/messages'):
                    response = {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': intent}]}
                else:
                    response = {'choices': [{'finish_reason': 'stop', 'message': {'role': 'assistant', 'content': intent}}]}
                response['usage'] = ({'prompt_tokens': 40, 'completion_tokens': 12} if self.path.endswith('/chat/completions') else {'input_tokens': 40, 'output_tokens': 12})
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(response, ensure_ascii=False).encode())
                return
            if body.get('model') == 'http-error':
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'{"error":"DO-NOT-ECHO-PRIVATE-PAYLOAD"}')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            text = '你好，这是本地流式测试。'
            if body.get('model') == 'ui-slow':
                self.wfile.flush()
                time.sleep(9)
            if body.get('model') == 'ui-block-tools':
                items = body.get('input', body.get('messages', []))
                results = [m for m in items if m.get('type') == 'function_call_output' or m.get('role') == 'tool']
                if self.path.endswith('/messages'):
                    results = [c for m in items for c in (m.get('content', []) if isinstance(m.get('content'), list) else []) if c.get('type') == 'tool_result']
                questions = ' '.join(m.get('content', '') for m in items if m.get('role') == 'user' and isinstance(m.get('content'), str))
                target = re.search(r'Session\s+(\d+).*?Block\s+(\d+)', questions, re.I | re.S)
                args = {'session_index': int(target[1]) if target else 1, 'block_index': int(target[2]) if target else 10}
                name = 'read_block' if not results else 'jump_to_block'
                if not results:
                    args.update(offset=0, limit=16000)
                call_id = 'block-call-' + str(len(results))
                final = len(results) >= 2
                text = '已定位目标区块。阅读位置会保留，回答不会把画面拉回底部。' if final else '正在查看区块。' if not results else '已读取记录，现在跳转到对应区块。'
                if self.path.endswith('/responses'):
                    self.event({'type': 'response.output_text.delta', 'delta': text})
                    output = [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text}]}]
                    if not final:
                        output.append({'type': 'function_call', 'call_id': call_id, 'name': name, 'arguments': json.dumps(args)})
                    self.event({'type': 'response.completed', 'response': {'status': 'completed', 'usage': {'input_tokens': 50, 'output_tokens': 15}, 'output': output}})
                elif self.path.endswith('/messages'):
                    self.event({'type': 'message_start', 'message': {'role': 'assistant', 'content': [], 'usage': {'input_tokens': 50, 'output_tokens': 0}}})
                    self.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
                    self.event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}})
                    self.event({'type': 'content_block_stop', 'index': 0})
                    if not final:
                        self.event({'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'tool_use', 'id': call_id, 'name': name, 'input': {}}})
                        self.event({'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(args)}})
                        self.event({'type': 'content_block_stop', 'index': 1})
                    self.event({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn' if final else 'tool_use'}, 'usage': {'output_tokens': 15}})
                    self.event({'type': 'message_stop'})
                else:
                    for offset in range(0, len(text), 3):
                        self.event({'choices': [{'delta': {'content': text[offset:offset+3]}}]})
                        time.sleep(.06)
                    if not final:
                        self.event({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': call_id, 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]}, 'finish_reason': 'tool_calls'}]})
                    else:
                        self.event({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
                    self.event({'choices': [], 'usage': {'prompt_tokens': 50, 'completion_tokens': 15}})
                    self.event('[DONE]')
                return
            if self.path.endswith('/responses'):
                self.event({'type': 'response.output_text.delta', 'delta': text})
                time.sleep(.2)
                self.event({'type': 'response.completed', 'response': {'status': 'completed', 'usage': {'input_tokens': 120, 'output_tokens': 30, 'input_tokens_details': {'cached_tokens': 40}, 'output_tokens_details': {'reasoning_tokens': 10}}, 'output': [{'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': text + '完成。'}]}]}})
            elif self.path.endswith('/messages'):
                self.event({'type': 'message_start', 'message': {'role': 'assistant', 'content': [], 'usage': {'input_tokens': 20, 'cache_read_input_tokens': 80, 'cache_creation_input_tokens': 20, 'output_tokens': 1}}})
                self.event({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
                self.event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}})
                time.sleep(.2)
                self.event({'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': '完成。'}})
                self.event({'type': 'content_block_stop', 'index': 0})
                self.event({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 30}})
                self.event({'type': 'message_stop'})
            elif self.path.endswith('/chat/completions'):
                messages = body.get('messages', [])
                results = [message for message in messages if message.get('role') == 'tool']
                if any(t.get('function', {}).get('name') == 'execute_command' for t in body.get('tools', [])) and len(results) < 2:
                    number = len(results) + 1
                    command = "printf 'EchoTerm local agent test\\n'" if number == 1 else "pwd; printf 'stream → command → result: OK\\n'"
                    args = json.dumps({'command': command, 'explanation': '验证终端自动执行与结果回传', 'risk': 'read'}, ensure_ascii=False)
                    self.event({'choices': [{'delta': {'content': f'第 {number} 步：检查当前终端。\n'}}]})
                    time.sleep(.3)
                    self.event({'choices': [{'delta': {'reasoning_content': 'opaque test fixture'}}]})
                    self.event({'choices': [{'delta': {'tool_calls': [{'index': 0, 'id': f'call-{number}', 'type': 'function', 'function': {'name': 'execute_command', 'arguments': args[:20]}}]}}]})
                    self.event({'choices': [{'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': args[20:]}}]}, 'finish_reason': 'tool_calls'}]})
                else:
                    full = ('本地测试完成。已执行两条真实命令，并读取了各自的输出和退出码。' if results else text + '完成。')
                    if body.get('model') == 'ui-markdown':
                        full = '## 当前目录检查\n\n**命令已正常完成。** `pwd` 会显示当前工作目录。\n\n- 检查项目文件\n- 查看 Git 状态\n\n```sh\ngit status --short\n```\n\n> 建议先确认当前目录，再继续操作。\n\n| 项目 | 状态 |\n| --- | --- |\n| Shell | 正常 |\n| 退出码 | 0 |'
                    for offset in range(0, len(full), 3):
                        self.event({'choices': [{'delta': {'content': full[offset:offset+3]}}]})
                        time.sleep(.5 if body.get('model') == 'ui-slow' else .09)
                    if body.get('model') == 'truncated':
                        return
                    self.event({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
                if body.get('stream_options', {}).get('include_usage'):
                    self.event({'choices': [], 'usage': {'prompt_tokens': 120, 'completion_tokens': 30, 'prompt_tokens_details': {'cached_tokens': 40}, 'completion_tokens_details': {'reasoning_tokens': 10}}})
                self.event('[DONE]')
        except (BrokenPipeError, ConnectionResetError):
            pass

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port-file', required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()
