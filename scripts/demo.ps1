# End-to-end demo and smoke test of the deployed application. Every step prints PASS or CHECK.
# Run from the project folder AFTER `terraform apply` (wait ~2 minutes after apply for the functions to be ready):
#     powershell -ExecutionPolicy Bypass -File scripts\demo.ps1
# Requires terraform and gcloud (logged in) on PATH.

param([int]$TimeoutSeconds = 150)

$ErrorActionPreference = "Continue"

$out    = terraform output -json | ConvertFrom-Json
$url    = $out.api_url.value.TrimEnd("/")
$key    = (terraform output -raw api_key).Trim()
$sub    = $out.dead_letter_subscription.value
$job    = $out.report_job.value
$region = $out.region.value
$proj   = $out.project_id.value

$script:pass = 0; $script:total = 0

function Banner($text) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Check($label, $ok, $detail) {
    $script:total++
    if ($ok) { $script:pass++ }
    $mark = if ($ok) { "PASS " } else { "CHECK" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("  {0} {1}  {2}" -f $mark, $label, $detail) -ForegroundColor $color
}

function Call($method, $path, $body, $withKey = $true) {
    $headers = @{}
    if ($withKey) { $headers["X-API-Key"] = $key }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $params = @{ Uri = "$url$path"; Method = $method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($body) { $params["Body"] = ($body | ConvertTo-Json -Depth 6); $params["ContentType"] = "application/json" }
        $r = Invoke-WebRequest @params
        $status = [int]$r.StatusCode; $text = $r.Content
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $text = ""
        if ($_.Exception.Response) {
            try { $text = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        }
    }
    $sw.Stop()
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ Status = $status; Json = $json; Ms = [int]$sw.ElapsedMilliseconds }
}

function Wait-Status($id, $wanted) {
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ""
    while ((Get-Date) -lt $end) {
        $r = Call "GET" "/orders/$id" $null
        if ($r.Json) { $last = $r.Json.status }
        if ($last -in $wanted) { return $last }
        Start-Sleep -Seconds 3
    }
    return $last
}

Banner "1. The API is up and protected"
$h = Call "GET" "/health" $null $false
Check "GET /health (public)" ($h.Status -eq 200) "-> $($h.Status) in $($h.Ms) ms (the first call may include a cold start)"
$noKey = Call "GET" "/orders" $null $false
Check "GET /orders without the API key is refused" ($noKey.Status -eq 401) "-> $($noKey.Status)"
$bad = Call "POST" "/orders" @{ customer = ""; items = @() }
Check "An invalid order is rejected with a clear error" ($bad.Status -eq 400) "-> $($bad.Status) $($bad.Json.error)"

Banner "2. Event-driven processing: orders flow API -> Pub/Sub -> worker -> Firestore"
$good = @()
foreach ($c in @("Alice", "Bob", "Carol")) {
    $r = Call "POST" "/orders" @{ customer = $c; items = @(@{ sku = "BOOK-1"; qty = 2; price_cents = 1500 }, @{ sku = "PEN_2"; qty = 5; price_cents = 120 }) }
    Check "POST /orders for $c" ($r.Status -eq 201) "-> $($r.Status) in $($r.Ms) ms, id $($r.Json.order_id)"
    if ($r.Json.order_id) { $good += $r.Json.order_id }
}
Write-Host "  Waiting for the worker (it starts from zero instances, so the first order may take a few seconds)..." -ForegroundColor DarkGray
foreach ($id in $good) {
    $s = Wait-Status $id @("processed", "failed")
    $o = (Call "GET" "/orders/$id" $null).Json
    Check "order $($id.Substring(0,8)) processed with the correct total" (($s -eq "processed") -and ($o.total_cents -eq 3600)) "-> status $s, total $($o.total_cents) cents (expected 3600)"
}

Banner "3. Reliability: a poison order is retried, then dead-lettered"
$p = Call "POST" "/orders" @{ customer = "poison"; items = @(@{ sku = "BOOK-1"; qty = 1; price_cents = 1000 }) }
Check "POST /orders for customer 'poison'" ($p.Status -eq 201) "-> $($p.Status), id $($p.Json.order_id)"
Write-Host "  The worker fails this order on purpose; it is retried, then moved to the dead-letter topic..." -ForegroundColor DarkGray
$ps = Wait-Status $p.Json.order_id @("failed")
$po = (Call "GET" "/orders/$($p.Json.order_id)" $null).Json
Check "the poison order ends as 'failed' after retries" ($ps -eq "failed") "-> status $ps after $($po.attempts) attempt(s): $($po.failure_reason)"
Write-Host "  Dead-letter topic contents:" -ForegroundColor DarkGray
$dl = cmd /c "gcloud pubsub subscriptions pull $sub --project=$proj --limit=5 --format=value(message.data) 2>&1" | Out-String
$dlText = $dl
try { $dlText = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($dl.Trim() -split "`n")[0].Trim()))) } catch { }
Check "the failed order is parked in the dead-letter topic" ($dl -match "[a-zA-Z0-9]{16,}") ("-> " + $dlText.Trim())

Banner "4. The scheduled report"
$run = cmd /c "gcloud scheduler jobs run $job --location=$region --project=$proj 2>&1" | Out-String
Check "Cloud Scheduler job triggered" ($LASTEXITCODE -eq 0) "-> $($run.Trim())"
Start-Sleep -Seconds 20
$rep = Call "GET" "/report" $null
for ($i = 0; $i -lt 6 -and $rep.Status -ne 200; $i++) { Start-Sleep -Seconds 10; $rep = Call "GET" "/report" $null }
Check "GET /report returns the aggregated counts" ($rep.Status -eq 200) "-> $($rep.Status) $(if ($rep.Json) { ($rep.Json.counts | ConvertTo-Json -Compress) })"

Banner "5. Live statistics"
$st = Call "GET" "/stats" $null
Write-Host ("  " + ($st.Json.counts | ConvertTo-Json -Compress))
Check "GET /stats" ($st.Status -eq 200) "-> $($st.Status)"

Banner "Result"
$color = if ($script:pass -eq $script:total) { "Green" } else { "Yellow" }
Write-Host ("  {0} of {1} checks passed." -f $script:pass, $script:total) -ForegroundColor $color
Write-Host ""
Write-Host "  See it in the console:  Monitoring > Dashboards (instances, latency, orders), Logging, Pub/Sub, Firestore." -ForegroundColor Cyan
Write-Host "  Open the dashboard:     $($out.dashboard_url.value)" -ForegroundColor Cyan
