@echo off
rem NetPulse 一键启动：会弹一次 UAC 拿提权数据
setlocal
set "HERE=%~dp0"
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh.exe"

start "" /min mshta "vbscript:CreateObject("WScript.Shell").Run(""\"%PS%\" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%HERE%Start-NetPulse.ps1""",0)(window.close)"
exit /b