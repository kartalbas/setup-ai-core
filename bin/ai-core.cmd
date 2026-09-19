@echo off
pwsh -NoProfile -File "%~dp0ai-core.ps1" %*
exit /b %ERRORLEVEL%
