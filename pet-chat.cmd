@echo off
rem 双击启动桌宠悬浮窗（无控制台窗口）
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0pet-chat.ps1"
