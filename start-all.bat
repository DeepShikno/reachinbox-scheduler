@echo off
REM Put this file in the reachinbox-scheduler-full folder (next to "backend" and "frontend"), then double-click it.

echo === Installing and preparing backend ===
cd /d "%~dp0backend"
call npm install
call npm run migrate
if errorlevel 1 (
  echo.
  echo Migration failed. Check backend\.env ^(DB_HOST, DB_PASSWORD, DB_SSL^) and try again.
  pause
  exit /b 1
)

echo === Starting API, worker and frontend in separate windows ===
start "API" cmd /k "npm run dev:api"
start "Worker" cmd /k "npm run dev:worker"

cd /d "%~dp0frontend"
call npm install
start "Frontend" cmd /k "npm run dev"

timeout /t 10 >nul
start http://localhost:5173
echo Done. Keep the three windows open.
pause
