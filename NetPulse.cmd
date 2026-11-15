@echo off
rem NetPulse 一键启动（双击本文件）
rem 会弹一次 UAC 拿提权数据；拒绝也能用，只是少了 WiFi 信号等三项。
start "" wscript.exe "%~dp0Launch.vbs"
exit /b
