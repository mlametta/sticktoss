# Fetch + pin + patch the ReXGlue SDK this port builds against, and fetch the
# vendored third-party deps (plume / XenosRecomp). Idempotent - re-run to repair.
#
# The SDK is public (https://github.com/rexglue/rexglue-sdk, BSD-3). This project
# pins the exact commit the port was developed against and applies the title-
# specific patch (sdk/rexglue-vulkan-nhl-legacy-bd9b519.patch): Vulkan texture/
# translator fixes (signed BC5 normals, cube sanitizer, exp_adjust), the
# NHL_VK_READBACK_MODE perf override, and the prebuilt-FidelityFX import path.
#
# Usage:  pwsh scripts/setup_sdk.ps1   (or powershell -File scripts/setup_sdk.ps1)
#   -SdkDir <path>   where to put the SDK source (default third_party/rexglue-sdk)
param(
    [string]$SdkDir = "",
    [string]$Pin = "bd9b51918faa71f962fa38af6d5f744af9aba2ce"
)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
if (-not $SdkDir) { $SdkDir = Join-Path $repo "third_party\rexglue-sdk" }
$patch = Join-Path $repo "sdk\rexglue-vulkan-nhl-legacy-bd9b519.patch"

# Run git quietly and return its exit code. Windows PowerShell 5.1 turns a native
# command's stderr into a terminating error when $ErrorActionPreference is "Stop"
# (which aborted the patch checks below before they could report anything), so
# relax it just for these probe calls.
# (Plain function using $args, not param(): an advanced function would try to
# bind git flags such as -e as PowerShell common parameters.)
function Invoke-GitQuiet {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & git @args 2>&1 | Out-Null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
}

# 1. Clone / pin the SDK.
if (-not (Test-Path (Join-Path $SdkDir ".git"))) {
    Write-Host "[sdk] cloning rexglue-sdk -> $SdkDir"
    git clone --recursive https://github.com/rexglue/rexglue-sdk $SdkDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
}
# The pin is no longer reachable from any upstream branch or tag (the default
# branch moved on to v0.11+), so a plain clone does not contain it. GitHub still
# serves the commit by SHA, so fetch it explicitly when it is missing.
if ((Invoke-GitQuiet -C $SdkDir cat-file -e "$Pin^{commit}") -ne 0) {
    Write-Host "[sdk] fetching pinned commit $Pin by SHA"
    git -C $SdkDir fetch origin $Pin
    if ($LASTEXITCODE -ne 0) { throw "git fetch of pinned commit $Pin failed" }
}
Write-Host "[sdk] pinning $Pin"
git -C $SdkDir checkout $Pin
if ($LASTEXITCODE -ne 0) { throw "git checkout $Pin failed" }
git -C $SdkDir submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }

# 2. Apply the pinned patches in order (skip each if already applied).
#    - the title patch (Vulkan/texture/readback fixes)
#    - upstream codegen cherry-picks that postdate the pin (e.g. the conditional
#      bcctr tail-recovery fix, upstream 10cf1ad - a conditional bnectr/beqctr
#      used to end the block and silently drop the rest of the function)
#    - the VP6 movie-bridge delta: NHL_VP6_LAST_OPEN in NtCreateFile (read by
#      src/vp6_bridge.cpp), the shared-memory race fixes, a TRANSFER_DST usage
#      flag for row-padded movie textures, and the NHL_VP6_TAP debug log. This
#      is rexglue-vp6-sharedmem-fixes.patch re-expressed on top of the title
#      patch (the old file overlaps the title patch and cannot be applied after it).
# Patches are applied from an LF-normalized copy: with core.autocrlf=true a
# checkout gives them CRLF line endings and git apply then rejects every hunk.
$patches = @(
    $patch,
    (Join-Path $repo "sdk\rexglue-codegen-bcctr-tail-fix.patch"),
    (Join-Path $repo "sdk\rexglue-vp6-bridge-delta.patch")
)
$lfDir = Join-Path $repo "out\sdk-patches-lf"
New-Item -ItemType Directory -Force $lfDir | Out-Null
foreach ($src in $patches) {
    $pname = Split-Path -Leaf $src
    $p = Join-Path $lfDir $pname
    $text = [System.IO.File]::ReadAllText($src) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
    if ((Invoke-GitQuiet -C $SdkDir apply --check $p) -eq 0) {
        git -C $SdkDir apply $p
        if ($LASTEXITCODE -ne 0) { throw "$pname apply failed" }
        Write-Host "[sdk] $pname applied"
    } elseif ((Invoke-GitQuiet -C $SdkDir apply --check --reverse --ignore-whitespace $p) -eq 0) {
        Write-Host "[sdk] $pname already applied - OK"
    } else {
        throw "[sdk] $pname does not apply (tree modified?). Reset with: git -C `"$SdkDir`" checkout -- . ; then re-run."
    }
}

# 3. Materialize git symlinks that Windows git checks out as plain text files.
#    libmspack's cabextract/mspack/*.{c,h} are symlinks to ../../libmspack/mspack;
#    without this the SDK build fails compiling "files" that contain only a path
#    (this is also what the original dev tree's unexplained submodule "-dirty"
#    state was). Idempotent: already-materialized files have no 120000 ls-files
#    entry content mismatch worth guarding - we just rewrite from the target.
foreach ($sub in @("thirdparty\libmspack", "thirdparty\o1heap")) {
    $subPath = Join-Path $SdkDir $sub
    $links = git -C $subPath ls-files -s | Where-Object { $_ -match '^120000' } |
             ForEach-Object { ($_ -split "`t")[1] }
    foreach ($rel in $links) {
        $file = Join-Path $subPath $rel
        $content = (Get-Content -Raw $file -ErrorAction SilentlyContinue)
        if ($null -eq $content -or $content.Length -gt 260 -or $content -match "`n.*`n") { continue }  # already materialized
        $target = Join-Path (Split-Path -Parent $file) $content.Trim()
        if (Test-Path $target) {
            Copy-Item -Force $target $file
            Write-Host "[sdk] materialized symlink $sub\$rel"
        }
    }
}

# 4. Vendored high-cut deps (required unconditionally by CMakeLists for now).
& (Join-Path $repo "tools\fetch_thirdparty.ps1")

Write-Host ""
Write-Host "SDK ready at $SdkDir (commit $Pin + title patch)."
Write-Host "Next: scripts\_ffx_sdk_configure.bat  (see BOOTSTRAP.md for the full order)"
