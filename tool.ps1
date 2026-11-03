param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('doctor', 'get', 'analyze', 'test', 'run', 'build-apk', 'build-release', 'build-local-test', 'devices')]
  [string]$Action,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ToolArguments
)

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$flutterSdk = if ($env:FLUTTER_ROOT -and (Test-Path -LiteralPath $env:FLUTTER_ROOT)) {
  $env:FLUTTER_ROOT
} elseif (Test-Path -LiteralPath (Join-Path $projectRoot '.tooling\flutter')) {
  Join-Path $projectRoot '.tooling\flutter'
} else {
  $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
  if (-not $flutterCommand) { throw '请先安装 Flutter 并加入 PATH，或设置 FLUTTER_ROOT。参见 README.md。' }
  Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
}
$dart = Join-Path $flutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
$flutterTools = Join-Path $flutterSdk 'bin\cache\flutter_tools.snapshot'
$jdk = if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
  $env:JAVA_HOME
} else {
  Get-ChildItem -LiteralPath (Join-Path $projectRoot '.tooling\jdk') -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') } |
    Select-Object -First 1 -ExpandProperty FullName
}
$androidSdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) {
  $env:ANDROID_SDK_ROOT
} else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

if (-not (Test-Path -LiteralPath $dart) -or -not (Test-Path -LiteralPath $flutterTools)) {
  throw 'Flutter 尚未准备完成，请先完成项目工具安装。'
}

if ($jdk) { $env:JAVA_HOME = $jdk }
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:Path = @(
  (Join-Path $flutterSdk 'bin'),
  $(if ($jdk) { Join-Path $jdk 'bin' }),
  (Join-Path $androidSdk 'platform-tools'),
  $env:Path
) -join ';'

Set-Location $projectRoot

function Invoke-Analyze {
  if ($projectRoot -notmatch '[^\x00-\x7F]') {
    & $dart $flutterTools analyze --no-pub @ToolArguments
    return
  }

  $mappedDrive = Get-FreeProjectDrive
  & subst $mappedDrive $projectRoot | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw '无法为中文项目路径创建临时分析盘符。'
  }

  try {
    Set-Location "$mappedDrive\"
    & $dart $flutterTools analyze --no-pub @ToolArguments
    $analysisExitCode = $LASTEXITCODE
  } finally {
    Set-Location $projectRoot
    & subst $mappedDrive /d | Out-Null
  }
  $global:LASTEXITCODE = $analysisExitCode
}

function Invoke-ApkBuild {
  param([ValidateSet('debug', 'release')][string]$BuildMode = 'release')
  $buildArguments = @('build', 'apk', "--$BuildMode", '--no-pub')
  if ($BuildMode -eq 'release') {
    $buildArguments += @('--target-platform', 'android-arm64', '--split-per-abi')
  }
  if ($projectRoot -notmatch '[^\x00-\x7F]' -and $flutterSdk -notmatch '[^\x00-\x7F]') {
    & $dart $flutterTools @buildArguments @ToolArguments
    return
  }

  $mappedDrive = Get-FreeProjectDrive
  & subst $mappedDrive $projectRoot | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw '无法为中文项目路径创建临时构建盘符。'
  }

  $mappedFlutterSdk = if ($flutterSdk.StartsWith($projectRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $flutterSdk.Replace($projectRoot, $mappedDrive)
  } else {
    $flutterSdk
  }
  $mappedSdkDrive = $null
  $previousFlutterRoot = $env:FLUTTER_ROOT

  try {
    if ($mappedFlutterSdk -match '[^\x00-\x7F]') {
      $sdkDriveCandidate = Get-FreeProjectDrive
      & subst $sdkDriveCandidate $flutterSdk | Out-Null
      if ($LASTEXITCODE -ne 0) { throw '无法为中文 Flutter SDK 路径创建临时盘符。' }
      $mappedSdkDrive = $sdkDriveCandidate
      $mappedFlutterSdk = "$mappedSdkDrive\"
    }
    $env:FLUTTER_ROOT = $mappedFlutterSdk
    $mappedDart = Join-Path $mappedFlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
    $mappedFlutterTools = Join-Path $mappedFlutterSdk 'bin\cache\flutter_tools.snapshot'
    Set-Location "$mappedDrive\"
    & $mappedDart $mappedFlutterTools @buildArguments @ToolArguments
    $buildExitCode = $LASTEXITCODE
  } finally {
    $env:FLUTTER_ROOT = $previousFlutterRoot
    Set-Location $projectRoot
    if ($mappedSdkDrive) { & subst $mappedSdkDrive /d | Out-Null }
    & subst $mappedDrive /d | Out-Null
  }
  $global:LASTEXITCODE = $buildExitCode
}

function Get-FreeProjectDrive {
  foreach ($letter in 'R','S','T','U','V','W','X','Y','Z') {
    if (-not (Test-Path "$($letter):\")) { return "$($letter):" }
  }
  throw '没有空闲临时盘符；请使用不含中文的工作目录。'
}

switch ($Action) {
  'doctor' { & $dart $flutterTools doctor -v @ToolArguments }
  'get' { & $dart $flutterTools pub get @ToolArguments }
  'analyze' { Invoke-Analyze }
  'test' { & $dart $flutterTools test --no-pub @ToolArguments }
  'run' { & $dart $flutterTools run @ToolArguments }
  'build-apk' { Invoke-ApkBuild -BuildMode debug }
  'build-release' { Invoke-ApkBuild }
  'build-local-test' {
    $previousSigningFlag = $env:ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING
    try {
      $env:ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING = 'true'
      Invoke-ApkBuild
      $localBuildExit = $LASTEXITCODE
    } finally {
      $env:ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING = $previousSigningFlag
    }
    $global:LASTEXITCODE = $localBuildExit
  }
  'devices' { & $dart $flutterTools devices @ToolArguments }
}

exit $LASTEXITCODE
