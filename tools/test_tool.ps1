# Windows launcher regression tests. Uses a local fake SDK, never an Android device.
$ErrorActionPreference = 'Stop'
$launcherSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'tool.ps1'
$testTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $testTempBase ('blackdog-launcher-' + [Guid]::NewGuid().ToString('N'))
$testSdk = Join-Path $testDirectory '外部 SDK'
$testProject = Join-Path $testDirectory '项目 空格'
$testCapture = Join-Path $testDirectory 'capture.txt'
$testVariables = @('FLUTTER_ROOT', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT',
  'PUB_HOSTED_URL', 'FLUTTER_STORAGE_BASE_URL', 'ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING',
  'BLACKDOG_TEST_CAPTURE', 'BLACKDOG_TEST_EXIT')
$originalVariables = @{}
foreach ($name in $testVariables) {
  $originalVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Assert-Contains([string[]]$Lines, [string]$Expected) {
  if ($Lines -notcontains $Expected) { throw "Missing capture: $Expected" }
}

function Invoke-LauncherTest([string]$Action, [string[]]$Arguments, [int]$ExpectedExit = 0) {
  $env:BLACKDOG_TEST_EXIT = [string]$ExpectedExit
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testProject 'tool.ps1') $Action @Arguments | Out-Null
  if ($LASTEXITCODE -ne $ExpectedExit) { throw "Unexpected exit for ${Action}: $LASTEXITCODE" }
  $capturedLines = @(Get-Content -LiteralPath $testCapture -Encoding UTF8)
  $capturedDirectory = ($capturedLines | Where-Object { $_.StartsWith('CWD=') }) -replace '^CWD=', ''
  if (-not (Test-Path -LiteralPath $testProject)) { throw 'Test project disappeared' }
  if ($capturedDirectory -match '^[A-Z]:\\$' -and (Test-Path -LiteralPath $capturedDirectory)) {
    throw "Temporary project drive was not released: $capturedDirectory"
  }
  return $capturedLines
}

try {
  New-Item -ItemType Directory -Path (Join-Path $testSdk 'bin/cache/dart-sdk/bin') -Force | Out-Null
  New-Item -ItemType Directory -Path $testProject | Out-Null
  Copy-Item -LiteralPath $launcherSource -Destination (Join-Path $testProject 'tool.ps1')
  New-Item -ItemType File -Path (Join-Path $testSdk 'bin/cache/flutter_tools.snapshot') | Out-Null
  $fakeDart = @'
using System;
using System.IO;
using System.Collections.Generic;
public class FakeDart {
  public static int Main(string[] args) {
    var lines = new List<string>();
    lines.Add("CWD=" + Directory.GetCurrentDirectory());
    foreach (var arg in args) lines.Add("ARG=" + arg);
    foreach (var name in new[] {"FLUTTER_ROOT", "PUB_HOSTED_URL", "FLUTTER_STORAGE_BASE_URL", "ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING"})
      lines.Add(name + "=" + (Environment.GetEnvironmentVariable(name) ?? "<unset>"));
    File.WriteAllLines(Environment.GetEnvironmentVariable("BLACKDOG_TEST_CAPTURE"), lines.ToArray());
    return int.Parse(Environment.GetEnvironmentVariable("BLACKDOG_TEST_EXIT") ?? "0");
  }
}
'@
  Add-Type -TypeDefinition $fakeDart -Language CSharp -OutputType ConsoleApplication `
    -OutputAssembly (Join-Path $testSdk 'bin/cache/dart-sdk/bin/dart.exe')
  $env:FLUTTER_ROOT = $testSdk
  $env:ANDROID_HOME = Join-Path $testDirectory 'android-sdk'
  $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
  $env:BLACKDOG_TEST_CAPTURE = $testCapture
  $env:PUB_HOSTED_URL = 'https://packages.example.invalid'
  $env:FLUTTER_STORAGE_BASE_URL = 'https://artifacts.example.invalid'

  $lines = Invoke-LauncherTest 'doctor' @('--help')
  Assert-Contains $lines 'ARG=--help'
  Assert-Contains $lines 'PUB_HOSTED_URL=https://packages.example.invalid'
  Assert-Contains $lines 'FLUTTER_STORAGE_BASE_URL=https://artifacts.example.invalid'
  'PASS: doctor arguments and explicit download hosts preserved'

  $lines = Invoke-LauncherTest 'build-local-test' @('--build-number=2050')
  Assert-Contains $lines 'ARG=--release'
  Assert-Contains $lines 'ARG=--build-number=2050'
  Assert-Contains $lines 'ORG_GRADLE_PROJECT_HARMONY_LOCAL_TEST_SIGNING=true'
  $sdkRoot = ($lines | Where-Object { $_.StartsWith('FLUTTER_ROOT=') }) -replace '^FLUTTER_ROOT=', ''
  if ($sdkRoot -match '[^\x00-\x7F]') { throw 'External Unicode SDK path was not mapped' }
  if ($sdkRoot -match '^[A-Z]:\\$' -and (Test-Path -LiteralPath $sdkRoot)) {
    throw 'Temporary SDK drive was not released'
  }
  'PASS: release arguments, local-test signing, Unicode path and drive cleanup'
  'PASS: external Unicode SDK path and SDK drive cleanup'

  $lines = Invoke-LauncherTest 'build-local-test' @('--build-number=12') 47
  Assert-Contains $lines 'ARG=--build-number=12'
  $failedSdkRoot = ($lines | Where-Object { $_.StartsWith('FLUTTER_ROOT=') }) -replace '^FLUTTER_ROOT=', ''
  if ($failedSdkRoot -match '^[A-Z]:\\$' -and (Test-Path -LiteralPath $failedSdkRoot)) {
    throw 'Failed build leaked the temporary SDK drive'
  }
  'PASS: failed release preserves exit and releases SDK mapping'

  $lines = Invoke-LauncherTest 'build-apk' @('--help')
  Assert-Contains $lines 'ARG=--debug'
  Assert-Contains $lines 'ARG=--help'
  'PASS: debug build arguments and Unicode project path'

  $lines = Invoke-LauncherTest 'analyze' @('--fatal-infos') 43
  Assert-Contains $lines 'ARG=--fatal-infos'
  'PASS: native failure exit preserved through drive cleanup'

  $env:PUB_HOSTED_URL = $null
  $env:FLUTTER_STORAGE_BASE_URL = $null
  $lines = Invoke-LauncherTest 'run' @('-d', 'test-device')
  Assert-Contains $lines 'ARG=test-device'
  Assert-Contains $lines 'PUB_HOSTED_URL=<unset>'
  Assert-Contains $lines 'FLUTTER_STORAGE_BASE_URL=<unset>'
  'PASS: device arguments forwarded; SDK defaults used when hosts unset'
} finally {
  foreach ($name in $testVariables) {
    [Environment]::SetEnvironmentVariable($name, $originalVariables[$name], 'Process')
  }
  # Delete only this run's generated fixtures, never a supplied project or SDK.
  $resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
  $expectedPrefix = $testTempBase.TrimEnd('\') + '\blackdog-launcher-'
  if (-not $resolvedTestDirectory.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing cleanup outside the generated test directory'
  }
  if (Test-Path -LiteralPath $resolvedTestDirectory) {
    Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
  }
}
