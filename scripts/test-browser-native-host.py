#!/usr/bin/env python3
"""Check the signed App's parser without opening audio, connecting IPC, or showing a window."""
from pathlib import Path
import base64
import hashlib
import json
import struct
import subprocess

root = Path(__file__).resolve().parents[1]
app = root / 'dist/Shenglin.app/Contents/MacOS/声邻'
manifest = json.loads((root / 'BrowserExtension/manifest.json').read_text())
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
