#!/usr/bin/env python3
"""录制已挂载的远端麦克风，支持增益对照、热调与空闲后重录。"""
import sys
import time
from remote_microphone.runtime import arguments, build_probe, command, execute, require


def main():
    if sys.argv[1:] == ['--list-outputs']:
        print(command(build_probe(), 'outputs'), end='')
        return 0
    parser = arguments(__doc__)
    parser.add_argument('--gains', help='用逗号分隔1,2,4,8；省略时保留当前增益')
    parser.add_argument('--live', action='store_true', help='保持同一个读取客户端，录音中切换增益')
    parser.add_argument('--idle-seconds', type=float, default=0, help='关闭读取客户端后等待，再新开一次录音')
    args = parser.parse_args()
    gains = [int(x) for x in args.gains.split(',')] if args.gains else None
    require(gains is None or (gains and len(set(gains)) == len(gains) and all(x in [1, 2, 4, 8] for x in gains)), '增益须为不重复的1/2/4/8')
    require(0 <= args.idle_seconds <= 3600, '空闲时间须在0至3600秒之间')

    def body(run):
        source = run.mount['remoteSource']
        inputs = run.mac('microphone', 'sources', source['peerID'])['microphones']
        require(any(x['id'] == source['sourceID'] for x in inputs), '请开启发送端共享并向Mac授权此输入')
        values = gains or [run.original_gain]
        if args.live:
            with run.reader('live') as reader:
                for gain in values:
                    run.gain(gain)
                    time.sleep(args.startup_wait)
                    reader.stage(f'gain-{gain}')
        else:
            for gain in values:
                run.gain(gain)
                with run.reader(f'gain-{gain}') as reader:
                    time.sleep(args.startup_wait)
                    reader.stage(f'gain-{gain}')
        if args.idle_seconds:
            time.sleep(args.idle_seconds)
            with run.reader('idle-reopen') as reader:
                time.sleep(args.startup_wait)
                reader.stage('idle-reopen')
    return execute(args, body)


if __name__ == '__main__':
    sys.exit(main())
