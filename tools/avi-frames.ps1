param([string]$Avi, [string]$OutDir, [double[]]$Seconds, [int]$Fps = 30)
# Godot Movie Maker가 만든 MJPEG AVI에서 지정한 시점의 프레임(JPEG)을 꺼내고, 프레임 수·길이·음성 크기를 알려 줍니다.
# 사용법: & tools/avi-frames.ps1 -Avi promo/output/sky_duel_promo.avi -OutDir $env:TEMP\frames -Seconds @(1.0, 5.0)
New-Item -ItemType Directory -Force $OutDir | Out-Null
$fs = [IO.File]::OpenRead($Avi)
$br = New-Object IO.BinaryReader($fs)
$frames = New-Object System.Collections.Generic.List[long]
$sizes = New-Object System.Collections.Generic.List[int]
$audioBytes = 0L
$width = 0; $height = 0
# RIFF 구조를 따라가며 'movi' LIST 안의 00dc(영상) / 01wb(음성) 청크를 모읍니다.
function Walk([long]$start, [long]$end) {
  $fs.Position = $start
  while ($fs.Position + 8 -le $end) {
    $id = [Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
    $size = $br.ReadUInt32()
    $dataPos = $fs.Position
    if ($id -eq 'RIFF' -or $id -eq 'LIST') {
      $kind = [Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
      Walk ($dataPos + 4) ($dataPos + $size)
    } elseif ($id -eq 'avih') {
      $fs.Position = $dataPos + 32; $script:width = $br.ReadInt32(); $script:height = $br.ReadInt32()
    } elseif ($id -like '00d?') {  # Godot는 00db를 씁니다(00dc 아님)
      $frames.Add($dataPos); $sizes.Add([int]$size)
    } elseif ($id -eq '01wb') {
      $script:audioBytes += $size
    }
    $fs.Position = $dataPos + $size + ($size % 2)
  }
}
Walk 0 $fs.Length
"size=${width}x${height} video_frames=$($frames.Count) ($([math]::Round($frames.Count / $Fps, 2))s) audio_bytes=$audioBytes"
foreach ($s in $Seconds) {
  $i = [math]::Min($frames.Count - 1, [int]($s * $Fps))
  $fs.Position = $frames[$i]
  $bytes = $br.ReadBytes($sizes[$i])
  $name = Join-Path $OutDir ("f_{0:000.0}s.jpg" -f $s)
  [IO.File]::WriteAllBytes($name, $bytes)
  $name
}
$br.Close()
