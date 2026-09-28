<#
  Plex Library Helper - the encoders it knows (loaded by library-helper.ps1 and compress.ps1)

  Each encoder: which ffmpeg encoder, how frames are decoded for it, its quality setting (lower number =
  better quality and bigger file, for all of them), the range the benchmark sweeps, and safe defaults for
  each quality level until the PC has been calibrated. "Rpu" = writes raw HEVC so the Dolby Vision data
  can be put back with dovi_tool; x265 carries Dolby Vision itself; AV1 output keeps HDR10 only.
#>

$Encoders = [ordered]@{
    amf       = @{ Label = 'AMD graphics (AMF, HEVC)';        Codec = 'hevc'; Kind = 'amd';    Ffmpeg = 'hevc_amf';   Rpu = $true;  Sweep = @(16, 20, 24, 28, 32); Default = @{ extreme = 18; high = 20; normal = 22; saver = 26 } }
    nvenc     = @{ Label = 'NVIDIA graphics (NVENC, HEVC)';   Codec = 'hevc'; Kind = 'nvidia'; Ffmpeg = 'hevc_nvenc'; Rpu = $true;  Sweep = @(18, 22, 26, 30, 34); Default = @{ extreme = 20; high = 23; normal = 26; saver = 30 } }
    qsv       = @{ Label = 'Intel graphics (Quick Sync, HEVC)'; Codec = 'hevc'; Kind = 'intel'; Ffmpeg = 'hevc_qsv';  Rpu = $true;  Sweep = @(18, 22, 26, 30, 34); Default = @{ extreme = 19; high = 22; normal = 25; saver = 29 } }
    x265      = @{ Label = 'Processor (x265 medium, HEVC)';   Codec = 'hevc'; Kind = 'cpu';    Ffmpeg = 'libx265';    Rpu = $false; Sweep = @(16, 19, 22, 25, 28); Default = @{ extreme = 18; high = 20; normal = 22; saver = 25 }; Preset = 'medium' }
    x265slow  = @{ Label = 'Processor (x265 slow, HEVC)';     Codec = 'hevc'; Kind = 'cpu';    Ffmpeg = 'libx265';    Rpu = $false; Sweep = @(16, 19, 22, 25, 28); Default = @{ extreme = 18; high = 20; normal = 22; saver = 25 }; Preset = 'slow'; Efficient = $true }
    av1_amf   = @{ Label = 'AMD graphics (AMF, AV1)';         Codec = 'av1';  Kind = 'amd';    Ffmpeg = 'av1_amf';    Rpu = $false; Sweep = @(80, 110, 140, 170, 200); Default = @{ extreme = 90; high = 110; normal = 130; saver = 160 } }
    av1_nvenc = @{ Label = 'NVIDIA graphics (NVENC, AV1)';    Codec = 'av1';  Kind = 'nvidia'; Ffmpeg = 'av1_nvenc';  Rpu = $false; Sweep = @(20, 26, 32, 38, 44); Default = @{ extreme = 24; high = 28; normal = 32; saver = 38 } }
    av1_qsv   = @{ Label = 'Intel graphics (Quick Sync, AV1)'; Codec = 'av1'; Kind = 'intel';  Ffmpeg = 'av1_qsv';    Rpu = $false; Sweep = @(20, 26, 32, 38, 44); Default = @{ extreme = 23; high = 27; normal = 31; saver = 37 } }
    svtav1    = @{ Label = 'Processor (SVT-AV1)';             Codec = 'av1';  Kind = 'cpu';    Ffmpeg = 'libsvtav1';  Rpu = $false; Sweep = @(20, 26, 32, 38, 44); Default = @{ extreme = 22; high = 26; normal = 30; saver = 36 }; Preset = '5'; Efficient = $true }
}

# What each quality level aims for (VMAF, on this owner's films): the benchmark finds each encoder's setting
$QualityTargets = [ordered]@{ extreme = 96.5; high = 95.0; normal = 93.5; saver = 90.0 }

# Decoding: hardware encoders get hardware decoding too (same speed, almost no CPU). Frames stay on the
# graphics card unless CPU filters (scaling, tone-mapping) need them. The default pool of GPU frames is too
# small while the encoder holds some, and ffmpeg then drops frames: hence -extra_hw_frames.
function Decode-Args($enc, [bool]$gpuFrames) {
    switch ($enc.Kind) {
        'amd'    { $a = @('-hwaccel', 'd3d11va'); if ($gpuFrames) { $a += '-hwaccel_output_format', 'd3d11', '-extra_hw_frames', '16' }; return $a }
        'nvidia' { $a = @('-hwaccel', 'cuda');    if ($gpuFrames) { $a += '-hwaccel_output_format', 'cuda', '-extra_hw_frames', '16' }; return $a }
        'intel'  { $a = @('-hwaccel', 'qsv');     if ($gpuFrames) { $a += '-hwaccel_output_format', 'qsv', '-extra_hw_frames', '16' }; return $a }
    }
    @()
}

