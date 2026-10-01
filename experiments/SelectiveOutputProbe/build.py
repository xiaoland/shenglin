"""只构建独立实验 App；不启动、不改变音量或系统权限。"""
import argparse
import math
import os
from pathlib import Path
import plistlib
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('pid',type=int)
parser.add_argument('seconds',type=int)
parser.add_argument('gain',type=float)
args=parser.parse_args()
if not 0<args.pid<2**31 or not 1<=args.seconds<=120 or not math.isfinite(args.gain) or not 0<=args.gain<=1:
    parser.error('要求有效正 PID、1..120 秒和 0..1 增益')
root=Path(__file__).resolve().parents[2]
app=root/'local/SelectiveOutputProbe/SelectiveOutputProbe.app'
binary=app/'Contents/MacOS/SelectiveOutputProbe'
if subprocess.run(['pgrep','-f',str(binary)],capture_output=True).returncode==0:
    raise SystemExit('请先结束运行中的实验 App')
binary.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-mmacosx-version-min=14.2',
    '-framework','AppKit','-framework','CoreAudio',str(Path(__file__).with_name('Relay.m')),'-o',str(binary)],check=True)
with (app/'Contents/Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleExecutable':binary.name,'CFBundleIdentifier':'local.shenglin.experimental.relay',
        'CFBundleName':'声邻输出实验','CFBundleDisplayName':'声邻输出实验','CFBundlePackageType':'APPL',
        'CFBundleVersion':'1','LSUIElement':True,'LSMinimumSystemVersion':'14.2',
        'NSAudioCaptureUsageDescription':'仅接管指定合成音源并重放，验证逐进程音量；不读取麦克风、不保存音频。',
        'ProbeTargetPID':args.pid,'ProbeDuration':args.seconds,'ProbeGain':args.gain},file)
subprocess.run(['codesign','--force','--sign',os.environ.get('SHENGLIN_SIGN_IDENTITY','Apple Development'),str(app)],check=True)
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
subprocess.run([str(binary),'--self-test'],check=True)
print(app)
