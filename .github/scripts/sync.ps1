# Portable gviz sync — pulls all 3 tabs and rewrites the embedded
# window.__DASHBOARD_DATA__ in index.html. Runs on any PS7+ runner
# (Windows / Linux / macOS). Designed for GitHub Actions but works locally too.
#
# Reads/writes ./index.html and ./CSM_Dashboard.html relative to CWD.

$ErrorActionPreference = 'Stop'
$repoRoot = Get-Location
# All copies the sync needs to keep in lockstep:
#   - index.html              GitHub repo + GitHub Pages (if enabled)
#   - CSM_Dashboard.html      historical email-snapshot mirror
#   - vercel_deploy/index.html Vercel production deployment
#                              (Vercel project: customer_success_operative_dashboard,
#                               team: hey-s-projects4)
# Bug fixed 2026-06-09: vercel_deploy/ was being ignored by sync, so Vercel kept
# serving a stale snapshot for ~2 weeks while index.html landed fresh data on
# every sync. Also the previous Vercel project (csm-dashboard-navy, owned by
# "hey's projects" team) was silently rejecting our commits because the GitHub
# author didn't have team access. New project + deploy-hook gates the rebuild
# on a GitHub Actions secret VERCEL_DEPLOY_HOOK rather than commit-author ACL.
# Any file in $dashFiles below gets the new window.__DASHBOARD_DATA__ block
# written to it.
$dashFiles = @(
    "$repoRoot/index.html",
    "$repoRoot/CSM_Dashboard.html",
    "$repoRoot/vercel_deploy/index.html"
) | Where-Object { Test-Path $_ }
$primary = "$repoRoot/index.html"
if (-not (Test-Path $primary)) { throw "index.html not found at $primary" }

$sheetId = '1kdGwx6rxBy8MWKq8WyR04xq4QgWSfnh1W4nHsOqj_HE'
$urls = @{
    vini    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=1616842841&headers=2"
    payment = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=674556270"
    # DEPRECATED: the ticket dump moved to the dilipticket Freshdesk API
    # (see $ticketsApiUrl below). Kept here only for reference / rollback.
    tickets = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=832733618"
    studio  = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=603796861"
    # CSAT / Communication source: published Google Sheet, gid=179502765
    # (per user spec, 2026-06-15). This is a "Publish to web" tab the user
    # maintains; we read its CSV export endpoint directly. Headers:
    #   Date · Enterprise Name · Enterprise ID · CSM Name ·
    #   Meeting CSAT · Thread CSAT · Ticket CSAT · Call CSAST ·
    #   Average_Csat_Score · Interaction Count
    # The /d/e/2PACX-.../pub?...&output=csv form auto-republishes whenever the
    # sheet changes, so the 15-min auto-sync picks up fresh data each cycle.
    # Fetched as CSV (ConvertFrom-Csv) via Fetch-Csv.
    csat    = "https://docs.google.com/spreadsheets/d/e/2PACX-1vSDnnhBjgOPrT56bih4U5DnVDWZwa20dS25L1UagS3s5FP5y3mFxWoaDE6Nyama86X9v-1LjUoPzIOv/pub?gid=179502765&single=true&output=csv"
    # Report-coverage API — aggregate per-day counts of reports sent / not sent.
    # Used for the Studio "Reports Sent (7d)" KPI tile.
    coverage = "https://vin-tracker-dashboard.vercel.app/api/report-coverage?days=7"
    # Report-tracking API — per-row data (one row per enterprise × date × type)
    # with status sent / skipped / error / pending. Paginated at 500 max.
    # Used to build the per-rooftop dot strip + per-group %.
    tracking = "https://vin-tracker-dashboard.vercel.app/api/report-tracking"
    # Payment periods — invoice-row granularity per enterprise. Used to derive
    # T-1 / T-2 / T-3 historical customer_status via dense-rank over
    # (Service_period_Start_date, Service_period_End_date) DESC, per enterprise.
    # Cols: E=customer_status, V=EnterprisesID, Y=Service_period_Start_date,
    # Z=Service_period_End_date.
    payperiods = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=1395015507&headers=1"
    # Churn-analysis source — a SEPARATE Spyne churn tracker, now the
    # published-to-web sheet (gid=1421999984) exported as CSV. Feeds
    # window.__CHURN_ANALYSIS__ (the Churn Intelligence tab + the Churn ARR
    # tile) independently of the main dashboard data above. Published CSV (the
    # /e/2PACX.. form) — NOT a gviz endpoint — so it's parsed via ConvertFrom-Csv
    # by header name below, not Fetch-Gviz.
    churn   = "https://docs.google.com/spreadsheets/d/e/2PACX-1vThFmDQitQOgcusYlhQW458fpNNq7xnTazx5YjPwOm3Bf90QcSpdSbhW7lsbMBENx6YB7AH4U7spC6G/pub?gid=1421999984&single=true&output=csv"
    # Per-CSM book ARR by Stage (gid=1436275090, main $sheetId). One row per
    # enterprise: Stage (D), CSM email (J), ARR (K). Feeds csm_grr (total ARR +
    # Live ARR per CSM → GRR = Live / Total) shown in CSM Performance.
    csmgrr  = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=1436275090"
}

# Use PowerShell Core's native ConvertFrom-Json (cross-platform, no .NET
# Framework assembly required). -AsHashtable returns nested hashtables so
# we get $obj['key'] semantics like JavaScriptSerializer used to give us.
function Parse-Json($s) { return $s | ConvertFrom-Json -AsHashtable -Depth 100 }

function Fetch-Gviz($url, $expectedMinRows = 0) {
    # Retry on partial responses. gviz occasionally returns a tiny subset
    # of rows for the same URL on consecutive fetches (seen 9 / 22 / 6497
    # for payment-periods). Two defenses:
    #   1) Append a unique cache-bust token on every retry so any proxy /
    #      gviz internal cache can't keep handing back the same short body.
    #   2) Exponential-ish backoff (4s, 6s, 10s, 15s, 22s) so a transient
    #      partial gradually clears out.
    # If after $maxAttempts the response is still short, surface a clear
    # WARN and proceed (better to update CSAT / tickets / vini with a stale
    # payperiods than abort the whole snapshot).
    $maxAttempts = 6
    $sleeps = @(4, 6, 10, 15, 22)
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        # Cache-bust on EVERY attempt (not just retries). gviz caches its
        # response per-URL, so a bare URL can keep handing back a stale
        # snapshot for minutes after the sheet is edited — which makes the
        # dashboard lag the source (e.g. a corrected ARR not showing up).
        # A fresh token per request forces gviz to return the current state.
        $sep = if ($url.Contains('?')) { '&' } else { '?' }
        $u   = "$url$sep`_cb=" + [Guid]::NewGuid().ToString('N')
        if ($attempt -gt 1) { Write-Host "  retry $attempt`: $u" }
        else                { Write-Host "  fetch: $u" }
        try {
            # Google's gviz endpoint quietly returns a truncated response to
            # non-browser User-Agents from some IPs (we see 9 rows back from
            # GitHub Actions runners while a browser sees 6497 from the same
            # URL). Pretend to be a recent Chrome so the full body comes back.
            $headers = @{
                'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
                'Accept'          = 'text/javascript, application/json, text/plain, */*'
                'Accept-Language' = 'en-US,en;q=0.9'
                'Cache-Control'   = 'no-cache'
                'Pragma'          = 'no-cache'
            }
            $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 90 -Headers $headers
            if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $u" }
            $txt = $resp.Content
            $s = $txt.IndexOf('{'); $e = $txt.LastIndexOf('}')
            $p = Parse-Json $txt.Substring($s, $e - $s + 1)
            if ($p.status -ne 'ok') { throw "gviz status=$($p.status) for $u" }
            $rowCount = $p.table.rows.Count
            if ($expectedMinRows -gt 0 -and $rowCount -lt $expectedMinRows) {
                Write-Host ("    WARN got $rowCount rows; expected >= $expectedMinRows; retrying...")
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds $sleeps[[Math]::Min($attempt - 1, $sleeps.Count - 1)]
                    continue
                }
                Write-Host ("    WARN exhausted retries; final attempt still short ($rowCount rows). Proceeding anyway.")
            }
            return $p.table
        } catch {
            Write-Host ("    WARN attempt $attempt failed: $_")
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Fetch-Csv($url, $expectedMinRows = 0) {
    # CSV sibling of Fetch-Gviz for the Metabase public-question endpoint.
    # Metabase serves the CSV only to browser-like clients (a bare curl/UA
    # gets an empty body), so we send the same Chrome User-Agent. We also
    # cache-bust per attempt and retry on short/empty bodies, mirroring the
    # gviz path. Returns an ARRAY of PSCustomObjects (one per data row, keyed
    # by CSV header name). The leading comma in `return ,@(...)` stops
    # PowerShell from unrolling a single-element array into a scalar.
    $maxAttempts = 6
    $sleeps = @(4, 6, 10, 15, 22)
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $sep = if ($url.Contains('?')) { '&' } else { '?' }
        $u   = "$url$sep`_cb=" + [Guid]::NewGuid().ToString('N')
        if ($attempt -gt 1) { Write-Host "  retry $attempt`: $u" }
        else                { Write-Host "  fetch: $u" }
        try {
            $headers = @{
                'User-Agent'      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
                'Accept'          = 'text/csv, text/plain, */*'
                'Accept-Language' = 'en-US,en;q=0.9'
                'Cache-Control'   = 'no-cache'
                'Pragma'          = 'no-cache'
            }
            $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 120 -Headers $headers
            if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $u" }
            $recs = @($resp.Content | ConvertFrom-Csv)
            $rowCount = $recs.Count
            if ($expectedMinRows -gt 0 -and $rowCount -lt $expectedMinRows) {
                Write-Host ("    WARN got $rowCount rows; expected >= $expectedMinRows; retrying...")
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds $sleeps[[Math]::Min($attempt - 1, $sleeps.Count - 1)]
                    continue
                }
                Write-Host ("    WARN exhausted retries; final attempt still short ($rowCount rows). Proceeding anyway.")
            }
            return ,@($recs)
        } catch {
            Write-Host ("    WARN attempt $attempt failed: $_")
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

function Norm-Lbl($s) { return ($s -replace '[^a-zA-Z0-9]+', '').ToLower() }
function Find-Col($cols, $candidates) {
    foreach ($c in @($candidates)) {
        $want = Norm-Lbl $c
        for ($i = 0; $i -lt $cols.Count; $i++) {
            if ((Norm-Lbl ($cols[$i].label + '')) -eq $want) { return $i }
        }
    }
    foreach ($c in @($candidates)) {
        $want = Norm-Lbl $c
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $g = Norm-Lbl ($cols[$i].label + '')
            if ($g.EndsWith($want) -and ($g.Length - $want.Length) -le 12) { return $i }
        }
    }
    return -1
}
function Gviz-Date($cell) {
    if (-not $cell) { return '' }
    $v = $cell.v
    if ($null -eq $v) { return ([string]$cell.f) }
    $s = [string]$v
    if ($s -match '^Date\((\d+),(\d+),(\d+)') {
        $y = $matches[1]; $mo = ([int]$matches[2] + 1).ToString('00'); $d = ([int]$matches[3]).ToString('00')
        return "$y-$mo-$d"
    }
    return $s
}
function Gviz-Val($cell) {
    if (-not $cell) { return '' }
    if ($null -eq $cell.v) { return ([string]$cell.f) }
    return $cell.v
}

Write-Host "=== Fetching 6 data sources ==="
# Expected minimum row counts — protect against gviz returning partial
# responses (seen on the payment-periods tab). Numbers are well below the
# typical fetch size so they only fire when something is clearly wrong.
$viniTab        = Fetch-Gviz $urls.vini       2000   # daily, ~4700 typical
$payTab         = Fetch-Gviz $urls.payment    100    # payment master ~140 typical
# Tickets now come from the dilipticket Freshdesk-backed API (the source behind
# its CS_use tab), replacing the Google-Sheet ticket dump (gid=832733618). The
# API returns a JSON array of tickets with clean field names + a resolved
# 9-char Enterprise ID (same hash the rest of the dashboard keys on). CORS is
# open and it caches 5 min on Vercel Edge. We still rebuild studio_tix/vini_tix
# into the identical {c,o,r,a,s,p} per-ticket schema below, so every downstream
# ticket-bucket computation stays byte-identical.
$ticketsApiUrl = 'https://dilipticket.vercel.app/api/tickets'
# The API fetches Freshdesk live; the first (cold) hit can come back partial
# because Freshdesk rate-limits the burst — once warm it returns the full set
# in <1s. Retry a few times until we get a healthy array, and only abort
# (never wipe ticket data) if every attempt looks broken. Use Invoke-WebRequest
# + ConvertFrom-Json (the same pattern as the coverage/tracking fetches) so a
# top-level JSON array deserializes reliably into a real array.
$apiTix = @()
for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
        $resp = Invoke-WebRequest -Uri $ticketsApiUrl -UseBasicParsing -TimeoutSec 120 -Headers @{ Accept = 'application/json' }
        $parsed = @($resp.Content | ConvertFrom-Json)
        Write-Host "  tickets API attempt $attempt -> $($parsed.Count) rows"
        if ($parsed.Count -ge 100) { $apiTix = $parsed; break }
    } catch {
        Write-Host "  tickets API attempt $attempt failed: $($_.Exception.Message)"
    }
    if ($attempt -lt 4) { Start-Sleep -Seconds 8 }
}
if ($apiTix.Count -lt 100) {
    throw "Ticket API returned $($apiTix.Count) rows after retries (<100) — looks broken. Aborting to avoid wiping ticket data."
}
Write-Host "  tickets API: $($apiTix.Count) tickets from $ticketsApiUrl"
$studioTab      = Fetch-Gviz $urls.studio     1000   # studio rooftops ~1400 typical
$payPeriodsTab  = Fetch-Gviz $urls.payperiods 3000   # payment-periods ~6500 typical

