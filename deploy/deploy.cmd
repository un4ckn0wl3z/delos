@echo off
rem Deploy / upgrade Delos on your seedbox over SSH (Windows 10/11, built-in OpenSSH).
rem Asks for the connection details; answers are remembered in %USERPROFILE%\.streammkv-deploy.cmd
setlocal EnableExtensions
title Delos deploy
set "URL=https://raw.githubusercontent.com/un4ckn0wl3z/streammkv/main/deploy/install.sh"
set "CFG=%USERPROFILE%\.streammkv-deploy.cmd"

set "SSH_HOST="
set "SSH_USER="
set "SSH_PORT=22"
set "MEDIA_ROOT="
set "APP_PORT="
if exist "%CFG%" call "%CFG%"

where ssh >nul 2>nul || (
  echo OpenSSH client not found. Install it: Settings - System - Optional features - OpenSSH Client.
  pause
  exit /b 1
)

echo Delos - deploy / upgrade on a seedbox over SSH
echo (press Enter to keep the value in [brackets])
echo.
call :ask SSH_HOST "Seedbox host"
call :ask SSH_USER "SSH username"
call :ask SSH_PORT "SSH port"
if not defined MEDIA_ROOT set "MEDIA_ROOT=/home/%SSH_USER%/torrents"
call :ask MEDIA_ROOT "Folder with your videos — mkv, mp4, … (on the seedbox)"
call :ask APP_PORT "Delos port (blank = random free port, or keep the current one)"

if not defined SSH_HOST goto :missing
if not defined SSH_USER goto :missing

> "%CFG%" (
  echo set "SSH_HOST=%SSH_HOST%"
  echo set "SSH_USER=%SSH_USER%"
  echo set "SSH_PORT=%SSH_PORT%"
  echo set "MEDIA_ROOT=%MEDIA_ROOT%"
  echo set "APP_PORT=%APP_PORT%"
)

set "ENVS=MEDIA_ROOT='%MEDIA_ROOT%'"
if defined APP_PORT set "ENVS=%ENVS% PORT=%APP_PORT%"

echo.
echo Connecting to %SSH_USER%@%SSH_HOST%:%SSH_PORT% ...
ssh -t -o StrictHostKeyChecking=accept-new -p %SSH_PORT% %SSH_USER%@%SSH_HOST% "curl -fsSL %URL% | %ENVS% bash"
echo.
echo Open the URL above in a browser (or put it into the app) and sign in with the Username / Password.
pause
exit /b 0

:missing
echo Host and username are required.
pause
exit /b 1

:ask
setlocal EnableDelayedExpansion
set "cur=!%~1!"
set "in="
set /p "in=%~2 [!cur!]: "
if not defined in set "in=!cur!"
endlocal & set "%~1=%in%"
goto :eof
