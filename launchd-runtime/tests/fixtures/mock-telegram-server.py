#!/usr/bin/env python3
# Mock Telegram API server.
# Usage: mock-telegram-server.py <port> <capture_file>
# Captures every POST request body to <capture_file> (one JSON record per line).
# Always responds with {"ok": true, "result": {"message_id": N}}.

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

if len(sys.argv) != 3:
    print("Usage: mock-telegram-server.py <port> <capture_file>", file=sys.stderr)
    sys.exit(2)

PORT = int(sys.argv[1])
CAPTURE_FILE = sys.argv[2]

message_id_counter = [1000]

# Telegram reports a rejected message — unknown chat, bot blocked by the user —
# as ok:false inside a 200, not as an HTTP error. Set MOCK_TG_NOT_OK to the
# description to make the mock answer that way instead of accepting.
NOT_OK = os.environ.get('MOCK_TG_NOT_OK', '')


class MockTelegramHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8', 'replace')

        with open(CAPTURE_FILE, 'a') as f:
            record = {
                'path': self.path,
                'body': body,
                'timestamp': time.time(),
            }
            f.write(json.dumps(record) + '\n')

        msg_id = message_id_counter[0]
        message_id_counter[0] += 1

        if NOT_OK:
            response = {'ok': False, 'error_code': 400, 'description': NOT_OK}
        else:
            response = {
                'ok': True,
                'result': {
                    'message_id': msg_id,
                    'date': int(time.time()),
                    'text': '...',
                },
            }
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))

    def do_GET(self):
        # Useful for liveness checks
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok": true, "mock": true}')

    def log_message(self, fmt, *args):
        pass  # silent


HTTPServer(('localhost', PORT), MockTelegramHandler).serve_forever()
