# Sky Duel 홍보 쇼츠(1080x1920, 30fps, 28초)를 Godot Movie Maker로 렌더링합니다.
# 사용법: powershell -ExecutionPolicy Bypass -File tools/render-promo.ps1  →  promo/output/sky_duel_promo.avi
# 렌더링하는 동안만 override.cfg로 화면 크기를 세로 1080x1920으로 바꿉니다(stretch "viewport"라야 창 크기와 무관하게 전체 해상도로 그려짐).
param([string]$Godot = (Join-Path $env:USERPROFILE 'Apps\Godot\Godot_v4.7.2-stable_win64_console.exe'))

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$out = Join-Path $root 'promo\output'
New-Item -ItemType Directory -Force $out | Out-Null
$override = Join-Path $root 'override.cfg'
$cfg = "[display]`n`nwindow/size/viewport_width=1080`nwindow/size/viewport_height=1920`nwindow/stretch/mode=`"viewport`"`n`n[editor]`n`nmovie_writer/mjpeg_quality=0.92`n"
[IO.File]::WriteAllText($override, $cfg, (New-Object Text.UTF8Encoding $false))
try {
  # --quit-after: 스크립트 오류로 장면이 스스로 끝나지 못해도 900프레임(30초)에서 멈춥니다.
  & $Godot --path $root --fixed-fps 30 --quit-after 900 --write-movie (Join-Path $out 'sky_duel_promo.avi') res://promo/promo.tscn
} finally {
  Remove-Item $override -ErrorAction SilentlyContinue
}
