# =============================================================================
# vLLM load test (PowerShell) — fire N requests with bounded concurrency.
# =============================================================================
# Usage: powershell -File load-test.ps1 [-Total 100] [-Concurrency 8] [-Port 8000]
# Alternates traffic-a / traffic-b (shared system prompt -> prefix cache).
# Prints progress every 10 completed, then a latency-percentile summary.
# =============================================================================
param(
    [int]$Total = 100,
    [int]$Concurrency = 8,
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$url = "http://localhost:$Port/v1/chat/completions"
$ta = Get-Content -Raw (Join-Path $scriptDir 'kind/traffic-a.json')
$tb = Get-Content -Raw (Join-Path $scriptDir 'kind/traffic-b.json')

Write-Host ">> firing $Total requests at $url (concurrency=$Concurrency)"

$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$done = [ref]0
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Bounded-concurrency via a runspace pool + async invocations.
$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()
$handles = @()

foreach ($i in 1..$Total) {
    $body = if ($i % 2 -eq 0) { $tb } else { $ta }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript({
        param($i, $url, $body, $results, $done)
        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180 -UseBasicParsing
            $code = [int]$r.StatusCode
        } catch {
            $code = 0
        }
        $t0.Stop()
        $results.Add([pscustomobject]@{ code = $code; ms = [math]::Round($t0.Elapsed.TotalMilliseconds) })
        $n = [System.Threading.Interlocked]::Increment($done)
        if ($n % 10 -eq 0) { Write-Host "   ...$n / done" }
    }).AddArgument($i).AddArgument($url).AddArgument($body).AddArgument($results).AddArgument($done)
    $handles += [pscustomobject]@{ ps = $ps; async = $ps.BeginInvoke() }
}

foreach ($h in $handles) { $h.ps.EndInvoke($h.async); $h.ps.Dispose() }
$pool.Close(); $pool.Dispose()
$sw.Stop()

$all = @($results)
$ok = @($all | Where-Object { $_.code -eq 200 })
$fail = @($all | Where-Object { $_.code -ne 200 })
$lat = @($ok | Select-Object -ExpandProperty ms | Sort-Object)

Write-Host ""
Write-Host "=== RESULTS ==="
Write-Host "total=$($all.Count)  ok=$($ok.Count)  failed=$($fail.Count)"
$wall = [math]::Max(1, $sw.Elapsed.TotalSeconds)
Write-Host ("wall_clock={0:N1}s  throughput={1:N2} req/s" -f $sw.Elapsed.TotalSeconds, ($all.Count / $wall))
if ($lat.Count -gt 0) {
    function Pct($p) { $lat[[math]::Min($lat.Count - 1, [int]($lat.Count * $p / 100))] }
    Write-Host ("latency ms: min={0}  p50={1}  p90={2}  p99={3}  max={4}" -f $lat[0], (Pct 50), (Pct 90), (Pct 99), $lat[-1])
}
if ($fail.Count -gt 0) {
    $codes = ($fail | Group-Object code | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ', '
    Write-Host "failed codes: $codes"
}
