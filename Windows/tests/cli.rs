use std::{path::PathBuf, process::Command};

// 帮助、版本和网络查询必须可在安装前运行，不能先创建或收紧配置目录权限。
#[test]
fn informational_commands_do_not_touch_configuration() {
    let directory = std::env::temp_dir().join(format!("shenglin-cli-check-{}", std::process::id()));
    assert!(!directory.exists());
    for command in ["--help", "--version", "networks"] {
        let output = Command::new(env!("CARGO_BIN_EXE_shenglin"))
            .args([command, "--data"])
            .arg(&directory)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let text = String::from_utf8(output.stdout).unwrap();
        if command == "--version" {
            assert!(text.contains(env!("CARGO_PKG_VERSION")));
        }
        assert!(
            !PathBuf::from(&directory).exists(),
            "{command} created configuration"
        );
    }
}
