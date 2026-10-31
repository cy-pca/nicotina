@echo off
rem nicotina.cmd: run the nicotina TX.WTF client in a stock Ariadne host, on Windows.
rem
rem   nicotina [--instance URL] [--terminal] [--backend ftxui|tvision] [host flags...] [-- doc args...]
rem
rem As bin/nicotina does elsewhere: `arigl run` (ImGui) on the desktop; in the console, `ari run`
rem (FTXUI, or tvision with --backend tvision), or `arigl run --terminal` where only arigl is
rem installed. The console is picked by --terminal or --backend, or in an SSH session. The host
rem gets the network for the instance's origin only, and keeps the session token in
rem %APPDATA%\nicotina\credentials.
rem
rem Other options go to the host before the document; arguments after -- go to the document.
rem The documents are in <prefix>\share\nicotina, <prefix> being this script's directory's
rem parent. ari and arigl come from <prefix>\bin, else PATH; NICOTINA_ARI and NICOTINA_ARIGL
rem name others.
setlocal EnableExtensions DisableDelayedExpansion

set "ME=nicotina"
for %%I in ("%~dp0..") do set "PREFIX=%%~fI"
set "SHARE=%PREFIX%\share\nicotina"
if not exist "%SHARE%\main.ari" (
  echo %ME%: the client's documents are not in %SHARE% 1>&2
  exit /b 2
)

set "INSTANCE=https://tx.wtf"
set "TERMINAL="
set "BACKEND="
set "DRYRUN="
set "HOSTARGS="
set "DOCARGS="

rem cmd splits --instance=URL at the "=" too, so both spellings arrive as two arguments.
:parse
if "%~1"=="" goto parsed
if "%~1"=="--" goto docargs
if /i "%~1"=="--instance" (
  if "%~2"=="" goto need_instance
  set "INSTANCE=%~2"
  shift
  shift
  goto parse
)
if /i "%~1"=="--backend" (
  set "BACKEND=%~2"
  shift
  shift
  goto parse
)
if /i "%~1"=="--terminal" (
  set "TERMINAL=1"
  shift
  goto parse
)
if /i "%~1"=="--dry-run" (
  set "DRYRUN=1"
  shift
  goto parse
)
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
set HOSTARGS=%HOSTARGS% %1
shift
goto parse

:docargs
shift
if "%~1"=="" goto parsed
set DOCARGS=%DOCARGS% %1
goto docargs

:parsed
if not defined BACKEND goto backend_ok
if /i "%BACKEND%"=="ftxui" (set "TERMINAL=1" & goto backend_ok)
if /i "%BACKEND%"=="tvision" (set "TERMINAL=1" & goto backend_ok)
echo %ME%: --backend is ftxui or tvision, not '%BACKEND%' 1>&2
exit /b 2
:backend_ok

rem The instance's origin, scheme://host[:port]: the one place the host may send requests.
:trim
if "%INSTANCE:~-1%"=="/" (set "INSTANCE=%INSTANCE:~0,-1%" & goto trim)
set "REST="
if /i "%INSTANCE:~0,8%"=="https://" (set "SCHEME=https://" & set "REST=%INSTANCE:~8%")
if /i "%INSTANCE:~0,7%"=="http://" (set "SCHEME=http://" & set "REST=%INSTANCE:~7%")
if not defined REST (
  echo %ME%: --instance must be an http:// or https:// URL, not '%INSTANCE%' 1>&2
  exit /b 2
)
for /f "tokens=1 delims=/?#" %%A in ("%REST%") do set "HOSTPORT=%%A"
echo(%HOSTPORT%| findstr /c:"@" >nul && (
  echo %ME%: --instance must not carry a user name or password 1>&2
  exit /b 2
)
set "ORIGIN=%SCHEME%%HOSTPORT%"

rem No desktop to open a window on in an SSH session.
if defined SSH_CONNECTION set "TERMINAL=1"
if defined SSH_CLIENT set "TERMINAL=1"

rem The hosts: NICOTINA_ARI / NICOTINA_ARIGL, else <prefix>\bin, else PATH.
set "ARI=%NICOTINA_ARI%"
rem ari-media (ari with sound and video) first, where it is installed.
if not defined ARI if exist "%PREFIX%\bin\ari-media.exe" set "ARI=%PREFIX%\bin\ari-media.exe"
if not defined ARI for %%X in (ari-media.exe) do set "ARI=%%~$PATH:X"
if not defined ARI if exist "%PREFIX%\bin\ari.exe" set "ARI=%PREFIX%\bin\ari.exe"
if not defined ARI for %%X in (ari.exe) do set "ARI=%%~$PATH:X"
set "ARIGL=%NICOTINA_ARIGL%"
if not defined ARIGL if exist "%PREFIX%\bin\arigl.exe" set "ARIGL=%PREFIX%\bin\arigl.exe"
if not defined ARIGL for %%X in (arigl.exe) do set "ARIGL=%%~$PATH:X"
if not defined ARI if not defined ARIGL (
  echo %ME%: neither ari nor arigl is installed: looked in %PREFIX%\bin and on PATH ^(cvcpkg install ari arigl^) 1>&2
  exit /b 2
)

set "MODE="
if defined TERMINAL (
  if defined ARI (set "HOST=%ARI%") else (set "HOST=%ARIGL%" & set "MODE= --terminal")
) else (
  if defined ARIGL (set "HOST=%ARIGL%") else (
    echo %ME%: arigl is not installed; running in the console with ari 1>&2
    set "HOST=%ARI%"
  )
)

rem The session token, kept by the host across runs, owner-only.
set "STORE="
if defined APPDATA set "STORE=%APPDATA%\nicotina\credentials"

set CMDLINE="%HOST%" run%MODE%
if /i "%BACKEND%"=="tvision" set CMDLINE=%CMDLINE% --backend tvision
set CMDLINE=%CMDLINE% --net --net-allow "%ORIGIN%"
if defined STORE set CMDLINE=%CMDLINE% --credential-store "%STORE%"
set CMDLINE=%CMDLINE%%HOSTARGS% "%SHARE%\main.ari" --instance "%INSTANCE%"%DOCARGS%

if defined DRYRUN (
  echo(%CMDLINE%
  exit /b 0
)
%CMDLINE%
exit /b %ERRORLEVEL%

:need_instance
echo %ME%: --instance needs a URL 1>&2
exit /b 2

:usage
echo usage: %ME% [--instance URL] [--terminal] [--backend ftxui^|tvision] [host flags...] [-- doc args...]
echo.
echo   --instance URL   the TX.WTF instance to use (default https://tx.wtf)
echo   --terminal       run in the console (ari) even on the desktop
echo   --backend NAME   the console backend: ftxui (default) or tvision; implies --terminal
echo   --dry-run        print the host command instead of running it
echo   -h, --help       this help
echo.
echo Other options go to the host (ari or arigl) before the document. Arguments after
echo -- go to the document; `%ME% -- --help` lists them.
exit /b 0