# CSAT now comes from the published Google Sheet CSV (gid=179502765, see
# $urls.csat comment). It's the fresh upstream of the old gid=701797891
# IMPORTRANGE tab, so no more "Loading..." stalls. On fetch failure we
# preserve the existing snapshot.
$csatRows = $null
try {
    $csatRows = Fetch-Csv $urls.csat 1000   # ~12.7k rows typical
} catch {
    Write-Host "  CSAT: WARNING — fetch failed ($_). Will preserve existing snapshot."
}

# Report-coverage aggregate (one row per day, ~7 days). Falls back gracefully.
$reportCoverage = @()
try {
    Write-Host "  fetch coverage: $($urls.coverage)"
    $resp = Invoke-WebRequest -Uri $urls.coverage -UseBasicParsing -TimeoutSec 30
    $reportCoverage = $resp.Content | ConvertFrom-Json
    if (-not $reportCoverage) { $reportCoverage = @() }
    Write-Host "  coverage: $($reportCoverage.Count) day(s)"
} catch {
    Write-Host "  coverage: WARNING — fetch failed ($_). Will preserve existing snapshot."
    $reportCoverage = $null
}

# Report-tracking — paginated per-row data. Returns ~5400 rows / 7 days.
# Build {eid: [{d (date), t (report_type), s (status), r (reason)}, …]} so the
# dashboard can render a real per-rooftop dot strip + a real per-group %.
$reportTracking = @{}
$trackingFailed = $false
try {
    $page = 1; $pageSize = 500
    do {
        $url = "$($urls.tracking)?days=7&pageSize=$pageSize&page=$page"
        Write-Host "  fetch tracking page $page"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
        $obj = $resp.Content | ConvertFrom-Json
        if (-not $obj.data) { break }
        foreach ($row in $obj.data) {
            $eid = if ($row.enterprise_id) { [string]$row.enterprise_id } else { '' }
            if (-not $eid) { continue }
            if (-not $reportTracking.ContainsKey($eid)) {
                $reportTracking[$eid] = New-Object System.Collections.Generic.List[hashtable]
            }
            $reportTracking[$eid].Add(@{
                d = [string]$row.date
                t = [string]$row.report_type
                s = [string]$row.status
                r = if ($row.reason) { [string]$row.reason } else { '' }
            })
        }
        if ($obj.pageCount -le $page) { break }
        $page++
    } while ($page -le 100)
    Write-Host "  tracking: $($reportTracking.Count) enterprises, total rows across pages"
} catch {
    Write-Host "  tracking: WARNING — fetch failed ($_). Will preserve existing snapshot."
    $trackingFailed = $true
    $reportTracking = $null
}
Write-Host "  vini rows=$($viniTab.rows.Count) | payment rows=$($payTab.rows.Count) | csat rows=$(if($csatRows){$csatRows.Count}else{'FAIL'}) | tickets(API)=$($apiTix.Count) | payperiods rows=$($payPeriodsTab.rows.Count)"

# --- Payment-period DENSE_RANK from gid=1395015507 ---
# For each enterprise (col V EnterprisesID), rank unique (start_date, end_date)
# periods DESC, so rank 1 = current period (T), rank 2 = T-1, rank 3 = T-2,
# rank 4 = T-3. customer_status (col E) from rank 2/3/4 → t1/t2/t3. When
# multiple rows share a rank (same start+end), worst-status wins
# (overdue > sent > draft > paid). This lookup feeds BOTH the Studio Studio
# rows AND the Vini payment-bucket rows downstream.
function Get-CanonicalPayStatus($list) {
    # Worst-wins per ranked slot. After the sent/draft filter above these
    # should now be only paid/overdue, but keep defensive fallbacks in case
    # the sheet adds new statuses later.
    if (-not $list -or $list.Count -eq 0) { return '' }
    if ($list -contains 'overdue') { return 'overdue' }
    if ($list -contains 'paid')    { return 'paid' }
    if ($list -contains 'sent')    { return 'sent' }
    if ($list -contains 'draft')   { return 'draft' }
    return [string]$list[0]
}
function Compute-PaymentRag($t1, $t2, $t3) {
    # Per user spec: count 'overdue' across T-1/T-2/T-3:
    #   0 overdue + at least one paid → Green
    #   1 overdue                      → Amber
    #   2+ overdue                     → Red
    #   nothing scorable at all        → blank
    $list = @($t1, $t2, $t3) | Where-Object { $_ -and $_ -ne '' } | ForEach-Object { ([string]$_).ToLower() }
    if (-not $list -or $list.Count -eq 0) { return '' }
    $overdueCount = @($list | Where-Object { $_ -eq 'overdue' }).Count
    if ($overdueCount -ge 2) { return 'Red' }
    if ($overdueCount -eq 1) { return 'Amber' }
    # 0 overdue: Green if there's at least one paid; otherwise blank
    # (sent/draft are pre-filtered, so this normally just falls through to paid).
    if ($list -contains 'paid') { return 'Green' }
    return ''
}

$ppCols = $payPeriodsTab.cols
# Find-Col by header name; fall back to absolute column letter (gviz cols[i].id)
# when the header row isn't recognized. Per the sheet schema confirmed manually:
# E=customer_status, V=EnterprisesID, Y=Service_period_Start_date, Z=Service_period_End_date.
function Find-ColById($cols, $letter) {
    for ($i = 0; $i -lt $cols.Count; $i++) {
        if (([string]$cols[$i].id) -eq $letter) { return $i }
    }
    return -1
}
$ppI = @{
    eid   = Find-Col $ppCols @('EnterprisesID','Enterprise ID','EnterpriseID')
    # IMPORTANT: cols D AND E both carry label 'customer_status' but with
    # DIFFERENT data — D is account-level ('active') while E is invoice-level
    # ('paid'/'draft'/'overdue'/'sent'), which is what the user spec calls for.
    # Force column letter E for this field; never trust the label match.
    cs    = Find-ColById $ppCols 'E'
    start = Find-Col $ppCols @('Service_period_Start_date','Service period Start date','Service Period Start Date')
    end   = Find-Col $ppCols @('Service_period_End_date','Service period End date','Service Period End Date')
    # Billing Terms (col W) — drives the yearly-billing rank exception below.
    bill  = Find-Col $ppCols @('Billing Terms','Billing Term','BillingTerms','Billing_Terms')
}
if ($ppI.eid   -lt 0) { $ppI.eid   = Find-ColById $ppCols 'V' }
if ($ppI.cs    -lt 0) { $ppI.cs    = Find-Col $ppCols @('customer_status','Customer Status') }
if ($ppI.start -lt 0) { $ppI.start = Find-ColById $ppCols 'Y' }
if ($ppI.end   -lt 0) { $ppI.end   = Find-ColById $ppCols 'Z' }
if ($ppI.bill  -lt 0) { $ppI.bill  = Find-ColById $ppCols 'W' }
Write-Host ("  payperiods cols: eid={0} cs={1} start={2} end={3} bill={4} (rows={5})" -f $ppI.eid, $ppI.cs, $ppI.start, $ppI.end, $ppI.bill, $payPeriodsTab.rows.Count)
if ($ppI.eid -lt 0 -or $ppI.cs -lt 0 -or $ppI.start -lt 0 -or $ppI.end -lt 0) {
    throw "Payment periods sheet (gid=1395015507) missing one of: EnterprisesID / customer_status / Service_period_Start_date / Service_period_End_date"
}
$payByEid = @{}
foreach ($row in $payPeriodsTab.rows) {
    if (-not $row) { continue }
    $c = $row.c
    $eid = [string](Gviz-Val $c[$ppI.eid])
    if ([string]::IsNullOrWhiteSpace($eid)) { continue }
    $st  = [string](Gviz-Date $c[$ppI.start])
    $en  = [string](Gviz-Date $c[$ppI.end])
    if ([string]::IsNullOrWhiteSpace($st)) { continue }
    $cs  = ([string](Gviz-Val $c[$ppI.cs])).ToLower().Trim()
    $bil = if ($ppI.bill -ge 0) { ([string](Gviz-Val $c[$ppI.bill])).ToLower().Trim() } else { '' }
    if (-not $payByEid.ContainsKey($eid)) {
        $payByEid[$eid] = New-Object System.Collections.Generic.List[object]
    }
    $payByEid[$eid].Add(@{ start=$st; end=$en; status=$cs; bill=$bil })
}
$payRanks = @{}
foreach ($eid in $payByEid.Keys) {
    $rows = $payByEid[$eid]
    # Per latest user spec: EXCLUDE sent/draft entirely from the source
    # first, then dense-rank by (Service_period_Start_date,
    # Service_period_End_date) DESC per enterprise. Each unique (start,end)
    # tuple is one rank.
    #
    # DEFAULT (non-yearly billing): SKIP rank 1 (the most-recent / in-flight
    # closed period the user wants ignored); take rank 2 → T-1, rank 3 → T-2,
    # rank 4 → T-3.
    #
    # YEARLY BILLING EXCEPTION (Billing Terms = 'Yearly', col W): with only one
    # invoice per year there is no in-flight period to skip, so consider from
    # rank 1: rank 1 → T-1, rank 2 → T-2, rank 3 → T-3. Everything else (the
    # sent/draft filter, worst-wins canonicalisation, RAG scoring) is unchanged.
    #
    # Sparse cases (default skip-1) render naturally:
    #   - 1 rank only      → t1/t2/t3 all blank → all NIR
    #   - 2 ranks (skip 1) → t1 = rank 2 status; t2/t3 blank → NIR
    #   - 3 ranks (skip 1) → t1 = rank 2, t2 = rank 3; t3 blank → NIR
    #   - 4+ ranks (skip 1)→ t1 = rank 2, t2 = rank 3, t3 = rank 4
    $closed = @($rows | Where-Object {
        $s = [string]$_.status
        $s -and $s -ne 'sent' -and $s -ne 'draft'
    })
    $sorted = @($closed | Sort-Object @{Expression={[string]$_.start};Descending=$true}, @{Expression={[string]$_.end};Descending=$true})
    $byRank = @{}
    $billByRank = @{}
    $rank = 0
    $prevKey = $null
    foreach ($pr in $sorted) {
        $key = "$($pr.start)|$($pr.end)"
        if ($key -ne $prevKey) { $rank++; $prevKey = $key }
        if ($rank -gt 4) { break }   # ranks 1-4 cover skip-1 + T-1/T-2/T-3
        if (-not $byRank.ContainsKey($rank)) {
            $byRank[$rank] = New-Object System.Collections.Generic.List[string]
            $billByRank[$rank] = New-Object System.Collections.Generic.List[string]
        }
        $byRank[$rank].Add([string]$pr.status)
        $billByRank[$rank].Add([string]$pr.bill)
    }
    # Classify the enterprise as yearly from its most-recent (rank 1) period's
    # Billing Terms. Exact 'yearly' only — 'half yearly' / 'quarterly' / etc.
    # keep the default skip-1 behaviour.
    $isYearly = $false
    if ($billByRank.ContainsKey(1)) {
        $isYearly = @($billByRank[1] | Where-Object { $_ -eq 'yearly' }).Count -gt 0
    }
    if ($isYearly) {
        # Yearly: consider from rank 1. T-1 = rank 1, T-2 = rank 2, T-3 = rank 3.
        $payRanks[$eid] = @{
            t1 = if ($byRank.ContainsKey(1)) { Get-CanonicalPayStatus $byRank[1] } else { '' }
            t2 = if ($byRank.ContainsKey(2)) { Get-CanonicalPayStatus $byRank[2] } else { '' }
            t3 = if ($byRank.ContainsKey(3)) { Get-CanonicalPayStatus $byRank[3] } else { '' }
        }
    } else {
        $payRanks[$eid] = @{
            # SKIP rank 1 (most recent / in-flight). T-1 = rank 2 onwards.
            t1 = if ($byRank.ContainsKey(2)) { Get-CanonicalPayStatus $byRank[2] } else { '' }
            t2 = if ($byRank.ContainsKey(3)) { Get-CanonicalPayStatus $byRank[3] } else { '' }
            t3 = if ($byRank.ContainsKey(4)) { Get-CanonicalPayStatus $byRank[4] } else { '' }
        }
    }
}
Write-Host ("  payperiods: {0} enterprises ranked from {1} invoice rows" -f $payRanks.Count, $payPeriodsTab.rows.Count)
# GUARD: gviz intermittently returns a truncated payment-periods body (seen 9 /
# 12 / 22 rows vs the real ~6500). Fetch-Gviz retries but ultimately "proceeds
# anyway" with the partial — which silently WIPES every enterprise's Payment RAG
# (t1/t2/t3/prag/ps all blank). Normal is ~994 ranked enterprises; abort well
# below that so the sync fails loudly and the last good payment data is
# preserved (the next scheduled run almost always gets the full body).
if ($payRanks.Count -lt 200) {
    throw "Payment-periods ranked only $($payRanks.Count) enterprises from $($payPeriodsTab.rows.Count) rows (expected ~994 from ~6500). Truncated gviz fetch — aborting to preserve the last good payment data."
}

