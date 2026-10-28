#!/usr/bin/env python3
"""通过实体设备检查后台语音、静音释放、前台恢复；锁屏为显式末尾案例。"""
import sys
import time
from remote_microphone.devices import Android, IPad
from remote_microphone.runtime import arguments, execute, require


def main():
    parser = arguments(__doc__)
    platform = parser.add_mutually_exclusive_group(required=True)
    platform.add_argument('--android-serial')
    platform.add_argument('--ipad-udid')
    parser.add_argument('--ipad-team', help='仅签名测试Runner，不安装或重签产品')
    parser.add_argument('--gain', type=int, choices=[1, 2, 4, 8])
    parser.add_argument('--idle-seconds', type=float, default=30)
    parser.add_argument('--lock', action='store_true', help='最后锁屏并录一段；可能需要手动解锁设备')
    args = parser.parse_args()
    require(not args.ipad_udid or args.ipad_team, 'iPad测试需要 --ipad-team')
    require(not (args.lock and args.android_serial), 'Android锁屏需人工解锁，使用普通后台回归；锁屏步骤请单独执行')
    require(0 <= args.idle_seconds <= 300, '空闲时间须在0至300秒之间')

    def body(run):
        device = Android(run, args.android_serial) if args.android_serial else IPad(run, args.ipad_udid, args.ipad_team)
        try:
            device.start()
            remote = run.mount['remoteSource']
            sources = run.mac('microphone', 'sources', remote['peerID'])['microphones']
            require(any(x['id'] == remote['sourceID'] for x in sources), '发送端没有向Mac授权这个输入')
            if args.gain is not None:
                run.gain(args.gain)
            with run.reader('lifecycle') as reader:
                time.sleep(args.startup_wait)
                reader.stage('foreground')
                device.background()
                reader.stage('background')
                run.mute(True); time.sleep(3)
                reader.stage('muted', silent=True)
                run.mute(False); time.sleep(15 if args.ipad_udid else 3)
                if args.ipad_udid:
                    reader.stage('background-waits-for-foreground', silent=True)
                    device.foreground(); time.sleep(args.startup_wait)
                reader.stage('resumed')
                if args.lock:
                    device.lock()
                    reader.stage('locked')
            if args.idle_seconds and not args.lock:
                time.sleep(args.idle_seconds)
                if args.ipad_udid:
                    device.foreground()
                with run.reader('idle-reopen') as reader:
                    time.sleep(args.startup_wait)
                    reader.stage('idle-reopen')
        finally:
            try:
                device.close()
            except Exception as exc:
                run.result['cleanup_errors'].append(str(exc))
    return execute(args, body)


if __name__ == '__main__':
    sys.exit(main())
