<#
.SYNOPSIS
Verifies a Hovermate ffmpeg.exe: licence and configuration, component lists against hovermate/required/*.txt,
size, and Hovermate's FFmpeg commands on synthetic media.

.DESCRIPTION
The commands mirror Overlay.App.Engine/Clips (ClipFfmpeg, ClipLibrary, ClipLibrary.Sessions): finalization, layer
split, thumbnail, fragments, every export format, layered exports and session concatenation, with the
product's fixed options (-progress pipe:1 and so on). Inputs are made by a reference FFmpeg (a full build: the
minimal one has no test sources), which also decodes every output. H.264/HEVC encoders are probed as
ClipFfmpeg.SelectEncoderAsync does; without a working H.264 encoder (a runner without GPU or Media Foundation)
the re-encoding commands are reported as skipped unless -RequireEncoder is given.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ffmpeg,
    [Parameter(Mandatory)][string]$Reference,
    [string]$Required = (Join-Path $PSScriptRoot 'required'),
    [string]$ConfigComponents,
    [string]$Work = (Join-Path ([IO.Path]::GetTempPath()) ('hovermate-ffmpeg-verify-' + [Guid]::NewGuid().ToString('N'))),
    [double]$MaxSizeMB = 25,
    [switch]$RequireEncoder,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Ffmpeg = (Resolve-Path -LiteralPath $Ffmpeg).Path
$Reference = (Resolve-Path -LiteralPath $Reference).Path
$failures = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$skipped = [Collections.Generic.List[string]]::new()

function Fail([string]$message) { $failures.Add($message); Write-Host "FAIL  $message" -ForegroundColor Red }
function Warn([string]$message) { $warnings.Add($message); Write-Host "WARN  $message" -ForegroundColor Yellow }
function Pass([string]$message) { Write-Host "ok    $message" }

function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($Exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    [pscustomobject]@{ Code = $process.ExitCode; Out = $out.Result; Err = $err.Result }
}

# ClipFfmpeg.RunAsync: the product's fixed options precede every command.
function Invoke-Product([string[]]$Arguments) {
    Invoke-Tool $Ffmpeg (@('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats') + $Arguments)
}

function Invoke-Reference([string[]]$Arguments) {
    $result = Invoke-Tool $Reference (@('-hide_banner', '-nostdin', '-y', '-loglevel', 'error') + $Arguments)
    if ($result.Code -ne 0) { throw "Reference FFmpeg failed ($($Arguments -join ' ')): $($result.Err.Trim())" }
}

# Streams of a media file as the reference decoder sees them, after a full decode.
function Get-Media([string]$Path) {
    $decode = Invoke-Tool $Reference @('-hide_banner', '-nostdin', '-v', 'error', '-i', $Path, '-f', 'null', '-')
    $info = Invoke-Tool $Reference @('-hide_banner', '-nostdin', '-i', $Path)
    $streams = @([regex]::Matches($info.Err, 'Stream #0:\d+[^:]*: (Video|Audio): ([^\r\n]+)') | ForEach-Object {
        [pscustomobject]@{ Type = $_.Groups[1].Value; Codec = ($_.Groups[2].Value -split '[ ,]')[0]; Text = $_.Groups[2].Value }
    })
    $duration = if ($info.Err -match 'Duration: (\d+):(\d+):([\d.]+)') { [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]$Matches[3] } else { 0 }
    [pscustomobject]@{ DecodeOk = $decode.Code -eq 0 -and -not $decode.Err.Trim(); DecodeError = $decode.Err.Trim(); Streams = $streams; Duration = $duration }
}

function Test-Media([string]$Name, [string]$Path, [string]$Video, [string[]]$Audio = @(), [string[]]$Contains = @(), [double]$MinDuration = 0) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "$Name - no output $Path"; return }
    $media = Get-Media $Path
    $problems = @()
    if (-not $media.DecodeOk) { $problems += "decode: $($media.DecodeError)" }
    $videos = @($media.Streams | Where-Object Type -eq 'Video')
    $audios = @($media.Streams | Where-Object Type -eq 'Audio' | ForEach-Object Codec)
    if ($Video -and ($videos.Count -ne 1 -or $videos[0].Codec -ne $Video)) { $problems += "video '$(($videos | ForEach-Object Codec) -join ',')' instead of '$Video'" }
    if (-not $Video -and $videos.Count) { $problems += 'unexpected video' }
    if (($audios -join ',') -ne ($Audio -join ',')) { $problems += "audio '$($audios -join ',')' instead of '$($Audio -join ',')'" }
    $text = ($media.Streams | ForEach-Object Text) -join ' | '
    foreach ($needle in $Contains) { if (-not $text.Contains($needle)) { $problems += "no '$needle' in: $text" } }
    if ($MinDuration -gt 0 -and $media.Duration -lt $MinDuration) { $problems += "duration $($media.Duration) < $MinDuration" }
    if ($problems) { Fail "$Name - $($problems -join '; ')" } else { Pass "$Name ($text)" }
}

# Runs one product command; returns $true on success.
function Step([string]$Name, [string[]]$Arguments) {
    $result = Invoke-Product $Arguments
    if ($result.Code -ne 0) { Fail "$Name - exit $($result.Code): $($result.Err.Trim())"; return $false }
    if ($result.Out -notmatch 'out_time_us=' -or $result.Out -notmatch 'progress=end') { Fail "$Name - no -progress output on stdout"; return $false }
    return $true
}

function Get-Names([string]$Kind) {
    $lines = (Invoke-Tool $Ffmpeg @('-hide_banner', "-$Kind")).Out -split '\r?\n'
    $body = $false
    switch -Regex ($Kind) {
        '^(encoders|decoders)$' {
            foreach ($line in $lines) { if ($body -and $line -match '^ [VAS][.FSXBD]{5} (\S+)') { $Matches[1] } elseif ($line -match '^ -{6}') { $body = $true } }
        }
        '^(muxers|demuxers)$' {
            foreach ($line in $lines) { if ($body -and $line -match '^ [D ][E ][d ] (\S+)') { $Matches[1] } elseif ($line -match '^ -{3}') { $body = $true } }
        }
        '^filters$' {
            foreach ($line in $lines) { if ($body -and $line -match '^ [T.][S.] (\S+)\s+\S+->\S+') { $Matches[1] } elseif ($line -match '^ +-{6}') { $body = $true } }
        }
        '^protocols$' {
            foreach ($line in $lines) { if ($line -match '^  (\S+)$') { $Matches[1] } }
        }
        '^bsfs$' {
            foreach ($line in $lines) { if ($body -and $line.Trim()) { $line.Trim() } elseif ($line -match '^Bitstream filters:') { $body = $true } }
        }
    }
}

function Compare-Components([string]$Kind, [string[]]$Actual, [bool]$Exact) {
    $expected = @(Get-Content -LiteralPath (Join-Path $Required "$Kind.txt") | ForEach-Object Trim | Where-Object { $_ })
    $actualSet = [Collections.Generic.HashSet[string]]::new([string[]]@($Actual | Sort-Object -Unique))
    $missing = @($expected | Where-Object { -not $actualSet.Contains($_) })
    $extra = @($actualSet | Where-Object { $_ -notin $expected } | Sort-Object)
    if ($missing) { Fail "$Kind - missing: $($missing -join ', ')" }
    if ($extra -and $Exact) { Fail "$Kind - not in required/${Kind}.txt: $($extra -join ', ')" }
    elseif ($extra) { Warn "$Kind - also present (selected by FFmpeg): $($extra -join ', ')" }
    if (-not $missing -and -not ($extra -and $Exact)) { Pass "$Kind - $($actualSet.Count) present, all $($expected.Count) required" }
}

New-Item -ItemType Directory -Path $Work -Force | Out-Null
try {
    Write-Host "== Licence and configuration"
    $version = (Invoke-Tool $Ffmpeg @('-hide_banner', '-version')).Out
    Write-Host (($version -split '\r?\n')[0])
    $buildconf = (Invoke-Tool $Ffmpeg @('-hide_banner', '-buildconf')).Out
    foreach ($forbidden in @('--enable-gpl', '--enable-nonfree', '--enable-version3', 'libx264', 'libx265', 'libfdk', 'openssl', 'libopenh264')) {
        if ($buildconf.Contains($forbidden)) {
            if ($forbidden -eq 'libopenh264') { Warn 'libopenh264 is enabled (HOVERMATE_LIBOPENH264=1)' } else { Fail "configuration contains $forbidden" }
        }
    }
    $licence = (Invoke-Tool $Ffmpeg @('-hide_banner', '-L')).Out
    $licenceText = $licence -replace '\s+', ' '
    if ($licenceText -match 'GNU Lesser General Public License' -and $licenceText -match 'either version 2\.1 of the License, or \(at your option\) any later version') {
        Pass 'ffmpeg -L: LGPL version 2.1 or later'
    }
    else { Fail "ffmpeg -L is not LGPL-2.1-or-later: $licence" }
    $size = (Get-Item -LiteralPath $Ffmpeg).Length
    if ($size -le $MaxSizeMB * 1MB) { Pass ("ffmpeg.exe {0:N1} MB (limit {1} MB)" -f ($size / 1MB), $MaxSizeMB) }
    else { Fail ("ffmpeg.exe {0:N1} MB exceeds {1} MB" -f ($size / 1MB), $MaxSizeMB) }
    $imports = Invoke-Tool $Ffmpeg @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=0.04', '-frames:v', '1', '-c:v', 'mjpeg', '-f', 'image2', (Join-Path $Work 'standalone.jpg'))
    if ($imports.Code -eq 0) { Pass 'runs standalone (no FFmpeg DLLs next to it)' } else { Fail "standalone run failed: $($imports.Err.Trim())" }

    Write-Host "== Components"
    foreach ($kind in @('encoders', 'decoders', 'muxers', 'demuxers', 'filters', 'protocols', 'bsfs')) {
        Compare-Components $kind @(Get-Names $kind) ($kind -in @('encoders', 'muxers', 'protocols'))
    }
    $parsers = if ($ConfigComponents) {
        @(Get-Content -LiteralPath $ConfigComponents | ForEach-Object { if ($_ -match '^#define CONFIG_(\w+)_PARSER 1') { $Matches[1].ToLowerInvariant() } })
    } else {
        Warn 'parsers - checked against -buildconf only (pass -ConfigComponents for the full list)'
        @(if ($buildconf -match '--enable-parser=(\S+)') { $Matches[1] -split ',' })
    }
    Compare-Components 'parsers' $parsers $false

    Write-Host "== Synthetic inputs (reference FFmpeg)"
    $in = Join-Path $Work 'in'
    $clips = Join-Path $Work 'clips'
    $exports = Join-Path $Work 'exports'
    New-Item -ItemType Directory -Path $in, $clips, $exports -Force | Out-Null
    $source = @('-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=60:d=6')
    Invoke-Reference ($source + @('-c:v', 'libopenh264', '-b:v', '6M', '-g', '60', '-pix_fmt', 'yuv420p', '-f', 'mpegts', (Join-Path $in 'game-h264.ts')))
    Invoke-Reference ($source + @('-c:v', 'libkvazaar', '-kvazaar-params', 'preset=ultrafast,period=64', '-pix_fmt', 'yuv420p', '-f', 'mpegts', (Join-Path $in 'game-hevc.ts')))
    Invoke-Reference @('-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=60:d=4', '-c:v', 'libopenh264', '-b:v', '6M', '-g', '60', '-pix_fmt', 'yuv420p', '-f', 'mpegts', (Join-Path $in 'game-h264-b.ts'))
    foreach ($track in @(@('game', 440, 6), @('microphone', 880, 6), @('game-b', 330, 4))) {
        Invoke-Reference @('-f', 'lavfi', '-i', "sine=f=$($track[1]):r=48000:d=$($track[2])", '-ac', '2', '-c:a', 'pcm_s16le', (Join-Path $in "audio-$($track[0]).wav"))
    }
    # A recorder layer: color and alpha matte as two video streams of one TS.
    Invoke-Reference @('-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=60:d=5', '-f', 'lavfi', '-i', 'color=c=gray:s=1280x720:r=60:d=5',
        '-map', '0:v', '-map', '1:v', '-c:v', 'libopenh264', '-b:v', '2M', '-g', '60', '-pix_fmt', 'yuv420p', '-f', 'mpegts', (Join-Path $in 'layer-1.ts'))
    Pass 'inputs: game-h264.ts, game-hevc.ts, game-h264-b.ts, audio-*.wav, layer-1.ts'

    Write-Host "== Encoders (as ClipFfmpeg.SelectEncoderAsync)"
    $encoders = @(Get-Names 'encoders')
    $probe = [ordered]@{}
    foreach ($encoder in @('h264_nvenc', 'h264_amf', 'h264_qsv', 'h264_mf', 'libopenh264', 'hevc_nvenc', 'hevc_amf', 'hevc_qsv', 'hevc_mf')) {
        if ($encoder -notin $encoders) { continue }
        $pix = if ($encoder -eq 'libopenh264') { 'yuv420p' } else { 'nv12' }
        $result = Invoke-Product @('-f', 'lavfi', '-i', 'color=c=black:s=256x144:d=0.2', '-pix_fmt', $pix, '-c:v', $encoder, '-f', 'null', '-')
        $probe[$encoder] = $result.Code -eq 0
        $detail = if ($result.Code -eq 0) { 'works' } else { 'unavailable: ' + (($result.Err.Trim() -split '\r?\n') | Select-Object -Last 1) }
        Write-Host ("      {0,-12} {1}" -f $encoder, $detail)
    }
    $h264 = @($probe.Keys | Where-Object { $_ -notlike 'hevc_*' -and $probe[$_] }) | Select-Object -First 1
    $hevc = @($probe.Keys | Where-Object { $_ -like 'hevc_*' -and $probe[$_] }) | Select-Object -First 1
    if (-not $hevc) { $hevc = $h264 }
    if ($h264) { Pass "selected: h264 -> $h264, hevc -> $hevc" }
    elseif ($RequireEncoder) { Fail 'no working H.264 encoder' }
    else { Warn 'no working H.264 encoder on this machine: re-encoding commands are skipped' }

    # ClipFfmpeg.VideoEncoderArguments
    function Encoder-Arguments([string]$Encoder, [int]$Kbps, [int]$Keyframes = 60) {
        if ($Encoder.StartsWith('lib')) { return @('-c:v', $Encoder, '-b:v', "${Kbps}k", '-pix_fmt', 'yuv420p', '-g', "$Keyframes") }
        $arguments = @('-c:v', $Encoder, '-b:v', "${Kbps}k", '-maxrate', "$([int]($Kbps * 3 / 2))k", '-bufsize', "$($Kbps * 2)k", '-pix_fmt', 'nv12')
        if ($Encoder.EndsWith('_nvenc')) { $arguments += @('-preset', 'p5') } elseif ($Encoder.EndsWith('_amf')) { $arguments += @('-quality', 'quality') }
        $arguments + @('-g', "$Keyframes")
    }
    function Skip([string]$Name) { $skipped.Add($Name); Write-Host "skip  $Name (no H.264 encoder)" -ForegroundColor DarkYellow }
    $mixTwo = 'amix=inputs=2:normalize=0:duration=longest,alimiter=limit=0.97[mix]'

    Write-Host "== Finalization, layers, thumbnail (ClipLibrary.FinalizeMediaAsync)"
    $clipH264 = Join-Path $clips 'h264'
    $clipHevc = Join-Path $clips 'hevc'
    New-Item -ItemType Directory -Path (Join-Path $clipH264 'layers'), (Join-Path $clipHevc 'layers') -Force | Out-Null
    if (Step 'finalize h264 (copy, Mix + 2 sources)' @('-i', (Join-Path $in 'game-h264.ts'), '-i', (Join-Path $in 'audio-game.wav'), '-i', (Join-Path $in 'audio-microphone.wav'),
            '-map', '0:v:0', '-filter_complex', "[1:a][2:a]$mixTwo", '-map', '[mix]', '-map', '1:a', '-map', '2:a',
            '-c:a', 'aac', '-b:a', '192k', '-metadata:s:a:0', 'title=Mix', '-disposition:a:0', 'default',
            '-metadata:s:a:1', 'title=Game', '-disposition:a:1', '0', '-metadata:s:a:2', 'title=Microphone', '-disposition:a:2', '0',
            '-c:v', 'copy', '-movflags', '+faststart', (Join-Path $clipH264 'clip.mp4'))) {
        Test-Media 'finalize h264' (Join-Path $clipH264 'clip.mp4') 'h264' @('aac', 'aac', 'aac') -MinDuration 5.5
    }
    if (Step 'finalize hevc (copy, one source)' @('-i', (Join-Path $in 'game-hevc.ts'), '-i', (Join-Path $in 'audio-game.wav'),
            '-map', '0:v:0', '-filter_complex', '[1:a]anull[mix]', '-map', '[mix]', '-map', '1:a',
            '-c:a', 'aac', '-b:a', '192k', '-metadata:s:a:0', 'title=Mix', '-disposition:a:0', 'default', '-metadata:s:a:1', 'title=Game', '-disposition:a:1', '0',
            '-c:v', 'copy', '-movflags', '+faststart', (Join-Path $clipHevc 'clip.mp4'))) {
        Test-Media 'finalize hevc' (Join-Path $clipHevc 'clip.mp4') 'hevc' @('aac', 'aac') -MinDuration 5.5
    }
    if (Step 'split layer (two streams, copy)' @('-probesize', '64M', '-analyzeduration', '30M', '-i', (Join-Path $in 'layer-1.ts'),
            '-map', '0:v:0', '-c', 'copy', '-movflags', '+faststart', (Join-Path $clipH264 'layers/1-color.mp4'),
            '-map', '0:v:1', '-c', 'copy', '-movflags', '+faststart', (Join-Path $clipH264 'layers/1-alpha.mp4'))) {
        Test-Media 'layer color' (Join-Path $clipH264 'layers/1-color.mp4') 'h264'
        Test-Media 'layer alpha' (Join-Path $clipH264 'layers/1-alpha.mp4') 'h264'
    }
    if (Step 'split layer with outpoint (session)' @('-probesize', '64M', '-analyzeduration', '30M', '-i', (Join-Path $in 'layer-1.ts'), '-t', '3',
            '-map', '0:v:0', '-c', 'copy', '-movflags', '+faststart', (Join-Path $clipHevc 'layers/1-color.mp4'),
            '-map', '0:v:1', '-c', 'copy', '-movflags', '+faststart', (Join-Path $clipHevc 'layers/1-alpha.mp4'))) {
        Test-Media 'layer cut' (Join-Path $clipHevc 'layers/1-color.mp4') 'h264'
    }
    foreach ($clip in @($clipH264, $clipHevc)) {
        if (Step "thumbnail $(Split-Path $clip -Leaf)" @('-ss', '1.5', '-i', (Join-Path $clip 'clip.mp4'), '-frames:v', '1', '-vf', 'scale=480:-2', '-q:v', '4', (Join-Path $clip 'thumb.jpg'))) {
            Test-Media "thumbnail $(Split-Path $clip -Leaf)" (Join-Path $clip 'thumb.jpg') 'mjpeg' -Contains @('480x270')
        }
    }

    Write-Host "== Fragments (ClipLibrary.CutAsync)"
    $copyCut = Join-Path $clips 'cut-copy'
    New-Item -ItemType Directory -Path (Join-Path $copyCut 'audio'), (Join-Path $copyCut 'layers') -Force | Out-Null
    $cut = @('-ss', '1', '-t', '3')
    if (Step 'fragment (stream copy)' ($cut + @('-i', (Join-Path $clipH264 'clip.mp4')) + $cut + @('-i', (Join-Path $in 'audio-game.wav')) + $cut + @('-i', (Join-Path $in 'audio-microphone.wav')) +
            @('-map', '0:v:0', '-filter_complex', "[1:a][2:a]$mixTwo", '-map', '[mix]', '-map', '1:a', '-map', '2:a', '-c:a', 'aac', '-b:a', '192k',
            '-metadata:s:a:0', 'title=Mix', '-disposition:a:0', 'default', '-c:v', 'copy', '-movflags', '+faststart', (Join-Path $copyCut 'clip.mp4')))) {
        Test-Media 'fragment copy' (Join-Path $copyCut 'clip.mp4') 'h264' @('aac', 'aac', 'aac')
    }
    if (Step 'fragment track (pcm_s16le)' ($cut + @('-i', (Join-Path $in 'audio-game.wav'), '-c:a', 'pcm_s16le', (Join-Path $copyCut 'audio/game.wav')))) {
        Test-Media 'fragment track' (Join-Path $copyCut 'audio/game.wav') '' @('pcm_s16le') -MinDuration 2.9
    }
    if (Step 'fragment layer (copy)' (@('-ss', '1', '-t', '2', '-i', (Join-Path $clipH264 'layers/1-color.mp4'), '-c:v', 'copy', '-an', '-movflags', '+faststart', (Join-Path $copyCut 'layers/1-color.mp4')))) {
        Test-Media 'fragment layer copy' (Join-Path $copyCut 'layers/1-color.mp4') 'h264'
    }
    if ($h264) {
        $precise = Join-Path $clips 'cut-precise'
        New-Item -ItemType Directory -Path (Join-Path $precise 'layers') -Force | Out-Null
        if (Step "fragment precise from HEVC ($h264)" ($cut + @('-i', (Join-Path $clipHevc 'clip.mp4')) + $cut + @('-i', (Join-Path $in 'audio-game.wav')) +
                @('-map', '0:v:0', '-filter_complex', '[1:a]anull[mix]', '-map', '[mix]', '-map', '1:a', '-c:a', 'aac', '-b:a', '192k',
                '-metadata:s:a:0', 'title=Mix', '-disposition:a:0', 'default') + (Encoder-Arguments $h264 6000 60) + @('-movflags', '+faststart', (Join-Path $precise 'clip.mp4')))) {
            Test-Media 'fragment precise' (Join-Path $precise 'clip.mp4') 'h264' @('aac', 'aac') -MinDuration 2.9
        }
        if (Step "fragment layer precise ($h264)" (@('-ss', '0.5', '-t', '2', '-i', (Join-Path $clipH264 'layers/1-alpha.mp4')) + (Encoder-Arguments $h264 4000 60) +
                @('-an', '-movflags', '+faststart', (Join-Path $precise 'layers/1-alpha.mp4')))) {
            Test-Media 'fragment layer precise' (Join-Path $precise 'layers/1-alpha.mp4') 'h264'
        }
    } else { Skip 'fragment precise'; Skip 'fragment layer precise' }

    Write-Host "== Exports (ClipLibrary.ExportCoreAsync: layer composited, two tracks)"
    $clipInput = @('-ss', '0.5', '-t', '3', '-i', (Join-Path $clipH264 'clip.mp4'))
    $layerInputs = @('-ss', '0.5', '-t', '3', '-i', (Join-Path $clipH264 'layers/1-color.mp4'), '-ss', '0.5', '-t', '3', '-i', (Join-Path $clipH264 'layers/1-alpha.mp4'))
    # A layer that starts 0.3 s into the exported range (-itsoffset path).
    $delayedLayerInputs = @('-itsoffset', '0.3', '-ss', '0', '-t', '2.7', '-i', (Join-Path $clipH264 'layers/1-color.mp4'),
        '-itsoffset', '0.3', '-ss', '0', '-t', '2.7', '-i', (Join-Path $clipH264 'layers/1-alpha.mp4'))
    $trackInputs = @('-ss', '0.5', '-t', '3', '-i', (Join-Path $in 'audio-game.wav'), '-ss', '0.5', '-t', '3', '-i', (Join-Path $in 'audio-microphone.wav'))
    $composite = '[1:v]format=yuva420p[c1];[2:v]scale=in_range=tv:out_range=pc,format=gray[a1];[c1][a1]alphamerge[l1];' +
        '[0:v][l1]overlay=0:0:alpha=premultiplied:eof_action=pass:format=auto[v1]'
    $mixExport = "[3:a][4:a]$mixTwo"
    $exportCases = @(
        @{ Name = 'mp4 (scale 540, fps 30, separate tracks)'; File = 'export.mp4'; Encoder = $h264; Layers = $layerInputs
           Filter = "$composite;[v1]scale=-2:540:flags=lanczos,fps=30[vout];$mixExport"; Audio = @('-map', '[mix]', '-map', '3:a', '-map', '4:a', '-c:a', 'aac', '-b:a', '192k')
           Tail = @('-movflags', '+faststart'); Video = 'h264'; AudioCodecs = @('aac', 'aac', 'aac'); Contains = @('960x540') }
        @{ Name = 'hevc (-tag:v hvc1)'; File = 'export-hevc.mp4'; Encoder = $hevc; Layers = $layerInputs
           Filter = "$composite;[v1]null[vout];$mixExport"; Audio = @('-map', '[mix]', '-c:a', 'aac', '-b:a', '192k')
           Tail = @('-movflags', '+faststart', '-tag:v', 'hvc1'); Video = 'hevc'; AudioCodecs = @('aac'); Contains = @('hvc1') }
        @{ Name = 'mkv (delayed layer)'; File = 'export.mkv'; Encoder = $h264; Layers = $delayedLayerInputs
           Filter = "$composite;[v1]null[vout];$mixExport"; Audio = @('-map', '[mix]', '-c:a', 'aac', '-b:a', '192k')
           Tail = @(); Video = 'h264'; AudioCodecs = @('aac'); Contains = @() }
        @{ Name = 'mov'; File = 'export.mov'; Encoder = $h264; Layers = $layerInputs
           Filter = "$composite;[v1]null[vout];$mixExport"; Audio = @('-map', '[mix]', '-c:a', 'aac', '-b:a', '192k')
           Tail = @('-movflags', '+faststart'); Video = 'h264'; AudioCodecs = @('aac'); Contains = @() }
        @{ Name = 'webm (vp9 + opus)'; File = 'export.webm'; Encoder = 'libvpx-vp9'; Layers = $layerInputs
           Filter = "$composite;[v1]null[vout];$mixExport"; Audio = @('-map', '[mix]', '-c:a', 'libopus', '-b:a', '160k')
           Tail = @(); Video = 'vp9'; AudioCodecs = @('opus'); Contains = @() }
        @{ Name = 'gif (palettegen/paletteuse)'; File = 'export.gif'; Encoder = 'gif'; Layers = $layerInputs
           Filter = "$composite;[v1]fps=15,scale=-2:480:flags=lanczos,split[g0][g1];[g0]palettegen=stats_mode=diff[gp];[g1][gp]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle[vout]"
           Audio = @(); Tail = @('-an', '-loop', '0'); Video = 'gif'; AudioCodecs = @(); Contains = @('854x480') }
    )
    foreach ($case in $exportCases) {
        if (-not $case.Encoder) { Skip "export $($case.Name)"; continue }
        $videoArguments = switch ($case.Encoder) {
            'libvpx-vp9' { @('-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32', '-row-mt', '1', '-deadline', 'good', '-cpu-used', '4', '-pix_fmt', 'yuv420p') }
            'gif' { @() }
            default { Encoder-Arguments $case.Encoder 8000 }
        }
        $output = Join-Path $exports $case.File
        if (Step "export $($case.Name)" ($clipInput + $case.Layers + $trackInputs + @('-filter_complex', $case.Filter, '-map', '[vout]') + $videoArguments + $case.Audio + $case.Tail + @($output))) {
            Test-Media "export $($case.Name)" $output $case.Video $case.AudioCodecs -Contains $case.Contains -MinDuration 2.5
        }
    }

    Write-Host "== Export For editing (ProRes, layers as ProRes 4444 with alpha)"
    $editing = Join-Path $exports 'editing'
    New-Item -ItemType Directory -Path $editing -Force | Out-Null
    # No layer inputs here: the clip (0) and the tracks (1, 2), Mix plus each track as PCM.
    $editingArguments = @('-ss', '0.5', '-t', '3', '-i', (Join-Path $clipH264 'clip.mp4'),
        '-ss', '0.5', '-t', '3', '-i', (Join-Path $in 'audio-game.wav'), '-ss', '0.5', '-t', '3', '-i', (Join-Path $in 'audio-microphone.wav'),
        '-filter_complex', "[1:a][2:a]$mixTwo", '-map', '0:v:0',
        '-c:v', 'prores_ks', '-profile:v', '3', '-pix_fmt', 'yuv422p10le', '-vendor', 'apl0',
        '-map', '[mix]', '-map', '1:a', '-map', '2:a', '-c:a', 'pcm_s16le', (Join-Path $editing 'video.mov'))
    if (Step 'editing video.mov' $editingArguments) {
        Test-Media 'editing video.mov' (Join-Path $editing 'video.mov') 'prores' @('pcm_s16le', 'pcm_s16le', 'pcm_s16le') -Contains @('yuv422p10le') -MinDuration 2.9
    }
    $layerArguments = @('-ss', '0', '-t', '2.7', '-i', (Join-Path $clipH264 'layers/1-color.mp4'), '-ss', '0', '-t', '2.7', '-i', (Join-Path $clipH264 'layers/1-alpha.mp4'),
        '-filter_complex', '[0:v]format=yuva444p10le[c];[1:v]scale=in_range=tv:out_range=pc,format=gray[a];[c][a]alphamerge,unpremultiply=inplace=1,tpad=start_duration=0.3:color=black@0[l]',
        '-map', '[l]', '-c:v', 'prores_ks', '-profile:v', '4', '-pix_fmt', 'yuva444p10le', '-alpha_bits', '16', '-vendor', 'apl0', (Join-Path $editing 'Layer.mov'))
    if (Step 'editing layer (ProRes 4444, alphamerge, unpremultiply, tpad)' $layerArguments) {
        Test-Media 'editing layer' (Join-Path $editing 'Layer.mov') 'prores' -Contains @('4444', 'yuva444') -MinDuration 2.9
    }

    Write-Host "== Sessions (ClipLibrary.Sessions: ffconcat)"
    $session = Join-Path $clips 'session'
    New-Item -ItemType Directory -Path (Join-Path $session 'audio') -Force | Out-Null
    function Write-Concat([string]$Path, [string[][]]$Entries) {
        $text = "ffconcat version 1.0`n"
        foreach ($entry in $Entries) {
            $text += "file '" + $entry[0].Replace('\', '/').Replace("'", "'\''") + "'`n"
            if ($entry.Count -gt 1 -and $entry[1]) { $text += "$($entry[2]) $($entry[1])`n" }
        }
        [IO.File]::WriteAllText($Path, $text)
        $Path
    }
    $videoList = Write-Concat (Join-Path $session 'run-1-video.txt') @(@((Join-Path $in 'game-h264.ts'), '5', 'outpoint'), @((Join-Path $in 'game-h264-b.ts'), '', ''))
    $gameList = Write-Concat (Join-Path $session 'run-1-game.txt') @(@((Join-Path $in 'audio-game.wav'), '5', 'outpoint'), @((Join-Path $in 'audio-game-b.wav'), '', ''))
    $micList = Write-Concat (Join-Path $session 'run-1-microphone.txt') @(@((Join-Path $in 'audio-microphone.wav'), '5', 'outpoint'), @((Join-Path $in 'audio-game-b.wav'), '', ''))
    $concatArguments = @('-f', 'concat', '-safe', '0', '-i', $videoList, '-f', 'concat', '-safe', '0', '-i', $gameList, '-f', 'concat', '-safe', '0', '-i', $micList,
        '-filter_complex', "[1:a]asplit=2[m0][w0];[2:a]asplit=2[m1][w1];[m0][m1]$mixTwo",
        '-map', '0:v:0', '-map', '[mix]', '-c:a', 'aac', '-b:a', '192k', '-metadata:s:a:0', 'title=Mix', '-c:v', 'copy', (Join-Path $session 'clip.mp4'),
        '-map', '[w0]', '-c:a', 'pcm_s16le', (Join-Path $session 'audio/game.wav'), '-map', '[w1]', '-c:a', 'pcm_s16le', (Join-Path $session 'audio/microphone.wav'))
    if (Step 'session run concat (TS + WAV parts, asplit, amix)' $concatArguments) {
        Test-Media 'session clip.mp4' (Join-Path $session 'clip.mp4') 'h264' @('aac') -MinDuration 8.5
        Test-Media 'session game.wav' (Join-Path $session 'audio/game.wav') '' @('pcm_s16le') -MinDuration 8.5
    }
    $exportList = Write-Concat (Join-Path $exports 'session.txt') @(@((Join-Path $clipH264 'clip.mp4'), '', ''), @((Join-Path $copyCut 'clip.mp4'), '1', 'inpoint'))
    if (Step 'session export (one run, stream copy)' @('-f', 'concat', '-safe', '0', '-i', $exportList, '-map', '0:v:0', '-map', '0:a:0?', '-c', 'copy', '-movflags', '+faststart', (Join-Path $exports 'session.mp4'))) {
        Test-Media 'session export copy' (Join-Path $exports 'session.mp4') 'h264' @('aac') -MinDuration 7
    }
    if ($h264) {
        $mixedList = Write-Concat (Join-Path $exports 'session-runs.txt') @(@((Join-Path $clipH264 'clip.mp4'), '', ''), @((Join-Path $clipHevc 'clip.mp4'), '1', 'inpoint'))
        if (Step "session export (several runs, $h264)" (@('-f', 'concat', '-safe', '0', '-i', $mixedList, '-map', '0:v:0', '-map', '0:a:0?') + (Encoder-Arguments $h264 6000) +
                @('-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', (Join-Path $exports 'session-runs.mp4')))) {
            Test-Media 'session export re-encode' (Join-Path $exports 'session-runs.mp4') 'h264' @('aac') -MinDuration 10
        }
    } else { Skip 'session export (several runs)' }
}
finally {
    if (-not $Keep) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "Work folder kept: $Work" }
}

Write-Host ''
Write-Host "Failures: $($failures.Count)  Warnings: $($warnings.Count)  Skipped: $($skipped.Count)"
if ($failures.Count) { exit 1 }
