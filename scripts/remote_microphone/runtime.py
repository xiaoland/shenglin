"""实机验收共用的 HAL 客户端、证据和配置恢复。仅使用 Python 标准库。"""
import argparse
from array import array
from contextlib import contextmanager
from datetime import datetime
import json
import math
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import time
import uuid
import wave
from .recognition import require_model

ROOT = Path(__file__).resolve().parents[2]
PHRASE = '这是远程麦克风测试。一二三四五。今天的天气很好。现在测试录音能否完整传到电脑。'
RATE = 48000


def command(*args, timeout=45):
    return subprocess.check_output([str(a) for a in args], text=True, timeout=timeout)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def build_probe():
    source = ROOT / 'experiments/VirtualMicrophoneProbe.cpp'
    binary = ROOT / 'local/RemoteMicrophoneAutomation/Probe'
    binary.parent.mkdir(parents=True, exist_ok=True)
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O2', str(source),
                        '-framework', 'CoreAudio', '-framework', 'CoreFoundation',
                        '-framework', 'AudioUnit', '-o', str(binary)], check=True)
    return binary


def arguments(description):
    p = argparse.ArgumentParser(description=description)
    p.add_argument('--mount', required=True, help='已挂载远端输入的 bundle；见 shenglin microphone mounts')
    p.add_argument('--speaker-uid', required=True, help='实际能被远端收音的扬声器 UID；用录音命令的 --list-outputs 列举')
    p.add_argument('--cli', type=Path, default=ROOT / '.build/debug/shenglin')
    p.add_argument('--output', type=Path, help='新建证据目录；已有目录不会被覆盖')
    p.add_argument('--voice', default='Tingting')
    p.add_argument('--phrase', default=PHRASE)
    p.add_argument('--startup-wait', type=float, default=2, help='HAL启动返回后等几秒再讲话；0可检查冷启动丢字')
    p.add_argument('--asr-python', type=Path, help='安装了 requirements-asr.txt 的 Python；省略时只验收HAL')
    p.add_argument('--model', type=Path, help='已下载的 faster-whisper 模型目录；不自动下载模型')
    return p


