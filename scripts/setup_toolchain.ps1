# setup_toolchain.ps1 - install a self-contained, portable build toolchain into ONE
# folder, with no Visual Studio, no LunarG Vulkan SDK, and nothing installed or
# registered anywhere else on the machine. Idempotent: re-run to repair.
#
# What lands under -Root (default: $env:STICKTOSS_DEVTOOLS):
#   llvm\     LLVM/Clang 22.1.8 (clang, lld, llvm-rc, llvm-dlltool, llvm-profdata)
#   cmake\    CMake 3.31.11            ninja\  Ninja 1.13.2
#   python\   Python 3.12.10 embeddable (glslang / SPIRV-Tools generate code with it)
#   xwin\     xwin 0.10.0, which downloads Microsoft's C/C++ runtime and the
#             Windows SDK headers/libraries into msvc\  (Microsoft license applies:
#             pass -AcceptMicrosoftLicense to agree to it)
#   src\      sources CMake would otherwise fetch with Git at configure time
#             (glslang 14.3.0, FidelityFX eee08db, plume's dxc-bin 7810655)
#   tmp\      TEMP/TMP for builds
# Every download is checked against a pinned SHA-256 before use.
#
# It also writes scripts\_env.local.bat (git-ignored), which makes scripts\_env.bat
# use this toolchain instead of looking for Visual Studio.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\setup_toolchain.ps1 `
#       -Root F:\devtools -GameDir "F:\Games\NHL Legacy\game" -AcceptMicrosoftLicense
# Needs Git on PATH (setup_sdk.ps1 needs it too).
param(
    [string]$Root = $env:STICKTOSS_DEVTOOLS,
    [string]$GameDir = "",
    [switch]$AcceptMicrosoftLicense
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # PS 5.1 progress bars slow downloads ~10x
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $Root) { throw "Pass -Root <folder> (e.g. -Root F:\devtools) or set STICKTOSS_DEVTOOLS." }
$repo = Split-Path -Parent $PSScriptRoot
$dl = Join-Path $Root "downloads"
foreach ($d in @($Root, $dl, (Join-Path $Root "tmp"), (Join-Path $Root "src"))) {
    New-Item -ItemType Directory -Force $d | Out-Null
}

function Get-Verified([string]$Url, [string]$Name, [string]$Sha256) {
    $f = Join-Path $dl $Name
    if ((Test-Path $f) -and ((Get-FileHash $f -Algorithm SHA256).Hash -eq $Sha256.ToUpper())) {
        Write-Host "[toolchain] have $Name"; return $f
    }
    Write-Host "[toolchain] downloading $Name"
    Invoke-WebRequest -Uri $Url -OutFile $f -UseBasicParsing
    $h = (Get-FileHash $f -Algorithm SHA256).Hash
    if ($h -ne $Sha256.ToUpper()) { Remove-Item $f -Force; throw "$Name SHA-256 mismatch: got $h, expected $Sha256" }
    return $f
}

# --- Python first: its tarfile/lzma modules unpack the .tar.xz / .tar.gz archives
# (Windows' built-in tar.exe has no xz support). -----------------------------
$py = Join-Path $Root "python\python.exe"
if (-not (Test-Path $py)) {
    $z = Get-Verified "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip" `
        "python-3.12.10-embed-amd64.zip" "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"
    Expand-Archive -Path $z -DestinationPath (Join-Path $Root "python") -Force
}

function Expand-Tar([string]$Archive, [string]$DestName) {
    $dest = Join-Path $Root $DestName
    if (Test-Path $dest) { Write-Host "[toolchain] $DestName already unpacked"; return }
    $stage = Join-Path $Root "tmp\unpack-$DestName"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    & $py -I -c "import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2], filter='data')" $Archive $stage
    if ($LASTEXITCODE -ne 0) { throw "unpacking $Archive failed" }
    $inner = @(Get-ChildItem $stage)
    $src = if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $inner[0].FullName } else { $stage }
    Move-Item $src $dest
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
}
function Expand-ZipTo([string]$Archive, [string]$DestName) {
    $dest = Join-Path $Root $DestName
    if (Test-Path $dest) { Write-Host "[toolchain] $DestName already unpacked"; return }
    $stage = Join-Path $Root "tmp\unpack-$DestName"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    Expand-Archive -Path $Archive -DestinationPath $stage -Force
    $inner = @(Get-ChildItem $stage)
    $src = if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $inner[0].FullName } else { $stage }
    Move-Item $src $dest
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
}

Expand-ZipTo (Get-Verified "https://github.com/Kitware/CMake/releases/download/v3.31.11/cmake-3.31.11-windows-x86_64.zip" `
    "cmake-3.31.11-windows-x86_64.zip" "1210542e49be1a88edfcfd7a3c68407804f5e85945509cf1c5eb5470b5e35beb") "cmake"
