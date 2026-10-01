"""核对指定进程的重放幅度，不把 Tap 读数解释为硬件最终混音。"""
import json
from pathlib import Path
import statistics
import sys

folder = Path(sys.argv[1] if len(sys.argv) > 1 else 'local/SelectiveOutputProbe')
events = [json.loads(line) for line in (folder / 'relay.jsonl').read_text().splitlines()]
assert [row['event'] for row in events] == ['ready', 'finished']
ready, finished = events
assert finished['result'] == 0 and finished['callbacks'] > 0 and finished['invalidBuffers'] == 0
assert ready['outputBefore'] == finished['outputAfter']
log = (folder / 'spectrum-app.stderr').read_text()
assert f"METER_READY pid={ready['pid']} " in log and 'METER_FINISHED result=0' in log
rows = [json.loads(line) for line in (folder / 'spectrum-app.jsonl').read_text().splitlines()][1:-1]
assert len(rows) >= 15 and all(row['invalidBuffers'] == 0 for row in rows)
assert all(ready['time'] < row['time'] < finished['time'] for row in rows)
assert all(a['window'] + 1 == b['window'] and a['time'] < b['time'] for a, b in zip(rows, rows[1:]))
gain = statistics.median(row['b660'] for row in rows) / .002
assert abs(gain - ready['gain']) < .005
assert all(abs(row['b660'] / .002 - ready['gain']) < .005 and row['a440'] < .000002 for row in rows)
print(json.dumps({'result': '重放幅度通过；硬件原声抑制与异常恢复尚待验证',
                  'windows': len(rows), 'gain': gain, 'systemOutputUnchanged': True}, ensure_ascii=False))
