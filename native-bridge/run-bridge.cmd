@echo off
setlocal
pushd "%~dp0"
dotnet run --project bridge\WacomNativeBridge.csproj --configuration Release
set "bridge_exit=%ERRORLEVEL%"
popd
pause
exit /b %bridge_exit%
