@echo off
rem NetPulse 一键启动（双击本文件）
rem 用 mshta 包一层，避免留下黑色控制台窗口
setlocal
set "HERE=%~dp0"
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"

start "" /min mshta "vbscript:CreateObject("WScript.Shell").Run(""\"%PS%\" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%HERE%NetPulse.Gui.ps1""",0)(window.close)"
exit /b
