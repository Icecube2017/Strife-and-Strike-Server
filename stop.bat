@echo off
call "%~dp0run.bat" stop %*
exit /b %errorlevel%
