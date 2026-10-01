"""比较已确认实际播放的阶段；页面 running 本身不属于本脚本的验证范围。"""
import json
import sys
from pathlib import Path

folder = Path(sys.argv[1] if len(sys.argv) > 1 else "local/BrowserAudioProbe")
signatures = {}
for phase in ["visible-A-only", "visible-A-and-B", "visible-B-only", "visible-stopped"]:
    rows = [json.loads(line) for line in (folder / f"{phase}.jsonl").read_text().splitlines()]
    assert len(rows) == 8, f"{phase}: 采样不完整"
    observations = []
    for row in rows:
        endpoints = []
        devices = {d["object"]: d["outputStreams"] for d in row["devices"]}
        for process in row["processes"]:
            if process["bundle"] != "net.imput.helium" or process["output"] != 1:
                continue
            assert process["outputDevices"]["status"] == 0
            for device in process["outputDevices"]["values"]:
                assert devices[device]["status"] == 0
                for stream in devices[device]["values"]:
                    endpoints.append((process["object"], process["pid"], device, stream))
        observations.append(tuple(sorted(endpoints)))
    assert len(set(observations)) == 1, f"{phase}: 阶段内端点发生变化"
    signatures[phase] = observations[0]
assert signatures["visible-stopped"] == (), "停止后仍有浏览器输出，归属需进一步核实"
active = [signatures[p] for p in signatures if p != "visible-stopped"]
assert all(len(s) == 1 for s in active), "不是单一端点，需独立分析隔离性"
assert active[0] == active[1] == active[2], "阶段间端点不同，需继续验证各端点归属"
print(json.dumps({"result": "三个有效播放阶段共用当前 Process Tap 可选端点", "phases": signatures}, ensure_ascii=False, indent=2))
