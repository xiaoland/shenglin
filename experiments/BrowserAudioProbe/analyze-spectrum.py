"""用独立 Process Tap 幅度验证逐页增益；不以扩展自身的 RMS 作为通过依据。"""
import json
from pathlib import Path
import re
import statistics
import sys

folder = Path(sys.argv[1] if len(sys.argv) > 1 else 'local/BrowserAudioProbe')
rows = [json.loads(line) for line in (folder / 'spectrum-app.jsonl').read_text().splitlines()]
markers = [json.loads(line) for line in (folder / 'spectrum-markers.jsonl').read_text().splitlines()]
assert [m['stage'] for m in markers] == ['B20', 'B100', 'B20-again', 'released', 'stopped']
assert all(a['time'] < b['time'] for a, b in zip(markers, markers[1:]))
assert rows and all(r['invalidBuffers'] == 0 for r in rows)
assert all(a['window'] + 1 == b['window'] and a['time'] < b['time'] for a, b in zip(rows, rows[1:]))
log = (folder / 'spectrum-app.stderr').read_text()
assert 'METER_FINISHED result=0' in log, '测量器没有正常完成'
target = re.search(r'METER_READY pid=(\d+) object=(\d+) sampleRate=48000', log)
assert target, '缺少有效测量器目标'
pid, obj = map(int, target.groups())
hal = [json.loads(line) for line in (folder / 'spectrum-baseline.hal.jsonl').read_text().splitlines()]
assert len(hal) == 8
for observation in hal:
    browser = [(p['pid'], p['object']) for p in observation['processes']
               if p['bundle'] == 'net.imput.helium' and p['output'] == 1]
    assert browser == [(pid, obj)], '测量对象与实际浏览器输出不一致'

boundaries = [{'stage': 'baseline', 'time': rows[0]['time']}] + markers
expected_b = {'baseline': 1, 'B20': .2, 'B100': 1, 'B20-again': .2, 'released': 1}
results = []
baseline = None
for current, following in zip(boundaries, boundaries[1:]):
    # 每次操作后留两秒稳定时间，排除按钮操作和半秒窗口跨越边界的样本。
    selected = [r for r in rows if current['time'] + 2 <= r['time'] < following['time'] - 2]
    assert len(selected) >= 8, f"{current['stage']}: 稳定样本不足"
    amplitudes = {key: statistics.median(r[key] for r in selected) for key in ['a440', 'b660']}
    if baseline is None:
        baseline = amplitudes
        assert all(abs(value / .002 - 1) < .02 for value in baseline.values()), '合成音基线不符'
    ratios = {key: amplitudes[key] / baseline[key] for key in baseline}
    for key, expected in [('a440', 1), ('b660', expected_b[current['stage']])]:
        assert abs(ratios[key] / expected - 1) < .02, f"{current['stage']}/{key}: 增益不符"
        assert all(abs(r[key] / (baseline[key] * expected) - 1) < .03 for r in selected), '稳定窗口存在输出异常'
    results.append({'stage': current['stage'], 'windows': len(selected),
                    'medianAmplitude': amplitudes, 'ratioToBaseline': ratios})
print(json.dumps({'result': '逐页衰减、恢复 100% 与解除接管通过进程输出验证',
                  'pid': pid, 'processObject': obj, 'stages': results}, ensure_ascii=False, indent=2))
