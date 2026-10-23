param(
    [string]$Executable = "$PSScriptRoot/shenglin.exe",
    [string]$BindAddress,
    [string]$DataDirectory = "$env:ProgramData/Shenglin",
    [string]$ServiceName = 'Shenglin'
)
$ErrorActionPreference = 'Stop'
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '请在管理员 PowerShell 中安装服务。' }
$nssmSource = (Get-Command nssm -ErrorAction Stop).Source
if (Get-Service $ServiceName -ErrorAction SilentlyContinue) { throw "服务 $ServiceName 已存在；先停止服务并更新原安装的可执行文件。" }
$source = (Resolve-Path $Executable).Path
& $source version
if ($LASTEXITCODE) { throw '无法运行声邻；本安装包要求 x64 Windows 10/11。' }
$networks = & $source networks
if ($LASTEXITCODE) { throw '无法读取本机物理网络。' }
$networks = @($networks | ConvertFrom-Json)
if ($BindAddress) {
    if (!($networks | Where-Object { $_.ip -eq $BindAddress })) { throw 'BindAddress 必须属于活动物理 Wi-Fi 或以太网；运行 shenglin.exe networks 查看。' }
} elseif ($networks.Count -ne 1) {
    throw '存在零个或多个物理网络；运行 shenglin.exe networks 后用 -BindAddress 选择地址。'
}
$install = "$env:ProgramFiles/Shenglin"
New-Item -ItemType Directory -Force $install | Out-Null
& icacls $install /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) { throw '无法保护服务程序目录' }
$exe = Join-Path $install shenglin.exe
if ($source -ne $exe) { Copy-Item $source $exe -Force }
foreach ($file in @('README.md', 'LICENSE.txt', 'BoringSSL-LICENSE.txt', 'LLVM-MinGW-LICENSE.txt', 'Rust-THIRD-PARTY-LICENSES.txt')) {
    $from = Join-Path (Split-Path $source) $file
    if (Test-Path $from) { Copy-Item $from $install -Force }
}
# LocalSystem 必须从受保护的持久目录运行 NSSM，不能依赖下载目录中的副本。
$nssm = Join-Path $install nssm.exe
if ($nssmSource -ne $nssm) { Copy-Item $nssmSource $nssm -Force }
New-Item -ItemType Directory -Force $DataDirectory | Out-Null
$data = (Resolve-Path $DataDirectory).Path
# Machine-scoped DPAPI supports CLI + LocalSystem; the directory ACL owns access control.
& icacls $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE) { throw '无法限制数据目录权限' }
function Set-Nssm { & $nssm @args; if ($LASTEXITCODE) { throw "NSSM 操作失败：$args" } }
Set-Nssm install $ServiceName $exe
$parameters = 'serve --data "' + $data + '"'
if ($BindAddress) { $parameters += ' --bind ' + $BindAddress }
Set-Nssm set $ServiceName AppParameters $parameters
Set-Nssm set $ServiceName AppDirectory (Split-Path $exe)
Set-Nssm set $ServiceName DependOnService Audiosrv
Set-Nssm set $ServiceName Start SERVICE_DELAYED_AUTO_START
Set-Nssm set $ServiceName AppStdout "$data/service.log"
Set-Nssm set $ServiceName AppStderr "$data/error.log"
Set-Nssm set $ServiceName AppRotateFiles 1
Set-Nssm set $ServiceName AppRotateOnline 1
Set-Nssm set $ServiceName AppRotateBytes 1048576
Set-Nssm set $ServiceName AppStopMethodConsole 15000
Set-Nssm set $ServiceName AppRestartDelay 2000
New-NetFirewallRule -DisplayName "$ServiceName LAN TCP" -Direction Inbound -Action Allow -Program $exe -Protocol TCP -RemoteAddress LocalSubnet -Profile Private,Domain | Out-Null
New-NetFirewallRule -DisplayName "$ServiceName mDNS" -Direction Inbound -Action Allow -Program $exe -Protocol UDP -LocalPort 5353 -RemoteAddress LocalSubnet -Profile Private,Domain | Out-Null
Set-Nssm start $ServiceName
Write-Output "服务已安装。使用 & '$nssm' stop/start/restart $ServiceName 管理；运行 & '$exe' status 查看实际音频与连接状态。"
