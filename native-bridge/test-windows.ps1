[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$nativeTestProject = Join-Path $scriptDirectory "bridge-tests\WacomNativeBridge.Tests.csproj"

$sdkVersion = & dotnet --version
if ($LASTEXITCODE -ne 0) {
    throw ".NET SDK was not found. Install the .NET 10 SDK first."
}
if ([int]($sdkVersion.Split('.')[0]) -lt 10) {
    throw ".NET 10 SDK or newer is required. Found: $sdkVersion"
}

Write-Host "Running Windows native regression tests"
& dotnet run `
    --project $nativeTestProject `
    --configuration $Configuration `
    --nologo
if ($LASTEXITCODE -ne 0) {
    throw "Windows native regression tests failed with exit code $LASTEXITCODE"
}

Write-Host "Windows regression suite passed"
Write-Host "  SDK:  $sdkVersion"
