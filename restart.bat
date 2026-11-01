@echo off
call "%~dp0run.bat" restart %*
exit /b %errorlevel%
