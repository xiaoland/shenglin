#!/usr/bin/env python3
"""构建具有独立身份的系统音频测量 App；构建不启动、不授予系统权限。"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid', type=int, help='仅捕获指定的合成音源进程')
parser.add_argument('seconds', type=int, choices=range(1, 301), metavar='1..300')
args = parser.parse_args()
if not 0 < args.pid <= 2**31 - 1:
    parser.error('PID 必须是有效正整数')

root = Path(__file__).resolve().parents[2]
app = root / 'local/BrowserAudioProbe/SpectrumMeter.app'
executable = app / 'Contents/MacOS/SpectrumMeter'
if executable.exists() and subprocess.run(['pgrep', '-x', 'SpectrumMeter'], capture_output=True).returncode == 0:
    raise SystemExit('请先结束正在运行的测量器，再重新构建。')
executable.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-mmacosx-version-min=14.2',
                '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'CoreAudio',
                str(Path(__file__).with_name('SpectrumMeter.m')), '-o', str(executable)], check=True)
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleExecutable': 'SpectrumMeter',
                  'CFBundleIdentifier': 'local.shenglin.experimental.spectrummeter',
                  'CFBundleName': '声邻频谱实验', 'CFBundleDisplayName': '声邻频谱实验',
                  'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True,
                  'LSMinimumSystemVersion': '14.2',
                  'NSAudioCaptureUsageDescription': '测量指定实验进程的两路合成音幅度；不保存音频，不读取麦克风。',
                  'ProbeTargetPID': args.pid, 'ProbeDuration': args.seconds}, file)
subprocess.run(['codesign', '--force', '--sign', os.environ.get('SHENGLIN_SIGN_IDENTITY', 'Apple Development'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
subprocess.run([str(executable), '--self-test'], check=True)
print(app)
