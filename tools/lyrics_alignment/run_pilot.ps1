param(
    [Parameter(Mandatory = $true)][string]$MusicRoot,
    [string]$Manifest = "tools\lyrics_alignment\pilot_manifest.json",
    [string]$OutputRoot = "artifacts\lyrics_alignment_pilot_output",
    [ValidateSet("cpu", "cuda")][string]$Device = "cpu"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$musicRootPath = (Resolve-Path -LiteralPath $MusicRoot).Path.TrimEnd("\")
$manifestPath = if ([IO.Path]::IsPathRooted($Manifest)) { $Manifest } else { Join-Path $projectRoot $Manifest }
$outputPath = if ([IO.Path]::IsPathRooted($OutputRoot)) { [IO.Path]::GetFullPath($OutputRoot) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $OutputRoot)) }
if ($outputPath.Equals($musicRootPath, [StringComparison]::OrdinalIgnoreCase) -or $outputPath.StartsWith($musicRootPath + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "输出目录不能位于音乐库内"
}
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$manifestData = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
$python = Join-Path $projectRoot ".tooling\lyrics-alignment\.venv\Scripts\python.exe"
$lyricAlign = Join-Path $projectRoot ".tooling\lyrics-alignment\.venv\Scripts\lyric-align.exe"
$tool = Join-Path $PSScriptRoot "harmony_lyrics_tool.py"
$xingyuRunner = Join-Path $PSScriptRoot "run_xingyu.ps1"
foreach ($required in @($python, $lyricAlign, $tool, $xingyuRunner)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "缺少批处理依赖：$required" }
}

$results = @()
$index = 0
foreach ($song in $manifestData.songs) {
    $index++
    $relative = [string]$song.lrc
    $source = Join-Path $musicRootPath ($relative -replace '/', '\')
    $output = Join-Path $outputPath ($relative -replace '/', '\')
    Write-Output "[$index/$($manifestData.songs.Count)] $relative"
    try {
        if (Test-Path -LiteralPath $output) {
            & $python $tool validate --source $source --enhanced $output | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Output "跳过已通过：$relative"
                $results += [ordered]@{ path = $relative; language = $song.language; status = "ready_for_listening"; reused = $true }
                continue
            }
        }

        if ($song.language -eq "zh") {
            & $xingyuRunner -MusicRoot $musicRootPath -RelativeLrc $relative -OutputRoot $outputPath -Device $Device
        } else {
            $arguments = @(
                $tool, "align",
                "--music-root", $musicRootPath,
                "--output-root", $outputPath,
                "--lyric-align", $lyricAlign,
                "--lrc", $relative,
                "--language", [string]$song.language,
                "--device", $Device,
                "--no-vad"
            )
            if ($song.separate -eq $true) { $arguments += "--separate" }
            & $python @arguments
        }
        if ($LASTEXITCODE -ne 0) { throw "对齐或校验失败，退出码 $LASTEXITCODE" }
        $results += [ordered]@{ path = $relative; language = $song.language; status = "ready_for_listening"; reused = $false }
    } catch {
        Write-Warning "$relative 处理失败：$($_.Exception.Message)"
        $results += [ordered]@{ path = $relative; language = $song.language; status = "needs_review"; error = $_.Exception.Message }
    }

    [ordered]@{ generatedAt = (Get-Date).ToString("o"); results = $results } |
        ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $outputPath "pilot_report.json")
}

$report = Join-Path $outputPath "pilot_report.json"
[ordered]@{ generatedAt = (Get-Date).ToString("o"); results = $results } |
    ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $report
$ready = @($results | Where-Object status -eq "ready_for_listening").Count
Write-Output "首批处理完成：$ready/$($results.Count) 首通过严格校验；报告：$report"
if ($ready -ne $results.Count) { exit 1 }
