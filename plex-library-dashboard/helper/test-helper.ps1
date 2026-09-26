# Offline tests for the Library Helper's quarantine rules. Uses throwaway folders under %TEMP%; touches nothing else.
$ErrorActionPreference = 'Stop'
$agent = Join-Path $PSScriptRoot 'library-helper.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($agent, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$QuarantineDir = '_TO_DELETE'; $LabelPrefix = 'pld:'; $LogDir = Join-Path $env:TEMP 'pld-test-logs'
function Log($m, $l) { }

$root = Join-Path $env:TEMP ("pld-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$drive = "$root\"
$script:TestDrive = $drive
$script:LocalServer = $false
$shares = @{ '\\testpc\plex server' = $root.TrimEnd('\') }
function MakeFile($p, $mb) { New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; $fs = [IO.File]::Create($p); $fs.SetLength($mb * 1MB); $fs.Close(); (Get-Item $p).Length }
function Plexify($p) { '\\TESTPC\PLEX Server' + $p.Substring($root.Length) }
$pass = 0; $fail = 0
function Check($name, $cond) { if ($cond) { $script:pass++; "PASS  $name" } else { $script:fail++; "FAIL  $name" } }

try {
    # 1. Movie in its own folder -> whole folder moves (with artwork)
    $f1 = "$root\Movies\Dune (2021)\Dune_t00.mkv"; $s1 = MakeFile $f1 400; MakeFile "$root\Movies\Dune (2021)\poster.jpg" 1 | Out-Null
    $r = Quarantine ([pscustomobject]@{ JobId = 'j1'; MediaId = '1' }) ([pscustomobject]@{ title = 'Dune'; year = 2021 }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = (Plexify $f1); size = $s1 }) }) $shares
    Check 'own folder moved as a unit' ((-not (Test-Path "$root\Movies\Dune (2021)")) -and (Test-Path "$root\_TO_DELETE\*\Movies\Dune (2021)\poster.jpg"))
    Check 'refresh path is the Movies folder in Plex terms' ($r.refresh -eq '\\TESTPC\PLEX Server\Movies')

    # 2. Loose file directly in Movies next to other movies -> only that file (+ same-name .srt) moves
    MakeFile "$root\Movies\Other (2020)\Other.mkv" 400 | Out-Null
    $f2 = "$root\Movies\Loose.2024.mkv"; $s2 = MakeFile $f2 350; MakeFile "$root\Movies\Loose.2024.en.srt" 1 | Out-Null
    Quarantine ([pscustomobject]@{ JobId = 'j2'; MediaId = '2' }) ([pscustomobject]@{ title = 'Loose'; year = 2024 }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = (Plexify $f2); size = $s2 }) }) $shares | Out-Null
    Check 'loose file moved, Movies folder kept' ((Test-Path "$root\Movies\Other (2020)\Other.mkv") -and -not (Test-Path $f2) -and -not (Test-Path "$root\Movies\Loose.2024.en.srt") -and (Test-Path "$root\_TO_DELETE\*\Movies\Loose.2024.en.srt"))

    # 3. Collection folder with two movies -> only the chosen file moves
    $c1 = "$root\Movies\Collection\Movie A.mkv"; $sc1 = MakeFile $c1 400; MakeFile "$root\Movies\Collection\Movie B.mkv" 400 | Out-Null
    Quarantine ([pscustomobject]@{ JobId = 'j3'; MediaId = '3' }) ([pscustomobject]@{ title = 'A'; year = 1 }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = (Plexify $c1); size = $sc1 }) }) $shares | Out-Null
    Check 'collection: other movie untouched' ((Test-Path "$root\Movies\Collection\Movie B.mkv") -and -not (Test-Path $c1))

    # 4. Size mismatch -> refuses, file stays
    $f4 = "$root\Movies\Size (2000)\Size.mkv"; MakeFile $f4 100 | Out-Null
    $threw = $false; try { Quarantine ([pscustomobject]@{ JobId = 'j4'; MediaId = '4' }) ([pscustomobject]@{ title = 'S' }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = (Plexify $f4); size = 12345 }) }) $shares | Out-Null } catch { $threw = $true }
    Check 'size mismatch refused and file kept' ($threw -and (Test-Path $f4))

    # 5. Missing file -> refuses
    $threw = $false; try { Quarantine ([pscustomobject]@{ JobId = 'j5'; MediaId = '5' }) ([pscustomobject]@{ title = 'M' }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = '\\TESTPC\PLEX Server\Movies\Nope\nope.mkv'; size = 1 }) }) $shares | Out-Null } catch { $threw = $true }
    Check 'missing file refused' $threw

    # 6. File on another PC -> skipped, not an error
    $r6 = Quarantine ([pscustomobject]@{ JobId = 'j6'; MediaId = '6' }) ([pscustomobject]@{ title = 'X' }) ([pscustomobject]@{ Part = @([pscustomobject]@{ file = '\\GAMING-PC\D\Movies\X.mkv'; size = 1 }) }) $shares
    Check 'other PC skipped' ($r6.skip -eq $true)

    # 7. Manifest written for restore
    $man = Get-Content "$root\_TO_DELETE\manifest.jsonl" | ForEach-Object { $_ | ConvertFrom-Json }
    Check 'manifest has from/to for every move' (($man | Where-Object { $_.from -and $_.to }).Count -ge 4)

    # 8. Label round-trip
    $j = Parse-Label 'pld:abc-12:q:98765:queued'
    Check 'label parse' ($j.JobId -eq 'abc-12' -and $j.Action -eq 'q' -and $j.MediaId -eq '98765' -and $j.State -eq 'queued')
    Check 'label with info' ((Job-Label $j 'fail' 'Size on disk: a,b') -eq 'pld:abc-12:q:98765:fail:Size on disk: a b')
    $fp = Parse-Label 'pld:abc-12:q:98765:fail:Size on disk: 5 bytes'
    Check 'info keeps colons' ($fp.Info -eq 'Size on disk: 5 bytes')
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$pass passed, $fail failed"
if ($fail) { exit 1 }
