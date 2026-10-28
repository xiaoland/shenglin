#!/usr/bin/env python3
"""离线识别录音，同时检查整句与开头/结尾；失败返回非零并保存结果。"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from remote_microphone.recognition import assess, require_model
from remote_microphone.runtime import PHRASE, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('audio', nargs='+', type=Path, help='首个文件应为同一句TTS清晰参考，其余为真实录音')
    parser.add_argument('--model', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--expected', default=PHRASE)
    parser.add_argument('--max-cer', type=float, default=.30)
    parser.add_argument('--edge-max-cer', type=float, default=.5)
    args = parser.parse_args()
    require(not args.output.exists(), '识别报告已存在；请使用新路径')
    require(0 <= args.max_cer <= 1 and 0 <= args.edge_max_cer <= 1, '误字率门槛须在0至1之间')
    report = {'status': 'running', 'expected': args.expected, 'max_cer': args.max_cer,
              'edge_max_cer': args.edge_max_cer, 'model': str(args.model.resolve()), 'files': []}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        require_model(args.model)
        os.environ['HF_HUB_OFFLINE'] = '1'
        import numpy as np
        from faster_whisper import WhisperModel
        from opencc import OpenCC
        model = WhisperModel(str(args.model.resolve()), device='cpu', compute_type='int8',
                             cpu_threads=4, local_files_only=True)
        converter = OpenCC('t2s').convert
        for index, path in enumerate(args.audio):
            started = time.monotonic()
            # Decode with ffmpeg: PyAV 19 removed an option used by faster-whisper 1.2.1.
            raw = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path), '-ar', '16000',
                                           '-ac', '1', '-f', 'f32le', '-'], timeout=60)
            audio = np.frombuffer(raw, '<f4').copy()
            require(audio.size > 0 and np.isfinite(audio).all(), f'音频为空或无效：{path}')
            features = model.feature_extractor(audio)
            require(np.isfinite(features).all(), '识别器特征计算产生无效值')
            segments, info = model.transcribe(audio, language='zh', beam_size=5,
                                             vad_filter=False, condition_on_previous_text=False)
            segments = list(segments)
            text = ''.join(s.text for s in segments)
            item = {'file': str(path.resolve()), 'reference': index == 0, 'text': text,
                    'seconds': info.duration, 'elapsed': time.monotonic() - started,
                    'segments': [{'start': s.start, 'end': s.end, 'text': s.text} for s in segments],
                    **assess(args.expected, text, converter, args.max_cer, args.edge_max_cer)}
            report['files'].append(item)
            print(json.dumps(item, ensure_ascii=False), flush=True)
            if index == 0:
                require(item['passed'], '清晰参考也未通过，不能用该识别器判断远端丢音')
        report['status'] = 'passed' if all(x['passed'] for x in report['files']) else 'failed'
    except (Exception, KeyboardInterrupt) as exc:
        report.update(status='failed', error=str(exc) or '用户中断')
    finally:
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
