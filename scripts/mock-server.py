#!/usr/bin/env python3
"""Local, synthetic Memos v0.30 protocol fixture for manual UI checks. No real tokens/data."""
import argparse
import base64
import datetime
import json
import pathlib
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=18741)
parser.add_argument('--data', default='/tmp/memos-popup-fixture')
args = parser.parse_args()
root = pathlib.Path(args.data)
root.mkdir(parents=True, exist_ok=True)
state_file = root / 'state.json'
if state_file.exists():
    state = json.loads(state_file.read_text())
else:
    state = {'memos': {
        'memos/welcome': {'name': 'memos/welcome', 'creator': 'users/1', 'content': '# 留住一个好想法\n\n从菜单栏开始，写下今天的小发现。\n\n- 支持 **Markdown**\n- 粘贴图片\n- #日常 #灵感', 'visibility': 'PRIVATE', 'createTime': '2026-09-18T02:30:00Z', 'updateTime': '2026-09-18T02:30:00Z', 'attachments': []},
        'memos/second': {'name': 'memos/second', 'creator': 'users/1', 'content': '午后散步时，想到一个简单的点子：让记录像呼吸一样自然。 #生活', 'visibility': 'PUBLIC', 'createTime': '2026-09-17T07:10:00Z', 'updateTime': '2026-09-17T07:10:00Z', 'attachments': []},
    }, 'attachments': {}}

def persist():
    state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2))

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *values):
        pass

    def respond(self, status, value=None, binary=None):
        self.send_response(status)
        self.send_header('Content-Type', 'image/png' if binary is not None else 'application/json')
        self.end_headers()
        self.wfile.write(binary if binary is not None else json.dumps(value or {}).encode())

    def handle_request(self):
        parsed = urlparse(self.path)
        path = unquote(parsed.path).removeprefix('/api/v1/')
        query = parse_qs(parsed.query)
        if self.headers.get('Authorization') != 'Bearer test-token':
            return self.respond(401)
        payload = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or '{}')
        with (root / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'method': self.command, 'path': path, 'query': query, 'fields': list(payload)}) + '\n')
        fault = root / 'fail-next'
        if fault.exists() and self.command in ('POST', 'PATCH'):
            fault.unlink()
            return self.respond(503)
        if path == 'auth/me':
            return self.respond(200, {'user': {'name': 'users/1', 'username': 'local-test', 'displayName': '本地测试'}})
        if path == 'memos' and self.command == 'GET':
            assert 'creator == "users/1"' in query.get('filter', [''])[0]
            memos = list(state['memos'].values())
            match = re.search(r'content\.contains\(("(?:[^"\\]|\\.)*")\)', query.get('filter', [''])[0])
            if match:
                term = json.loads(match.group(1))
                memos = [m for m in memos if term in m['content']]
            memos.sort(key=lambda m: m['createTime'], reverse=True)
            return self.respond(200, {'memos': memos, 'nextPageToken': ''})
        if path == 'memos' and self.command == 'POST':
            assert payload['visibility'] == 'PRIVATE'
            name = 'memos/' + query['memoId'][0]
            if name in state['memos']:
                return self.respond(409)
            stamp = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
            memo = dict(payload, name=name, creator='users/1', createTime=stamp, updateTime=stamp)
            state['memos'][name] = memo
            persist()
            return self.respond(200, memo)
        if path.startswith('memos/') and path in state['memos']:
            memo = state['memos'][path]
            if self.command == 'PATCH':
                assert query['updateMask'] == ['content,attachments']
                assert 'visibility' not in payload
                memo.update(content=payload['content'], attachments=payload['attachments'])
                memo['updateTime'] = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
                persist()
            return self.respond(200, memo)
        if path == 'attachments' and self.command == 'POST':
            name = 'attachments/' + query['attachmentId'][0]
            if name in state['attachments']:
                return self.respond(409)
            state['attachments'][name] = dict(payload, name=name)
            persist()
            return self.respond(200, {k: v for k, v in state['attachments'][name].items() if k != 'content'})
        if path.startswith('attachments/') and path in state['attachments']:
            return self.respond(200, {k: v for k, v in state['attachments'][path].items() if k != 'content'})
        if path.startswith('/file/attachments/'):
            name = 'attachments/' + path.split('/')[3]
            if name in state['attachments']:
                return self.respond(200, binary=base64.b64decode(state['attachments'][name]['content']))
        return self.respond(404)

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request

persist()
print(f'Local test fixture: http://127.0.0.1:{args.port}', flush=True)
ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