# The encoder's own settings at quality $q. $tenBit: 10-bit output; $cpuFrames: frames come from CPU filters.
function Codec-Args($enc, [double]$q, [bool]$tenBit, [bool]$cpuFrames) {
    $q = [int][math]::Round($q)
    $prof = if ($tenBit) { 'main10' } else { 'main' }
    $pix = if ($cpuFrames -or $enc.Kind -eq 'cpu') { @('-pix_fmt', $(if ($enc.Kind -eq 'cpu') { if ($tenBit) { 'yuv420p10le' } else { 'yuv420p' } } else { 'p010le' })) } else { @() }
    switch ($enc.Ffmpeg) {
        'hevc_amf'   { return @('-c:v', 'hevc_amf', '-profile:v', $prof, '-quality', 'quality', '-vbaq', '1', '-rc', 'cqp', '-qp_i', $q, '-qp_p', $q, '-qp_b', ($q + 2)) + $pix }
        'av1_amf'    { return @('-c:v', 'av1_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', $q, '-qp_p', $q) + $pix }
        'hevc_nvenc' { return @('-c:v', 'hevc_nvenc', '-profile:v', $prof, '-preset', 'p6', '-tune', 'hq', '-rc', 'vbr', '-cq', $q, '-b:v', '0', '-spatial_aq', '1', '-temporal_aq', '1', '-rc-lookahead', '32') + $pix }
        'av1_nvenc'  { return @('-c:v', 'av1_nvenc', '-preset', 'p6', '-tune', 'hq', '-rc', 'vbr', '-cq', $q, '-b:v', '0', '-spatial_aq', '1', '-temporal_aq', '1', '-rc-lookahead', '32') + $pix }
        'hevc_qsv'   { return @('-c:v', 'hevc_qsv', '-profile:v', $prof, '-preset', 'medium', '-global_quality', $q) + $pix }
        'av1_qsv'    { return @('-c:v', 'av1_qsv', '-preset', 'medium', '-global_quality', $q) + $pix }
        'libx265'    { return @('-c:v', 'libx265', '-preset', $enc.Preset, '-crf', $q) + $pix }
        'libsvtav1'  { return @('-c:v', 'libsvtav1', '-preset', $enc.Preset, '-crf', $q, '-svtav1-params', 'tune=0') + $pix }
    }
    throw "Unknown encoder $($enc.Ffmpeg)"
}

# Which encoders actually work on this PC: a half-second test encode each (a missing graphics card or
# driver fails straight away). Returns the ids that worked.
function Test-Encoders([string]$ffmpeg) {
    $ok = @()
    foreach ($id in $Encoders.Keys) {
        $e = $Encoders[$id]
        $a = @('-nostdin', '-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24', '-t', '0.5') + (Codec-Args $e $e.Default.normal $true $true) + @('-f', 'null', '-')
        $p = Start-Process -FilePath $ffmpeg -ArgumentList $a -NoNewWindow -PassThru -RedirectStandardError ([IO.Path]::GetTempFileName())
        $null = $p.Handle
        if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch { }; continue }
        if ($p.ExitCode -eq 0) { $ok += $id }
    }
    $ok
}

# The encoder and setting for a job on this PC, or $null if this PC shouldn't take it.
#   level: extreme|high|normal|saver   tier: 4k|1080   codec: hevc|av1
# Graphics-card encoders first; 'extreme' prefers the processor's efficient encoder (x265 slow / SVT-AV1)
# when this PC allows processor encodes. Settings come from the benchmark's calibration when there is one.
function Choose-Encoder($compressCfg, [string]$level, [string]$tier, [string]$codec) {
    $avail = @($compressCfg.encoders | Where-Object { $_ })   # (@($null) would count as one)
    if (-not $avail.Count) { $avail = @('amf', 'x265', 'x265slow') }   # set up before encoders were tested (the owner's AMD PC)
    $allowCpu = $compressCfg.allowCpu -ne $false
    $mine = @($avail | Where-Object { $Encoders[$_] -and $Encoders[$_].Codec -eq $codec })
    $hw = @($mine | Where-Object { $Encoders[$_].Kind -ne 'cpu' })
    $cpu = @($mine | Where-Object { $Encoders[$_].Kind -eq 'cpu' } | Sort-Object { -not $Encoders[$_].Efficient })
    $pick = $null
    if ($level -eq 'extreme' -and $allowCpu -and $cpu.Count) { $pick = $cpu[0] }
    elseif ($hw.Count) { $pick = $hw[0] }
    elseif ($allowCpu -and $cpu.Count) { $pick = @($cpu | Where-Object { -not $Encoders[$_].Efficient })[0]; if (-not $pick) { $pick = $cpu[0] } }
    if (-not $pick) { return $null }
    $cal = $compressCfg.calibration
    $q = $null
    if ($cal -and $cal.$pick -and $cal.$pick.$tier -and $cal.$pick.$tier.levels -and $null -ne $cal.$pick.$tier.levels.$level) { $q = [double]$cal.$pick.$tier.levels.$level }
    if ($null -eq $q) { $q = [double]$Encoders[$pick].Default[$level] }
    @{ encoder = $pick; q = $q; calibrated = $null -ne ($cal.$pick.$tier.levels.$level) }
}

# Old preset ids (still what the dashboard sends) -> level and tier
function Preset-Level([string]$id) {
    switch -regex ($id) {
        '^4k([xhns])$'   { return @{ tier = '4k'; level = @{ x = 'extreme'; h = 'high'; n = 'normal'; s = 'saver' }[$Matches[1]] } }
        '^1080([hns])$'  { return @{ tier = '1080'; level = @{ h = 'high'; n = 'normal'; s = 'saver' }[$Matches[1]] } }
    }
    $null
}
