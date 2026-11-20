# Run Flutter widget tests for this project on Windows.
#
# Two environment quirks are handled here:
#  1. The Windows user folder contains an apostrophe (L't). The Flutter test
#     runner embeds the project path into a single-quoted Dart string without
#     escaping, so tests cannot compile from the original path. We run from an
#     apostrophe-free directory junction instead.
#  2. HTTP_PROXY / HTTPS_PROXY are set without NO_PROXY, which makes the
#     flutter_tester WebSocket handshake fail. Clear them for this process.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1
#   powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1 test/widget_test.dart

$ErrorActionPreference = 'Stop'

$project = "C:\Users\L't\Desktop\TED"
$alias = 'C:\dev\TED'

foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'ALL_PROXY', 'all_proxy')) {
    [Environment]::SetEnvironmentVariable($name, $null)
}
$env:NO_PROXY = 'localhost,127.0.0.1'
$env:no_proxy = 'localhost,127.0.0.1'

if (-not (Test-Path -LiteralPath $alias)) {
    $parent = Split-Path -Parent $alias
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    New-Item -ItemType Junction -Path $alias -Target $project | Out-Null
}

Push-Location -LiteralPath $alias
try {
    # Flutter 3.47.x on Windows can fail with PathExistsException while copying
    # NativeAssetsManifest.json into an existing unit_test_assets directory.
    # Removing the stale manifest makes the copy path deterministic.
    $manifest = Join-Path $alias 'build\unit_test_assets\NativeAssetsManifest.json'
    if (Test-Path -LiteralPath $manifest) {
        Remove-Item -LiteralPath $manifest -Force
    }
    & flutter test --no-pub @args
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
