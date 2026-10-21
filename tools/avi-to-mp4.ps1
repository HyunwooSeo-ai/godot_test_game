# Godot Movie Maker가 만든 AVI(MJPEG + PCM)를 Windows 내장 Media Foundation으로 MP4(H.264 + AAC)로 바꿉니다.
# 사용법: powershell -ExecutionPolicy Bypass -File tools/avi-to-mp4.ps1 -Src promo/output/sky_duel_promo.avi
param([Parameter(Mandatory)][string]$Src, [string]$Dst = '', [int]$Width = 1080, [int]$Height = 1920, [int]$Fps = 30, [int]$Mbps = 10)

$Src = [IO.Path]::GetFullPath($Src)
if (-not $Dst) { $Dst = [IO.Path]::ChangeExtension($Src, '.mp4') }
$Dst = [IO.Path]::GetFullPath($Dst)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime] | Out-Null

$ext = [System.WindowsRuntimeSystemExtensions].GetMethods()
$asTaskOp = $ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
$asTaskProg = $ext | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncActionWithProgress`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
  $task = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op))
  $task.Wait(-1) | Out-Null
  $task.Result
}

$in = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Src)) ([Windows.Storage.StorageFile])
$folder = Await ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync([IO.Path]::GetDirectoryName($Dst))) ([Windows.Storage.StorageFolder])
$out = Await ($folder.CreateFileAsync([IO.Path]::GetFileName($Dst), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])

$profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4([Windows.Media.MediaProperties.VideoEncodingQuality]::HD1080p)
$profile.Video.Width = $Width
$profile.Video.Height = $Height
$profile.Video.Bitrate = $Mbps * 1000000
$profile.Video.FrameRate.Numerator = $Fps
$profile.Video.FrameRate.Denominator = 1
$profile.Audio = [Windows.Media.MediaProperties.AudioEncodingProperties]::CreateAac(48000, 2, 192000)

$tr = New-Object Windows.Media.Transcoding.MediaTranscoder
$tr.HardwareAccelerationEnabled = $true
$prep = Await ($tr.PrepareFileTranscodeAsync($in, $out, $profile)) ([Windows.Media.Transcoding.PrepareTranscodeResult])
if (-not $prep.CanTranscode) { throw "변환할 수 없습니다: $($prep.FailureReason)" }
$task = $asTaskProg.MakeGenericMethod([double]).Invoke($null, @($prep.TranscodeAsync()))
$task.Wait(-1) | Out-Null
if ($task.IsFaulted) { throw $task.Exception }
Get-Item $Dst | Select-Object FullName, Length
