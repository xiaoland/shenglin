# 声邻 Windows

`0.2.0-beta.7`，适用于 x64 Windows 10/11。无需 Rust 或编译工具；通过命令行配对、授权麦克风，用 NSSM 管理后台服务。当前可把 Windows 麦克风挂载到 Mac，Windows 接收远端麦克风尚未实现。

## 安装

从 [GitHub Releases](https://github.com/xiaoland/shenglin/releases) 下载 `Shenglin-Windows-x64.zip` 和 `SHA256SUMS.txt`，运行 `Get-FileHash .\Shenglin-Windows-x64.zip -Algorithm SHA256` 与校验文件比较，再完整解压。程序未作 Authenticode 签名，Windows 可能显示未知发布者。

另从 [NSSM 官网](https://nssm.cc/download) 获取 `2.24-101` 或更新构建的 x64 `nssm.exe`，将其目录加入当前 PowerShell 的 `PATH`。安装脚本会把 NSSM 复制到受保护的安装目录，安装成功后不再依赖下载目录。NSSM 为 public domain 软件，参见其[说明](https://nssm.cc/)。

在管理员 PowerShell 中进入解压目录：

```powershell
.\shenglin.exe version
.\shenglin.exe networks
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-windows-service.ps1 -BindAddress 192.168.1.20
```

将示例地址换为 `networks` 列出的本机物理 Wi-Fi 或以太网 IPv4；只有一个物理地址时可省略 `-BindAddress`。若设备使用 DHCP，建议在路由器保留该地址。地址改变后需更新 NSSM 的 `AppParameters` 中 `--bind` 并重启服务。

程序和 NSSM 安装到 `C:\Program Files\Shenglin`，配置、恢复快照及轮转日志位于 `C:\ProgramData\Shenglin`。两个目录仅 SYSTEM 和管理员可访问，配对密钥另由机器 DPAPI 加密。服务以 LocalSystem 延迟自动启动，依赖 Windows Audio；防火墙仅对专用/域网络的本地子网开放 TCP 和 mDNS，公用网络不自动放行。系统“隐私和安全性 → 麦克风”应允许设备和桌面应用使用麦克风。

后续管理仍在管理员 PowerShell 中执行：

```powershell
$shenglin = "$env:ProgramFiles\Shenglin\shenglin.exe"
$nssm = "$env:ProgramFiles\Shenglin\nssm.exe"
& $shenglin status
& $nssm restart Shenglin
```

`status.runtime.running` 表示服务进程持有运行锁，`current` 表示快照新鲜；只有两者均为 `true` 才可把快照视为当前状态。错误记录在 `error.log`，服务输出在 `service.log`，各按 1 MB 轮转。

## 配对与共享

先在 Mac 的“添加设备”中显示验证码，然后在 Windows 执行：

```powershell
& $shenglin discover --bind 192.168.1.20
& $shenglin pair '发现结果中的设备名称' '六位验证码' --bind 192.168.1.20
& $shenglin status
& $shenglin sources
& $shenglin share 'status 中的 peer ID' 'sources 中的输入 ID'
```

服务运行并完成双向认证后，peer 的 `pending` 应为 `false`。也可先运行 `pair --bind 192.168.1.20` 在 Windows 显示验证码，再从 Mac 输入。配对只建立关系，共享必须单独向该 peer 授权指定输入。

Mac 需要本版 App 和已安装的声邻虚拟麦克风驱动。在“设置… → 专用麦克风”点击“挂载远端麦克风…”，选择 Windows，读取已授权输入并挂载；录音应用选择新增的“声邻 · …”输入。只有录音应用使用该输入时才会采集；静音或停止使用会释放 Windows 上游。断线时 Mac 输入静音，连接恢复后自动重新认证。

撤销授权：`& $shenglin unshare 'peer ID' '输入 ID'`。删除配对：`& $shenglin remove 'peer ID'`。授权按 peer 与输入分别保存；服务重启后保留。

## 升级与卸载

升级前退出使用远端输入的录音应用。在管理员 PowerShell 中停止服务，保存原 EXE，再复制新包文件并启动；不要删除 ProgramData，以保留配对和授权：

```powershell
& $nssm stop Shenglin
Copy-Item $shenglin "$shenglin.previous" -Force
Copy-Item .\shenglin.exe $shenglin -Force
Copy-Item .\README.md,.\*LICENSE*.txt "$env:ProgramFiles\Shenglin" -Force
& $nssm start Shenglin
& $shenglin version
& $shenglin status
```

若新版本无法运行，停止服务，把 `shenglin.exe.previous` 复制回 `shenglin.exe`，再启动。不要在 NSSM 服务仍运行时覆盖 EXE。首次从旧 PoC 安装迁移到本包，先用原 NSSM 停止并移除服务，再运行新安装脚本；保留 ProgramData 即可保留配对。

卸载时先停止服务，再运行 `& $nssm remove Shenglin confirm`，删除防火墙规则 `Shenglin LAN TCP` 与 `Shenglin mDNS`，最后删除 Program Files 下的 Shenglin 目录。只有确定不再保留配对与授权时才删除 ProgramData 下的数据目录。

## 当前边界

音频为 48 kHz、单声道、20 ms 一包，已验证 Logi C270 输入的采集、静音、撤销授权、服务停启恢复和空闲释放。尚未验收多小时录音、睡眠唤醒、热拔插及所有声卡。音量协同独立于共享授权；`enabled off` 不撤销麦克风授权。Windows 只使用局域网，不提供蓝牙协同。混用网线和 Wi-Fi 做音量协同时，各端需选择“同一局域网”；Mac 的“同一 Wi-Fi”条件不会接受 Windows 以太网连接。

完整[使用指南](https://github.com/xiaoland/shenglin/blob/main/manuals/使用指南.md)与[验收记录](https://github.com/xiaoland/shenglin/blob/main/docs/validation.md)随源码维护。
