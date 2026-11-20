# 批量：抽音频(16k mono) + whisper base 转写 12 篇
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\L''t\Desktop\TED'
$ffmpeg = 'C:\Users\Public\ffmpeg.exe'
$whisper = "$root\tools\whisper\bin\Release\whisper-cli.exe"
$model = "$root\tools\whisper\ggml-base.en.bin"
$wdir = "$root\tools\whisper"

$map = @(
  @('levitin_stay_calm','ted_03.mp4'),
  @('ted_true_confidence','ted_04.mp4'),
  @('ted_humility_water','ted_06.mp4'),
  @('brewer_break_habit','ted_07.mp4'),
  @('ted_self_criticism','ted_13.mp4'),
  @('ted_believe_yourself','ted_09.mp4'),
  @('ted_not_personal','ted_08.mp4'),
  @('esfahani_more_than_happy','ted_12.mp4'),
  @('ted_why_meaning','ted_05.mp4'),
  @('ted_meaning_of_life','ted_10.mp4'),
  @('robbins_five_seconds','ted_11.mp4'),
  @('ted_mind_control','ted_02.mp4')
)

foreach ($m in $map) {
  $id = $m[0]; $audio = $m[1]
  Write-Host "=== $id ($audio) ==="
  & $ffmpeg -y -i "$root\assets\audio\$audio" -ar 16000 -ac 1 -c:a pcm_s16le "$wdir\${id}16.wav" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] ffmpeg $id"; continue }
  & $whisper -m $model -f "$wdir\${id}16.wav" -l en -ojf -t 8 -sns -of "$wdir\${id}_base" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] whisper $id"; continue }
  Copy-Item "$wdir\${id}_base.json" "$wdir\${id}.json" -Force
  Write-Host "  [OK] $id"
}
Write-Host "ALL DONE"
