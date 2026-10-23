#!/usr/bin/env python3
"""隔离执行安装脚本；替代构建、签名与系统服务，不改本机安装。"""
from pathlib import Path
import os
import subprocess
import tempfile
import shutil

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='shenglin-install-test-') as temporary:
    work = Path(temporary)
    repo = work / 'repo'
    applications = work / 'Applications'
    binaries = work / 'bin'
    for directory in [repo / '.git', repo / 'scripts', applications, binaries,
                      repo / 'MacGUI', repo / 'local/DriverBuild/ShenglinDriver.driver']:
        directory.mkdir(parents=True)
    for name in ['install-mac-driver.sh']:
        (repo / 'scripts' / name).touch()
    (repo / 'MacGUI/local.shenglin.microphone.plist').touch()
    (repo / 'scripts/build-rust-core.sh').write_text('#!/bin/sh\nexit 0\n')
    (repo / 'scripts/build-rust-core.sh').chmod(0o755)
    for name in ['build-mac-app.sh', 'run-mac-app.sh', 'package-macos-dmg.sh']:
        source = (root / 'scripts' / name).read_text()
        source = source.replace('/Applications/', f'{applications}/')
        source = source.replace('ln -s /Applications ', f'ln -s {applications} ')
        source = source.replace('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', str(binaries / 'lsregister'))
        source = source.replace('/usr/libexec/PlistBuddy', str(binaries / 'PlistBuddy'))
        (repo / 'scripts' / name).write_text(source)
    mock = '''#!/usr/bin/env python3
from pathlib import Path
import os, shutil, sys, subprocess
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'xcodebuild':
    app = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Release/声邻.app/Contents/MacOS/声邻'
    app.parent.mkdir(parents=True)
    app.write_text('#!/bin/sh\\necho stopped > "$STOP_LOG"\\n')
    app.chmod(0o755)
    sys.exit(1 if os.environ.get('BUILD_FAIL') else 0)
elif name == 'mv':
    if os.environ.get('INSTALL_FAIL') and args[0].endswith('/Shenglin.app') and '.shenglin.' in args[0]:
        sys.exit(1)
    if os.environ.get('ROLLBACK_FAIL') and args[0].endswith('/previous.app'):
        sys.exit(1)
    sys.exit(subprocess.run(['/bin/mv', *args]).returncode)
elif name == 'ditto':
    shutil.copytree(args[0], args[1], dirs_exist_ok=True)
elif name == 'codesign':
    sys.exit(1 if os.environ.get('SIGN_FAIL') and '--force' in args else 0)
elif name == 'PlistBuddy':
    print('false' if os.environ.get('INPUT_PERMISSION_FAIL') else 'true')
elif name == 'lsof':
    running = os.environ.get('RUNNING')
    if running == 'gui' or (running in ['agent', 'stuck'] and not Path(os.environ['STOP_LOG']).exists()):
        print('123' if '-t' in args else 'app 123 user txt')
    elif running == 'stuck':
        print('123' if '-t' in args else 'app 123 user txt')
elif name == 'ps':
    print('--microphone-agent' if os.environ.get('RUNNING') in ['agent', 'stuck'] else 'GUI')
elif name == 'pgrep':
    sys.exit(1)
elif name in ['lsregister', 'open', 'hdiutil', 'mv']:
    with open(os.environ['COMMAND_LOG'], 'a') as log:
        log.write(name + ' ' + ' '.join(args) + '\\n')
'''
    for name in ['xcodebuild', 'ditto', 'codesign', 'PlistBuddy', 'lsof', 'ps', 'pgrep', 'lsregister', 'open', 'hdiutil', 'mv']:
        command = binaries / name
        command.write_text(mock)
        command.chmod(0o755)
    installed = applications / 'Shenglin.app'
    executable = installed / 'Contents/MacOS/声邻'
    stop_log = work / 'stopped'
    command_log = work / 'commands'
    env = {**os.environ, 'PATH': f'{binaries}:{os.environ["PATH"]}',
           'STOP_LOG': str(stop_log), 'COMMAND_LOG': str(command_log)}

    def old_install():
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!/bin/sh\necho stopped > "$STOP_LOG"\n# old\n')
        executable.chmod(0o755)
        stop_log.unlink(missing_ok=True)

    def run(name, **variables):
        return subprocess.run(['sh', str(repo / 'scripts' / name)], env={**env, **variables},
                              capture_output=True, text=True)

    for failure in ['BUILD_FAIL', 'SIGN_FAIL', 'INPUT_PERMISSION_FAIL']:
        old_install()
        result = run('build-mac-app.sh', **{failure: '1'})
        assert result.returncode != 0, (failure, result)
        assert '# old' in executable.read_text(), failure
        assert not list(applications.glob('.shenglin.*')), failure
        assert not (repo / 'local/MacDerived.noindex/Build/Products/Release/声邻.app').exists(), failure
    for running in ['gui', 'stuck']:
        old_install()
        result = run('build-mac-app.sh', RUNNING=running)
        assert result.returncode != 0, (running, result)
        assert '# old' in executable.read_text(), running
    old_install()
    result = run('build-mac-app.sh', INSTALL_FAIL='1')
    assert result.returncode != 0
    assert '# old' in executable.read_text(), '安装失败必须恢复旧版。'
    assert not list(applications.glob('.shenglin.*'))
    old_install()
    result = run('build-mac-app.sh', INSTALL_FAIL='1', ROLLBACK_FAIL='1')
    assert result.returncode != 0
    backups = list(applications.glob('.shenglin.*.noindex/previous.app/Contents/MacOS/声邻'))
    assert len(backups) == 1 and '# old' in backups[0].read_text(), '回滚失败也不能删除旧版。'
    assert '安装回滚失败' in result.stderr
    for staging in applications.glob('.shenglin.*'):
        shutil.rmtree(staging)
    old_install()
    result = run('build-mac-app.sh', RUNNING='agent')
    assert result.returncode == 0, result.stderr
    assert stop_log.exists(), '必须停止旧后台服务。'
    assert '# old' not in executable.read_text()
    assert not list(applications.glob('.shenglin.*'))
    assert not (repo / 'dist/Shenglin.app').exists()
    assert not (repo / 'local/MacDerived.noindex/Build/Products/Release/声邻.app').exists()
    result = run('package-macos-dmg.sh')
    assert result.returncode == 0, result.stderr
    result = run('run-mac-app.sh')
    assert result.returncode == 0, result.stderr
    assert f'open -g {installed}' in command_log.read_text()
    shutil_app = repo / 'dist/Shenglin.app'
    installed.rename(shutil_app)
    result = run('run-mac-app.sh')
    assert result.returncode != 0, '缺失安装时不能回退到 dist App。'
    result = run('package-macos-dmg.sh')
    assert result.returncode != 0, 'DMG 必须取自唯一安装。'
print('通过：唯一安装、构建与签名失败保留旧版、GUI 拒绝替换、后台服务停止、临时 App 清理、DMG 与启动路径。')
