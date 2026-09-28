#!/usr/bin/env python3
"""Inspect 声邻's local trace batches and optionally extract a WAV."""

import argparse
import array
import json
import struct
import sys
import wave
from pathlib import Path

BATCH = struct.Struct("<IIQII")
BLOCK = struct.Struct("<QQqIIIIII")


def blocks(folder, stream):
    paths = sorted(folder.glob(f"*-{stream}.bin"), key=lambda p: tuple(map(int, p.name.split("-")[:2])))
    for path in paths:
        with path.open("rb") as file:
            while header := file.read(BATCH.size):
                if len(header) != BATCH.size:
                    raise ValueError(f"{path}: truncated batch header")
                magic, version, lost, count, reserved = BATCH.unpack(header)
                if (magic, version, reserved) != (0x4E415452, 1, 0):
                    raise ValueError(f"{path}: unsupported trace batch")
                if count > 128:
                    raise ValueError(f"{path}: invalid block count")
                yield None, lost
                for _ in range(count):
                    raw = file.read(BLOCK.size)
                    if len(raw) != BLOCK.size:
                        raise ValueError(f"{path}: truncated block header")
                    sequence, host, sample, pid, client, rate, channels, frames, muted = BLOCK.unpack(raw)
                    limit = 2048 if stream == "hal-output" else 192000
                    if not (8000 <= rate <= 192000 and 1 <= channels <= 2 and 1 <= frames <= limit):
                        raise ValueError(f"{path}: invalid audio format")
                    samples = file.read(frames * channels * 4)
                    if len(samples) != frames * channels * 4:
                        raise ValueError(f"{path}: truncated samples")
                    yield (sequence, host, sample, pid, client, rate, channels, frames, muted), samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path, help="device/rolling or device/incidents/<time> directory")
    parser.add_argument("--stream", choices=("upstream", "hal-output"), default="hal-output")
    parser.add_argument("--pid", type=int, help="HAL client PID; omit to list all clients")
    parser.add_argument("--wav", type=Path, help="write selected stream as 16-bit WAV")
    args = parser.parse_args()
    if args.wav and args.stream == "hal-output" and args.pid is None:
        parser.error("--wav for hal-output requires --pid")
    summary = {}
    lost_total = 0
    format_ = None
    output = None
    try:
        for header, raw in blocks(args.folder, args.stream):
            if header is None:
                lost_total += raw
                continue
            sequence, host, sample, pid, client, rate, channels, frames, muted = header
            key = f"{pid}:{client}" if args.stream == "hal-output" else "upstream"
            item = summary.setdefault(key, {"blocks": 0, "frames": 0, "firstHostTime": host,
                                            "lastHostTime": host, "mutedBlocks": 0})
            item["blocks"] += 1
            item["frames"] += frames
            item["lastHostTime"] = host
            item["mutedBlocks"] += bool(muted)
            if args.wav and (args.stream == "upstream" or pid == args.pid):
                if format_ is None:
                    format_ = (rate, channels)
                    output = wave.open(str(args.wav), "wb")
                    output.setnchannels(channels)
                    output.setsampwidth(2)
                    output.setframerate(rate)
                elif format_ != (rate, channels):
                    raise ValueError("selected stream changes format; export each device format separately")
                floats = array.array("f")
                floats.frombytes(raw)
                pcm = array.array("h", (int(max(-1.0, min(1.0, value)) * 32767) for value in floats))
                output.writeframesraw(pcm.tobytes())
    finally:
        if output is not None:
            output.close()
    print(json.dumps({"traceLostBlocks": lost_total, "clients": summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        sys.exit(str(error))
