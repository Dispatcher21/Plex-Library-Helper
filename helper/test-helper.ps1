# Offline tests for the Library Helper's quarantine rules. Uses throwaway folders under %TEMP%; touches nothing else.
$ErrorActionPreference = 'Stop'
$agent = Join-Path $PSScriptRoot 'library-helper.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($agent, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
$QuarantineDir = '_TO_DELETE'; $LabelPrefix = 'pld:'; $CompressPrefix = 'pldc:'; $LogDir = Join-Path $env:TEMP 'pld-test-logs'
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

    # 9. Compression labels: own prefix (older helpers ignore it), options, progress
    $c = Parse-Label 'Pldc:k2x-9ab:c:555:queued:p=4kh;a=small;r=plex+game'
    Check 'compress label parsed (capitalised by Plex)' ($c.Prefix -eq 'pldc:' -and $c.Action -eq 'c' -and $c.MediaId -eq '555' -and $c.State -eq 'queued')
    Check 'compress label keeps its prefix' ((Job-Label $c 'run' '37;3300;Encoding') -eq 'pldc:k2x-9ab:c:555:run:37;3300;Encoding')
    Check 'old helpers would ignore compress labels' (-not 'pldc:x:c:1:queued'.StartsWith('pld:', [StringComparison]::OrdinalIgnoreCase))
    $o = Parse-CompressOptions $c.Info
    Check 'options: preset/audio/rules' ($o.preset -eq '4kh' -and $o.audio -eq 'small' -and $o.rules.plex -and $o.rules.game -and -not $o.rules.idle -and -not $o.rules.night)
    Check 'options: audio defaults to keep' ((Parse-CompressOptions 'p=1080n').audio -eq 'keep')
    Check 'info formatting has no commas' ((Fmt-Info @{ p = '4kh'; b = 123; q = 94.6 }) -eq 'b=123;p=4kh;q=94.6')

    # 10. Compression worker rules (compress.ps1)
    . (Join-Path $PSScriptRoot 'compress.ps1')
    $hdr4k = [pscustomobject]@{ Width = 3840; Height = 2160; Hdr = $true; DvProfile = 7; BitDepth = 10; Primaries = 'bt2020'; Transfer = 'smpte2084'; Matrix = 'bt2020nc' }
    $scope = [pscustomobject]@{ Width = 3840; Height = 1600; Hdr = $true; DvProfile = 0; BitDepth = 10; Primaries = 'bt2020'; Transfer = 'smpte2084'; Matrix = 'bt2020nc' }
    $sdr1080 = [pscustomobject]@{ Width = 1920; Height = 1080; Hdr = $false; DvProfile = 0; BitDepth = 8; Primaries = 'bt709'; Transfer = 'bt709'; Matrix = 'bt709' }
    Check '4K preset refused on a 1080p file' ([bool](Preset-Problem $Presets['4kh'] $sdr1080))
    Check '4K preset fine on a scope 4K file' (-not (Preset-Problem $Presets['4kn'] $scope))
    Check 'Dolby Vision profile 5 refused' ([bool](Preset-Problem $Presets['4kh'] ([pscustomobject]@{ Width = 3840; Height = 2160; DvProfile = 5 })))
    $gpu4k = (Encode-Args $Presets['4kh'] $hdr4k 'in.mkv' 'out.hevc' $null) -join ' '
    Check '4K GPU: frames stay on the GPU, raw HEVC out, HDR tags kept' ($gpu4k -match 'hwaccel_output_format d3d11' -and $gpu4k -match 'hevc_mp4toannexb' -and $gpu4k -match 'color_trc smpte2084' -and $gpu4k -notmatch ' -vf ')
    $cpu4k = (Encode-Args $Presets['4kx'] $hdr4k 'in.mkv' 'out.mkv' $null) -join ' '
    Check '4K Extreme: x265 with Dolby Vision forced on and a VBV cap' ($cpu4k -match 'libx265' -and $cpu4k -match '-dolbyvision 1' -and $cpu4k -match 'vbv-maxrate=40000')
    $gpu1080 = (Encode-Args $Presets['1080n'] $scope 'in.mkv' 'out.hevc' $null) -join ' '
    Check '1080p from HDR: tone-mapped, fitted to 1920 wide, HDR tags stripped, SDR tags set' ($gpu1080 -match 'tonemap' -and $gpu1080 -match 'w=1920:h=-2' -and $gpu1080 -match 'type=MASTERING_DISPLAY_METADATA' -and $gpu1080 -match 'color_trc bt709' -and $gpu1080 -notmatch 'hwaccel_output_format')
    $sdrKeep = (Encode-Args $Presets['1080h'] $sdr1080 'in.mkv' 'out.hevc' $null) -join ' '
    Check '1080p SDR source stays 8-bit main profile, no filters' ($sdrKeep -match 'profile:v main ' -and $sdrKeep -notmatch ' -vf ')
    Check 'overnight window wraps midnight' ((In-Window '23:00-07:00' ([datetime]'2026-01-01 23:30')) -and (In-Window '23:00-07:00' ([datetime]'2026-01-02 06:59')) -and -not (In-Window '23:00-07:00' ([datetime]'2026-01-02 12:00')))
    Check 'daytime window' ((In-Window '09:00-17:00' ([datetime]'2026-01-01 10:00')) -and -not (In-Window '09:00-17:00' ([datetime]'2026-01-01 18:00')))
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$pass passed, $fail failed"
if ($fail) { exit 1 }
