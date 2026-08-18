[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDirectory
$projectFile = Join-Path $scriptDirectory "bridge\WacomNativeBridge.csproj"
$outputDirectory = Join-Path $projectRoot "dist\windows"
$outputExecutable = Join-Path $outputDirectory "WacomNativeBridge.exe"
$checksumFile = Join-Path $outputDirectory "WacomNativeBridge.exe.sha256"
$stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) ("WacomNativeBridge-publish-" + [Guid]::NewGuid().ToString("N"))
$testScript = Join-Path $scriptDirectory "test-windows.ps1"

$sdkVersion = & dotnet --version
if ($LASTEXITCODE -ne 0) {
    throw ".NET SDK was not found. Install the .NET 10 SDK first."
}
$sdkMajor = [int]($sdkVersion.Split('.')[0])
if ($sdkMajor -lt 10) {
    throw ".NET 10 SDK or newer is required. Found: $sdkVersion"
}

if (-not $SkipTests) {
    & $testScript -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "Windows regression suite failed with exit code $LASTEXITCODE"
    }
}

New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
try {
    & dotnet publish $projectFile `
        --configuration $Configuration `
        --runtime win-x64 `
        --self-contained true `
        --output $stagingDirectory `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE"
    }

    $stagedExecutable = Join-Path $stagingDirectory "WacomNativeBridge.exe"
    if (-not (Test-Path -LiteralPath $stagedExecutable -PathType Leaf)) {
        throw "Publish did not produce WacomNativeBridge.exe"
    }

    $unexpectedFiles = @(Get-ChildItem -LiteralPath $stagingDirectory -File | Where-Object Name -ne "WacomNativeBridge.exe")
    if ($unexpectedFiles.Count -ne 0) {
        throw "Publish is not single-file. Unexpected: $($unexpectedFiles.Name -join ', ')"
    }

    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    Copy-Item -LiteralPath $stagedExecutable -Destination $outputExecutable -Force

    $bytes = [IO.File]::ReadAllBytes($outputExecutable)
    if ($bytes.Length -lt 256) {
        throw "Published executable is unexpectedly small."
    }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    $machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
    $subsystem = [BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68)
    if ($machine -ne 0x8664) {
        throw ("Expected x64 PE machine 0x8664, found 0x{0:x4}" -f $machine)
    }
    if ($subsystem -ne 2) {
        throw "Expected Windows GUI subsystem (2), found $subsystem"
    }

    $hash = (Get-FileHash -LiteralPath $outputExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $checksumFile -Value "$hash  WacomNativeBridge.exe" -Encoding ascii

    $sizeMiB = [Math]::Round((Get-Item -LiteralPath $outputExecutable).Length / 1MB, 2)
    Write-Host "Windows package ready"
    Write-Host "  SDK:       $sdkVersion"
    Write-Host "  Executable: $outputExecutable"
    Write-Host "  Size:       $sizeMiB MiB"
    Write-Host "  SHA-256:    $hash"
}
finally {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
