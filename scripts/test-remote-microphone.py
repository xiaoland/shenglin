#!/usr/bin/env python3
"""实测已挂载的 Windows→Mac 麦克风；会短暂静音、撤销授权及停启 Windows 服务。"""
import argparse
import base64
import json
from pathlib import Path
import selectors
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-host', required=True, help='可运行管理员 PowerShell 的 SSH 主机')
    parser.add_argument('--mount', required=True, help='microphone mounts 返回的 bundle')
    args = parser.parse_args()
    output = ROOT / 'local/RemoteMicrophoneTests'
    output.mkdir(parents=True, exist_ok=True)
    cli = ROOT / '.build/debug/shenglin'

    def mac(*arguments):
        value = json.loads(subprocess.check_output([str(cli), *arguments], text=True, timeout=25))
        assert value.get('ok'), value
        return value

    def win(code):
        source = "$ErrorActionPreference='Stop'\n$ProgressPreference='SilentlyContinue'\n$exe=\"$env:ProgramFiles\\Shenglin\\shenglin.exe\"\n$nssm=\"$env:ProgramFiles\\Shenglin\\nssm.exe\"\n" + code
        encoded = base64.b64encode(source.encode('utf-16le')).decode()
        return subprocess.check_output(['ssh', args.windows_host,
            'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + encoded], text=True, timeout=30).strip()

    def quote(text):
        return "'" + text.replace("'", "''") + "'"

    mount = next(item for item in mac('microphone', 'mounts')['mounts'] if item['bundle'] == args.mount)
    peer, source = (mount['remoteSource'][key] for key in ('peerID', 'sourceID'))
    selector = 'bundle:' + args.mount
    initial = json.loads(win('& $exe status'))
    assert initial['runtime']['running'] and initial['runtime']['current'], 'Windows 服务必须正常运行'
    assert not initial['runtime']['microphoneStreams'], '请先停止所有远端输入客户端'
    assert any(p['id'] == peer and source in p['sources'] for p in initial['peers']), '请先向 Mac 授权输入'
    state = next(item for item in mac('control', 'status')['status']['sources'] if item['selector'] == selector)
    assert not state['muted'] and not state['microphoneInUse'], '测试输入必须空闲且未静音'
    grant = f'{quote(peer)} {quote(source)}'
    binary = output / 'Probe'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', str(ROOT / 'experiments/VirtualMicrophoneProbe.cpp'),
        '-framework', 'CoreAudio', '-framework', 'CoreFoundation', '-framework', 'AudioUnit', '-o', str(binary)], check=True)
    stages = []
    with (output / 'reader.stderr').open('w') as errors:
        reader = subprocess.Popen([str(binary), 'read-mono', 'local.shenglin.virtual-microphone.' + args.mount],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)

        def line():
            with selectors.DefaultSelector() as poll:
                poll.register(reader.stdout, selectors.EVENT_READ)
                if not poll.select(8):
                    raise RuntimeError('HAL 读取端超时')
            value = reader.stdout.readline().strip()
            assert value, 'HAL 读取端已退出'
            return value

        def request(command):
            reader.stdin.write(command + '\n')
            reader.stdin.flush()
            return line()

        def measure(name, seconds=3, audible=True):
            request('stats')
            request('peak')
            time.sleep(seconds)
            stats = list(map(int, request('stats').split()))
            peak = float(request('peak'))
            runtime = json.loads(win('& $exe status'))['runtime']
            stages.append({'phase': name, 'stats': stats, 'peak': peak, 'windows': runtime})
            print(json.dumps({'phase': name, 'stats': stats, 'peak': peak}, ensure_ascii=False), flush=True)
            assert stats[0] >= seconds * 48000 * 0.8 and stats[2] == 0, (name, stats)
            assert peak > 0 if audible else peak == 0, (name, peak)
            if name == '服务停止':
                assert not runtime['running'] and not runtime['current'], (name, '服务仍在运行')
            else:
                assert runtime['running'] and runtime['current'], (name, '服务状态不新鲜')
                if not audible:
                    assert not runtime['microphoneStreams'], (name, 'Windows 仍在采集')

        try:
            print(line(), flush=True)
            time.sleep(6)
            measure('真实音频', 5)
            assert any(item['id'] == source for item in mac('microphone', 'sources', peer)['microphones'])
            mac('control', 'mute', 'add', selector)
            time.sleep(2)
            measure('静音', 2, False)
            mac('control', 'mute', 'remove', selector)
            time.sleep(2)
            measure('取消静音', 2)
            win(f'& $exe unshare {grant}\nif ($LASTEXITCODE) {{ throw "撤销失败" }}')
            time.sleep(3)
            measure('撤销授权', 2, False)
            win(f'& $exe share {grant}\nif ($LASTEXITCODE) {{ throw "授权失败" }}')
            time.sleep(7)
            measure('恢复授权')
            win('& $nssm stop Shenglin | Out-Null\nif ($LASTEXITCODE) { throw "停服失败" }')
            time.sleep(3)
            measure('服务停止', 2, False)
            win('& $nssm start Shenglin | Out-Null\nif ($LASTEXITCODE) { throw "启动失败" }')
            time.sleep(8)
            measure('服务恢复')
        finally:
            try:
                if reader.poll() is None:
                    reader.stdin.write('quit\n')
                    reader.stdin.flush()
                reader.wait(timeout=5)
            finally:
                if reader.poll() is None:
                    reader.kill()
                    reader.wait()
                (output / 'results.json').write_text(json.dumps(stages, ensure_ascii=False, indent=2))
                win(f'& $exe share {grant}\nif ($LASTEXITCODE) {{ throw "恢复授权失败" }}\nif ((Get-Service Shenglin).Status -ne "Running") {{ Start-Service Shenglin }}')
                mac('control', 'mute', 'remove', selector)
    time.sleep(3)
    final = json.loads(win('& $exe status'))
    assert not final['runtime']['microphoneStreams'] and final['runtime']['error'] is None, final
    (output / 'after-idle.json').write_text(json.dumps(final, ensure_ascii=False, indent=2))
    print('通过：真实 PCM、流中列表、静音、授权撤销/恢复、服务停启及空闲释放。')


if __name__ == '__main__':
    main()
