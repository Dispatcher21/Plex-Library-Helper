# Builds download/Plex-Library-Helper.zip: the one download every PC uses (the dashboard links to it).
# Run after changing anything in helper\, and commit the zip with the change.
#   powershell -ExecutionPolicy Bypass -File make-helper-download.ps1
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src = Join-Path $repo 'helper'
$files = 'Set up Plex Library Helper.cmd', 'Check status.cmd', 'Stop and remove.cmd', 'README.md',
    'library-helper.ps1', 'compress.ps1', 'install-helper.ps1', 'uninstall-helper.ps1'

$stage = Join-Path $env:TEMP ("pld-zip-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$dir = Join-Path $stage 'Plex Library Helper'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText((Join-Path $src $f))
        # Windows line endings everywhere (.cmd files misbehave without them); no BOM except for PowerShell,
        # which needs one to read non-ASCII text correctly in Windows PowerShell 5.1
        $text = ($text.TrimStart([char]0xFEFF) -replace "`r?`n", "`r`n")
        [IO.File]::WriteAllText((Join-Path $dir $f), $text, (New-Object Text.UTF8Encoding ($f -like '*.ps1')))
    }
    $version = [regex]::Match([IO.File]::ReadAllText((Join-Path $src 'library-helper.ps1')), "\`$Version = '([^']+)'").Groups[1].Value
    "Plex Library Helper $version`r`n`r`nDouble-click 'Set up Plex Library Helper.cmd' on each PC. See README.md." |
        Out-File -LiteralPath (Join-Path $dir 'VERSION.txt') -Encoding ascii
    $out = Join-Path $repo 'download'
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $zip = Join-Path $out 'Plex-Library-Helper.zip'
    Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    # Not Compress-Archive: in Windows PowerShell 5.1 it writes "\" in entry names, which other tools reject
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($f in Get-ChildItem -LiteralPath $dir -File) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, "Plex Library Helper/$($f.Name)") | Out-Null
        }
    } finally { $z.Dispose() }
    "Built $zip (version $version, $([math]::Round((Get-Item $zip).Length / 1KB)) KB)"
} finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
