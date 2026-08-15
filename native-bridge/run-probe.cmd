@echo off
setlocal
pushd "%~dp0"
dotnet run --project WacomInputProbe.csproj --configuration Release -- --duration 20
set "probe_exit=%ERRORLEVEL%"
popd
pause
exit /b %probe_exit%
