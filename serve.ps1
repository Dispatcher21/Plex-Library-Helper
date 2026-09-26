# Minimal static file server for trying the dashboard locally (Windows PowerShell 5.1+).
# Usage: powershell -ExecutionPolicy Bypass -File serve.ps1 [-Port 5173]
param([int]$Port = 5173)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.json' = 'application/json'; '.webmanifest' = 'application/manifest+json' }
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Plex Library Dashboard running at http://localhost:$Port/  (Ctrl+C to stop)"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
        if (-not $rel) { $rel = 'index.html' }
        $path = [IO.Path]::GetFullPath((Join-Path $root $rel))
        $res = $ctx.Response
        try {
            if ($path.StartsWith($root) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $bytes = [IO.File]::ReadAllBytes($path)
                $res.ContentType = $types[[IO.Path]::GetExtension($path).ToLower()]
                if (-not $res.ContentType) { $res.ContentType = 'application/octet-stream' }
                $res.Headers['Cache-Control'] = 'no-cache'
                $res.ContentLength64 = $bytes.Length
                if ($ctx.Request.HttpMethod -ne 'HEAD') { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
            } else { $res.StatusCode = 404 }
        } catch { Write-Host "Request for /$rel failed: $($_.Exception.Message)" }
        try { $res.Close() } catch { }
    }
} finally { $listener.Stop() }
