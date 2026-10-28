#!/usr/bin/env python3
"""离线检查语音判据及失败/中断后的进程与配置恢复，不读取音频设备。"""
import argparse
from array import array
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch
from remote_microphone import runtime
from remote_microphone.recognition import assess, normalize, require_model
from remote_microphone.devices import Android, IPad


class SpeechCriteria(unittest.TestCase):
    def test_words_are_required_at_both_ends(self):
        text = normalize(runtime.PHRASE)
        self.assertTrue(assess(text, text)['passed'])
        self.assertTrue(assess(text, text.replace('这是', '这次'))['passed'])
        for broken in ['', text[9:], text[:-10], '今天的天气很好', '现代做生意的偶然就传到电脑']:
            with self.subTest(text=broken):
                self.assertFalse(assess(text, broken)['passed'])

    def test_digits_and_punctuation_are_equivalent(self):
        self.assertEqual(normalize('１，二 三、四五！'), '12345')

    def test_invalid_pcm_is_rejected_and_silence_is_exact(self):
        self.assertTrue(runtime.pcm_stats(array('f', [0, 0]))['exact_zero'])
        self.assertFalse(runtime.pcm_stats(array('f', [1e-8, 0]))['exact_zero'])
        for values in [[], [float('nan')], [float('inf')], [1.1]]:
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                runtime.pcm_stats(array('f', values))

    def test_partial_model_cannot_trigger_tokenizer_download(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'model.bin').touch()
            with self.assertRaisesRegex(ValueError, 'tokenizer.json'):
                require_model(root)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.gain, self.muted, self.fail_restore = 1, False, False
        self.mount = {'bundle': 'remote.test', 'remoteSource': {'peerID': 'peer', 'sourceID': 'input'}}
        self.probe = self.root / 'probe'
        self.probe.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
print('ready 123 456', flush=True)
for line in sys.stdin:
 if line.strip() == 'quit': break
Path(sys.argv[3]).write_bytes(b'\\x00'*480)
''')
        self.probe.chmod(0o755)
        self.args = argparse.Namespace(startup_wait=2, asr_python=None, model=None, mount='remote.test',
                                       output=self.root / 'evidence', cli=self.root / 'cli',
                                       speaker_uid='speaker', voice='voice', phrase=runtime.PHRASE)

    def mac(self, *args):
        if args == ('microphone', 'mounts'):
            return {'ok': True, 'mounts': [{**self.mount, 'gain': self.gain}]}
        if args == ('control', 'status'):
            return {'ok': True, 'status': {'inputCount': 0, 'error': '',
                    'captureDiagnostics': dict(busyDroppedFrames=0, conversionDroppedFrames=0, pushFailedFrames=0),
                    'sources': [{'selector': 'bundle:remote.test', 'muted': self.muted, 'microphoneInUse': False}]}}
        if args[:2] == ('microphone', 'gain'):
            if self.fail_restore and args[-1] == '1':
                raise RuntimeError('模拟配置恢复失败')
            self.gain = int(args[-1])
        elif args[:2] == ('control', 'mute'):
            self.muted = args[2] == 'add'
        else:
            raise AssertionError(args)
        return {'ok': True}

    def run_failure(self, failure):
        readers = []
        def body(run):
            run.gain(8)
            run.mute(True)
            readers.append(runtime.Reader(run, 'interrupted'))
            if failure == 'SIGTERM':
                os.kill(os.getpid(), signal.SIGTERM)
            raise failure
        with patch.object(runtime, 'build_probe', return_value=self.probe), \
             patch.object(runtime, 'command', return_value='73'), \
             patch.object(runtime.Run, 'mac', side_effect=self.mac):
            code = runtime.execute(self.args, body)
        self.assertEqual(code, 1)
        self.assertIsNotNone(readers[0].process.poll())
        self.assertTrue((self.args.output / 'interrupted.f32').exists())
        result = json.loads((self.args.output / 'results.json').read_text())
        self.assertEqual(result['status'], 'failed')
        return result

    def test_child_and_settings_are_restored_after_exception(self):
        result = self.run_failure(RuntimeError('模拟播放失败'))
        self.assertEqual((self.gain, self.muted), (1, False))
        self.assertEqual(result['cleanup_errors'], [])

    def test_keyboard_interrupt_restores_settings(self):
        self.run_failure(KeyboardInterrupt())
        self.assertEqual((self.gain, self.muted), (1, False))

    def test_sigterm_restores_settings(self):
        self.run_failure('SIGTERM')
        self.assertEqual((self.gain, self.muted), (1, False))

    def test_restore_failure_cannot_be_reported_as_success(self):
        self.fail_restore = True
        result = self.run_failure(RuntimeError('模拟播放失败'))
        self.assertIn('模拟配置恢复失败', result['cleanup_errors'])
        self.assertFalse(self.muted)

    def test_preexisting_mute_is_not_changed_when_preflight_fails(self):
        self.muted = True
        with patch.object(runtime, 'build_probe', return_value=self.probe), \
             patch.object(runtime, 'command', return_value='73'), \
             patch.object(runtime.Run, 'mac', side_effect=self.mac):
            code = runtime.execute(self.args, lambda run: self.fail('不应开始采集'))
        self.assertEqual(code, 1)
        self.assertTrue(self.muted)


class AndroidUI(unittest.TestCase):
    def test_nonclickable_label_does_not_hide_clickable_switch(self):
        xml = '''<hierarchy><node text="共享内置麦克风" clickable="false"/>
<node clickable="true" package="local.shenglin" bounds="[20,20][40,40]">
<node content-desc="共享内置麦克风" clickable="false"/></node></hierarchy>'''
        with tempfile.TemporaryDirectory() as folder:
            run = argparse.Namespace(output=Path(folder))
            device = Android(run, 'test-device')
            with patch.object(device, 'state', side_effect=[{'sharing': False}, {'sharing': True}]), \
                 patch.object(device, 'adb', side_effect=['', xml, '']) as adb:
                device.sharing(True)
            self.assertEqual(adb.call_args.args, ('shell', 'input', 'tap', '30', '30'))


class IPadRecovery(unittest.TestCase):
    def test_launch_device_options_are_not_passed_to_the_app(self):
        device = IPad(argparse.Namespace(output=Path('/unused')), 'device', 'team')
        with patch('remote_microphone.devices.command', return_value='') as launch:
            device.dev('process', 'launch', 'com.apple.Preferences')
        args = launch.call_args.args
        self.assertLess(args.index('--device'), args.index('com.apple.Preferences'))

    def test_ui_failure_stops_temporary_sharing_and_still_fails(self):
        run = argparse.Namespace(args=argparse.Namespace(lock=False), result={}, output=Path('/unused'))
        device = IPad(run, 'device', 'team')
        device.original_sharing = False
        with patch.object(device, 'foreground', side_effect=RuntimeError('UI失联')), \
             patch.object(device, 'stop_product') as stop, self.assertRaisesRegex(RuntimeError, 'UI失联'):
            device.close()
        stop.assert_called_once()
        self.assertTrue(run.result['ipad_forced_close'])


if __name__ == '__main__':
    unittest.main()
