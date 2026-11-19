@echo off
REM Alternative to _ffx_dll_build.bat that needs no Visual Studio: stage an
REM existing amd_fidelityfx_vk.dll (e.g. the one shipped in a release zip or in
REM your installed game folder) and generate its import library with LLVM, so
REM _ffx_sdk_configure.bat imports it as the prebuilt FidelityFX.
REM
REM The DLL exports a 5-function C ABI (ffxConfigure, ffxCreateContext,
REM ffxDestroyContext, ffxDispatch, ffxQuery) and is DELAYLOAD'd by the SDK, so an
REM import library rebuilt from its export table links the same as the original.
REM
REM Usage:  scripts\_ffx_import_prebuilt.bat "<path>\amd_fidelityfx_vk.dll"
call "%~dp0_env.bat" || exit /b 1
if "%~1"=="" (
  echo usage: %~nx0 "path\to\amd_fidelityfx_vk.dll"
  exit /b 1
)
if not exist "%~1" (
  echo ERROR: %~1 not found
  exit /b 1
)
if not exist "%REXGLUE_FFX_PREBUILT%" mkdir "%REXGLUE_FFX_PREBUILT%"
copy /y "%~1" "%REXGLUE_FFX_PREBUILT%\amd_fidelityfx_vk.dll" >nul || exit /b 1
set "DEF=%REXGLUE_FFX_PREBUILT%\amd_fidelityfx_vk.def"
> "%DEF%" echo LIBRARY amd_fidelityfx_vk.dll
>> "%DEF%" echo EXPORTS
for /f "tokens=2" %%n in ('llvm-readobj --coff-exports "%REXGLUE_FFX_PREBUILT%\amd_fidelityfx_vk.dll" ^| findstr /r /c:"^ *Name: "') do >> "%DEF%" echo     %%n
llvm-dlltool -m i386:x86-64 -d "%DEF%" -l "%REXGLUE_FFX_PREBUILT%\amd_fidelityfx_vk.lib" -D amd_fidelityfx_vk.dll || exit /b 1
type "%DEF%"
echo staged amd_fidelityfx_vk.dll + .lib -^> %REXGLUE_FFX_PREBUILT%
