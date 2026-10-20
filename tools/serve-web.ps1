# 웹 빌드(web/)를 로컬에서 확인하는 정적 파일 서버 (Node.js/Python 없이 실행)
# 사용법: powershell -ExecutionPolicy Bypass -File tools/serve-web.ps1  →  http://localhost:8060
param([int]$Port = 8060)

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\web"))
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Serving $root at http://localhost:$Port/"

$types = @{
  ".html" = "text/html; charset=utf-8"; ".js" = "application/javascript; charset=utf-8"
  ".wasm" = "application/wasm"; ".pck" = "application/octet-stream"
  ".png" = "image/png"; ".svg" = "image/svg+xml"; ".ico" = "image/x-icon"; ".json" = "application/json"
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $res = $ctx.Response
  try {
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart("/")
    if ($path -eq "") { $path = "index.html" }
    $file = [System.IO.Path]::GetFullPath((Join-Path $root $path))
    if ($file.StartsWith($root) -and (Test-Path $file -PathType Leaf)) {
      $bytes = [System.IO.File]::ReadAllBytes($file)
      $ext = [System.IO.Path]::GetExtension($file).ToLower()
      $res.ContentType = if ($types[$ext]) { $types[$ext] } else { "application/octet-stream" }
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $res.StatusCode = 404
    }
  } catch {
    $res.StatusCode = 500
  } finally {
    $res.Close()
  }
}