# --- Studio Customer Segment lookup (source of truth) -----------------------
# gid=603796861 col G (Customer Segment) carries 'Resellers' which the Vini
# source (gid=1616842841 col I) doesn't have at all. Build an eid → seg map
# from Studio so Vini can backfill its segment when its own value is missing
# or generic — surfaces the Resellers segment on the Vini tab.
$studioSegByEid = @{}
foreach ($row in $studioTab.rows) {
    if (-not $row) { continue }
    $c = $row.c
    if ($c.Count -le 6) { continue }
    $eid = ([string](Gviz-Val $c[0])).Trim()
    if (-not $eid) { continue }
    $seg = ([string](Gviz-Val $c[6])).Trim()
    if (-not $seg) { continue }
    if ($seg -eq 'Customer Segment') { continue }   # stray header row in source
    # First-write wins; Studio is consistent within an enterprise.
    if (-not $studioSegByEid.ContainsKey($eid)) { $studioSegByEid[$eid] = $seg }
}
Write-Host ("  studio_seg lookup: {0} enterprises" -f $studioSegByEid.Count)

# --- Read existing dashboard JSON to learn the v_schema ---
$lines = [System.IO.File]::ReadAllLines($primary)
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
if ($dlIdx -lt 0) { throw "DASHBOARD_DATA line not found" }
$dl = $lines[$dlIdx]
$origJson = $dl.Substring($dl.IndexOf('{')).TrimEnd(';').Trim()
$D = Parse-Json $origJson
$vSchema = $D.v_schema

# --- Build v_rows ---
$cols = $viniTab.cols
$labelOf = @{
    day=@('Day'); agent=@('Agent Type'); rid=@('Rooftop ID'); rn=@('Rooftop Name')
    eid=@('Enterprise ID'); en=@('Enterrpise Name','Enterprise Name')
    ct=@('Customer Type'); cst=@('Customer Subtype'); seg=@('Customer Segment')
    csm=@('CSM Name'); region=@('Region'); stage=@('Stage')
    rag=@('Final Status RAG','Final Status/RAG'); churn=@('Churned','Final Status Churned','Final Status/Churned')
    t=@('Usage # Touched','# Touched','Usage/# Touched')
    q=@('# Qualified','Usage # Qualified','Usage/# Qualified')
    a=@('# Appt Booked','Usage # Appt Booked','Usage/# Appt Booked')
    cv=@('Conv Rate','Usage Conv Rate','Usage/Conv Rate')
    av=@('RoI? Appt Value ($)','Appt Value ($)','RoI?/Appt Value ($)')
    roi=@('RoI (Factor)','RoI? RoI (Factor)','RoI?/RoI (Factor)')
    rs=@('Report Sent (D/W/M)?','RoI? Report Sent (D/W/M)?','RoI?/Report Sent (D/W/M)?')
    cr=@('Tickets # Created','# Created','Tickets/# Created')
    op=@('Tickets # Open','# Open','Tickets/# Open')
    ota=@('Tickets Open Ticket Ageing (Hrs)','Open Ticket Ageing (Hrs)','Tickets/Open Ticket Ageing (Hrs)')
    res=@('Tickets Avg Resolution hrs','Avg Resolution hrs','Tickets/Avg Resolution hrs')
    trag=@('Tickets Ticket RAG','Ticket RAG','Tickets/Ticket RAG')
    red=@('Communication RAG','Communication/RAG')
    mbr=@('Leadership Connect MBR','MBR','Leadership Connect/MBR')
    cf=@('Leadership Connect Contact Freq','Contact Freq','Leadership Connect/Contact Freq')
    t1=@(''); t2=@(''); t3=@(''); ps=@('')
}
$idx = @{}
foreach ($k in $vSchema) { $idx[$k] = Find-Col $cols $labelOf[$k] }

$csmIdx2 = [array]::IndexOf($vSchema, 'csm')
$vRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $viniTab.rows) {
    $cells = $row.c
    $newRow = New-Object object[] $vSchema.Count
    for ($k = 0; $k -lt $vSchema.Count; $k++) {
        $field = $vSchema[$k]
        $i = $idx[$field]
        if ($i -lt 0) { $newRow[$k] = ''; continue }
        $cell = if ($cells -and $i -lt $cells.Count) { $cells[$i] } else { $null }
        $newRow[$k] = if ($field -eq 'day') { Gviz-Date $cell } else { Gviz-Val $cell }
    }
    $cv = [string]$newRow[$csmIdx2]
    if ([string]::IsNullOrWhiteSpace($cv) -or $cv.Trim().ToLower() -in 'csm not assigned','not assigned','unassigned','na','tbd') {
        $newRow[$csmIdx2] = 'Unassigned CSM'
    }
    $vRows.Add($newRow)
}
Write-Host "  v_rows built: $($vRows.Count)"

# --- Build vini_stage (with seg backfill from v_rows + manual EID map) ---
$pCols = $payTab.cols
$pi = @{
    eid=Find-Col $pCols @('Enterprise ID'); en=Find-Col $pCols @('Account')
    rid=Find-Col $pCols @('Team ID'); rn=Find-Col $pCols @('Rooftop Name')
    agent=Find-Col $pCols @('Agent Opted'); mrr=Find-Col $pCols @('MRR'); arr=Find-Col $pCols @('ARR')
    stage=Find-Col $pCols @('Stage'); t1=Find-Col $pCols @('Payment T1','T1')
    t2=Find-Col $pCols @('Payment T2','T2'); t3=Find-Col $pCols @('Payment T3','T3')
    ps=Find-Col $pCols @('Payment Score')
    go_live=Find-Col $pCols @('Go-Live Date','Go Live Date','GoLive Date')
}

# Meta from v_rows: most-recent CSM/region/seg per (rid,agent) and per en
$ridIdxV=[array]::IndexOf($vSchema,'rid'); $agentIdxV=[array]::IndexOf($vSchema,'agent')
$csmIdxV=[array]::IndexOf($vSchema,'csm'); $regionIdxV=[array]::IndexOf($vSchema,'region')
$segIdxV=[array]::IndexOf($vSchema,'seg'); $dayIdxV=[array]::IndexOf($vSchema,'day')
$enIdxV=[array]::IndexOf($vSchema,'en'); $ctIdxV=[array]::IndexOf($vSchema,'ct')
$cstIdxV=[array]::IndexOf($vSchema,'cst')

$metaByRidAgent=@{}; $metaByRid=@{}; $metaByEn=@{}
foreach ($r in $vRows) {
    $rid=[string]$r[$ridIdxV]; if (-not $rid) { continue }
    $ag=[string]$r[$agentIdxV]; $day=[string]$r[$dayIdxV]
    $csm=[string]$r[$csmIdxV]; $region=[string]$r[$regionIdxV]; $seg=[string]$r[$segIdxV]
    $en=[string]$r[$enIdxV]; $ct=[string]$r[$ctIdxV]
    $cst = if ($cstIdxV -ge 0) { [string]$r[$cstIdxV] } else { '' }
    $key = $rid + '|' + $ag
    if (-not $metaByRidAgent.ContainsKey($key) -or $metaByRidAgent[$key].day -lt $day) {
        $metaByRidAgent[$key]=@{csm=$csm;region=$region;seg=$seg;day=$day;ct=$ct;cst=$cst}
    }
    if (-not $metaByRid.ContainsKey($rid) -or $metaByRid[$rid].day -lt $day) {
        $metaByRid[$rid]=@{csm=$csm;region=$region;seg=$seg;day=$day;ct=$ct;cst=$cst}
    }
    if ($en -and (-not $metaByEn.ContainsKey($en) -or $metaByEn[$en].day -lt $day)) {
        $metaByEn[$en]=@{csm=$csm;region=$region;seg=$seg;day=$day;ct=$ct;cst=$cst}
    }
}

$manualSeg = @{
    'c68580ae5'='SMB'; '9bc114fc6'='SMB'; '9d4468871'='SMB'; '82255fce5'='Ent'
}
# Per-enterprise segment overrides that WIN over both Vini source and Studio
# sheet — for cases like CallSource (62f962c8e) where the enterprise only
# appears in the payment-periods tab and neither product tab tags it as a
# Reseller. Add entries here as more such enterprises come up.
$manualReseller = @{
    '62f962c8e' = 'Resellers'   # CallSource — per user override
}
function Parse-Money($v) {
    if ($null -eq $v -or $v -eq '') { return 0 }
    $c = ([string]$v -replace '[\$,]', '').Trim()
    try { return [double]$c } catch { return 0 }
}

$viniStage = New-Object System.Collections.Generic.List[object]
$payEids = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $payTab.rows) {
    $c = $row.c; if (-not $c) { continue }
    $eid=[string](Gviz-Val $c[$pi.eid]); $rid=[string](Gviz-Val $c[$pi.rid])
    if (-not $eid -or -not $rid) { continue }
    [void]$payEids.Add($eid)
    $agent=[string](Gviz-Val $c[$pi.agent])
    $meta = $metaByRidAgent[$rid + '|' + $agent]
    if (-not $meta) { $meta = $metaByRid[$rid] }
    $en=[string](Gviz-Val $c[$pi.en])
    if (-not $meta -and $en -and $metaByEn.ContainsKey($en)) { $meta = $metaByEn[$en] }
    $csm = if ($meta) { $meta.csm } else { '' }
    if ([string]::IsNullOrWhiteSpace($csm) -or $csm.Trim().ToLower() -in 'csm not assigned','not assigned','unassigned','na','tbd') { $csm='Unassigned CSM' }
    $region = if ($meta -and $meta.region) { $meta.region } else { 'AMER' }
    $seg = if ($meta -and $meta.seg -and $meta.seg -ne 'Other') { $meta.seg } else { '' }
    # Studio (gid=603796861) is the source of truth for Customer Segment, and
    # it carries 'Resellers' which Vini source doesn't. Prefer Studio's tag
    # whenever it exists for this eid — keeps the two products aligned and
    # surfaces Resellers on the Vini tab. Only falls through to manual /
    # ct-based defaults when Studio doesn't know the enterprise.
    if ($studioSegByEid.ContainsKey($eid)) { $seg = $studioSegByEid[$eid] }
    # Per-enterprise reseller overrides WIN over both Vini source and Studio
    # sheet (e.g. CallSource lives only in the payment-periods tab so neither
    # product tab carries the right tag).
    if ($manualReseller.ContainsKey($eid)) { $seg = $manualReseller[$eid] }
    if (-not $seg -and $manualSeg.ContainsKey($eid)) { $seg = $manualSeg[$eid] }
    if (-not $seg -and $meta -and $meta.ct) {
        if ($meta.ct -eq 'GROUP_DEALER') { $seg='Ent' }
        elseif ($meta.ct -eq 'INDIVIDUAL_DEALER') { $seg='SMB' }
    }
    if (-not $seg) { $seg='Other' }

    $rec = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $rec['rid']=$rid; $rec['en']=$en; $rec['rn']=[string](Gviz-Val $c[$pi.rn])
    $rec['eid']=$eid; $rec['mrr']=Parse-Money (Gviz-Val $c[$pi.mrr])
    $rec['arr']=Parse-Money (Gviz-Val $c[$pi.arr]); $rec['stage']=[string](Gviz-Val $c[$pi.stage])
    $rec['agent']=$agent
    # T-1/T-2/T-3 from gid=1395015507 dense-rank (NOT the payment-master sheet
    # cols T1/T2/T3). Same lookup the Studio side uses, keyed by enterprise_id.
    $pr = $null
    if ($payRanks.ContainsKey($eid)) { $pr = $payRanks[$eid] }
    if ($pr) {
        $rec['t1']=[string]$pr.t1; $rec['t2']=[string]$pr.t2; $rec['t3']=[string]$pr.t3
        $rec['ps']=Compute-PaymentRag $pr.t1 $pr.t2 $pr.t3
    } else {
        $rec['t1']=''; $rec['t2']=''; $rec['t3']=''; $rec['ps']=''
    }
    $rec['csm']=$csm
    $rec['region']=$region; $rec['seg']=$seg
    # account_type / account_subtype — used by the Account Type column +
    # filter (FGD/GSD/ISD/IGD/Others/Partner). Falls back to '' when v_rows
    # doesn't have the value for this rooftop/agent pair.
    $rec['ct']  = if ($meta -and $meta.ct)  { $meta.ct }  else { '' }
    $rec['cst'] = if ($meta -and $meta.cst) { $meta.cst } else { '' }
    # Go-Live Date (ISO YYYY-MM-DD); '' if missing
    $rec['go_live'] = if ($pi.go_live -ge 0 -and $c.Count -gt $pi.go_live) { Gviz-Date $c[$pi.go_live] } else { '' }
    [void]$viniStage.Add($rec)
}
Write-Host "  vini_stage rows: $($viniStage.Count) | enterprises: $($payEids.Count)"

