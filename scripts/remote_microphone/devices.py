"""只控制测试设备的原生UI；不操作Mac窗口、不改变配对或逐设备授权。"""
import json
from pathlib import Path
import re
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
from .runtime import ROOT, command, require


class Android:
    def __init__(self, run, serial):
        self.run, self.serial = run, serial
        self.original_sharing, self.original_activity = None, None

    def adb(self, *args):
        return command('adb', '-s', self.serial, *args)

    def state(self):
        text = self.adb('shell', 'dumpsys', 'activity', 'service', 'local.shenglin/.PeerService')
        require('microphoneEnabled=' in text, '请先在Android启动声邻服务')
        return {'sharing': 'microphoneEnabled=true' in text,
                'capturing': 'microphoneCapturing=true' in text, 'dump': text}

    def start(self):
        state = self.state()
        require(not state['capturing'], '手机已经在供音，不能接管现有录音')
        self.original_sharing = state['sharing']
        text = self.adb('shell', 'dumpsys', 'activity', 'activities')
        match = re.search(r'mResumedActivity:.*?\s([\w.]+/[\w.$]+)\s', text)
        self.original_activity = match[1] if match else None
        self.run.result['android_before'] = {**state, 'activity': self.original_activity,
                                              'model': self.adb('shell', 'getprop', 'ro.product.model').strip()}
        self.run.save()
        self.foreground()
        self.sharing(True)

    def foreground(self):
        self.adb('shell', 'am', 'start', '-n', 'local.shenglin/.MainActivity')

    def sharing(self, value):
        if self.state()['sharing'] == value:
            return
        self.adb('shell', 'uiautomator', 'dump', '/sdcard/shenglin-remote-mic-test.xml')
        xml = self.adb('exec-out', 'cat', '/sdcard/shenglin-remote-mic-test.xml')
        (self.run.output / 'android-ui.xml').write_text(xml)
        tree = ET.fromstring(xml)
        parents = {c: p for p in tree.iter() for c in p}
        for node in tree.iter('node'):
            if '共享内置麦克风' not in (node.get('text'), node.get('content-desc')):
                continue
            while node is not None and node.get('clickable') != 'true':
                node = parents.get(node)
            if node is None:
                continue
            require(node.get('package') == 'local.shenglin', '共享开关不属于声邻')
            x1, y1, x2, y2 = map(int, re.findall(r'\d+', node.get('bounds')))
            self.adb('shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2))
            time.sleep(.5)
            require(self.state()['sharing'] == value, '共享未切换，请在手机检查麦克风权限')
            return
        raise RuntimeError('没有找到共享内置麦克风开关')

    def background(self):
        self.adb('shell', 'input', 'keyevent', 'KEYCODE_HOME')
        text = self.adb('shell', 'dumpsys', 'activity', 'activities')
        resumed = [s for s in text.splitlines() if 'mResumedActivity' in s]
        require(resumed and all('local.shenglin/' not in s for s in resumed), '手机未进入后台')
        self.run.result['android_background'] = resumed

    def close(self):
        if self.original_sharing is not None:
            self.foreground()
            self.sharing(self.original_sharing)
            self.run.result['android_after'] = self.state()
            self.adb('shell', 'rm', '-f', '/sdcard/shenglin-remote-mic-test.xml')
            if self.original_activity:
                self.adb('shell', 'am', 'start', '-n', self.original_activity)


class IPad:
    runner_id = 'local.shenglin.remotemictests.xctrunner'

    def __init__(self, run, udid, team):
        self.run, self.udid, self.team = run, udid, team
        self.process, self.original_sharing = None, None
        self.log = run.output / 'ipad-ui.log'

    def dev(self, group, action, *args):
        # launch treats tokens after the bundle as app arguments, so device options must precede it.
        return command('xcrun', 'devicectl', 'device', group, action,
                       '--device', self.udid, '--timeout', '20', *args)

    def start(self):
        build = ROOT / 'local/RemoteMicrophoneAutomation/iPadUI.noindex'
        with (self.run.output / 'ipad-ui-build.log').open('w') as log:
            subprocess.run(['xcodebuild', 'build-for-testing', '-project',
                            str(ROOT / 'experiments/RemoteMicrophoneUI/RemoteMicUI.xcodeproj'),
                            '-scheme', 'RemoteMicUI', '-destination', f'platform=iOS,id={self.udid}',
                            '-derivedDataPath', str(build), '-allowProvisioningUpdates',
                            f'DEVELOPMENT_TEAM={self.team}'], stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=300)
        configurations = list((build / 'Build/Products').glob('RemoteMicUI_*.xctestrun'))
        require(bool(configurations), '没有生成iPad UI测试配置')
        configuration = max(configurations, key=lambda p: p.stat().st_mtime)
        self.handle = self.log.open('w')
        self.process = subprocess.Popen(['xcodebuild', 'test-without-building', '-xctestrun', str(configuration),
                                         '-destination', f'platform=iOS,id={self.udid}'],
                                        stdout=self.handle, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 120
        while 'REMOTE_MIC_UI_READY' not in self.log.read_text():
            require(self.process.poll() is None and time.monotonic() < deadline, 'iPad UI驱动未就绪；检查签名、解锁状态与ipad-ui.log')
            time.sleep(.5)
        self.original_state = self.send('status')['state']
        state = self.foreground()
        require('sharing' in state, '未找到iPad共享开关')
        require('正在共享内置麦克风' not in state.get('tree', ''), 'iPad已在供音，不能接管现有录音')
        self.original_sharing = state['sharing']
        self.run.result['ipad_before'] = state
        self.run.save()
        self.send('sharing', value='true')

    def send(self, action, **values):
        request = {'id': uuid.uuid4().hex, 'action': action, **values}
        path = self.run.output / 'ipad-command.json'
        path.write_text(json.dumps(request))
        self.dev('copy', 'to', '--domain-type', 'appDataContainer', '--domain-identifier', self.runner_id,
                 '--source', path, '--destination', 'Documents/command.json', '--quiet')
        deadline = time.monotonic() + 30
        while 'REMOTE_MIC_UI_DONE ' + request['id'] not in self.log.read_text():
            require(self.process.poll() is None and time.monotonic() < deadline, f'iPad命令失败或超时：{action}')
            time.sleep(.25)
        response = self.run.output / 'ipad-response.json'
        self.dev('copy', 'from', '--domain-type', 'appDataContainer', '--domain-identifier', self.runner_id,
                 '--source', 'Documents/result.json', '--destination', response, '--quiet')
        result = json.loads(response.read_text())
        require(result['id'] == request['id'] and 'error' not in result, f'iPad命令失败：{result}')
        self.run.result.setdefault('ipad_events', []).append(result)
        self.run.save()
        return result

    def foreground(self):
        result = self.send('activate')
        require(result['state'] == 4 and result['lockState'] == 0, '请解锁iPad并让声邻回到前台')
        return result

    def background(self):
        # XCTest.activate(Settings) did not background the app on the acceptance iPad.
        self.dev('process', 'launch', 'com.apple.Preferences')
        deadline = time.monotonic() + 10
        while True:
            result = self.send('status')
            if result['state'] in [2, 3] and result['lockState'] == 0:
                return
            require(time.monotonic() < deadline, 'iPad未进入后台')
            time.sleep(.25)

    def lock(self):
        self.send('lock')
        time.sleep(2)
        require(self.send('status')['lockState'] == 1, '无法确认iPad锁屏')

    def stop_product(self):
        path = self.run.output / 'ipad-processes.json'
        self.dev('info', 'processes', '--json-output', path)
        for p in json.loads(path.read_text())['result']['runningProcesses']:
            if p.get('executable', '').endswith('/ShenglinPad.app/ShenglinPad'):
                self.dev('process', 'terminate', '--pid', str(p['processIdentifier']))

    def close(self):
        errors = []
        try:
            if self.original_sharing is False:
                if self.run.args.lock:
                    # Sharing is not persisted by the product. Termination restores off without unlocking.
                    self.stop_product()
                else:
                    self.foreground()
                    state = self.send('sharing', value='false')
                    require(state['sharing'] is False, 'iPad共享未恢复为关闭')
                    if self.original_state <= 1:
                        self.stop_product()
        except Exception as exc:
            errors.append(str(exc))
            if self.original_sharing is False:
                try:
                    self.stop_product()
                    self.run.result['ipad_forced_close'] = True
                except Exception as stop_error:
                    errors.append(str(stop_error))
        finally:
            if self.process is not None:
                try:
                    if self.process.poll() is None:
                        self.send('quit')
                    self.process.wait(timeout=30)
                    require(self.process.returncode == 0, 'iPad XCTest失败，见ipad-ui.log')
                except Exception as exc:
                    errors.append(str(exc))
                finally:
                    if self.process.poll() is None:
                        self.process.terminate()
                        try: self.process.wait(timeout=5)
                        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
                    self.handle.close()
                try:
                    apps = self.run.output / 'ipad-apps-after.json'
                    self.dev('info', 'apps', '--json-output', apps)
                    if any(x['bundleIdentifier'] == self.runner_id for x in json.loads(apps.read_text())['result']['apps']):
                        self.dev('uninstall', 'app', self.runner_id)
                except Exception as exc:
                    errors.append(f'移除临时UI Runner失败：{exc}')
        require(not errors, '; '.join(errors))