Expand-ZipTo (Get-Verified "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip" `
    "ninja-1.13.2-win.zip" "07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65") "ninja"
Expand-Tar (Get-Verified "https://github.com/Jake-Shadle/xwin/releases/download/0.10.0/xwin-0.10.0-x86_64-pc-windows-msvc.tar.gz" `
    "xwin-0.10.0-x86_64-pc-windows-msvc.tar.gz" "96e83665ef5c1406aabd0be603a8d08e67e604f36fda630b6807ee948a614e26") "xwin"
Expand-Tar (Get-Verified "https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.8/clang%2Bllvm-22.1.8-x86_64-pc-windows-msvc.tar.xz" `
    "clang+llvm-22.1.8-x86_64-pc-windows-msvc.tar.xz" "d96c2cc1736f4eb7fa43cb9bbdf56d93551a9ae0a9aadb9c99c3c3b2b712a234") "llvm"

# --- Microsoft C/C++ runtime + Windows SDK via xwin ---------------------------
$msvc = Join-Path $Root "msvc"
if (-not (Test-Path (Join-Path $msvc "crt\include"))) {
    if (-not $AcceptMicrosoftLicense) {
        throw "msvc\ is missing. xwin downloads Microsoft's C/C++ runtime and Windows SDK, which are under Microsoft's license terms. Re-run with -AcceptMicrosoftLicense to agree and continue."
    }
    $env:TEMP = Join-Path $Root "tmp"; $env:TMP = $env:TEMP
    & (Join-Path $Root "xwin\xwin.exe") --accept-license --cache-dir (Join-Path $Root "xwin-cache") `
        --arch x86_64 --variant desktop splat --output $msvc --include-debug-libs --disable-symlinks
    if ($LASTEXITCODE -ne 0) { throw "xwin failed" }
} else { Write-Host "[toolchain] msvc already present" }

# --- Sources CMake would fetch with Git (so builds need no Git at all) ---------
function Get-Pinned([string]$Url, [string]$Name, [string]$Pin) {
    $dest = Join-Path $Root "src\$Name"
    if (-not (Test-Path (Join-Path $dest ".git"))) {
        git clone --quiet --recurse-submodules $Url $dest
        if ($LASTEXITCODE -ne 0) { throw "git clone $Url failed" }
    }
    git -C $dest checkout --quiet $Pin
    if ($LASTEXITCODE -ne 0) { throw "git checkout $Pin in $Name failed" }
    git -C $dest submodule update --quiet --init --recursive
    Write-Host "[toolchain] src\$Name @ $Pin"
}
Get-Pinned "https://github.com/KhronosGroup/glslang.git" "glslang" "14.3.0"                                     # CMakeLists.txt FetchContent
Get-Pinned "https://github.com/rexglue/FidelityFX-SDK.git" "fidelityfx" "eee08db1688ac3d1275a70b728f4a8ba22914213" # SDK cmake/rexglue_fidelityfx.cmake
Get-Pinned "https://github.com/renderbag/dxc-bin.git" "dxc-bin" "781065589d5dba23598b746b3d2e457e985b1442"         # plume PlumeDXC.cmake

# --- Point scripts\_env.bat at this toolchain ----------------------------------
$local = Join-Path $PSScriptRoot "_env.local.bat"
$lines = @(
    "@echo off",
    "REM Written by scripts\setup_toolchain.ps1 - machine-specific, git-ignored.",
    "set ""STICKTOSS_DEVTOOLS=$Root"""
)
if ($GameDir) { $lines += "set ""NHL_GAME_DIR=$GameDir""" }
elseif (Test-Path $local) {
    $prev = Select-String -Path $local -Pattern '^set "NHL_GAME_DIR=' | Select-Object -First 1
    if ($prev) { $lines += $prev.Line }
}
[System.IO.File]::WriteAllText($local, (($lines -join "`r`n") + "`r`n"))
Write-Host ""
Write-Host "Toolchain ready at $Root; wrote $local"
Write-Host "Next: powershell -ExecutionPolicy Bypass -File scripts\setup_sdk.ps1  (see BOOTSTRAP.md)"