# Filter v_rows to payment scope
$eidIdxV=[array]::IndexOf($vSchema,'eid')
$vRowsScoped = New-Object System.Collections.Generic.List[object]
foreach ($r in $vRows) { if ($payEids.Contains([string]$r[$eidIdxV])) { [void]$vRowsScoped.Add($r) } }
Write-Host "  v_rows in scope: $($vRowsScoped.Count)"

# --- Build CSAT dicts from the published Google Sheet (gid=179502765) ---
# Columns (ConvertFrom-Csv → PSCustomObject per row, keyed by header):
#   Date · Enterprise Name · Enterprise ID · CSM Name ·
#   Meeting CSAT · Thread CSAT · Ticket CSAT · Call CSAST ·
#   Average_Csat_Score · Interaction Count
#
# `Average_Csat_Score` is read DIRECTLY (the sheet already computes the blend
# across channels), so the dashboard avg matches the sheet. `Date` is already
# ISO YYYY-MM-DD — no Gviz-Date conversion needed. Header names contain spaces,
# so they're accessed via $row.'Enterprise ID' quoted-property syntax.
# RAG thresholds: avg<2.5 Red, <4 Amber, >=4 Green, blank → NA.
#
# If the CSV fetch FAILED or returned 0 rows, we preserve the
# previously-spliced CSAT dicts from $D so we don't wipe the dashboard JSON.
$csatBroken = $false
if ($null -eq $csatRows) { $csatBroken = $true }
if (-not $csatBroken -and $csatRows.Count -eq 0) { $csatBroken = $true }

if ($csatBroken) {
    Write-Host "  CSAT: WARNING — published-sheet CSV fetch empty or failed. Preserving existing snapshot."
    $byEid=@{}; $byName=@{}; $allByEid=@{}; $allByName=@{}
    if ($D.csat_by_eid) {
        foreach ($k in $D.csat_by_eid.Keys) {
            $r = $D.csat_by_eid[$k]
            $byEid[$k] = @{ date_iso=[string]$r.date_iso; avg=$r.avg; name=[string]$r.name }
        }
    }
    if ($D.csat_by_name) {
        foreach ($k in $D.csat_by_name.Keys) {
            $r = $D.csat_by_name[$k]
            $byName[$k] = @{ date_iso=[string]$r.date_iso; avg=$r.avg; name=[string]$r.name }
        }
    }
    if ($D.csat_all_by_eid) {
        foreach ($k in $D.csat_all_by_eid.Keys) {
            $arr = $D.csat_all_by_eid[$k]
            $list = New-Object System.Collections.Generic.List[hashtable]
            foreach ($r in $arr) {
                $ic = if ($null -eq $r.intCount) { 0 } else { [int]$r.intCount }
                $list.Add(@{ date_iso=[string]$r.date_iso; avg=$r.avg; rag=[string]$r.rag; intCount=$ic })
            }
            $allByEid[$k] = $list
        }
    }
    if ($D.csat_all_by_name) {
        foreach ($k in $D.csat_all_by_name.Keys) {
            $arr = $D.csat_all_by_name[$k]
            $list = New-Object System.Collections.Generic.List[hashtable]
            foreach ($r in $arr) {
                $ic = if ($null -eq $r.intCount) { 0 } else { [int]$r.intCount }
                $list.Add(@{ date_iso=[string]$r.date_iso; avg=$r.avg; rag=[string]$r.rag; intCount=$ic })
            }
            $allByName[$k] = $list
        }
    }
    Write-Host "  CSAT: preserved $($byEid.Count) by_eid | $($byName.Count) by_name | $($allByEid.Count) all_by_eid | $($allByName.Count) all_by_name"
} else {
    # Normalize enterprise name for fuzzy match: lowercase + trim + strip
    # " - <eid>" suffix the CSAT dump sometimes appends.
    function NormCsatName($s) {
        if (-not $s) { return '' }
        $t = [string]$s
        $dash = $t.IndexOf(' - ')
        if ($dash -ge 0) { $t = $t.Substring(0, $dash) }
        return $t.Trim().ToLower()
    }
    $byEid=@{}; $byName=@{}; $allByEid=@{}; $allByName=@{}
    foreach ($row in $csatRows) {
        if (-not $row) { continue }
        $eid  = ([string]$row.'Enterprise ID').Trim()
        $name = ([string]$row.'Enterprise Name').Trim()
        $iso  = ([string]$row.Date).Trim()
        $rawAvg = $row.Average_Csat_Score
        $avg = $null
        if ($null -ne $rawAvg -and ([string]$rawAvg) -ne '') {
            try { $avg = [double]$rawAvg } catch { $avg = $null }
        }
        # interaction_count — the actual number of interactions captured for
        # this reading. SUMMED downstream (rather than counting CSAT rows) so
        # the dashboard's "# Interaction" reflects engagement volume, not just
        # survey frequency.
        $intCount = 0
        $rawInt = $row.'Interaction Count'
        if ($null -ne $rawInt -and ([string]$rawInt) -ne '') {
            try { $intCount = [int]([double]$rawInt) } catch { $intCount = 0 }
        }
        $rag = 'NA'
        if ($null -ne $avg) {
            if ($avg -lt 2.5) { $rag = 'Red' } elseif ($avg -lt 4) { $rag = 'Amber' } else { $rag = 'Green' }
        }
        $rec = @{ date_iso=$iso; avg=$avg; name=$name; intCount=$intCount }
        $allRec = @{ date_iso=$iso; avg=$avg; rag=$rag; intCount=$intCount }
        if ($eid) {
            if (-not $byEid.ContainsKey($eid) -or [string]$byEid[$eid].date_iso -lt $iso) { $byEid[$eid] = $rec }
            if (-not $allByEid.ContainsKey($eid)) { $allByEid[$eid] = New-Object System.Collections.Generic.List[hashtable] }
            $allByEid[$eid].Add($allRec)
        }
        if ($name) {
            # by_name keyed UPPERCASE (latest-reading lookup, unchanged)
            $kUp = $name.ToUpper()
            if (-not $byName.ContainsKey($kUp) -or [string]$byName[$kUp].date_iso -lt $iso) { $byName[$kUp] = $rec }
            # all_by_name keyed NORMALIZED (for date-filtered name fallback)
            $kNorm = NormCsatName $name
            if ($kNorm) {
                if (-not $allByName.ContainsKey($kNorm)) { $allByName[$kNorm] = New-Object System.Collections.Generic.List[hashtable] }
                $allByName[$kNorm].Add($allRec)
            }
        }
    }
    Write-Host "  CSAT: $($byEid.Count) by_eid | $($byName.Count) by_name | $($allByEid.Count) all_by_eid | $($allByName.Count) all_by_name"
}

# --- Build vini_tix / studio_tix from the dilipticket API ($apiTix) ---
# API field names (per ticket): Ticket ID | Status | Priority | Created time |
#   Resolved time | Closed time | Resolution time (in hrs) | Resolution status |
#   Product (Studio/Vini) | Enterprise Name | Enterprise ID | is_pending …
#
# Per enterprise (filtered to product AND eid is in the LIVE set):
#   cr  = total tickets   (count)
#   op  = open tickets    (Status NOT IN Closed/Resolved)
#   ota = avg ageing hrs  (now - Created) over open tickets
#   res = avg resolution  (Resolution time hrs) over resolved/closed tickets

# Build the "live enterprise" set from the payment master. An enterprise is
# "live" if at least one of its (rooftop × agent) contracts has stage != Churned.
# Using viniStage built above so we share the canonical source.
$liveEids = New-Object System.Collections.Generic.HashSet[string]
foreach ($s in $viniStage) {
    $stg = [string]$s['stage']
    if ($stg -and $stg.Trim().ToLower() -ne 'churned') {
        [void]$liveEids.Add([string]$s['eid'])
    }
}
Write-Host "  Live enterprises: $($liveEids.Count) (filtering ticket dump to these)"


# Ship RAW per-ticket rows so the dashboard can apply its date-range filter
# (MTD / Last Month / L2L / custom) at render time.
#
# Per-row schema (compact field names to keep JSON size down):
#   c = created date (YYYY-MM-DD)
#   o = open bool (Status NOT IN Closed/Resolved)
#   r = resolution hrs (parsed from col G `[h]:mm:ss`; 0 for open)
#   a = ageing hrs at sync time (UtcNow - Created); 0 for non-open
#
# Source: gid=832733618 has a "Product" column = 'Studio' | 'Vini'. We split
# tickets to vini_tix vs studio_tix and match each ticket back to a master
# enterprise:
#   - Vini   tickets match against vini_stage (gid=674556270) EIDs (live only).
#   - Studio tickets match against the Studio sheet (gid=603796861) EIDs.
# If the EID doesn't match, fall back to ENTERPRISE NAME (case-insensitive,
# stripping the " - <eid>" suffix the dump often appends).

# Normalize an enterprise name for fallback match. Lowercase + trim and strip
# " - xxxxxxxxx" suffix (e.g., "Brandon Steven Motors - 7d06f7427").
function NormName($s) {
    if (-not $s) { return '' }
    $t = [string]$s
    $dash = $t.IndexOf(' - ')
    if ($dash -ge 0) { $t = $t.Substring(0, $dash) }
    return $t.Trim().ToLower()
}

# Build VINI master: live EIDs + name→eid map (live only per existing spec).
$viniEidSet = $liveEids
$viniNameToEid = @{}
foreach ($s in $viniStage) {
    $stg = [string]$s['stage']
    if ($stg -and $stg.Trim().ToLower() -eq 'churned') { continue }
    $nKey = NormName $s['en']
    if ($nKey -and -not $viniNameToEid.ContainsKey($nKey)) {
        $viniNameToEid[$nKey] = [string]$s['eid']
    }
}

# Build STUDIO master from the Studio gviz tab directly (the full $sRows build
# happens further down, but for the ticket join we only need eid + name).
$sColsForMaster = $studioTab.cols
$siMaster = @{
    eid = Find-Col $sColsForMaster @('Enterprise ID')
    en  = Find-Col $sColsForMaster @('Enterrpise Name','Enterprise Name')
}
$studioEidSet = New-Object System.Collections.Generic.HashSet[string]
$studioNameToEid = @{}
foreach ($row in $studioTab.rows) {
    $c = $row.c; if (-not $c) { continue }
    $eid = [string](Gviz-Val $c[$siMaster.eid])
    if (-not $eid) { continue }
    [void]$studioEidSet.Add($eid)
    $nKey = NormName ([string](Gviz-Val $c[$siMaster.en]))
    if ($nKey -and -not $studioNameToEid.ContainsKey($nKey)) {
        $studioNameToEid[$nKey] = $eid
    }
}
Write-Host "  Master sets: vini live=$($viniEidSet.Count) name-map=$($viniNameToEid.Count) | studio eid=$($studioEidSet.Count) name-map=$($studioNameToEid.Count)"