class Reader:
    def __init__(self, run, name):
        self.run, self.name = run, name
        self.path = run.output / (name + '.f32')
        self.stages, self.closed = [], False
        self.errors = (run.output / (name + '.stderr')).open('w')
        self.process = subprocess.Popen([str(run.probe), 'record', run.uid, str(self.path), '300'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors, text=True, bufsize=1)
        run.readers.append(self)
        ready = self.line()
        require(ready.startswith('ready '), f'HAL启动失败：{ready}')
        self.started = time.monotonic()
        self.summary = {'name': name, 'ready': ready, 'epoch': time.time()}
        run.result['readers'].append(self.summary)

    def line(self):
        with selectors.DefaultSelector() as poll:
            poll.register(self.process.stdout, selectors.EVENT_READ)
            require(bool(poll.select(10)), 'HAL客户端十秒内未响应')
        line = self.process.stdout.readline().strip()
        require(bool(line), 'HAL客户端提前退出；见 stderr')
        return line

    def mark(self):
        self.process.stdin.write('mark\n'); self.process.stdin.flush()
        value = json.loads(self.line())
        require(value['errors'] == 0 and value['overflows'] == 0, f'HAL读取或容量错误：{value}')
        return value['frames']

    def stage(self, name, silent=False, seconds=3):
        item = {'name': name, 'reader': self.name, 'start': self.mark(), 'silent': silent}
        self.stages.append(item)
        self.run.result['stages'].append(item)
        started = time.monotonic()
        if silent:
            time.sleep(seconds)
        else:
            command('say', '-a', self.run.speaker, '-v', self.run.args.voice, self.run.args.phrase, timeout=60)
            time.sleep(1)
        item.update(end=self.mark(), wall_seconds=time.monotonic() - started)
        item['mac'] = self.run.mac('control', 'status')['status']
        self.run.save()
        print(f'已采集：{name}', flush=True)

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            if self.process.poll() is None:
                self.process.communicate('quit\n', timeout=15)
            else:
                self.process.wait()
        finally:
            if self.process.poll() is None:
                self.process.kill(); self.process.wait()
            self.errors.close()
        # Even an interrupted stage leaves its raw PCM and completed stage WAVs available.
        if self.path.exists():
            data = array('f'); data.frombytes(self.path.read_bytes())
            if sys.byteorder != 'little':
                data.byteswap()
            if data:
                self.summary['pcm'] = pcm_stats(data)
            for stage in self.stages:
                if 'end' not in stage:
                    continue
                samples = data[stage['start']:stage['end']]
                stats = pcm_stats(samples)
                stage.update(stats)
                stage['wav'] = str(self.run.output / (stage['name'] + '.wav'))
                pcm = array('h', (round(max(-1, min(1, x)) * 32767) for x in samples))
                if sys.byteorder != 'little':
                    pcm.byteswap()
                with wave.open(stage['wav'], 'wb') as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(RATE)
                    wav.writeframes(pcm.tobytes())
                require(len(samples) == stage['end'] - stage['start'], 'PCM容量不足，阶段音频被截断')
                require(abs(stats['seconds'] - stage['wall_seconds']) < max(.25, stage['wall_seconds'] * .1), 'HAL采样长度与墙钟不符')
                require(stats['exact_zero'] == stage['silent'], f"阶段静音结果不符：{stage['name']}")
        require(self.process.returncode == 0, f'HAL客户端失败：{self.process.returncode}；保留原始PCM')


def pcm_stats(samples):
    require(bool(samples), '录音为空')
    require(all(math.isfinite(x) and abs(x) <= 1 for x in samples), 'PCM包含无效或越界样本')
    first = next((i for i, x in enumerate(samples) if x != 0), None)
    return {'seconds': len(samples) / RATE, 'peak': max(abs(x) for x in samples),
            'exact_zero': first is None, 'first_nonzero_seconds': None if first is None else first / RATE,
            'clipped_fraction': sum(abs(x) >= 1 for x in samples) / len(samples)}


class Run:
    def __init__(self, args):
        require(0 <= args.startup_wait <= 30, '--startup-wait 必须在0至30秒之间')
        require(bool(args.asr_python) == bool(args.model), '--asr-python 与 --model 必须一起指定')
        if args.model:
            require_model(args.model)
            require(shutil.which(str(args.asr_python)) and shutil.which('ffmpeg'), '需要有效的ASR Python和FFmpeg')
        self.args = args
        self.output = (args.output or ROOT / 'local/RemoteMicrophoneAutomation' /
                       (datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:6])).resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.result = {'status': 'running', 'phrase': args.phrase, 'startup_wait': args.startup_wait,
                       'readers': [], 'stages': [], 'cleanup_errors': [], 'hal': 'not_run', 'asr': 'not_run'}
        self.readers = []
        self.mount = None
        self.save()

    def save(self):
        (self.output / 'results.json').write_text(json.dumps(self.result, ensure_ascii=False, indent=2))

    def mac(self, *args):
        response = json.loads(command(self.args.cli, *args))
        require(response.get('ok'), str(response))
        return response

    def prepare(self):
        if self.args.asr_python:
            command(self.args.asr_python, '-c', 'import numpy, faster_whisper, opencc')
        self.probe = build_probe()
        self.speaker = command(self.probe, 'device-id', self.args.speaker_uid).strip()
        mounts = self.mac('microphone', 'mounts')['mounts']
        self.mount = next((x for x in mounts if x['bundle'] == self.args.mount), None)
        require(self.mount and 'remoteSource' in self.mount, '指定输入不是已有远端挂载')
        self.selector = 'bundle:' + self.args.mount
        self.uid = 'local.shenglin.virtual-microphone.' + self.args.mount
        state = self.mac('control', 'status')['status']
        source = next(x for x in state['sources'] if x['selector'] == self.selector)
        require(not source['muted'] and not source['microphoneInUse'] and state['inputCount'] == 0,
                '请先停止录音，并取消测试挂载的静音')
        self.original_gain = self.mount.get('gain', 1)
        self.current_gain = self.original_gain
        self.result.update(mount=self.mount, before=state)
        self.save()
        command('say', '-v', self.args.voice, '-o', self.output / 'reference.aiff', self.args.phrase, timeout=60)

    def gain(self, value):
        if self.current_gain != value:
            self.mac('microphone', 'gain', self.selector, str(value))
            self.current_gain = value

    def mute(self, value):
        self.mac('control', 'mute', 'add' if value else 'remove', self.selector)

    @contextmanager
    def reader(self, name):
        reader = Reader(self, name)
        try:
            yield reader
        finally:
            reader.close()

    def cleanup(self):
        actions = [r.close for r in self.readers]
        if hasattr(self, 'original_gain'):
            actions += [lambda: self.mute(False), self.restore_gain]
        for action in actions:
            try:
                action()
            except Exception as exc:
                self.result['cleanup_errors'].append(str(exc))
        if hasattr(self, 'original_gain'):
            try:
                time.sleep(1)
                state = self.mac('control', 'status')['status']
                self.result['after'] = state
                source = next(x for x in state['sources'] if x['selector'] == self.selector)
                require(not source['microphoneInUse'] and not source['muted'], '读取端结束后，挂载未释放或未取消静音')
                before = self.result['before']['captureDiagnostics']
                after = state['captureDiagnostics']
                require(all(after[key] <= before[key] for key in
                            ['busyDroppedFrames', 'conversionDroppedFrames', 'pushFailedFrames']),
                        '本轮新增转换、背压或推送失败，见前后诊断')
            except Exception as exc:
                self.result['cleanup_errors'].append(str(exc))
        self.save()

    def restore_gain(self):
        mounts = self.mac('microphone', 'mounts')['mounts']
        current = next(x for x in mounts if x['bundle'] == self.args.mount)
        if current.get('gain', 1) != self.original_gain:
            self.mac('microphone', 'gain', self.selector, str(self.original_gain))

    def recognize(self):
        if self.args.asr_python:
            wavs = [x['wav'] for x in self.result['stages'] if not x['silent']]
            command(self.args.asr_python, ROOT / 'scripts/recognize-remote-microphone.py',
                    '--model', self.args.model, '--expected', self.args.phrase,
                    '--output', self.output / 'recognition.json', self.output / 'reference.aiff',
                    *wavs, timeout=600)
            self.result['asr'] = 'passed'


def execute(args, body):
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f'收到信号{signum}')
    previous = signal.signal(signal.SIGTERM, interrupted)
    run = Run(args)
    try:
        run.prepare()
        run.result['hal'] = 'running'
        body(run)
        run.result.update(status='hal_passed', hal='passed')
    except (Exception, KeyboardInterrupt) as exc:
        run.result.update(status='failed', error=str(exc) or '用户中断')
        if run.result['hal'] == 'running':
            run.result['hal'] = 'failed'
    finally:
        run.cleanup()
    if run.result['status'] != 'failed' and not run.result['cleanup_errors']:
        try:
            run.recognize()
        except (Exception, KeyboardInterrupt) as exc:
            run.result.update(status='failed', asr='failed', error=str(exc))
    if run.result['cleanup_errors']:
        run.result['status'] = 'failed'
    run.save()
    signal.signal(signal.SIGTERM, previous)
    print(f"{run.result['status']}（HAL：{run.result['hal']}，ASR：{run.result['asr']}）：{run.output}", flush=True)
    return 1 if run.result['status'] == 'failed' else 0
