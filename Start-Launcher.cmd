@echo off
setlocal
set "LAUNCHER_PS="
where pwsh.exe >nul 2>nul && set "LAUNCHER_PS=pwsh.exe"
if not defined LAUNCHER_PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "LAUNCHER_PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined LAUNCHER_PS if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe" set "LAUNCHER_PS=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if not defined LAUNCHER_PS (
  echo PowerShell 7 is required. Install it using your normal software process.
  pause
  exit /b 1
)
pushd "%~dp0"
if errorlevel 1 exit /b 1
"%LAUNCHER_PS%" -NoProfile -STA -File "%~dp0Start-PowerShellUI.ps1" %*
set "LAUNCHER_EXIT=%ERRORLEVEL%"
popd
if not "%LAUNCHER_EXIT%"=="0" (
  echo Launcher stopped. Review the error above.
  pause
)
exit /b %LAUNCHER_EXIT%