# Single pass over the API tickets → dispatch by product, resolve EID via the
# master sets (eid first, then name fallback). Same resolution + same per-row
# {c,o,r,a,s,p} schema as the old sheet path — only the source changed.
$viniTix = @{}; $studioTix = @{}
$nowUtc = [DateTime]::UtcNow
$kept = @{ vini=0; studio=0 }; $skipped = @{ vini=0; studio=0; other=0 }
foreach ($row in $apiTix) {
    $prodRaw = [string]$row.'Product (Studio/Vini)'
    if (-not $prodRaw) { $skipped.other++; continue }
    # Classify: any 'studio*' → Studio, any '*vini*' → Vini (covers the API's
    # 'Studio - ETA', 'Internal-Vini', 'Vini - ETA' variants). Spam/blank skip.
    $prodL = $prodRaw.Trim().ToLower()
    $prod = if ($prodL -like 'studio*') { 'Studio' } elseif ($prodL -like '*vini*') { 'Vini' } else { '' }
    if (-not $prod) { $skipped.other++; continue }

    $eidRaw = ([string]$row.'Enterprise ID').Trim()
    $nameKey = NormName ([string]$row.'Enterprise Name')

    # Resolve to master EID per product
    $resolvedEid = $null
    $targetDict = $null
    if ($prod -eq 'Vini') {
        if ($eidRaw -and $eidRaw -ne 'Not Required' -and $viniEidSet.Contains($eidRaw)) {
            $resolvedEid = $eidRaw
        } elseif ($nameKey -and $viniNameToEid.ContainsKey($nameKey)) {
            $resolvedEid = $viniNameToEid[$nameKey]
        }
        if (-not $resolvedEid) { $skipped.vini++; continue }
        $targetDict = $viniTix
    } else {
        if ($eidRaw -and $eidRaw -ne 'Not Required' -and $studioEidSet.Contains($eidRaw)) {
            $resolvedEid = $eidRaw
        } elseif ($nameKey -and $studioNameToEid.ContainsKey($nameKey)) {
            $resolvedEid = $studioNameToEid[$nameKey]
        }
        if (-not $resolvedEid) { $skipped.studio++; continue }
        $targetDict = $studioTix
    }

    # Created → YYYY-MM-DD (API ships ISO-8601 UTC, e.g. 2026-06-23T20:24:40Z).
    $createdStr = [string]$row.'Created time'
    $created = $null
    if ($createdStr) {
        try {
            $created = [DateTime]::Parse($createdStr, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        } catch { $created = $null }
    }
    if (-not $created) {
        if ($prod -eq 'Vini') { $skipped.vini++ } else { $skipped.studio++ }
        continue
    }
    $createdIso = $created.ToString('yyyy-MM-dd')

    # #Unresolved = Status NOT IN ('closed','resolved') — raw 'Open' AND any
    # in-flight state (Pending / Waiting / On Hold) all count as unresolved.
    $status = ([string]$row.'Status').ToLower().Trim()
    $isOpen = ($status -ne 'closed' -and $status -ne 'resolved')

    # SLA Violated flag — API 'Resolution status' = 'Violated SLA'. Kept for
    # backwards compatibility; the priority-based Ticket RAG no longer needs it.
    $isSlaViolated = (([string]$row.'Resolution status').Trim().ToLower() -eq 'violated sla')

    # Priority — lower-cased ('low'|'medium'|'high'|'urgent') for client matching.
    $priority = ([string]$row.'Priority').Trim().ToLower()

    $resHrs = 0.0; $ageHrs = 0.0
    if ($isOpen) {
        $ageHrs = ($nowUtc - $created).TotalHours
        if ($ageHrs -lt 0) { $ageHrs = 0.0 }
    } else {
        # API ships 'Resolution time (in hrs)' as a plain decimal string.
        $parsed = 0.0
        if ([double]::TryParse([string]$row.'Resolution time (in hrs)', [ref]$parsed) -and $parsed -gt 0) {
            $resHrs = $parsed
        }
    }

    if (-not $targetDict.ContainsKey($resolvedEid)) {
        $targetDict[$resolvedEid] = New-Object System.Collections.Generic.List[hashtable]
    }
    # i = Freshdesk ticket id — shipped so the dashboard can deep-link each open
    # ticket to https://spyne.freshdesk.com/a/tickets/<id> in the clickable list.
    $ticketId = ([string]$row.'Ticket ID').Trim()
    # fr = First response SLA status ('Within SLA' / 'Violated SLA' / '') — shown
    # in the clickable ticket popup so CSMs can spot first-response breaches.
    $frStatus = ([string]$row.'First response status').Trim()
    $targetDict[$resolvedEid].Add(@{ c = $createdIso; o = $isOpen; r = $resHrs; a = $ageHrs; s = $isSlaViolated; p = $priority; i = $ticketId; fr = $frStatus })
    if ($prod -eq 'Vini') { $kept.vini++ } else { $kept.studio++ }
}
Write-Host "  vini_tix:   $($viniTix.Count) enterprises, $($kept.vini) tickets kept, $($skipped.vini) skipped"
Write-Host "  studio_tix: $($studioTix.Count) enterprises, $($kept.studio) tickets kept, $($skipped.studio) skipped"

# --- Build Studio s_rows from gid=603796861 ---
# Schema columns in the CURRENT source (1 row per Studio rooftop), after the
# 2026-06 restructure:
#   A Enterprise ID | B Enterprise Name | C Rooftop ID | D Rooftop Name |
#   E account_type | F account_subtype | G Customer Segment | H CSM Name |
#   I Region | J Quality Website Score | K Website Link | L Pendency (6 hrs) |
#   M Usage Jan'26 | N Feb'26 | O Mar'26 | P Apr'26 | Q May'26 | R mtd_vins |
#   S ARR | T Payment T1 | U T2 | V T3 | W Payment RAG |
#   X Tickets #Unresolved | Y #Created | Z Open Ageing | AA Avg Resolution |
#   AB Ticket RAG | AC Comm RAG Status | AD MBR | AE Contact Freq
#
# NEW: the sheet now carries an ARR column. We read ARR directly and compute
# MRR = ARR/12 per row (user spec). The earlier "preserve MRR/ARR from old
# snapshot" code is no longer needed and has been removed.
#
# Also: the old "RoI Report Sent (D/W/M)?" column was removed from the sheet,
# so the `rs` field is dropped from the schema. The dashboard's RoI bucket
# will be sourced from a future last-7-days history when one is provided.
# NEW (2026-06 sheet restructure): the Usage block is now 6 monthly VIN
# columns M-R (Usage Jan'26 … May'26 + mtd_vins). The old Active VINs / IMS
# Vins / #Actual / Last-month Actual / Usage Factor / Inventory Score columns
# were all removed from the sheet, so those fields are dropped from the schema.
# The dashboard derives "Usage Trend" (Rising/Declining/Steady) from the 5 full
# months at render time — it is NOT stored here.
$sStudioSchema = @(
    'rid','rn','en',
    'mrr','arr',
    'u_jan','u_feb','u_mar','u_apr','u_may','u_mtd',
    'pen','ws','ws_link',
    't1','t2','t3','prag',
    'unr','cr','ota','res','trag',
    'red','mbr','cf','csm','ct','cst','seg','region','eid'
)

# Map new-sheet col labels → field name
$sCols = $studioTab.cols
$si = @{
    eid     = Find-Col $sCols @('Enterprise ID')
    en      = Find-Col $sCols @('Enterrpise Name','Enterprise Name')
    rid     = Find-Col $sCols @('Rooftop ID')
    rn      = Find-Col $sCols @('Rooftop Name')
    ct      = Find-Col $sCols @('account_type')
    cst     = Find-Col $sCols @('account_subtype')
    seg     = Find-Col $sCols @('Customer Segment')
    csm     = Find-Col $sCols @('CSM Name')
    region  = Find-Col $sCols @('Region')
    ws      = Find-Col $sCols @('Quality Website Score','Website Score')
    ws_link = Find-Col $sCols @('Website Link')
    pen     = Find-Col $sCols @('Pendency (6 hrs)','Pendency')
    # Monthly usage VINs — sheet cols M-R (gid=603796861). Header text carries
    # an apostrophe ("Jan'26"); match defensively then fall back to position.
    u_jan   = Find-Col $sCols @("Usage Jan'26","Usage Jan26","Jan'26","Jan26")
    u_feb   = Find-Col $sCols @("Feb'26","Feb26")
    u_mar   = Find-Col $sCols @("Mar'26","Mar26")
    u_apr   = Find-Col $sCols @("Apr'26","Apr26")
    u_may   = Find-Col $sCols @("May'26","May26")
    u_mtd   = Find-Col $sCols @('mtd_vins','MTD VINs','MTD Vins','MTD')
    arr     = Find-Col $sCols @('ARR')
    t1      = Find-Col $sCols @('Payment T1','T1')
    t2      = Find-Col $sCols @('T2')
    t3      = Find-Col $sCols @('T3')
    prag    = Find-Col $sCols @('Payment RAG')
    unr     = Find-Col $sCols @('Tickets #Unresolved','#Unresolved')
    cr      = Find-Col $sCols @('#Created','Tickets #Created')
    ota     = Find-Col $sCols @('Open Ticket Ageing (Hrs)','Open Ticket Ageing','Open Ageing (Hrs)')
    res     = Find-Col $sCols @('Avg Resolution hrs','Avg Resolution')
    trag    = Find-Col $sCols @('Ticket RAG')
    red     = Find-Col $sCols @('Communication RAG Status','Communication RAG')
    mbr     = Find-Col $sCols @('Leadership Connect MBR','MBR')
    cf      = Find-Col $sCols @('Contact Freq')
}
# Positional fallbacks for the monthly usage block (M=12 … R=17, 0-based) in
# case the apostrophe'd header text doesn't match exactly.
if ($si.u_jan -lt 0) { $si.u_jan = 12 }
if ($si.u_feb -lt 0) { $si.u_feb = 13 }
if ($si.u_mar -lt 0) { $si.u_mar = 14 }
if ($si.u_apr -lt 0) { $si.u_apr = 15 }
if ($si.u_may -lt 0) { $si.u_may = 16 }
if ($si.u_mtd -lt 0) { $si.u_mtd = 17 }

# Resolution time column is `[h]:mm:ss` formatted — extract from the
# Gviz cell.f (display string) rather than .v (broken Date encoding).
function Gviz-Hrs($cell) {
    if (-not $cell) { return '' }
    $f = [string]$cell.f
    if (-not $f) { return '' }
    if ($f -match '^(\d+):(\d+):(\d+)') {
        return ([double]$matches[1] + [double]$matches[2]/60.0 + [double]$matches[3]/3600.0)
    }
    return ''
}

# Manual segment overrides for Studio — keyed by Enterprise ID. Use when the
# sheet's Customer Segment column is wrong/missing for a specific enterprise
# and the user wants a different classification surfaced in the dashboard.
# Mirrors the same pattern used for $manualSeg on the Vini side.
$studioManualSeg = @{
    '00d2aafe9' = 'Ent'   # IM Marketplace GmBH — per user override
}

$sRows = New-Object System.Collections.Generic.List[object]
$idx = @{}; for ($i=0; $i -lt $sStudioSchema.Count; $i++) { $idx[$sStudioSchema[$i]] = $i }
foreach ($row in $studioTab.rows) {
    $c = $row.c; if (-not $c) { continue }
    $rid = [string](Gviz-Val $c[$si.rid])
    if (-not $rid) { continue }

    # ARR comes from the new sheet column S. MRR is derived: ARR / 12.
    $arrRaw = if ($si.arr -ge 0) { Gviz-Val $c[$si.arr] } else { 0 }
    $arrNum = 0.0
    try { $arrNum = [double]$arrRaw } catch { $arrNum = 0.0 }
    $mrrNum = if ($arrNum -gt 0) { $arrNum / 12.0 } else { 0.0 }

    $r = New-Object object[] $sStudioSchema.Count

    $r[$idx['rid']]     = $rid
    $r[$idx['rn']]      = [string](Gviz-Val $c[$si.rn])
    $r[$idx['en']]      = [string](Gviz-Val $c[$si.en])
    $r[$idx['mrr']]     = $mrrNum
    $r[$idx['arr']]     = $arrNum
    # Monthly usage VINs (sheet cols M-R). Numeric per rooftop. The dashboard
    # sums these across a group and derives the Usage Trend at render time.
    $r[$idx['u_jan']]   = Gviz-Val $c[$si.u_jan]
    $r[$idx['u_feb']]   = Gviz-Val $c[$si.u_feb]
    $r[$idx['u_mar']]   = Gviz-Val $c[$si.u_mar]
    $r[$idx['u_apr']]   = Gviz-Val $c[$si.u_apr]
    $r[$idx['u_may']]   = Gviz-Val $c[$si.u_may]
    $r[$idx['u_mtd']]   = Gviz-Val $c[$si.u_mtd]
    $r[$idx['pen']]     = Gviz-Val $c[$si.pen]
    $r[$idx['ws']]      = Gviz-Val $c[$si.ws]
    $r[$idx['ws_link']] = if ($si.ws_link -ge 0) { [string](Gviz-Val $c[$si.ws_link]) } else { '' }
    # T-1 / T-2 / T-3 sourced from gid=1395015507 dense-rank by enterprise_id
    # (NOT the sheet's Payment T1/T2/T3 columns). Rank 2/3/4 customer_status →
    # t1/t2/t3. Payment RAG is recomputed worst-wins from the resulting statuses.
    $eidStr  = [string](Gviz-Val $c[$si.eid])
    $eidNorm = $eidStr.Trim().ToLower()
    $pr = $null
    if ($payRanks.ContainsKey($eidStr))      { $pr = $payRanks[$eidStr] }
    elseif ($payRanks.ContainsKey($eidNorm)) { $pr = $payRanks[$eidNorm] }
    if ($pr) {
        $r[$idx['t1']]   = [string]$pr.t1
        $r[$idx['t2']]   = [string]$pr.t2
        $r[$idx['t3']]   = [string]$pr.t3
        $r[$idx['prag']] = Compute-PaymentRag $pr.t1 $pr.t2 $pr.t3
    } else {
        $r[$idx['t1']]   = ''
        $r[$idx['t2']]   = ''
        $r[$idx['t3']]   = ''
        $r[$idx['prag']] = ''
    }
    $r[$idx['unr']]     = Gviz-Val $c[$si.unr]
    $r[$idx['cr']]      = Gviz-Val $c[$si.cr]
    $r[$idx['ota']]     = Gviz-Val $c[$si.ota]
    # Avg Resolution: parse the formatted h:mm:ss string from `f`
    $r[$idx['res']]     = if ($si.res -ge 0) { Gviz-Hrs $c[$si.res] } else { '' }
    $r[$idx['trag']]    = [string](Gviz-Val $c[$si.trag])
    $r[$idx['red']]     = [string](Gviz-Val $c[$si.red])
    $r[$idx['mbr']]     = [string](Gviz-Val $c[$si.mbr])
    $r[$idx['cf']]      = [string](Gviz-Val $c[$si.cf])

    $csmRaw = [string](Gviz-Val $c[$si.csm])
    if ([string]::IsNullOrWhiteSpace($csmRaw) -or $csmRaw.Trim().ToLower() -in 'csm not assigned','not assigned','unassigned','na','tbd') {
        $csmRaw = 'Unassigned CSM'
    }
    $r[$idx['csm']]     = $csmRaw
    $r[$idx['ct']]      = [string](Gviz-Val $c[$si.ct])
    $r[$idx['cst']]     = [string](Gviz-Val $c[$si.cst])
    # Read eid first so we can apply the manual segment override below.
    $eidForRow = [string](Gviz-Val $c[$si.eid])
    $segValue  = [string](Gviz-Val $c[$si.seg])
    if ($eidForRow -and $studioManualSeg.ContainsKey($eidForRow)) {
        $segValue = $studioManualSeg[$eidForRow]
    }
    $r[$idx['seg']]     = $segValue
    $r[$idx['region']]  = [string](Gviz-Val $c[$si.region])
    # eid: needed so payment-bucket aggregates can dedup per enterprise.
    $r[$idx['eid']]     = $eidForRow

    $sRows.Add($r)
}
Write-Host "  Studio: built $($sRows.Count) s_rows (MRR computed as ARR/12)"

# Guard: never overwrite Studio data with an empty/near-empty fetch. gviz can
# hand back an empty table even after Fetch-Gviz's retries (seen 2026-06-22),
# which previously wiped all ~1400 rooftops to s_rows:[] and zeroed the Studio
# tab. Abort the whole sync instead — the existing snapshot is preserved, the
# next 15-min run retries, and a sustained failure shows up red in Actions.
if ($sRows.Count -lt 100) {
    throw "Studio s_rows came back as $($sRows.Count) (expected ~1400). Aborting sync to avoid wiping Studio data — the gid=603796861 gviz fetch returned empty/partial."
}

# --- Manual JSON build (avoid PowerShell serializer quirks) ---
function JsEscape($s) {
    if ($null -eq $s) { return 'null' }
    $t=[string]$s
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $t.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '"' { [void]$sb.Append('\"') }
            "`r" { [void]$sb.Append('\r') }
            "`n" { [void]$sb.Append('\n') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code=[int]$ch
                if ($code -lt 32) { [void]$sb.AppendFormat('\u{0:x4}',$code) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function JsNum($v) {
    # PowerShell quirk: `0 -eq ''` is TRUE (right operand coerced to int 0).
    # So the previous shorthand `$v -eq ''` was silently converting a numeric
    # zero to JSON null. Now we explicitly require an empty STRING to null out.
    if ($null -eq $v) { return 'null' }
    if ($v -is [string] -and $v -eq '') { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    try { return [string]([double]$v) } catch { return (JsEscape $v) }
}
function RowToJsArr($r) {
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($cell in $r) {
        if ($null -eq $cell) { $parts.Add('""') }
        elseif ($cell -is [string]) { $parts.Add((JsEscape $cell)) }
        elseif ($cell -is [int] -or $cell -is [long] -or $cell -is [double] -or $cell -is [float] -or $cell -is [decimal]) {
            $parts.Add([string]$cell)
        } elseif ($cell -is [bool]) {
            $parts.Add($(if ($cell) {'true'} else {'false'}))
        } else { $parts.Add((JsEscape ([string]$cell))) }
    }
    return '[' + ($parts -join ',') + ']'
}
$sb=New-Object System.Text.StringBuilder
[void]$sb.Append('[')
for ($i=0;$i -lt $vRowsScoped.Count;$i++) { if ($i -gt 0) { [void]$sb.Append(',') }; [void]$sb.Append((RowToJsArr $vRowsScoped[$i])) }
[void]$sb.Append(']')
$jsonVRows=$sb.ToString()

# Studio s_rows + s_schema
$sb_s = New-Object System.Text.StringBuilder
[void]$sb_s.Append('[')
for ($i=0; $i -lt $sRows.Count; $i++) {
    if ($i -gt 0) { [void]$sb_s.Append(',') }
    [void]$sb_s.Append((RowToJsArr $sRows[$i]))
}
[void]$sb_s.Append(']')
$jsonSRows = $sb_s.ToString()
$jsonSSchema = '[' + (($sStudioSchema | ForEach-Object { JsEscape $_ }) -join ',') + ']'

$sb2=New-Object System.Text.StringBuilder
[void]$sb2.Append('[')
for ($i=0;$i -lt $viniStage.Count;$i++) {
    if ($i -gt 0) { [void]$sb2.Append(',') }
    $rec=$viniStage[$i]
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($k in 'rid','en','rn','eid','stage','agent','t1','t2','t3','ps','csm','region','seg','go_live') { $parts.Add((JsEscape $k) + ':' + (JsEscape $rec[$k])) }
    foreach ($k in 'mrr','arr') { $parts.Add((JsEscape $k) + ':' + (JsNum $rec[$k])) }
    [void]$sb2.Append('{' + ($parts -join ',') + '}')
}
[void]$sb2.Append(']')
$jsonStage=$sb2.ToString()

function CsatRecToJson($rec) {
    return '{' + (JsEscape 'date_iso') + ':' + (JsEscape $rec.date_iso) + ',' + (JsEscape 'avg') + ':' + (JsNum $rec.avg) + ',' + (JsEscape 'name') + ':' + (JsEscape $rec.name) + '}'
}
function CsatDictToJson($dict) {
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) { $parts.Add((JsEscape $k) + ':' + (CsatRecToJson $dict[$k])) }
    return '{' + ($parts -join ',') + '}'
}
function CsatAllToJson($dict) {
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $items=New-Object System.Collections.Generic.List[string]
        foreach ($r in $dict[$k]) {
            # intCount sourced from column J (interaction_count) — kept as
            # int; absent on legacy snapshots so default to 0.
            $ic = if ($null -eq $r.intCount) { 0 } else { [int]$r.intCount }
            $items.Add('{"date_iso":' + (JsEscape $r.date_iso) + ',"avg":' + (JsNum $r.avg) + ',"rag":' + (JsEscape $r.rag) + ',"intCount":' + $ic + '}')
        }
        $parts.Add((JsEscape $k) + ':[' + ($items -join ',') + ']')
    }
    return '{' + ($parts -join ',') + '}'
}
$jsonCsatEid=CsatDictToJson $byEid
$jsonCsatName=CsatDictToJson $byName
$jsonCsatAll     = CsatAllToJson $allByEid
$jsonCsatAllName = CsatAllToJson $allByName

# vini_tix dict → JSON. Each entry is { rows: [{c,o,r,a}, ...] } where the
# dashboard then date-filters and aggregates client-side per active period.
function ViniTixToJson($dict) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $dict[$k]) {
            $oBool = if ($r.o) { 'true' } else { 'false' }
            # s = SLA Violated flag (col I 'Resolution status' = 'SLA Violated').
            $sBool = if ($r.s) { 'true' } else { 'false' }
            # p = priority (lowercased) — drives the per-priority Ticket RAG
            # client-side (urgent/high/medium/low → distinct SLA thresholds).
            $pStr = if ($null -eq $r.p) { '""' } else { JsEscape $r.p }
            # i = Freshdesk ticket id (string) for the clickable open-ticket list.
            $iStr = if ($null -eq $r.i) { '""' } else { JsEscape $r.i }
            # fr = First response SLA status for the ticket popup column.
            $frStr = if ($null -eq $r.fr) { '""' } else { JsEscape $r.fr }
            $items.Add('{"c":' + (JsEscape $r.c) + ',"o":' + $oBool + ',"r":' + (JsNum $r.r) + ',"a":' + (JsNum $r.a) + ',"s":' + $sBool + ',"p":' + $pStr + ',"i":' + $iStr + ',"fr":' + $frStr + '}')
        }
        $parts.Add((JsEscape $k) + ':{"rows":[' + ($items -join ',') + ']}')
    }
    return '{' + ($parts -join ',') + '}'
}
$jsonViniTix   = ViniTixToJson $viniTix
$jsonStudioTix = ViniTixToJson $studioTix

