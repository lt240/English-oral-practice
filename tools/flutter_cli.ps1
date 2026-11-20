# Flutter CLI 直连入口（绕过 flutter.bat 对 cmd.exe 的依赖）
# 在本机受限 shell 中也能执行 pub get / analyze / test / build apk。
# 用法：powershell -File tools/flutter_cli.ps1 build apk --release
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CliArgs
)

$ErrorActionPreference = 'Continue'
$flutterRoot = 'D:\flutter'
$env:FLUTTER_ROOT = $flutterRoot
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$env:PUB_ENVIRONMENT = 'flutter_cli'

if (-not $env:JAVA_HOME) { $env:JAVA_HOME = "$env:LOCALAPPDATA\Programs\jdk-17.0.20.1+1" }
if (Test-Path "$env:JAVA_HOME\bin\java.exe") {
    $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
}
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
if (Test-Path $sdk) {
    $env:ANDROID_HOME = $sdk
    $env:ANDROID_SDK_ROOT = $sdk
}

$dart = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
$snapshot = Join-Path $flutterRoot 'bin\cache\flutter_tools.snapshot'
$pkgConfig = Join-Path $flutterRoot 'packages\flutter_tools\.dart_tool\package_config.json'

# PowerShell treats --debug / --release as common parameters and swallows them.
# Allow passing the whole command as one quoted string, then split it here.
if ($CliArgs.Count -eq 1 -and $CliArgs[0] -match '\s') {
    $cli = $CliArgs[0] -split '\s+'
} else {
    $cli = $CliArgs
}

& $dart --disable-dart-dev "--packages=$pkgConfig" $snapshot @cli
exit $LASTEXITCODE
