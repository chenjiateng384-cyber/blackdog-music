param(
    [string]$Endpoint = "https://hf-mirror.com"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$runtimeRoot = Join-Path $projectRoot ".tooling\lyrics-alignment"
$source = Join-Path $runtimeRoot "sources\xingyu-lyrics-aligner"
$venv = Join-Path $runtimeRoot ".venv-xingyu"
$modelDir = Join-Path $runtimeRoot "models\wav2vec2-large-xlsr-53-chinese-zh-cn"
$nltkDir = Join-Path $runtimeRoot "nltk_data"
$pinnedCommit = "ef5ad02a0059ab07f4cc92f608d373447c89b007"
$modelRevision = "99ccb2737be22b8bb50dcfcc39ad4d567fb90cfd"
$modelSha256 = "DE031FD4B29E0C0667E5346450FADFE1326C89936B888B59C4EDE608DB763EE4"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "需要先安装 Git" }
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { throw "需要先安装 uv" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw "需要系统 curl.exe" }

New-Item -ItemType Directory -Force -Path (Split-Path $source), $modelDir, $nltkDir | Out-Null
if (-not (Test-Path (Join-Path $source ".git"))) {
    git clone https://github.com/wangjiqing/xingyu-lyrics-aligner.git $source
    if ($LASTEXITCODE -ne 0) { throw "Xingyu Lyrics Aligner 下载失败" }
    git -C $source checkout $pinnedCommit
    if ($LASTEXITCODE -ne 0) { throw "无法切换到固定版本" }
}
$currentCommit = (git -C $source rev-parse HEAD).Trim()
if ($currentCommit -ne $pinnedCommit) { throw "Xingyu 源码版本不符：$currentCommit" }

$python = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path $python)) {
    uv venv --python 3.12 $venv
    if ($LASTEXITCODE -ne 0) { throw "Python 环境创建失败" }
}
uv pip install --python $python -e "${source}[alignment]"
if ($LASTEXITCODE -ne 0) { throw "Xingyu 依赖安装失败" }

$files = [ordered]@{
    "config.json" = 1567L
    "preprocessor_config.json" = 158L
    "special_tokens_map.json" = 85L
    "vocab.json" = 44357L
    "pytorch_model.bin" = 1276296151L
}
$base = "$Endpoint/jonatasgrosman/wav2vec2-large-xlsr-53-chinese-zh-cn/resolve/$modelRevision"
foreach ($entry in $files.GetEnumerator()) {
    $target = Join-Path $modelDir $entry.Key
    if ((Test-Path $target) -and (Get-Item $target).Length -eq $entry.Value) { continue }
    if ((Test-Path $target) -and (Get-Item $target).Length -gt $entry.Value) {
        Move-Item -LiteralPath $target -Destination "$target.corrupt.$([DateTimeOffset]::Now.ToUnixTimeSeconds())"
    }
    curl.exe -L --fail --retry 20 --retry-all-errors --retry-delay 2 --speed-time 30 --speed-limit 1024 --continue-at - --output $target "$base/$($entry.Key)"
    if ($LASTEXITCODE -ne 0 -or (Get-Item $target).Length -ne $entry.Value) { throw "模型文件下载不完整：$($entry.Key)" }
}
$actualHash = (Get-FileHash (Join-Path $modelDir "pytorch_model.bin") -Algorithm SHA256).Hash
if ($actualHash -ne $modelSha256) { throw "中文对齐模型校验失败" }

$env:NLTK_ALLOW_PROXIED_URLOPEN = "1"
& $python -c "import nltk,sys; sys.exit(0 if nltk.download('punkt_tab', download_dir=r'$nltkDir', quiet=True) else 1)"
if ($LASTEXITCODE -ne 0) { throw "NLTK punkt_tab 下载失败" }

Write-Output "高精度歌词对齐环境准备完成"
Write-Output "模型：$modelDir"
Write-Output "运行：tools\lyrics_alignment\run_xingyu.ps1"