# report_coverage → JSON array. Preserves the previously-spliced data when
# the fetch fails (null). Each entry is {day, attempted, sent, notSent,
# sentPct, pendingVins, negativeTat}.
function ReportCoverageToJson($arr) {
    $parts = New-Object System.Collections.Generic.List[string]
    if ($arr) {
        foreach ($r in $arr) {
            $day      = if ($r.reportDay) { JsEscape $r.reportDay } else { 'null' }
            $att      = if ($null -ne $r.attemptedRooftops) { JsNum $r.attemptedRooftops } else { '0' }
            $sent     = if ($null -ne $r.sent) { JsNum $r.sent } else { '0' }
            $notSent  = if ($null -ne $r.notSent) { JsNum $r.notSent } else { '0' }
            $pct      = if ($null -ne $r.sentPct) { JsNum $r.sentPct } else { '0' }
            $pendVins = if ($null -ne $r.reasonPendingVins) { JsNum $r.reasonPendingVins } else { '0' }
            $negTat   = if ($null -ne $r.reasonNegativeTat) { JsNum $r.reasonNegativeTat } else { '0' }
            $parts.Add('{"day":' + $day + ',"attempted":' + $att + ',"sent":' + $sent +
                       ',"notSent":' + $notSent + ',"sentPct":' + $pct +
                       ',"pendingVins":' + $pendVins + ',"negativeTat":' + $negTat + '}')
        }
    }
    return '[' + ($parts -join ',') + ']'
}
# report_tracking → JSON. Dict keyed by enterprise_id, each value is the
# array of per-attempt rows for the last 7 days.
function ReportTrackingToJson($dict) {
    if (-not $dict) { return '{}' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $dict[$k]) {
            $items.Add('{"d":' + (JsEscape $r.d) + ',"t":' + (JsEscape $r.t) + ',"s":' + (JsEscape $r.s) + ',"r":' + (JsEscape $r.r) + '}')
        }
        $parts.Add((JsEscape $k) + ':[' + ($items -join ',') + ']')
    }
    return '{' + ($parts -join ',') + '}'
}
if ($trackingFailed) {
    # Preserve from previous snapshot if fetch failed.
    $jsonTracking = '{}'
    if ($D.report_tracking) {
        $preserved = @{}
        foreach ($k in $D.report_tracking.Keys) {
            $list = New-Object System.Collections.Generic.List[hashtable]
            foreach ($r in $D.report_tracking[$k]) {
                $list.Add(@{ d=[string]$r.d; t=[string]$r.t; s=[string]$r.s; r=[string]$r.r })
            }
            $preserved[$k] = $list
        }
        $jsonTracking = ReportTrackingToJson $preserved
    }
} else {
    $jsonTracking = ReportTrackingToJson $reportTracking
}

if ($null -eq $reportCoverage) {
    # preserve from snapshot
    $jsonCoverage = '[]'
    if ($D.report_coverage) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $D.report_coverage) {
            $items.Add('{"day":' + (JsEscape $r.day) +
                       ',"attempted":' + (JsNum $r.attempted) +
                       ',"sent":' + (JsNum $r.sent) +
                       ',"notSent":' + (JsNum $r.notSent) +
                       ',"sentPct":' + (JsNum $r.sentPct) +
                       ',"pendingVins":' + (JsNum $r.pendingVins) +
                       ',"negativeTat":' + (JsNum $r.negativeTat) + '}')
        }
        $jsonCoverage = '[' + ($items -join ',') + ']'
    }
} else {
    $jsonCoverage = ReportCoverageToJson $reportCoverage
}

