# MediLink Round 3 verification. Run from PowerShell:
#   powershell -ExecutionPolicy Bypass -File "<project>\redesign\verify.ps1"
# Writes everything to redesign\verify\ so Claude can read the results.
$ErrorActionPreference = 'Continue'
$root  = Split-Path -Parent $PSScriptRoot
$out   = Join-Path $root 'redesign\verify'
$tools = Join-Path $root 'redesigned_app_screenshots\_capture_tooling'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$log = Join-Path $out 'verify_log.txt'
"MediLink verify $(Get-Date -Format s)" | Out-File $log -Encoding utf8
function Step($name, [scriptblock]$cmd) {
  "`n===== $name =====" | Out-File $log -Append -Encoding utf8
  & $cmd *>&1 | Out-File $log -Append -Encoding utf8
  "EXIT $name : $LASTEXITCODE" | Out-File $log -Append -Encoding utf8
  Write-Host "$name -> exit $LASTEXITCODE"
}

Set-Location (Join-Path $root 'frontend')
Step 'pub get'            { flutter pub get }
Step 'analyze'            { flutter analyze --no-fatal-infos }
Step 'existing tests'     { flutter test }
Step 'SOS regression AFTER' { flutter test "$tools\sos_regression_test.dart" --dart-define=PHASE=after "--dart-define=OUT_DIR=$out" }
Step 'profile + fallbacks'  { flutter test "$tools\profile_fallback_test.dart" "--dart-define=OUT_DIR=$out" }

# Baseline (git a7eb01a) in a temporary worktree: same SOS test, before the redesign.
$base = Join-Path $env:TEMP 'medilink_baseline_a7eb01a'
if (Test-Path $base) { git -C $root worktree remove --force $base 2>$null; Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue }
Step 'baseline worktree'  { git -C $root worktree add --detach $base a7eb01a }
Set-Location (Join-Path $base 'frontend')
Step 'baseline pub get'   { flutter pub get }
Step 'SOS regression BEFORE' { flutter test "$tools\sos_regression_test.dart" --dart-define=PHASE=before "--dart-define=OUT_DIR=$out" }
Set-Location $root
Step 'remove baseline worktree' { git -C $root worktree remove --force $base }

Write-Host "`nDone. Results: $out"
