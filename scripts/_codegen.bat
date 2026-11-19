@echo off
REM Recompile default.xex into generated\ (BOOTSTRAP.md step 5) without editing
REM the tracked nhllegacy_manifest.toml. Writes nhllegacy_manifest.local.toml
REM (git-ignored) with game_root / file_path pointed at %NHL_GAME_DIR% and runs
REM rexglue codegen on that copy. Codegen also rewrites sdk_version in the copy.
REM
REM Set NHL_GAME_DIR in scripts\_env.local.bat (setup_toolchain.ps1 -GameDir does
REM it), or pass the folder holding the vanilla default.xex as the first argument,
REM e.g. the game\ folder of an nhl-legacy-builder install.
call "%~dp0_env.bat" || exit /b 1
if not "%~1"=="" set "NHL_GAME_DIR=%~1"
if not defined NHL_GAME_DIR (
  echo ERROR: set NHL_GAME_DIR in scripts\_env.local.bat or pass the game folder
  exit /b 1
)
if not exist "%NHL_GAME_DIR%\default.xex" (
  echo ERROR: "%NHL_GAME_DIR%\default.xex" not found
  exit /b 1
)
cd /d "%REPO_ROOT%" || exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$g = $env:NHL_GAME_DIR -replace '\\','/';" ^
  "$t = Get-Content -Raw 'nhllegacy_manifest.toml';" ^
  "$t = $t -replace '(?m)^game_root = .*$', ('game_root = \"' + $g + '\"');" ^
  "$t = $t -replace '(?m)^file_path = .*$', ('file_path = \"' + $g + '/default.xex\"');" ^
  "[IO.File]::WriteAllText((Join-Path (Get-Location) 'nhllegacy_manifest.local.toml'), $t)" || exit /b 1
"%REXGLUE_SDK_INSTALL%\bin\rexglue.exe" codegen nhllegacy_manifest.local.toml || exit /b 1
echo CODEGEN-OK
