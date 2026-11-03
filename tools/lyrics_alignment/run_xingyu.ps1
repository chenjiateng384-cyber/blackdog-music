param(
    [Parameter(Mandatory = $true)][string]$MusicRoot,
    [Parameter(Mandatory = $true)][string]$RelativeLrc,
    [string]$OutputRoot = "artifacts\lyrics_alignment_xingyu_output",
    [ValidateSet("cpu", "cuda")][string]$Device = "cpu"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$musicRootPath = (Resolve-Path -LiteralPath $MusicRoot).Path.TrimEnd("\")
$outputPath = if ([IO.Path]::IsPathRooted($OutputRoot)) { [IO.Path]::GetFullPath($OutputRoot) } else { [IO.Path]::GetFullPath((Join-Path $projectRoot $OutputRoot)) }
if ($outputPath.Equals($musicRootPath, [StringComparison]::OrdinalIgnoreCase) -or $outputPath.StartsWith($musicRootPath + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "输出目录不能位于音乐库内"
}

$sourceLrc = Join-Path $musicRootPath $RelativeLrc
if (-not (Test-Path -LiteralPath $sourceLrc)) { throw "找不到原歌词：$sourceLrc" }
$stem = [IO.Path]::GetFileNameWithoutExtension($sourceLrc)
$audio = $null
foreach ($extension in @(".flac", ".wav", ".mp3", ".m4a", ".aac", ".ogg", ".opus")) {
    $candidate = Join-Path (Split-Path $sourceLrc) ($stem + $extension)
    if (Test-Path -LiteralPath $candidate) { $audio = $candidate; break }
}
if (-not $audio) { throw "找不到同目录同名音频：$sourceLrc" }

$runtimeRoot = Join-Path $projectRoot ".tooling\lyrics-alignment"
$python = Join-Path $runtimeRoot ".venv-xingyu\Scripts\python.exe"
$aligner = Join-Path $runtimeRoot ".venv-xingyu\Scripts\xingyu-align.exe"
$modelDir = Join-Path $runtimeRoot "models\wav2vec2-large-xlsr-53-chinese-zh-cn"
$nltkDir = Join-Path $runtimeRoot "nltk_data"
$tool = Join-Path $PSScriptRoot "harmony_lyrics_tool.py"
foreach ($required in @($python, $aligner, $modelDir, $nltkDir, $tool)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "对齐环境未准备，请先运行 bootstrap_xingyu.ps1：$required" }
}

$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (-not $ffmpeg) {
    $packages = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    $ffmpeg = Get-ChildItem -LiteralPath $packages -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $ffmpeg) { throw "找不到 FFmpeg，请先安装 FFmpeg" }
$env:PATH = "$($ffmpeg.DirectoryName);$env:PATH"
$env:XINGYU_ALIGNMENT_MODEL_DIR = $modelDir
$env:NLTK_DATA = $nltkDir

$relativeParent = Split-Path $RelativeLrc -Parent
$rawDir = Join-Path $outputPath (Join-Path ".work\xingyu" (Join-Path $relativeParent $stem))
$trustedText = Join-Path $rawDir "trusted.txt"
$enhanced = Join-Path $outputPath $RelativeLrc
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

& $python $tool prepare-text --source $sourceLrc --output $trustedText --language zh
if ($LASTEXITCODE -ne 0) { throw "可信歌词提取失败" }
& $aligner align --audio $audio --lyrics $trustedText --output-dir $rawDir --language zh --device $Device --overwrite --json-result
if ($LASTEXITCODE -ne 0) { throw "逐字强制对齐失败" }
& $python $tool convert-swlrc --source (Join-Path $rawDir "lyrics.swlrc") --source-lrc $sourceLrc --output $enhanced --language zh
if ($LASTEXITCODE -ne 0) { throw "Harmony增强歌词转换失败" }
& $python $tool validate --source $sourceLrc --enhanced $enhanced
if ($LASTEXITCODE -ne 0) { throw "增强歌词严格校验失败" }
Write-Output "已生成：$enhanced"
Write-Output "原歌词未修改：$sourceLrc"