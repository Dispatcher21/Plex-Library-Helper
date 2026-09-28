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
    Check '4K GPU: frames stay on the GPU with a big enough frame pool, raw HEVC out, HDR tags kept' ($gpu4k -match 'hwaccel_output_format d3d11 -extra_hw_frames 16' -and $gpu4k -match 'hevc_mp4toannexb' -and $gpu4k -match 'color_trc smpte2084' -and $gpu4k -notmatch ' -vf ')
    $cpu4k = (Encode-Args $Presets['4kx'] $hdr4k 'in.mkv' 'out.mkv' $null) -join ' '
    Check '4K Extreme: x265 with Dolby Vision forced on and a VBV cap' ($cpu4k -match 'libx265' -and $cpu4k -match '-dolbyvision 1' -and $cpu4k -match 'vbv-maxrate=40000')
    $gpu1080 = (Encode-Args $Presets['1080n'] $scope 'in.mkv' 'out.hevc' $null) -join ' '
    Check '1080p from HDR: tone-mapped, fitted to 1920 wide, HDR tags stripped, SDR tags set' ($gpu1080 -match 'tonemap' -and $gpu1080 -match 'w=1920:h=-2' -and $gpu1080 -match 'type=MASTERING_DISPLAY_METADATA' -and $gpu1080 -match 'color_trc bt709' -and $gpu1080 -notmatch 'hwaccel_output_format')
    $sdrKeep = (Encode-Args $Presets['1080h'] $sdr1080 'in.mkv' 'out.hevc' $null) -join ' '
    Check '1080p SDR source stays 8-bit main profile, no filters' ($sdrKeep -match 'profile:v main ' -and $sdrKeep -notmatch ' -vf ')
    Check 'overnight window wraps midnight' ((In-Window '23:00-07:00' ([datetime]'2026-01-01 23:30')) -and (In-Window '23:00-07:00' ([datetime]'2026-01-02 06:59')) -and -not (In-Window '23:00-07:00' ([datetime]'2026-01-02 12:00')))
    Check 'options: "pause for any playback" rule' ((Parse-CompressOptions 'p=4kh;r=plexall').rules.plexall -and -not (Parse-CompressOptions 'p=4kh;r=plex').rules.plexall)

    # 11. Plex pause rule: only transcoding counts by default; paused sessions never count
    $script:PlexUrl = 'http://plex.test'; $script:PlexToken = 'x'
    function Invoke-WebRequest { [pscustomobject]@{ Content = $script:FakeSessions } }
    $script:FakeSessions = '<MediaContainer size="2"><Video title="Stuart Little"><Player state="playing"/></Video><Video title="Blue''s Clues"><Player state="paused"/><TranscodeSession videoDecision="transcode"/></Video></MediaContainer>'
    Check 'direct play = watching; paused transcode ignored' ((Plex-Activity) -eq 'watching')
    Check 'default rule keeps encoding during direct play' ((Pause-Reason @{ plex = $true }) -eq '')
    Check '"any playback" rule pauses during direct play' ((Pause-Reason @{ plexall = $true }) -eq 'someone is watching Plex')
    $script:FakeSessions = '<MediaContainer size="1"><Video title="Dune"><Player state="playing"/><TranscodeSession videoDecision="transcode"/></Video></MediaContainer>'
    Check 'a playing transcode pauses' ((Pause-Reason @{ plex = $true }) -eq 'Plex is transcoding a stream')
    $script:FakeSessions = '<MediaContainer size="1"><Video title="Dune"><Player state="playing"/><TranscodeSession videoDecision="copy"/></Video></MediaContainer>'
    Check 'direct stream (video copied) is not transcoding' ((Plex-Activity) -eq 'watching')
    $script:FakeSessions = '<MediaContainer size="0"></MediaContainer>'
    Check 'nothing playing' ((Plex-Activity) -eq '')
    Remove-Item Function:\Invoke-WebRequest

    # 12. Pre-flight: free space on a folder, and a write test that leaves nothing behind
    $pf = Join-Path $root 'preflight'; New-Item -ItemType Directory -Force $pf | Out-Null
    Check 'free space readable' ((Free-Bytes $pf) -gt 0)
    $script:Work = $pf
    $threw = $false; try { Preflight-Check ([pscustomobject]@{ Size = 1MB }) $pf } catch { $threw = $true }
    Check 'pre-flight passes on a writable folder and cleans up' (-not $threw -and -not (Get-ChildItem -LiteralPath $pf -Force))
    $threw = $false; try { Preflight-Check ([pscustomobject]@{ Size = 1MB }) (Join-Path $root 'no-such-folder') } catch { $threw = $_.Exception.Message -match "Can't write" }
    Check 'pre-flight refuses an unwritable folder' $threw
    $threw = $false; try { Preflight-Check ([pscustomobject]@{ Size = 1PB }) $pf } catch { $threw = $_.Exception.Message -match 'Not enough free space' }
    Check 'pre-flight refuses when there is no room' $threw

    # 13. Setup in a new folder while an older copy is installed (browser saved the download as "(1)")
    $oldCopy = Join-Path $root 'old copy'; $newCopy = Join-Path $root 'new copy (1)'
    New-Item -ItemType Directory -Force "$oldCopy\jobs", "$oldCopy\tools", $newCopy | Out-Null
    '{"serverName":"Home PC"}' | Out-File "$oldCopy\config.json" -Encoding UTF8
    'exe' | Out-File "$oldCopy\tools\dovi_tool.exe"
    function Get-ScheduledTask { [pscustomobject]@{ Actions = @([pscustomobject]@{ Arguments = "-NoProfile -File `"$oldCopy\library-helper.ps1`"" }) } }
    function Write-Host { }
    $saveRoot = $Root; $saveCfg = $ConfigPath
    $Root = $newCopy; $ConfigPath = "$newCopy\config.json"
    @{ title = 'Transformers'; workerPid = $PID } | ConvertTo-Json | Out-File "$oldCopy\jobs\busy.json" -Encoding UTF8   # this test's own PowerShell = a live worker
    Check 'refuses to take over while the old copy is encoding' ((-not (Replace-OldCopy)) -and -not (Test-Path $ConfigPath))
    Remove-Item "$oldCopy\jobs\busy.json"
    Check 'takes over an idle old copy: keeps sign-in and dovi_tool' ((Replace-OldCopy) -and (Test-Path $ConfigPath) -and (Test-Path "$newCopy\tools\dovi_tool.exe"))
    $Root = $oldCopy
    Check 'same folder: nothing to replace' (Replace-OldCopy)
    $Root = $saveRoot; $ConfigPath = $saveCfg
    Remove-Item Function:\Get-ScheduledTask, Function:\Write-Host

    # 14. Phone notifications (ntfy)
    $DashboardUrl = 'https://example.test/'
    $PresetLabels = @{ '4kh' = '4K High' }
    $script:Cfg = [pscustomobject]@{ notify = [pscustomobject]@{ enabled = $true; server = 'https://ntfy.example/'; topic = 'pld-test' } }
    $jfC = [pscustomobject]@{ mode = 'compress'; title = 'Amélie'; year = 2001; preset = '4kh' }
    $jfE = [pscustomobject]@{ mode = 'estimate'; title = 'Dune'; year = 2021; preset = '4kh' }
    $n = Job-Notification $jfC 'done' ([pscustomobject]@{ bytes = 15GB; srcBytes = 70GB }) ''
    Check 'compressed message' ($n.title -eq 'Compressed: Amélie (2001)' -and $n.message -like "4K High: 70.0 GB $([char]0x2192) 15.0 GB (21%)*")
    $n = Job-Notification $jfE 'done' ([pscustomobject]@{ bytes = 20GB; srcBytes = 80GB; secs = 5400; vmaf = 94.6 }) ''
    Check 'estimate message' ($n.title -eq 'Estimate ready: Dune (2021)' -and $n.message -eq '4K High: about 20.0 GB (25%) of 80.0 GB, about 1 h 30 min to encode, quality 94.6/100.')
    Check 'failure message' ((Job-Notification $jfC 'fail' $null 'Not enough free space').title -eq 'Compression failed: Amélie (2001)')
    Check 'no message for jobs you stopped' ($null -eq (Job-Notification $jfC 'fail' $null 'Stopped from the dashboard'))
    function Invoke-RestMethod { param($Method, $Uri, $Body, $ContentType, $TimeoutSec) $script:Sent = @{ Uri = $Uri; Json = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json } }
    Send-Ntfy 'Compressed: Amélie' "70 GB $([char]0x2192) 15 GB" 'white_check_mark'
    Check 'ntfy: JSON to the server root with topic, click link and UTF-8 text' ($script:Sent.Uri -eq 'https://ntfy.example' -and $script:Sent.Json.topic -eq 'pld-test' -and $script:Sent.Json.click -eq 'https://example.test/' -and $script:Sent.Json.title -eq 'Compressed: Amélie' -and $script:Sent.Json.message -eq "70 GB $([char]0x2192) 15 GB" -and $script:Sent.Json.tags[0] -eq 'white_check_mark')
    function Invoke-RestMethod { throw 'network down' }
    $threw = $false; try { Notify-Job $jfC 'done' ([pscustomobject]@{ bytes = 1GB; srcBytes = 2GB }) '' } catch { $threw = $true }
    Check 'a failed notification never breaks the job' (-not $threw)
    Remove-Item Function:\Invoke-RestMethod
    $script:Cfg.notify.enabled = $false; $script:Sent = $null
    Notify-Job $jfC 'done' ([pscustomobject]@{ bytes = 1GB; srcBytes = 2GB }) ''
    Check 'nothing sent when turned off' ($null -eq $script:Sent)
    Check 'topic: long and random' ((New-Topic) -match '^pld-[a-z2-9]{20}$' -and (New-Topic) -ne (New-Topic))

    # 17. Show quarantines: episode copies listed on the show's label; season folders never moved whole
    $sd = "$root\Shows\Test Show (2020)\Season 1"
    $f1 = "$sd\Test Show - S01E01.mkv"; $s1 = MakeFile $f1 5; MakeFile "$sd\Test Show - S01E01.en.srt" 1 | Out-Null
    MakeFile "$sd\Test Show - S01E010.en.srt" 1 | Out-Null   # another episode's subtitles with a similar name
    $f2a = "$sd\Test Show - S01E02.mkv"; $s2a = MakeFile $f2a 5
    $f2b = "$sd\Test Show - S01E02 (WEB).mkv"; $s2b = MakeFile $f2b 4
    $f3 = "$sd\Test Show - S01E03.mkv"; $s3 = MakeFile $f3 5
    $ep = { param($n, $media) [pscustomobject]@{ parentIndex = 1; index = $n; title = "Ep $n"; Media = $media } }
    $md = { param($id, $file, $size) [pscustomobject]@{ id = $id; Part = @([pscustomobject]@{ file = (Plexify $file); size = $size }) } }
    $script:FakeEps = @(
        (& $ep 1 @(& $md 101 $f1 $s1)),
        (& $ep 2 @((& $md 201 $f2a $s2a), (& $md 202 $f2b $s2b))),
        (& $ep 3 @(& $md 301 $f3 $s3)))
    $script:ShowLabels = @()
    function Pms($method, $path, $params) {
        if ($method -eq 'GET' -and $path -like '*/allLeaves') { return @{ MediaContainer = @{ Metadata = $script:FakeEps } } }
        if ($method -eq 'GET' -and $path -match '^/library/metadata/\d+$') { return @{ MediaContainer = @{ Metadata = @(@{ Label = @($script:ShowLabels | ForEach-Object { @{ tag = $_ } }) }) } } }
        if ($method -eq 'PUT') {
            if ($params.ContainsKey('label[].tag.tag-')) { $script:ShowLabels = @($script:ShowLabels | Where-Object { $_ -ne $params['label[].tag.tag-'] }) }
            else { $script:ShowLabels = @($params.Keys | Where-Object { $_ -like 'label*tag.tag' } | Sort-Object | ForEach-Object { $params[$_] }) }
        }
        $null
    }
    $script:Cfg = [pscustomobject]@{ serverName = 'Test' }
    $runShow = { param($tag) $script:ShowLabels = @($tag)
        $w = [pscustomobject]@{ Job = (Parse-Label $tag); Section = '5'; Item = [pscustomobject]@{ ratingKey = '900'; title = 'Test Show'; year = 2020 }; IsShow = $true }
        Process-ShowJob $w $shares; $script:ShowLabels }
    # clean-up: the WEB copy of E02 goes (the other copy survives); E03's only copy is kept by the guard
    $after = & $runShow 'pld:t1-a:qm:sh900:queued:ids=202+301;n=2;s=S01'
    Check 'show clean-up: duplicate moved, last copy kept by the guard' ((-not (Test-Path $f2b)) -and (Test-Path $f2a) -and (Test-Path $f3) -and ("$after" -match ':done:.*f=1;n=1;s=S01;x=S01E03'))
    Check 'show clean-up: the season folder and other episodes stay put' ((Test-Path $sd) -and (Test-Path $f1) -and (Test-Path "$sd\Test Show - S01E01.en.srt"))
    # removing a season on purpose (qma): E01 moves with its subtitles, no guard
    $after = & $runShow 'pld:t1-b:qma:sh900:queued:ids=101;n=1;s=S01'
    Check 'season quarantine: episode and its subtitles moved, labelled done' ((-not (Test-Path $f1)) -and -not (Test-Path "$sd\Test Show - S01E01.en.srt") -and (Test-Path "$root\_TO_DELETE\*\Shows\Test Show (2020)\Season 1\Test Show - S01E01.en.srt") -and ("$after" -match ':done:.*n=1'))
    $man = @(Get-Content "$root\_TO_DELETE\manifest.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.job -eq 't1-b' })
    Check "a similar-named episode's subtitles stay" (Test-Path "$sd\Test Show - S01E010.en.srt")
    Check 'show quarantine recorded with episode names' ($man.Count -ge 1 -and $man[0].title -eq 'Test Show - S01E01 - Ep 1')
    $after = & $runShow 'pld:t1-c:qma:sh900:queued:ids=999;n=1;s=S01'
    Check 'unknown episode: job fails instead of hanging' ("$after" -match ':fail:')
    $after = & $runShow 'pld:t1-d:qma:sh900:queued:ids=101+999;n=2;s=S01'
    Check 'already-moved file: reported, not crashed' ("$after" -match ':fail:.*File not found')
    Remove-Item Function:\Pms

    # 18. Compressing a season: which episode files get picked
    $cd = "$root\Shows\Comp Show (2019)"
    $c1 = "$cd\Season 1\Comp - S01E01.mkv"; MakeFile $c1 3 | Out-Null
    $c1b = "$cd\Season 1\Comp - S01E01 (big).mkv"; MakeFile $c1b 6 | Out-Null
    $c2 = "$cd\Season 1\Comp - S01E02.mkv"; MakeFile $c2 3 | Out-Null
    $c2c = "$cd\Season 1\Comp Show (2019) - S01E02 - Compressed 1080p Normal.mkv"; MakeFile $c2c 1 | Out-Null
    $c3 = "$cd\Season 2\Comp - S02E01.mkv"; MakeFile $c3 3 | Out-Null
    $pm = { param($id, $file, $mb) [pscustomobject]@{ id = $id; duration = 1300000; Part = @([pscustomobject]@{ file = (Plexify $file); size = $mb * 1MB }) } }
    $script:FakeEps = @(
        [pscustomobject]@{ parentIndex = 1; index = 1; title = 'One'; Media = @((& $pm 11 $c1 3), (& $pm 12 $c1b 6)) },
        [pscustomobject]@{ parentIndex = 1; index = 2; title = 'Two'; Media = @((& $pm 21 $c2 3), (& $pm 22 $c2c 1)) },
        [pscustomobject]@{ parentIndex = 2; index = 1; title = 'Three'; Media = @(& $pm 31 $c3 3) })
    function Pms($method, $path, $params) { if ($path -like '*/allLeaves') { return @{ MediaContainer = @{ Metadata = $script:FakeEps } } }; $null }
    $s1 = Show-CompressItems '77' 'S01' $shares
    Check 'season compress: biggest copy picked, compressed episodes skipped, other seasons left out' ($s1.items.Count -eq 1 -and $s1.items[0].ep -eq 'S01E01' -and $s1.items[0].source -eq $c1b -and $s1.already -eq 1 -and $s1.items[0].durationMs -eq 1300000)
    $sa = Show-CompressItems '77' 'all' $shares
    Check 'whole-show compress: every season, in order' (($sa.items | ForEach-Object { $_.ep }) -join ',' -eq 'S01E01,S02E01')
    Remove-Item Function:\Pms
    Check 'season names' ((Scope-Name 'S02') -eq 'Season 2' -and (Scope-Name 'S00') -eq 'Specials' -and (Scope-Name 'all') -eq 'whole show')
    $PresetLabels = @{ '1080n' = '1080p Normal' }
    $jfS = [pscustomobject]@{ mode = 'compress'; title = 'Comp Show'; year = 2019; preset = '1080n'; scope = 'S01'; items = @(1, 2) }
    $ns = Job-Notification $jfS 'done' ([pscustomobject]@{ bytes = 3GB; srcBytes = 12GB; episodes = 10; done = 9; failed = 1; problem = 'S01E05: file not found' }) ''
    Check 'season notification: counts and the problem, flagged' ($ns.title -eq 'Compressed: Comp Show (2019) - Season 1' -and $ns.message -like '1080p Normal: 9 of 10 episodes, 12.0 GB * 3.0 GB (25%). 1 not done: S01E05: file not found' -and $ns.priority -eq 'high')

    # 19. MakeMKV rip watcher: reading the disc, estimating, following a rip
    . (Join-Path $PSScriptRoot 'rips.ps1')
    $disc = Join-Path $root 'disc'
    New-Item -ItemType Directory -Force "$disc\BDMV\PLAYLIST", "$disc\BDMV\STREAM" | Out-Null
    # a minimal Blu-ray playlist: header, then play items (clip name, in/out time at 45 kHz)
    function Write-Mpls($path, [object[]]$items) {
        $ms = New-Object IO.MemoryStream
        $w = { param([long]$v, [int]$n) for ($k = $n - 1; $k -ge 0; $k--) { $ms.WriteByte([byte](($v -shr (8 * $k)) -band 0xFF)) } }
        $ms.Write([Text.Encoding]::ASCII.GetBytes('MPLS0200'), 0, 8); & $w 40 4; & $w 0 4; & $w 0 4
        while ($ms.Length -lt 40) { $ms.WriteByte(0) }
        & $w (6 + 22 * $items.Count) 4; & $w 0 2; & $w $items.Count 2; & $w 0 2
        foreach ($it in $items) {
            & $w 20 2; $ms.Write([Text.Encoding]::ASCII.GetBytes($it[0]), 0, 5); $ms.Write([Text.Encoding]::ASCII.GetBytes('M2TS'), 0, 4)
            & $w 0 2; & $w 0 1; & $w 0 4; & $w ([long]($it[1] * 45000)) 4
        }
        [IO.File]::WriteAllBytes($path, $ms.ToArray())
    }
    Write-Mpls "$disc\BDMV\PLAYLIST\00800.mpls" @(,@('00100', 7200))              # the film, 2 h
    Write-Mpls "$disc\BDMV\PLAYLIST\00801.mpls" @(,@('00100', 7200))              # same clips again (a duplicate)
    Write-Mpls "$disc\BDMV\PLAYLIST\00100.mpls" @(,@('00200', 1500))              # a 25 min extra
    Write-Mpls "$disc\BDMV\PLAYLIST\00001.mpls" @(,@('00300', 30))                # a menu loop: too short
    foreach ($c in @(@('00100', 40), @('00200', 5), @('00300', 1))) { $fs = [IO.File]::Create("$disc\BDMV\STREAM\$($c[0]).m2ts"); $fs.SetLength($c[1] * 1MB); $fs.Close() }
    $titles = @(Get-DiscTitles "$disc\")
    Check 'disc: titles with lengths and sizes, duplicates and short ones left out' ($titles.Count -eq 2 -and $titles[0].Seconds -eq 7200 -and $titles[0].Bytes -eq 40MB -and $titles[1].Bytes -eq 5MB)
    Check 'estimate: a movie disc means the film' ((Expected-Bytes $titles 1MB) -eq 40MB)
    $tv = @(1..4 | ForEach-Object { [pscustomobject]@{ Seconds = 1320; Bytes = (5 + $_) * 1MB } })
    Check 'estimate: a TV disc means a typical episode' ((Expected-Bytes $tv 1MB) -eq 8MB)
    Check 'estimate: a growing file never shows 100%' ((Expected-Bytes $titles 45MB) -gt 45MB)

    $dest = Join-Path $root 'rips\Coraline (2009)'; New-Item -ItemType Directory -Force $dest | Out-Null
    $rf = "$dest\Coraline_t00.mkv"
    $st = @{ active = $false }
    $t0 = Get-Date
    Check 'no rip: nothing to report' ($null -eq (Rip-Step $st $t0 $true @($dest) @() $null))
    $fs = [IO.File]::Create($rf); $fs.SetLength(10MB); $fs.Close()
    $d0 = @([pscustomobject]@{ Root = "$disc\"; Label = 'CORALINE'; Bytes = 50MB })
    $s1 = Rip-Step $st $t0 $true @($dest) $d0 $null
    $fs = [IO.File]::Open($rf, 'Open'); $fs.SetLength(20MB); $fs.Close()
    $s2 = Rip-Step $st $t0.AddSeconds(10) $true @($dest) $d0 $null
    Check 'rip: disc name, folder, file, bytes, speed and estimated %' ($s2.state -eq 'ripping' -and $s2.disc -eq 'CORALINE' -and $s2.folder -eq 'Coraline (2009)' -and $s2.file -eq 'Coraline_t00.mkv' -and $s2.bytes -eq 20MB -and $s2.rate -eq 1MB -and $s2.percent -eq 50 -and -not $s2.exact -and $s2.secsLeft -eq 20)
    $gui = [pscustomobject]@{ Current = 60; Total = 30 }
    $s3 = Rip-Step $st $t0.AddSeconds(20) $true @($dest) $d0 $gui
    Check "rip: MakeMKV's own bars win when readable" ($s3.exact -and $s3.percent -eq 60 -and $s3.totalPercent -eq 30)
    (Get-Item $rf).LastWriteTime = $t0.AddSeconds(20)
    $s4 = Rip-Step $st $t0.AddSeconds(200) $true @($dest) $d0 $null
    Check 'rip: done once the file has stopped growing' ($s4.state -eq 'done' -and $s4.done.Count -eq 1 -and $s4.done[0].bytes -eq 20MB -and -not $st.active)

    # The real-rip bug: MakeMKV's window keeps naming the finished file and its bars sit at 100%
    $st = @{ active = $false }
    $rf2 = "$dest\Second_t00.mkv"; $fs = [IO.File]::Create($rf2); $fs.SetLength(10MB); $fs.Close()
    $guiNamed = [pscustomobject]@{ Current = 100; Total = 100; OutputFile = $rf2; SourceBytes = 10MB }
    $t1 = Get-Date
    $null = Rip-Step $st $t1 $true @() $d0 ([pscustomobject]@{ Current = 90; Total = 90; OutputFile = $rf2; SourceBytes = 10MB })
    (Get-Item $rf2).LastWriteTime = $t1
    $a = Rip-Step $st $t1.AddSeconds(30) $true @() $d0 $guiNamed
    Check 'rip: finished file named by the window, bars at 100%: done, not "ripping" forever' ($a.state -eq 'done' -and -not $st.active)

    # 20. Rip channel: the dashboard link and the auto-compress switch coming back from ntfy
    $DashboardUrl = 'https://example.test/'
    $script:Cfg = [pscustomobject]@{ notify = [pscustomobject]@{ enabled = $true; server = 'https://ntfy.sh'; topic = 'pld-abc' }; rip = [pscustomobject]@{ enabled = $true } }
$JobsDir = Join-Path $root 'live-jobs'
    . (Join-Path $PSScriptRoot 'live.ps1')
    $DashboardUrl = 'https://example.test/'
    Check 'rip: dashboard link carries the topic after #' ((Dashboard-Link) -eq 'https://example.test/#ntfy=pld-abc')
    $script:Rip = @{ active = $true; id = 'r1' }; $script:RipCmdSince = $null
    function Invoke-WebRequest { param($Uri) $script:AskedUri = $Uri; [pscustomobject]@{ Content = (@(
        '{"id":"a1","event":"open"}',
        ('{"id":"a2","event":"message","message":' + ('{"cmd":"autocompress","id":"old","on":true}' | ConvertTo-Json) + '}'),
        ('{"id":"a3","event":"message","message":' + ('{"cmd":"autocompress","id":"r1","on":true}' | ConvertTo-Json) + '}')) -join "`n") } }
    $JobsDir = Join-Path $root 'live-jobs'; $PauseFile = Join-Path $JobsDir 'PAUSED'; $script:LiveStarted = (Get-Date).AddMinutes(-1); $script:CmdSince = $null
    Read-Commands
    Check 'rip: switch for this rip applied, others ignored, position remembered' ($script:Rip.autoCompress -eq $true -and $script:CmdSince -eq 'a3' -and $script:AskedUri -eq 'https://ntfy.sh/pld-abc-cmd/json?poll=1&since=10m')
    Remove-Item Function:\Invoke-WebRequest

    # 21. ntfy reachability explained in plain words (a VPN blocked it on the owner's PC)
    function Invoke-WebRequest { throw 'The operation has timed out.' }
    function Get-NetAdapter { @([pscustomobject]@{ Name = 'SurfsharkWireGuard'; InterfaceDescription = 'WireGuard Tunnel'; Status = 'Up' }, [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Realtek'; Status = 'Up' }) }
    $why = Test-Ntfy 'https://ntfy.sh'
    Check 'ntfy blocked by a VPN: says which and how to fix' ($why -match 'SurfsharkWireGuard' -and $why -match 'Bypasser' -and $why -notmatch 'Ethernet')
    function Invoke-WebRequest { 'ok' }
    Check 'ntfy reachable: nothing to report' ((Test-Ntfy 'https://ntfy.sh') -eq '')
    Remove-Item Function:\Invoke-WebRequest, Function:\Get-NetAdapter
    $mk = Read-MakeMkvInfo @('Source :', 'BD-RE', 'Source size :', '76763.2 M', 'Read rate :', '17.6 M/s', 'Output file :', 'G:/PLEX/MOVIES/HP/HP_t00.mkv', 'Output size :', '1700.2 M')
    Check "MakeMKV window: output file and source size read" ($mk.OutputFile -eq 'G:\PLEX\MOVIES\HP\HP_t00.mkv' -and $mk.SourceBytes -eq [long](76763.2 * 1MB))

    # 22. Pause switch and emptying _TO_DELETE from the dashboard
    $now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # (not called Cmd: PowerShell ignores case, so that would hijack every later 'cmd /c')
    function Ntfy-Msg($id, $obj, $age = 0) { '{"id":"' + $id + '","event":"message","time":' + ($now - $age) + ',"message":' + (($obj | ConvertTo-Json -Compress) | ConvertTo-Json) + '}' }
    function Serve($lines) { $script:Served = $lines -join "`n" }
    function Invoke-WebRequest { [pscustomobject]@{ Content = $script:Served } }
    function Publish-Live($o) { $script:Published += , $o }
    function Send-Ntfy { }
    $script:Published = @(); $script:CmdSince = $null
    Serve @((Ntfy-Msg 'p1' @{ cmd = 'pause'; pc = $env:COMPUTERNAME; on = $true }), (Ntfy-Msg 'p2' @{ cmd = 'pause'; pc = 'OTHER-PC'; on = $false }))
    Read-Commands
    Check 'pause from the dashboard: this PC paused, other PC''s command ignored' (Is-Paused)
    Serve @(Ntfy-Msg 'p3' @{ cmd = 'pause'; pc = $env:COMPUTERNAME; on = $false }); Read-Commands
    Check 'resume from the dashboard' (-not (Is-Paused))
    $trash2 = Join-Path $root 'live-trash\_TO_DELETE'; $script:TestDrive = Join-Path $root 'live-trash\'
    MakeFile "$trash2\2020-03-03\Movies\A.mkv" 2 | Out-Null; MakeFile "$trash2\2020-04-04\Movies\B.mkv" 3 | Out-Null
    function Trash-Roots { @($trash2) }
    $sum = Trash-Summary
    Check 'trash summary: batches with sizes, for the dashboard' ($sum.kind -eq 'trash' -and $sum.batches.Count -eq 2 -and $sum.total -eq 5MB)
    $b3 = "$trash2\2020-03-03"; $outside = Join-Path $root 'outside-trash'; MakeFile "$outside\keep.mkv" 1 | Out-Null
    Serve @((Ntfy-Msg 'e1' @{ cmd = 'emptytrash'; pc = $env:COMPUTERNAME; req = 'old1'; batches = @($b3) } 1200))
    Read-Commands
    Check 'empty: a request older than 10 minutes is ignored' (Test-Path $b3)
    Serve @((Ntfy-Msg 'e2' @{ cmd = 'emptytrash'; pc = $env:COMPUTERNAME; req = 'r1'; batches = @($b3, $outside) }))
    Read-Commands
    Check 'empty: the reported batch is deleted, a path it never reported is not' ((-not (Test-Path $b3)) -and (Test-Path "$outside\keep.mkv") -and ($script:Published | Where-Object { $_.kind -eq 'trashResult' -and $_.freed -eq 2MB }))
    MakeFile "$b3\Movies\A2.mkv" 1 | Out-Null
    $script:CmdSince = $null; Read-Commands
    Check 'empty: the same request never runs twice (ntfy keeps old messages)' (Test-Path $b3)
    Remove-Item Function:\Invoke-WebRequest, Function:\Publish-Live, Function:\Send-Ntfy, Function:\Trash-Roots
    $script:TestDrive = $drive

    # 23. Choosing an encoder for a job on this PC
    . (Join-Path $PSScriptRoot 'encoders.ps1')
    $amdPc = [pscustomobject]@{ encoders = @('amf', 'x265', 'x265slow', 'svtav1'); allowCpu = $true }
    $n100 = [pscustomobject]@{ encoders = @('qsv', 'x265', 'x265slow', 'svtav1'); allowCpu = $false }
    Check 'encoder: graphics card for normal levels' ((Choose-Encoder $amdPc 'high' '4k' 'hevc').encoder -eq 'amf')
    Check 'encoder: Extreme uses the processor''s efficient encoder when allowed' ((Choose-Encoder $amdPc 'extreme' '4k' 'hevc').encoder -eq 'x265slow')
    Check 'encoder: Extreme on a PC without processor jobs uses its graphics card' ((Choose-Encoder $n100 'extreme' '4k' 'hevc').encoder -eq 'qsv')
    Check 'encoder: AV1 falls back to the processor when allowed' ((Choose-Encoder $amdPc 'normal' '4k' 'av1').encoder -eq 'svtav1')
    Check 'encoder: a PC that can''t do the job leaves it for another' ($null -eq (Choose-Encoder $n100 'normal' '4k' 'av1'))
    Check 'encoder: old setups (no encoder list) keep AMD' ((Choose-Encoder ([pscustomobject]@{ allowCpu = $true }) 'normal' '4k' 'hevc').encoder -eq 'amf')
    $cal = [pscustomobject]@{ encoders = @('qsv'); allowCpu = $false; calibration = [pscustomobject]@{ qsv = [pscustomobject]@{ '4k' = [pscustomobject]@{ levels = [pscustomobject]@{ high = 23.5 } } } } }
    $c = Choose-Encoder $cal 'high' '4k' 'hevc'
    Check 'encoder: calibrated setting wins over the default' ($c.q -eq 23.5 -and $c.calibrated)
    Check 'encoder: default setting until calibrated' ((Choose-Encoder $cal 'normal' '4k' 'hevc').q -eq 25)
    Check 'options: AV1 request' ((Parse-CompressOptions 'p=4kh;v=av1').codec -eq 'av1' -and (Parse-CompressOptions 'p=4kh').codec -eq 'hevc')
    $q = (Codec-Args $Encoders.nvenc 26 $true $false) -join ' '
    Check 'NVENC command: constant quality, 10-bit profile' ($q -match 'hevc_nvenc' -and $q -match '-cq 26' -and $q -match 'main10' -and $q -match '-b:v 0')
    $q = (Codec-Args $Encoders.qsv 22 $true $true) -join ' '
    Check 'Quick Sync command: global quality, frames from the CPU as p010' ($q -match 'hevc_qsv' -and $q -match '-global_quality 22' -and $q -match 'p010le')

    # 24. Calibration maths: from measured points to the setting for each quality level
    $pts = @(@{ q = 16; vmaf = 97; kbps = 30000; fps = 50 }, @{ q = 20; vmaf = 95.5; kbps = 18000; fps = 55 }, @{ q = 24; vmaf = 93; kbps = 10000; fps = 58 }, @{ q = 28; vmaf = 90; kbps = 5000; fps = 60 }, @{ q = 32; vmaf = 86; kbps = 2500; fps = 61 })
    Check 'calibration: setting between two measured points' ((Interp-Level $pts 95.0) -eq 20.8)
    Check 'calibration: target above every point uses the best setting' ((Interp-Level $pts 99) -eq 16)
    Check 'calibration: target below every point uses the smallest file' ((Interp-Level $pts 80) -eq 32)
    Check 'calibration: size read off at that setting' ([math]::Round((Interp-At $pts 20.8 'kbps')) -eq 16400)

    # 25. Benchmark: which films, saving the results, skipping too-slow encoders, what the dashboard hears
    $JobsDir = Join-Path $root 'bench-jobs'; New-Item -ItemType Directory -Force $JobsDir | Out-Null
    . (Join-Path $PSScriptRoot 'bench.ps1')
    $ConfigPath = Join-Path $root 'bench-config.json'; $Version = 'test'
    function Pms($m, $path, $p) {
        if ($path -eq '/library/sections') { return @{ MediaContainer = @{ Directory = @(@{ type = 'movie'; key = '1' }, @{ type = 'show'; key = '2' }) } } }
        $mk = { param($t, $res, $file, $kbps, $min, $genre = 'Action') @{ title = $t; Genre = @(@{ tag = $genre }); Media = @(@{ videoResolution = $res; bitrate = $kbps; duration = $min * 60000; Part = @(@{ file = $file }) }) } }
        @{ MediaContainer = @{ Metadata = @(
            (& $mk 'Net4k' '4k' '\\GAMING-PC\D\Movies\Net.mkv' 80000 130),
            (& $mk 'Local4k' '4k' '\\TESTPC\PLEX Server\Movies\A.mkv' 50000 120),
            (& $mk 'Local4kBig' '4k' '\\TESTPC\PLEX Server\Movies\B.mkv' 70000 120),
            (& $mk 'Cartoon' '4k' '\\TESTPC\PLEX Server\Movies\Toon.mkv' 99000 100 'Animation'),
            (& $mk 'Short' '4k' '\\TESTPC\PLEX Server\Movies\Short.mkv' 90000 20),
            (& $mk 'Done' '4k' '\\TESTPC\PLEX Server\Movies\C - Compressed 4K High.mkv' 95000 120),
            (& $mk 'HD' '1080' '\\TESTPC\PLEX Server\Movies\D.mkv' 30000 100),
            (& $mk 'SD' 'sd' '\\TESTPC\PLEX Server\Movies\E.mkv' 5000 100)) } }
    }
    $bs = @(Find-BenchSources $shares)
    $b4 = $bs | Where-Object { $_.tier -eq '4k' }; $b1 = $bs | Where-Object { $_.tier -eq '1080' }
    Check 'benchmark films: local first, then highest bitrate; no animated, short, compressed or unreadable ones' ((@($b4.paths) -join '|') -eq "$root\Movies\B.mkv|$root\Movies\A.mkv" -and @($b1.paths).Count -eq 1 -and $bs.Count -eq 2)
    $script:Cfg = [pscustomobject]@{ serverUrl = 'x'; compress = [pscustomobject]@{ enabled = $true; encoders = @('amf', 'x265slow'); allowCpu = $true; calibration = $null } }
    Check 'benchmark: runs by itself when encoders were never measured' (Needs-Calibration)
    $res = '{"time":"2026-09-28T10:00:00","tiers":{"4k":{"source":"B.mkv","srcKbps":60000,"encoders":{
        "amf":{"fps":37,"levels":{"extreme":20.4,"high":22.6,"normal":24.5,"saver":27.3},"kbps":{"extreme":27000,"high":19000,"normal":14000,"saver":9000},"vmaf":{"high":95},"points":[{"q":16,"vmaf":98.5}],"skipped":null},
        "x265slow":{"fps":0.4,"levels":{},"kbps":{},"vmaf":{},"points":[{"q":16,"vmaf":96}],"skipped":"too slow on this PC (0.4 fps)"}}}}}' | ConvertFrom-Json
    Save-Calibration $res
    $script:Cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Check 'benchmark: results saved per encoder and tier' ($script:Cfg.compress.calibration.amf.'4k'.levels.high -eq 22.6 -and $script:Cfg.compress.calibration.amf.'4k'.points[0].q -eq 16)
    Check 'benchmark: not again once everything is measured' (-not (Needs-Calibration))
    $c = Choose-Encoder $script:Cfg.compress 'high' '4k' 'hevc'
    Check 'benchmark: jobs use the measured setting' ($c.encoder -eq 'amf' -and $c.q -eq 22.6 -and $c.calibrated)
    Check 'benchmark: a processor encoder too slow for 4K here is not used for 4K Extreme' ((Choose-Encoder $script:Cfg.compress 'extreme' '4k' 'hevc').encoder -eq 'amf')
    Check 'benchmark: ...but still for 1080p' ((Choose-Encoder $script:Cfg.compress 'extreme' '1080' 'hevc').encoder -eq 'x265slow')
    Check 'benchmark phone summary' ((Bench-Summary $res) -eq '4K: AMD graphics (AMF, HEVC) at 37 fps, High = setting 22.6 (32% of the film)')
    $caps = Caps-Summary
    $capsJson = $caps | ConvertTo-Json -Depth 5 -Compress
    Check 'caps for the dashboard: small, with levels in order' ($caps.kind -eq 'caps' -and (@($caps.calibration.amf.'4k'.q) -join ',') -eq '20.4,22.6,24.5,27.3' -and $caps.calibration.x265slow.'4k'.skip -and $capsJson.Length -lt 3000)
    Request-Benchmark 'test'
    Check 'benchmark request holds new compressions' (Bench-Holding)
    Stop-Benchmark 'test'
    Check 'benchmark request can be withdrawn' (-not (Bench-Holding))
    Remove-Item Function:\Pms

    # 16. Pause alerts: only after 2 minutes, at most every 30 minutes, "resumed" only after a "paused"
    $PauseAlertAfter = 120; $PauseAlertEvery = 1800; $PresetLabels = @{ '4kh' = '4K High' }
    $jp = [pscustomobject]@{ mode = 'compress'; title = 'Dune'; year = 2021; preset = '4kh' }
    $t0 = [datetime]'2026-09-27 20:00'
    $pausedSt = [pscustomobject]@{ paused = 'Plex is transcoding a stream'; percent = 37; secsLeft = 3000 }
    $runSt = [pscustomobject]@{ paused = ''; percent = 37; secsLeft = 3000 }
    $seq = @(
        (Track-Pause $jp $pausedSt $t0),                    # pause starts: nothing yet
        (Track-Pause $jp $pausedSt $t0.AddSeconds(60)),     # 1 min: still nothing
        (Track-Pause $jp $pausedSt $t0.AddSeconds(130)),    # past 2 min: alert
        (Track-Pause $jp $pausedSt $t0.AddSeconds(600)),    # still paused: no repeat
        (Track-Pause $jp $runSt $t0.AddSeconds(900)),       # carries on: resumed alert
        (Track-Pause $jp $pausedSt $t0.AddSeconds(1000)),   # short blip...
        (Track-Pause $jp $runSt $t0.AddSeconds(1030)),      # ...under 2 min: nothing either way
        (Track-Pause $jp $pausedSt $t0.AddSeconds(1100)),   # another long pause 20 min after the first alert
        (Track-Pause $jp $pausedSt $t0.AddSeconds(1300))    # past 2 min but within 30 min of the last alert: quiet
    )
    Check 'pause alerts: timing and throttling' (($seq -join ',') -eq ',,pause,,resume,,,,')
    $jp.pausedFor = 770
    $np = Pause-Notification $jp 'pause' $pausedSt; $nr = Pause-Notification $jp 'resume' $runSt
    Check 'pause alert wording' ($np.title -eq 'Paused: Dune (2021)' -and $np.message -eq '4K High compression at 37%: Plex is transcoding a stream. It carries on by itself.' -and $np.priority -eq 'low')
    Check 'resume alert wording' ($nr.title -eq 'Resumed: Dune (2021)' -and $nr.message -eq '4K High compression carrying on from 37% after 13 min paused. About 50 min left.')

    # 15. Emptying _TO_DELETE: only dated batches, never through a link, logged in the manifest
    $trash = Join-Path $root '_TO_DELETE'   # $script:TestDrive = $root, so this is "the drive's" _TO_DELETE
    $keep = Join-Path $root 'elsewhere'; New-Item -ItemType Directory -Force $keep | Out-Null
    MakeFile "$keep\precious.mkv" 1 | Out-Null
    MakeFile "$trash\2020-01-01\Movies\Old (2000)\Old.mkv" 2 | Out-Null
    New-Item -ItemType Directory -Force "$trash\2020-02-02\Movies" | Out-Null
    cmd /c "mklink /J `"$trash\2020-02-02\Movies\Link`" `"$keep`"" | Out-Null
    New-Item -ItemType Directory -Force "$trash\not-a-date" | Out-Null
    '{"to":"' + ("$trash\2020-01-01\Movies\Old (2000)").Replace('\', '\\') + '","title":"Old","year":2000}' | Add-Content "$trash\manifest.jsonl" -Encoding UTF8
    $batches = @(Get-TrashBatches @($trash))
    $b1 = $batches | Where-Object Name -eq '2020-01-01'; $b2 = $batches | Where-Object Name -eq '2020-02-02'
    Check 'trash: lists dated batches only, with titles and sizes' (-not ($batches | Where-Object Name -eq 'not-a-date') -and $b1 -and $b2 -and $b1.Titles -contains 'Old (2000)' -and $b1.Bytes -eq 2MB -and -not $b1.HasLinks -and $b2.HasLinks)
    Remove-TrashBatch $b1
    Check 'trash: batch deleted, logged, manifest kept' (-not (Test-Path $b1.Path) -and (Test-Path "$trash\manifest.jsonl") -and (Get-Content "$trash\manifest.jsonl" -Raw) -match '"deleted"')
    $threw = $false; try { Remove-TrashBatch $b2 } catch { $threw = $true }
    Check 'trash: batch with a link is skipped and the link target survives' ($threw -and (Test-Path "$keep\precious.mkv") -and (Test-Path $b2.Path))
    $threw = $false; try { Remove-TrashBatch ([pscustomobject]@{ Path = $keep; HasLinks = $false; Root = $trash }) } catch { $threw = $true }
    Check 'trash: refuses anything that is not a dated _TO_DELETE folder' ($threw -and (Test-Path "$keep\precious.mkv"))
    cmd /c "rmdir `"$trash\2020-02-02\Movies\Link`"" | Out-Null

    Check 'daytime window' ((In-Window '09:00-17:00' ([datetime]'2026-01-01 10:00')) -and -not (In-Window '09:00-17:00' ([datetime]'2026-01-01 18:00')))
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"`n$pass passed, $fail failed"
if ($fail) { exit 1 }
