@echo off
setlocal
pushd "%~dp0"
dotnet run --project bridge\WacomLocalBridge.csproj --configuration Release -- --web-root ..
set "bridge_exit=%ERRORLEVEL%"
popd
pause
exit /b %bridge_exit%
