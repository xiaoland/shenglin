param([switch]$Test)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
Set-Location $root
$toolDir = Split-Path (Get-Command clang -ErrorAction Stop).Source
if ((& "$toolDir/clang.exe" -dumpmachine) -notmatch 'windows-gnu|w64-mingw') { throw '需要 LLVM MinGW 的 clang，而不是 MSVC clang。' }
$env:PATH = "$toolDir;$env:PATH"
$env:CC = "$toolDir/clang.exe"
$env:AR = "$toolDir/llvm-ar.exe"
$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER = "$toolDir/clang.exe"
$lib = & rustc +stable-x86_64-pc-windows-gnu --print target-libdir
if ($LASTEXITCODE) { throw '请先运行 rustup toolchain install stable-x86_64-pc-windows-gnu --profile minimal' }
$env:LIBRARY_PATH = "$lib/self-contained"
$env:CARGO_ENCODED_RUSTFLAGS = @('-L', "native=$toolDir/../x86_64-w64-mingw32/lib", '-C', 'link-self-contained=no', '-C', 'link-arg=-static', '-C', 'link-arg=-lbcrypt') -join [char]31
$env:CARGO_TARGET_DIR = "$root/local/rust-target-windows"
$revision = 'e98a6564575520260ef95b2389e5d63a24917093'
if (!(Test-Path local/boringssl/.shenglin-revision)) {
    New-Item -ItemType Directory -Force local/boringssl | Out-Null
    Invoke-WebRequest "https://github.com/google/boringssl/archive/$revision.tar.gz" -OutFile local/boringssl.tar.gz
    & tar -xzf local/boringssl.tar.gz -C local/boringssl --strip-components=1
    if ($LASTEXITCODE) { throw 'BoringSSL 解包失败' }
    Set-Content local/boringssl/.shenglin-revision $revision -Encoding ascii
}
if ((Get-Content local/boringssl/.shenglin-revision -Raw).Trim() -ne $revision) { throw 'BoringSSL 版本不同，请清理 local/boringssl 后重建。' }
& cmake -S local/boringssl -B local/boringssl-windows -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=Windows "-DCMAKE_C_COMPILER=$toolDir/clang.exe" "-DCMAKE_CXX_COMPILER=$toolDir/clang++.exe" -DOPENSSL_NO_ASM=ON -DBUILD_SHARED_LIBS=OFF
if ($LASTEXITCODE) { throw 'CMake 配置失败' }
& cmake --build local/boringssl-windows --target crypto -j 8
if ($LASTEXITCODE) { throw 'BoringSSL 构建失败' }
$ErrorActionPreference = 'Continue'
& cargo +stable-x86_64-pc-windows-gnu build --locked --manifest-path Windows/Cargo.toml --target x86_64-pc-windows-gnu --release
if ($LASTEXITCODE) { throw 'Windows 构建失败' }
if ($Test) {
    foreach ($manifest in @('Core/Cargo.toml','Windows/Cargo.toml')) {
        & cargo +stable-x86_64-pc-windows-gnu test --locked --manifest-path $manifest --target x86_64-pc-windows-gnu
        if ($LASTEXITCODE) { throw "测试失败：$manifest" }
    }
}
$ErrorActionPreference = 'Stop'
$output = "$root/dist/windows"
New-Item -ItemType Directory -Force $output | Out-Null
Copy-Item "$env:CARGO_TARGET_DIR/x86_64-pc-windows-gnu/release/shenglin.exe" $output -Force
Copy-Item scripts/install-windows-service.ps1 $output -Force
Copy-Item Windows/README.md $output -Force
Copy-Item LICENSE "$output/LICENSE.txt" -Force
Copy-Item third_party/BoringSSL-LICENSE.txt $output -Force
Copy-Item "$toolDir/../LICENSE.TXT" "$output/LLVM-MinGW-LICENSE.txt" -Force
$ErrorActionPreference = 'Continue'
$metadata = & cargo +stable-x86_64-pc-windows-gnu metadata --locked --format-version 1 --manifest-path Windows/Cargo.toml
if ($LASTEXITCODE) { throw '无法读取依赖许可证清单' }
$ErrorActionPreference = 'Stop'
$notices = foreach ($package in ($metadata | ConvertFrom-Json).packages) {
    "`n$($package.name) $($package.version) — $($package.license)`n"
    $directory = Split-Path $package.manifest_path
    foreach ($file in (Get-ChildItem $directory -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' })) {
        Get-Content $file.FullName -Raw
    }
}
$notices | Set-Content "$output/Rust-THIRD-PARTY-LICENSES.txt" -Encoding UTF8
$files = @('shenglin.exe', 'install-windows-service.ps1', 'README.md', 'LICENSE.txt', 'BoringSSL-LICENSE.txt', 'LLVM-MinGW-LICENSE.txt', 'Rust-THIRD-PARTY-LICENSES.txt')
$archive = "$root/dist/Shenglin-Windows-x64.zip"
Compress-Archive -Path ($files | ForEach-Object { Join-Path $output $_ }) -DestinationPath $archive -Force
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  Shenglin-Windows-x64.zip" | Set-Content "$archive.sha256" -Encoding ascii
Write-Output "已生成 $archive"