# --- Splice into existing dashboard JSON ---
function StripKey($s, $key) {
    $marker='"' + $key + '":'
    $start=$s.IndexOf($marker)
    if ($start -lt 0) { return $s }
    $i=$start + $marker.Length
    while ($i -lt $s.Length -and $s[$i] -in ' ',"`t","`r","`n") { $i++ }
    if ($i -ge $s.Length) { return $s }
    $open=$s[$i]
    if ($open -eq '{' -or $open -eq '[') {
        $close=if ($open -eq '{') {'}'} else {']'}
        $depth=0; $inStr=$false; $esc=$false; $end=-1
        for ($j=$i;$j -lt $s.Length;$j++) {
            $ch=$s[$j]
            if ($inStr) {
                if ($esc) { $esc=$false } elseif ($ch -eq '\') { $esc=$true } elseif ($ch -eq '"') { $inStr=$false }
            } else {
                if ($ch -eq '"') { $inStr=$true }
                elseif ($ch -eq $open) { $depth++ }
                elseif ($ch -eq $close) { $depth--; if ($depth -eq 0) { $end=$j; break } }
            }
        }
        if ($end -lt 0) { return $s }
    } else {
        $end=$i
        while ($end -lt $s.Length -and $s[$end] -notin ',','}',"`r","`n") { $end++ }
        $end--
    }
    $stripStart=$start
    if ($start -gt 0 -and $s[$start-1] -eq ',') { $stripStart=$start-1 }
    elseif ($end+1 -lt $s.Length -and $s[$end+1] -eq ',') { $end=$end+1 }
    return $s.Substring(0,$stripStart) + $s.Substring($end+1)
}

# --- Account status from Metabase (per-CSM stage buckets: Live / OB / Contracted) ---
# Public CSV; the CSM dashboard can't fetch it client-side (no CORS), so we pull
# it here every sync and embed window.__DASHBOARD_DATA__.account_status, keyed by
# CSM display name ('__all__' = org). Contracted = Contract-Initiated|Contracted|New.
function NormalizeCsmName($email) {
    if (-not $email -or $email -notmatch '@') { return [string]$email }
    $local = ($email -split '@')[0].Trim()
    if ($local.ToLower() -eq 'greeva.mishra') { return 'Greeva' }
    return (($local -split '[._]' | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ' ')
}
# Signed Metabase embed (HS256 JWT). The secret comes from the
# METABASE_SECRET_KEY Actions secret — NEVER hard-coded or shipped to the page.
function New-MetabaseJwt($secret, $questionId) {
    $enc = [System.Text.Encoding]::UTF8
    $b64 = { param($bytes) [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 600
    $h = & $b64 $enc.GetBytes('{"alg":"HS256","typ":"JWT"}')
    $p = & $b64 $enc.GetBytes('{"resource":{"question":' + $questionId + '},"params":{},"exp":' + $exp + '}')
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $enc.GetBytes($secret)
    $s = & $b64 $hmac.ComputeHash($enc.GetBytes("$h.$p"))
    return "$h.$p.$s"
}
$accountStatusJson = $null
try {
    $mbSecret = $env:METABASE_SECRET_KEY
    if (-not $mbSecret) { throw "METABASE_SECRET_KEY env not set" }
    $mbTok = New-MetabaseJwt $mbSecret 12436
    $metaCsv = Invoke-RestMethod -Uri "https://metabase.spyne.ai/api/embed/card/$mbTok/query/csv" -TimeoutSec 90
    $asRows = $metaCsv | ConvertFrom-Csv
    if ($asRows.Count -lt 100) { throw "only $($asRows.Count) rows" }
    # Detect name columns once (flexible — fall back to id when absent) so the
    # OB / Contracted popups can show enterprise_name / team_name, not just ids.
    $colNames = @($asRows[0].PSObject.Properties.Name)
    $pick = { param($cands) foreach ($c in $cands) { if ($colNames -contains $c) { return $c } }; return $null }
    $entNameCol  = & $pick @('enterprise_name','account_name','company_name','company','enterprise')
    $teamNameCol = & $pick @('team_name','rooftop_name','dealership_name','rooftop','dealership')
    Write-Host "  account_status name cols: enterprise='$entNameCol' team='$teamNameCol'"
    # Each bucket holds e/t as ordered id->name maps (name '' falls back to id).
    $byCsm = @{}
    foreach ($r in $asRows) {
        $st = ([string]$r.stage).Trim()
        $b = if ($st -eq 'Live') {'live'} elseif ($st -eq 'Onboarding') {'ob'} elseif (@('Contract-Initiated','Contracted','New') -contains $st) {'contracted'} else {$null}
        if (-not $b) { continue }
        $csmName = NormalizeCsmName ([string]$r.cs_poc_email)
        $enNm = if ($entNameCol)  { [string]$r.$entNameCol }  else { '' }
        $tmNm = if ($teamNameCol) { [string]$r.$teamNameCol } else { '' }
        foreach ($key in @($csmName, '__all__')) {
            if (-not $byCsm.ContainsKey($key)) { $byCsm[$key] = @{ live=@{e=[ordered]@{};t=[ordered]@{}}; ob=@{e=[ordered]@{};t=[ordered]@{}}; contracted=@{e=[ordered]@{};t=[ordered]@{}} } }
            if ($r.enterprise_id) { $byCsm[$key][$b].e[[string]$r.enterprise_id] = $enNm }
            # Teams store the enterprise_id alongside the name so the rooftop
            # console deep-link can be enterprise_id + team_id.
            if ($r.team_id)       { $byCsm[$key][$b].t[[string]$r.team_id]       = @{ n = $tmNm; e = [string]$r.enterprise_id } }
        }
    }
    $asParts = New-Object System.Collections.Generic.List[string]
    # eL/tL = [{i:id, n:name}] lists. Emitted ONLY for ob/contracted (the red,
    # clickable rows); live stays counts-only to keep the payload small.
    # eL = enterprises [{i:id, n:name}]; tL = teams [{i:team_id, n:name, e:enterprise_id}].
    $listJsonE = { param($map) (@($map.GetEnumerator() | ForEach-Object { '{"i":' + (JsEscape $_.Key) + ',"n":' + (JsEscape $(if ($_.Value) { $_.Value } else { $_.Key })) + '}' }) -join ',') }
    $listJsonT = { param($map) (@($map.GetEnumerator() | ForEach-Object { '{"i":' + (JsEscape $_.Key) + ',"n":' + (JsEscape $(if ($_.Value.n) { $_.Value.n } else { $_.Key })) + ',"e":' + (JsEscape ([string]$_.Value.e)) + '}' }) -join ',') }
    $cellCount = { param($x) '{"a":' + $x.e.Count + ',"r":' + $x.t.Count + '}' }
    $cellFull  = { param($x) '{"a":' + $x.e.Count + ',"r":' + $x.t.Count + ',"eL":[' + (& $listJsonE $x.e) + '],"tL":[' + (& $listJsonT $x.t) + ']}' }
    foreach ($k in $byCsm.Keys) {
        $o = $byCsm[$k]
        $asParts.Add((JsEscape $k) + ':{"live":' + (& $cellCount $o.live) + ',"ob":' + (& $cellFull $o.ob) + ',"contracted":' + (& $cellFull $o.contracted) + '}')
    }
    $accountStatusJson = '{' + ($asParts -join ',') + '}'
    Write-Host "  account_status: $($byCsm.Count) CSM keys from Metabase"
} catch {
    Write-Host "  account_status: WARNING — Metabase fetch/parse failed ($_). Preserving existing block."
}

# --- GRR per CSM from gid=1436275090 ----------------------------------------
# One row per enterprise: Stage (col D=3), CSM email (col J=9), ARR (col K=10).
# Rows are filtered to those whose CSM cell contains '@' so the summary row
# (col J empty) and the header row (col J = 'CSM Name_New') drop out. Per CSM:
#   total = SUM ARR (whole book, all stages)   live = SUM ARR where Stage='Live'
# Embedded as csm_grr keyed by CSM display name ('__all__' = org); the dashboard
# shows GRR = live / total. Preserves the existing block on any failure.
$csmGrrJson = $null
try {
    $grrTab = Fetch-Gviz $urls.csmgrr 200    # ~900 enterprise rows typical
    $grr = @{}
    foreach ($row in $grrTab.rows) {
        $c = $row.c; if (-not $c) { continue }
        $csmRaw = [string](Gviz-Val $c[9])
        if (-not $csmRaw.Contains('@')) { continue }   # skips summary + header rows
        $arr = [double](Parse-Money (Gviz-Val $c[10]))
        $isLive = ((([string](Gviz-Val $c[3])).Trim()).ToLower() -eq 'live')
        $csmName = NormalizeCsmName $csmRaw
        if (-not $csmName) { $csmName = 'Unassigned' }
        foreach ($key in @($csmName, '__all__')) {
            if (-not $grr.ContainsKey($key)) { $grr[$key] = @{ total = 0.0; live = 0.0 } }
            $grr[$key].total += $arr
            if ($isLive) { $grr[$key].live += $arr }
        }
    }
    if ($grr.Count -gt 1) {
        $gParts = New-Object System.Collections.Generic.List[string]
        foreach ($k in $grr.Keys) {
            $o = $grr[$k]
            $gParts.Add((JsEscape $k) + ':{"arr":' + ([string][double]$o.total) + ',"live":' + ([string][double]$o.live) + '}')
        }
        $csmGrrJson = '{' + ($gParts -join ',') + '}'
        $allTot = if ($grr.ContainsKey('__all__')) { [math]::Round($grr['__all__'].total) } else { 0 }
        Write-Host "  csm_grr: $($grr.Count) CSM keys (org book ARR $allTot)"
    } else {
        Write-Host "  csm_grr: WARNING — 0 rows parsed; preserving existing block."
    }
} catch {
    Write-Host "  csm_grr: WARNING — fetch/parse failed ($_). Preserving existing block."
}

# --- New-addition "Live This Month" ARR from the OB sheet --------------------
# Sheet 1ioRroo… : Vini gid=2053683245 (Go-Live Date = col 16), Studio
# gid=1134407178 (Live Month = col 37, 'YYYY-MM'). Per product: rows where
# Stage='Live' AND the go-live month == the current month; sum ARR ($) (col 2).
# Embedded as new_addition so the email snapshot uses real per-product values
# (replacing the fragile onboarding-SPA scrape + hard-coded constant).
$naSheet = '1ioRrooOvDSBxc7gjC2XUGjqHH_YBze_2HryOF8JWqL0'
$naCurYM = (Get-Date).ToString('yyyy-MM')
function NA-Money($v) { if ($null -eq $v -or $v -eq '') { return 0.0 }; $c = ([string]$v) -replace '[^0-9.\-]',''; try { return [double]$c } catch { return 0.0 } }
function NA-LiveThisMonth($gid, $goCol, $isStudio, $allRows = $false) {
    # ARR=col 2, Stage=col 4. Data starts at row 3 (rows 0-2 are total/note/header).
    # $allRows = $true → count EVERY account in the tab (no Stage / go-live-month
    # filter); used for Studio, where the whole onboarding workbook is the
    # new-business cohort ("AMER + APAC/EMEA = studio ARR").
    $tab = Fetch-Gviz "https://docs.google.com/spreadsheets/d/$naSheet/gviz/tq?tqx=out:json&gid=$gid" 50
    $arr = 0.0; $n = 0
    $roofs = New-Object System.Collections.Generic.HashSet[string]
    $ents  = New-Object System.Collections.Generic.HashSet[string]
    $items = New-Object System.Collections.ArrayList   # per-rooftop {r=name; a=arr} for cross-sync union
    for ($ri = 3; $ri -lt $tab.rows.Count; $ri++) {
        $c = $tab.rows[$ri].c; if (-not $c) { continue }
        $acct = [string](Gviz-Val $c[0]); if (-not $acct) { continue }
        if (-not $allRows) {
            if ((([string](Gviz-Val $c[4])).Trim().ToLower()) -ne 'live') { continue }
            # go-live month: Studio = 'YYYY-MM' string; Vini = a date → YYYY-MM-DD.
            $gm = if ($isStudio) { ([string](Gviz-Val $c[$goCol])).Trim() } else { [string](Gviz-Date $c[$goCol]) }
            if (-not $gm.StartsWith($naCurYM)) { continue }
        }
        $a = NA-Money (Gviz-Val $c[2])
        $arr += $a; $n++
        $rn = [string](Gviz-Val $c[1]); if ($rn) { [void]$roofs.Add($rn) }
        $eid = [string](Gviz-Val $c[$(if ($isStudio) {6} else {7})]); if ($eid) { [void]$ents.Add($eid) } elseif ($acct) { [void]$ents.Add($acct) }
        $rkey = if ($rn) { $rn } else { $acct }
        [void]$items.Add(@{ r = $rkey; a = $a })
    }
    return @{ arr = $arr; rooftops = $roofs.Count; ents = $ents.Count; n = $n; items = $items }
}
$newAdditionJson = $null
$newAdditionStudioAcctsJson = $null
try {
    # VINI: read from the PERSISTENT payment master ($payTab, gid 674556270) —
    # Stage='Live' AND Go-Live Date in the current month, deduped by rooftop
    # (Team ID) so multi-agent rows don't double-count ARR. Unlike the onboarding
    # tab this book retains live accounts, so the figure is stable/immediate.
    if ($pi.go_live -ge 0 -and $pi.stage -ge 0) {
        $naVArr = 0.0
        $naVRoofs = New-Object System.Collections.Generic.HashSet[string]
        $naVEnts  = New-Object System.Collections.Generic.HashSet[string]
        foreach ($row in $payTab.rows) {
            $c = $row.c; if (-not $c) { continue }
            if ((([string](Gviz-Val $c[$pi.stage])).Trim().ToLower()) -ne 'live') { continue }
            $gm = [string](Gviz-Date $c[$pi.go_live])
            if (-not $gm.StartsWith($naCurYM)) { continue }
            $rid = [string](Gviz-Val $c[$pi.rid]); if (-not $rid) { $rid = [string](Gviz-Val $c[$pi.rn]) }
            if ($rid -and $naVRoofs.Contains($rid)) { continue }   # one ARR per rooftop
            if ($rid) { [void]$naVRoofs.Add($rid) }
            $naVArr += NA-Money (Gviz-Val $c[$pi.arr])
            $eid = [string](Gviz-Val $c[$pi.eid]); if ($eid) { [void]$naVEnts.Add($eid) }
        }
        $naV = @{ arr = $naVArr; rooftops = $naVRoofs.Count; ents = $naVEnts.Count; n = $naVRoofs.Count }
    } else {
        # Column lookup failed — fall back to the onboarding tab.
        $naV = NA-LiveThisMonth 2053683245 16 $false
    }
    # STUDIO new-addition = AMER tab + APAC/EMEA tab, per spec
    # "AMER + APAC/EMEA = studio ARR". Sum EVERY account in both onboarding tabs
    # (no Stage / go-live-month filter — the whole workbook is the new-business
    # cohort). ARR = col 2; rooftops = row count; ents = unique Enterprise IDs.
    $naS1 = NA-LiveThisMonth 1134407178 37 $true $true
    $naS2 = NA-LiveThisMonth 764039413 40 $true $true
    $naS = @{ arr = ($naS1.arr + $naS2.arr); rooftops = ($naS1.n + $naS2.n); ents = ($naS1.ents + $naS2.ents) }
    $newAdditionStudioAcctsJson = '{}'   # cross-sync union no longer used
    $studioSrc = "AMER+APAC/EMEA tabs"

    $cell = { param($x) '{"arr":' + ([string][double]$x.arr) + ',"rooftops":' + $x.rooftops + ',"ents":' + $x.ents + '}' }
    $newAdditionJson = '{"month":' + (JsEscape $naCurYM) + ',"studio":' + (& $cell $naS) + ',"vini":' + (& $cell $naV) + '}'
    Write-Host "  new_addition ($naCurYM): Studio `$$([math]::Round($naS.arr)) ($($naS.rooftops) rt, $studioSrc) | Vini `$$([math]::Round($naV.arr)) ($($naV.rooftops) rt) | Overall `$$([math]::Round($naS.arr + $naV.arr))"
} catch {
    Write-Host "  new_addition: WARNING — fetch/parse failed ($_). Preserving existing block."
}

$json=$origJson
$asKeys = @('v_rows','vini_stage','csat_by_eid','csat_by_name','csat_all_by_eid','csat_all_by_name','vini_tix','studio_tix','s_rows','s_schema','report_coverage','report_tracking')
if ($accountStatusJson) { $asKeys += 'account_status' }   # only strip when we have a fresh value to replace it
if ($csmGrrJson)        { $asKeys += 'csm_grr' }          # only strip when we have a fresh value to replace it
if ($newAdditionJson)   { $asKeys += 'new_addition' }     # only strip when we have a fresh value to replace it
if ($newAdditionStudioAcctsJson) { $asKeys += 'new_addition_studio_accts' }   # cross-sync Studio union state
foreach ($k in $asKeys) { $json=StripKey $json $k }
$lastBrace=$json.LastIndexOf('}')
$inserted = ',"v_rows":' + $jsonVRows +
            ',"vini_stage":' + $jsonStage +
            ',"csat_by_eid":' + $jsonCsatEid +
            ',"csat_by_name":' + $jsonCsatName +
            ',"csat_all_by_eid":' + $jsonCsatAll +
            ',"csat_all_by_name":' + $jsonCsatAllName +
            ',"vini_tix":' + $jsonViniTix +
            ',"studio_tix":' + $jsonStudioTix +
            ',"s_rows":' + $jsonSRows +
            ',"s_schema":' + $jsonSSchema +
            ',"report_coverage":' + $jsonCoverage +
            ',"report_tracking":' + $jsonTracking
if ($accountStatusJson) { $inserted += ',"account_status":' + $accountStatusJson }
if ($csmGrrJson)        { $inserted += ',"csm_grr":' + $csmGrrJson }
if ($newAdditionJson)   { $inserted += ',"new_addition":' + $newAdditionJson }
if ($newAdditionStudioAcctsJson) { $inserted += ',"new_addition_studio_accts":' + $newAdditionStudioAcctsJson }
$json = $json.Substring(0,$lastBrace) + $inserted + $json.Substring($lastBrace)

# --- Churn-analysis records → window.__CHURN_ANALYSIS__ ---------------------
# Source: the SEPARATE Spyne churn tracker — published-to-web CSV, gid=1421999984
# (see $urls.churn). Row 0 is a "do not shift columns" note; row 1 is the header;
# data begins at row 2. We read by HEADER NAME (robust to reordering):
#   New Enterprise ID, Customer, Customer Segment, ARR, Churn/Contraction Month,
#   Product, Region, CSM Name, Billing Status, Category, Reason,
#   Regretable/ Unregretable, Leader Approved
# CSM email local-part → "First Last" display (anuj.tewatia → Anuj Tewatia).
# On ANY fetch/parse failure we PRESERVE the existing embedded block (the
# __CHURN_ANALYSIS__ line is left untouched) rather than wiping the tab.
function Title-Token($t) {
    if (-not $t) { return '' }
    return $t.Substring(0,1).ToUpper() + $t.Substring(1).ToLower()
}
function Csm-Display($raw) {
    # Normalize CSM identity to ONE canonical form so the dropdown doesn't show
    # dirty duplicates (e.g. a stray tab + lowercase "\tankur Batra" vs the clean
    # "Ankur Batra"). Strip an email domain if present, then split on dots /
    # underscores / ANY whitespace (incl. tabs) and Title-Case each token.
    $s = (([string]$raw) -replace '\s+', ' ').Trim()
    if (-not $s) { return 'Unassigned' }
    if ($s.Contains('@')) { $s = $s.Substring(0, $s.IndexOf('@')) }
    $toks = $s -split '[._\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { Title-Token $_ }
    $disp = ($toks -join ' ').Trim()
    if (-not $disp) { return 'Unassigned' }
    return $disp
}
$churnJson = $null
try {
    # The published sheet exports CSV. Row 0 is a "do not shift columns" note;
    # row 1 is the real header; data begins at row 2. We drop the first physical
    # line, then ConvertFrom-Csv (which honours quoted commas / embedded
    # newlines) using the real header, and read each field BY NAME (robust to
    # column reordering). Column layout matches the old gviz tab.
    $churnText = $null
    for ($att = 1; $att -le 5; $att++) {
        try {
            $sepc = if ($urls.churn.Contains('?')) { '&' } else { '?' }
            $cu = "$($urls.churn)$sepc`_cb=" + [Guid]::NewGuid().ToString('N')
            if ($att -gt 1) { Write-Host "  churn csv retry $att" }
            $cr = Invoke-WebRequest -Uri $cu -UseBasicParsing -TimeoutSec 120 -Headers @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
                'Accept'     = 'text/csv, text/plain, */*'
            }
            if ($cr.StatusCode -eq 200 -and $cr.Content -and $cr.Content.Length -gt 500) { $churnText = $cr.Content; break }
        } catch { Write-Host "  churn csv attempt $att failed: $_" }
        Start-Sleep -Seconds 5
    }
    if (-not $churnText) { throw "no CSV content after retries" }
    # Drop the leading "do not shift" note line so the real header is first.
    $brk = $churnText.IndexOf("`n")
    $body = if ($brk -ge 0) { $churnText.Substring($brk + 1) } else { $churnText }
    $caRows = @($body | ConvertFrom-Csv)
    if ($caRows.Count -lt 1) { throw "0 CSV rows after header" }
    # Build a normalized-header -> actual-property-name map once, then read by
    # candidate names (mirrors the gviz Find-Col approach).
    $caMap = @{}
    $caRows[0].PSObject.Properties | ForEach-Object { $caMap[(Norm-Lbl $_.Name)] = $_.Name }
    function CaCol($rec, $names) {
        foreach ($n in @($names)) { $k = Norm-Lbl $n; if ($caMap.ContainsKey($k)) { return [string]$rec.($caMap[$k]) } }
        return ''
    }
    $caRecs = New-Object System.Collections.Generic.List[string]
    foreach ($r in $caRows) {
        $eid = (CaCol $r @('New Enterprise ID','Enterprise ID','EnterpriseID')).Trim()
        if (-not $eid) { continue }
        if ($eid -match 'Do not shift') { continue }
        $monRaw = (CaCol $r @('Churn/Contraction Month','Churn Contraction Month','Churn Month')).Trim()
        $mon = ''
        if ($monRaw -match '^(\d{4})-(\d{2})') { $mon = "$($matches[1])-$($matches[2])" }
        elseif ($monRaw) { try { $mon = ([datetime]$monRaw).ToString('yyyy-MM') } catch { $mon = '' } }
        $rsnRaw = (CaCol $r @('Reason')).Trim()
        $rgrRaw = (CaCol $r @('Regretable/ Unregretable','Regrettable/Unregrettable','Regretable Unregretable')).Trim()
        $parts = @(
            '"eid":'  + (JsEscape $eid),
            '"cust":' + (JsEscape (CaCol $r @('Customer'))),
            '"seg":'  + (JsEscape (CaCol $r @('Customer Segment','Segment'))),
            '"arr":'  + ([string][double](Parse-Money (CaCol $r @('ARR')))),
            '"mon":'  + (JsEscape $mon),
            '"prod":' + (JsEscape (CaCol $r @('Product'))),
            '"reg":'  + (JsEscape (CaCol $r @('Region'))),
            '"csm":'  + (JsEscape (Csm-Display (CaCol $r @('CSM Name','CSM')))),
            '"cat":'  + (JsEscape (CaCol $r @('Category'))),
            '"rsn":'  + (JsEscape $(if ($rsnRaw) { $rsnRaw } else { 'Not Tagged' })),
            '"rgr":'  + (JsEscape $(if ($rgrRaw) { $rgrRaw } else { 'Untagged' })),
            '"appr":' + (JsEscape (CaCol $r @('Leader Approved'))),
            '"bill":' + (JsEscape (CaCol $r @('Billing Status')))
        )
        # [string[]] cast forces a deterministic comma join (see history: an
        # untyped -join intermittently used $OFS space → invalid JS).
        $caRecs.Add('{' + [string]::Join(',', [string[]]$parts) + '}')
    }
    if ($caRecs.Count -gt 0) {
        $churnJson = '[' + ($caRecs -join ',') + ']'
        Write-Host "  churn_analysis: $($caRecs.Count) records (CSV gid=1421999984)"
    } else {
        Write-Host "  churn_analysis: WARNING — 0 records parsed; preserving existing block."
    }
} catch {
    Write-Host "  churn_analysis: WARNING — fetch failed ($_). Preserving existing block."
}
if ($churnJson) {
    $caIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'window\.__CHURN_ANALYSIS__\s*=') { $caIdx = $i; break }
    }
    if ($caIdx -ge 0) {
        # Emit the churn array as a JS *string* that the page JSON.parses inside a
        # try/catch, with a one-shot repair (whitespace-before-key -> comma) as a
        # fallback. Belt-and-suspenders: even if the serializer ever regresses to
        # space separators again, the browser self-heals instead of throwing a
        # SyntaxError that kills the whole script block (Churn tab + Vision).
        $churnLit = JsEscape $churnJson
        $lines[$caIdx] = 'window.__CHURN_ANALYSIS__ = (function(){var s=' + $churnLit + ';try{return JSON.parse(s)}catch(e){try{return JSON.parse(s.replace(/\s+("\w+":)/g,",$1"))}catch(_){return[]}}})();'
    } else {
        Write-Host "  churn_analysis: WARNING — __CHURN_ANALYSIS__ line not found; skipping splice."
    }
}

$prefix='window.__DASHBOARD_DATA__ = '
$lines[$dlIdx] = $prefix + $json + ';'

# Write to both files
foreach ($f in $dashFiles) {
    [System.IO.File]::WriteAllLines($f, $lines, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  wrote: $f"
}
Write-Host ""
Write-Host "=== Sync complete ==="
Write-Host "  v_rows in scope: $($vRowsScoped.Count) | vini_stage: $($viniStage.Count) | CSAT: $($byEid.Count) | vini_tix: $($viniTix.Count) | studio_tix: $($studioTix.Count) | s_rows: $($sRows.Count)"
