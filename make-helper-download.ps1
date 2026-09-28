# Builds download/Plex-Library-Helper-<version>.exe, the one file every PC runs, and download/latest.json
# (which file is current; the dashboard's download link and the app's updater read it). Older builds are removed.
# The exe (app\, C# for .NET Framework 4.8) carries the PowerShell engine (helper\) inside.
# Run after changing anything in helper\ or app\, and commit the download folder with the change.
#   powershell -ExecutionPolicy Bypass -File make-helper-download.ps1
# Needs the .NET 8 SDK (only on the PC that builds; winget Microsoft.DotNet.SDK.8, or dotnet-install.ps1).
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src = Join-Path $repo 'helper'
$engine = 'library-helper.ps1', 'compress.ps1', 'encoders.ps1', 'bench.ps1', 'rips.ps1', 'live.ps1', 'api.ps1', 'install-helper.ps1', 'uninstall-helper.ps1', 'README.md'

$dotnet = @((Get-Command dotnet -ErrorAction SilentlyContinue).Source, "$env:ProgramFiles\dotnet\dotnet.exe", "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe") |
    Where-Object { $_ -and (Test-Path $_) -and (& $_ --list-sdks) } | Select-Object -First 1
if (-not $dotnet) { throw 'The .NET SDK is needed to build the app (winget install Microsoft.DotNet.SDK.8).' }

$version = [regex]::Match([IO.File]::ReadAllText((Join-Path $src 'library-helper.ps1')), "\`$Version = '([^']+)'").Groups[1].Value
$stage = Join-Path $env:TEMP ("pld-build-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$engineDir = Join-Path $stage 'engine'
New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
try {
    foreach ($f in $engine) {
        # Windows line endings; a BOM on PowerShell files (5.1 needs it to read non-ASCII text correctly)
        $text = [IO.File]::ReadAllText((Join-Path $src $f)).TrimStart([char]0xFEFF) -replace "`r?`n", "`r`n"
        [IO.File]::WriteAllText((Join-Path $engineDir $f), $text, (New-Object Text.UTF8Encoding ($f -like '*.ps1')))
    }
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
    $bin = Join-Path $stage 'bin'
    $log = & $dotnet build (Join-Path $repo 'app') -c Release -o $bin "-p:Version=$version" "-p:EngineDir=$engineDir\" 2>&1
    if ($LASTEXITCODE) { $log | Select-String 'error' | Select-Object -First 20 | ForEach-Object { $_.Line }; throw 'Build failed.' }

    $out = Join-Path $repo 'download'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    Get-ChildItem -LiteralPath $out -Filter 'Plex-Library-Helper*' | Remove-Item   # only the current version is kept
    $name = "Plex-Library-Helper-$version.exe"
    Copy-Item -LiteralPath (Join-Path $bin 'Plex Library Helper.exe') -Destination (Join-Path $out $name)
    $bytes = (Get-Item (Join-Path $out $name)).Length
    [ordered]@{ version = $version; file = $name; bytes = $bytes; built = (Get-Date).ToString('yyyy-MM-dd') } | ConvertTo-Json |
        Out-File -LiteralPath (Join-Path $out 'latest.json') -Encoding ascii
    "Built download\$name (version $version, $([math]::Round($bytes / 1KB)) KB) and latest.json"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
