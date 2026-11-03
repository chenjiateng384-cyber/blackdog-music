param(
  [string]$ToolingRoot = ".tooling\lyrics-alignment"
)

$ErrorActionPreference = "Stop"
$source = Join-Path $ToolingRoot "sources\lyric-align"
$venv = Join-Path $ToolingRoot ".venv"
$repo = "https://github.com/ijuinryukichi/lyric-align.git"
$commit = "50aefb487deb30dd8b0590b78e1a705199ed9189"

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
  throw "未找到 uv。请先安装 uv，再重新运行。"
}
if (-not (Test-Path -LiteralPath $source)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $source) | Out-Null
  git clone $repo $source
  git -C $source checkout --detach $commit
}

$actual = (git -C $source rev-parse HEAD).Trim()
if ($actual -ne $commit) {
  throw "lyric-align 源码版本不匹配。期望 $commit，实际 $actual。为避免静默更换算法，已停止。"
}

if (-not (Test-Path -LiteralPath $venv)) {
  uv venv --python 3.12 $venv
}
$python = Join-Path $venv "Scripts\python.exe"
uv pip install --python $python -e "$source[asr]"

Write-Output "环境已就绪：$python"
Write-Output "对齐器：$(Join-Path $venv 'Scripts\lyric-align.exe')"
