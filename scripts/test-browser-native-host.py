#!/usr/bin/env python3
"""Check the signed App's parser and isolated IPC recovery without audio or a window."""
from pathlib import Path
import base64
import hashlib
import json
import os
import select
import struct
import subprocess
import socket
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
app = root / 'dist/Shenglin.app/Contents/MacOS/声邻'
manifest = json.loads((root / 'BrowserExtension/.output/chrome-mv3/manifest.json').read_text())
digest = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
identity = ''.join(chr(ord('a') + int(c, 16)) for c in digest)
assert f'extensionID = "{identity}"' in (root / 'Mac/BrowserAdapter.swift').read_text()
origin = f'chrome-extension://{identity}/'
for arguments, payload, expected in [
    (['--browser-native-host', 'chrome-extension://wrong/'], b'', 2),
    (['--browser-native-host', origin], struct.pack('<I', 32769), 2),
    (['--browser-native-host', origin], b'\x01', 1),
    (['--browser-native-host', origin], struct.pack('<I', 2) + b'{}', 1),
    (['--browser-native-host', origin], b'', 0),
]:
    result = subprocess.run([str(app), *arguments], input=payload, capture_output=True, timeout=5)
    assert result.returncode == expected, (result.returncode, expected)
    assert not result.stdout, 'Invalid or absent requests must not emit a frame.'
print('通过：签名 App 的固定扩展身份、32 KiB、短帧、无效 JSON 与正常 EOF。')

# Compile the shipping bridge and IPC with only external model/store dependencies replaced.
# A temporary socket keeps the recovery check independent of the user's running App.
with tempfile.TemporaryDirectory(prefix='shenglin-native-') as temporary:
    directory = Path(temporary)
    source = directory / 'main.swift'
    source.write_text('''import Foundation
struct CaptureDiagnostics: Codable {}
enum PeerPlatform: String, Codable { case mac, ipad }
enum ExclusionStore {
    static let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHENGLIN_TEST_DIRECTORY"]!).appendingPathComponent("exclusions.json")
}
BrowserNativeHost.run()
''')
    host = directory / 'native-host'
    subprocess.run(['swiftc', str(root / 'Mac/BrowserAdapter.swift'),
                    str(root / 'Mac/ControlIPC.swift'), str(source), '-o', str(host)], check=True)
    environment = dict(os.environ, SHENGLIN_TEST_DIRECTORY=temporary)
    process = subprocess.Popen([str(host), origin], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment)
    process_connection = str(uuid.uuid4())
    payload = json.dumps({'connection': process_connection, 'pages': []}).encode()

    def send_snapshot():
        process.stdin.write(struct.pack('<I', len(payload)) + payload)
        process.stdin.flush()

    def read_reply():
        assert select.select([process.stdout], [], [], 5)[0], 'Native host must reply within five seconds.'
        prefix = process.stdout.read(4)
        assert len(prefix) == 4, 'Valid requests must receive a frame.'
        length, = struct.unpack('<I', prefix)
        assert 0 < length <= 32768
        return json.loads(process.stdout.read(length))

    server = socket.socket(socket.AF_UNIX)
    server.settimeout(5)
    try:
        send_snapshot()
        reply = read_reply()
        assert reply['ok'] is False and '从应用程序打开声邻' in reply['message'], reply
        assert reply.get('browser') is None
        assert process.poll() is None, 'Unavailable App must not terminate the native host.'

        server.bind(str(directory / 'control.sock'))
        server.listen(1)
        send_snapshot()
        client, _ = server.accept()
        with client:
            request = json.loads(client.makefile('rb').readline())
            assert request['command'] == 'browser.state' and request['browser']['pages'] == []
            assigned_connection = request['browser']['connection']
            assert assigned_connection != process_connection
            uuid.UUID(assigned_connection)
            client.sendall(json.dumps({'ok': True, 'browser': {'gain': 0.2, 'leaseSeconds': 5,
                                                              'message': '已连接'}}).encode() + b'\n')
        reply = read_reply()
        assert reply['ok'] is True and reply['browser']['gain'] == 0.2, reply

        send_snapshot()
        client, _ = server.accept()
        with client:
            request = json.loads(client.makefile('rb').readline())
            assert request['browser']['connection'] == assigned_connection
            client.sendall(json.dumps({'ok': False, 'message': '网页状态无效'}).encode() + b'\n')
        reply = read_reply()
        assert reply['ok'] is False and reply['message'] == '网页状态无效', reply
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert not process.stdout.read(), 'Native stdout must contain only protocol frames.'
    finally:
        server.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
print('通过：正式桥接与 IPC 在 App 未启动时返回操作提示、同一连接自动恢复、主机身份绑定与服务端错误保留。')
