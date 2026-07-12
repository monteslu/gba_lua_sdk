@echo off
REM Launch a GameTank emulator with a .gtr ROM file (Windows).
REM Resolution order: GAMETANK_EMULATOR env var, then GameTankEmulator on PATH.
REM https://github.com/clydeshaffer/GameTankEmulator

set "rom=%~1"
if "%rom%"=="" (
  echo usage: run_emulator.cmd ^<game.gtr^> 1>&2
  exit /b 2
)

if defined GAMETANK_EMULATOR (
  "%GAMETANK_EMULATOR%" "%rom%"
  exit /b %errorlevel%
)

where GameTankEmulator >nul 2>&1
if %errorlevel%==0 (
  GameTankEmulator "%rom%"
  exit /b %errorlevel%
)

echo ERROR: no GameTank emulator found. 1>&2
echo Set GAMETANK_EMULATOR to your emulator, or put GameTankEmulator on PATH. 1>&2
echo Emulator: https://github.com/clydeshaffer/GameTankEmulator 1>&2
exit /b 1
