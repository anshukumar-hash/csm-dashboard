# Portable gviz sync — pulls all 3 tabs and rewrites the embedded
# window.__DASHBOARD_DATA__ in index.html. Runs on any PS7+ runner
# (Windows / Linux / macOS). Designed for GitHub Actions but works locally too.
#
# Reads/writes ./index.html and ./CSM_Dashboard.html relative to CWD.

$ErrorActionPreference = 'Stop'
$repoRoot = Get-Location
$dashFiles = @("$repoRoot/index.html", "$repoRoot/CSM_Dashboard.html")
$primary = $dashFiles[0]
if (-not (Test-Path $primary)) { throw "index.html not found at $primary" }

$sheetId = '1kdGwx6rxBy8MWKq8WyR04xq4QgWSfnh1W4nHsOqj_HE'
$urls = @{
    vini    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=1616842841&headers=2"
    payment = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=674556270"
    tickets = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=832733618"
    studio  = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=603796861"
    # CSAT source: gid=701797891 with column I "Comm Avg." pre-computed by the
    # user. The earlier IMPORTRANGE issue (which forced us to Metabase) appears
    # to be resolved — the tab now returns real data via gviz. We read the
    # pre-computed Comm Avg column directly so our display matches the sheet.
    csat    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=701797891&headers=1"
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
}

# Use PowerShell Core's native ConvertFrom-Json (cross-platform, no .NET
# Framework assembly required). -AsHashtable returns nested hashtables so
# we get $obj['key'] semantics like JavaScriptSerializer used to give us.
function Parse-Json($s) { return $s | ConvertFrom-Json -AsHashtable -Depth 100 }

function Fetch-Gviz($url, $expectedMinRows = 0) {
    # Retry on partial responses. gviz occasionally returns a tiny
    # subset of rows (seen 22 instead of 6497 on the payment-periods tab)
    # — caller can pass $expectedMinRows; if the response has fewer rows
    # than that, sleep + retry up to 3 times before giving up.
    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -eq 1) { Write-Host "  fetch: $url" }
        else { Write-Host "  retry $attempt`: $url" }
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
            if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $url" }
            $txt = $resp.Content
            $s = $txt.IndexOf('{'); $e = $txt.LastIndexOf('}')
            $p = Parse-Json $txt.Substring($s, $e - $s + 1)
            if ($p.status -ne 'ok') { throw "gviz status=$($p.status) for $url" }
            $rowCount = $p.table.rows.Count
            if ($expectedMinRows -gt 0 -and $rowCount -lt $expectedMinRows) {
                Write-Host ("    WARN got $rowCount rows; expected >= $expectedMinRows; retrying...")
                if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 4; continue }
                # On final attempt with low row count, surface a clear warning
                # but proceed so the rest of the snapshot still updates.
                Write-Host ("    WARN final attempt still short ($rowCount rows). Proceeding anyway.")
            }
            return $p.table
        } catch {
            Write-Host ("    WARN attempt $attempt failed: $_")
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Seconds 4
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
$tixTab         = Fetch-Gviz $urls.tickets    500    # tickets ~1500 typical
$studioTab      = Fetch-Gviz $urls.studio     1000   # studio rooftops ~1400 typical
$payPeriodsTab  = Fetch-Gviz $urls.payperiods 3000   # payment-periods ~6500 typical

# CSAT comes back from gid=701797891 (gviz) now that the IMPORTRANGE works.
# We still keep the "Loading..." sentinel detection from the original gviz
# path so the sync degrades gracefully if the formula stops resolving.
$csatTab = $null
try {
    $csatTab = Fetch-Gviz $urls.csat
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
Write-Host "  vini rows=$($viniTab.rows.Count) | payment rows=$($payTab.rows.Count) | csat rows=$(if($csatTab){$csatTab.rows.Count}else{'FAIL'}) | tickets rows=$($tixTab.rows.Count) | payperiods rows=$($payPeriodsTab.rows.Count)"

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
    # After the sent/draft filter, T-1/2/3 are paid or overdue (or blank).
    # Worst-wins: any overdue → Red, all paid → Green, nothing → blank.
    $list = @($t1, $t2, $t3) | Where-Object { $_ -and $_ -ne '' } | ForEach-Object { ([string]$_).ToLower() }
    if (-not $list -or $list.Count -eq 0) { return '' }
    if ($list -contains 'overdue') { return 'Red' }
    if (($list -contains 'sent') -or ($list -contains 'draft')) { return 'Amber' }
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
}
if ($ppI.eid   -lt 0) { $ppI.eid   = Find-ColById $ppCols 'V' }
if ($ppI.cs    -lt 0) { $ppI.cs    = Find-Col $ppCols @('customer_status','Customer Status') }
if ($ppI.start -lt 0) { $ppI.start = Find-ColById $ppCols 'Y' }
if ($ppI.end   -lt 0) { $ppI.end   = Find-ColById $ppCols 'Z' }
Write-Host ("  payperiods cols: eid={0} cs={1} start={2} end={3} (rows={4})" -f $ppI.eid, $ppI.cs, $ppI.start, $ppI.end, $payPeriodsTab.rows.Count)
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
    if (-not $payByEid.ContainsKey($eid)) {
        $payByEid[$eid] = New-Object System.Collections.Generic.List[object]
    }
    $payByEid[$eid].Add(@{ start=$st; end=$en; status=$cs })
}
$payRanks = @{}
foreach ($eid in $payByEid.Keys) {
    $rows = $payByEid[$eid]
    # Per latest user spec: EXCLUDE sent/draft entirely from the source
    # first, then dense-rank by (Service_period_Start_date,
    # Service_period_End_date) DESC per enterprise. Each unique (start,end)
    # tuple is one rank. SKIP rank 1 (the most-recent / in-flight closed
    # period the user wants ignored); take rank 2 → T-1, rank 3 → T-2,
    # rank 4 → T-3.
    #
    # Sparse cases render naturally:
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
    $rank = 0
    $prevKey = $null
    foreach ($pr in $sorted) {
        $key = "$($pr.start)|$($pr.end)"
        if ($key -ne $prevKey) { $rank++; $prevKey = $key }
        if ($rank -gt 4) { break }   # ranks 1-4 cover skip-1 + T-1/T-2/T-3
        if (-not $byRank.ContainsKey($rank)) {
            $byRank[$rank] = New-Object System.Collections.Generic.List[string]
        }
        $byRank[$rank].Add([string]$pr.status)
    }
    $payRanks[$eid] = @{
        # SKIP rank 1 (most recent / in-flight). T-1 = rank 2 onwards.
        t1 = if ($byRank.ContainsKey(2)) { Get-CanonicalPayStatus $byRank[2] } else { '' }
        t2 = if ($byRank.ContainsKey(3)) { Get-CanonicalPayStatus $byRank[3] } else { '' }
        t3 = if ($byRank.ContainsKey(4)) { Get-CanonicalPayStatus $byRank[4] } else { '' }
    }
}
Write-Host ("  payperiods: {0} enterprises ranked from {1} invoice rows" -f $payRanks.Count, $payPeriodsTab.rows.Count)

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

# --- Build CSAT dicts from gid=701797891 (gviz) ---
# Schema (with headers=1):
#   A Day | B Enterprise Name | C Enterprise ID | D CSM Name |
#   E meeting_csat | F thread_csat | G ticket_csat | H call_csat |
#   I Comm Avg.
#
# We read column I "Comm Avg." DIRECTLY rather than recomputing — the user
# maintains the formula in the sheet, so the dashboard's avg matches what
# they see in Sheets.
# RAG thresholds: avg<2.5 Red, <4 Amber, >=4 Green, blank → NA.
#
# If the gviz fetch FAILED OR returned the "Loading..." sentinel (the
# IMPORTRANGE state we hit before), we preserve the previously-spliced
# CSAT dicts from $D so we don't wipe the dashboard JSON.
$csatBroken = $false
if ($null -eq $csatTab) { $csatBroken = $true }
if (-not $csatBroken -and $csatTab.rows.Count -eq 0) { $csatBroken = $true }
if (-not $csatBroken) {
    # Check first row col A for the "Loading..." sentinel
    $firstCell = $csatTab.rows[0].c[0]
    $firstVal = if ($firstCell -and $firstCell.v) { [string]$firstCell.v } else { '' }
    if ($firstVal -match '^(?i)loading\.\.\.?$') { $csatBroken = $true }
}

if ($csatBroken) {
    Write-Host "  CSAT: WARNING — fetch empty or 'Loading...'. Preserving existing snapshot."
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
                $list.Add(@{ date_iso=[string]$r.date_iso; avg=$r.avg; rag=[string]$r.rag })
            }
            $allByEid[$k] = $list
        }
    }
    if ($D.csat_all_by_name) {
        foreach ($k in $D.csat_all_by_name.Keys) {
            $arr = $D.csat_all_by_name[$k]
            $list = New-Object System.Collections.Generic.List[hashtable]
            foreach ($r in $arr) {
                $list.Add(@{ date_iso=[string]$r.date_iso; avg=$r.avg; rag=[string]$r.rag })
            }
            $allByName[$k] = $list
        }
    }
    Write-Host "  CSAT: preserved $($byEid.Count) by_eid | $($byName.Count) by_name | $($allByEid.Count) all_by_eid | $($allByName.Count) all_by_name"
} else {
    $cCols = $csatTab.cols
    $ci = @{
        date = Find-Col $cCols @('Day','date','Date')
        en   = Find-Col $cCols @('Enterprise Name','company_name')
        eid  = Find-Col $cCols @('Enterprise ID','company_external_id')
        csm  = Find-Col $cCols @('CSM Name','csm_name')
        avg  = Find-Col $cCols @('Comm Avg.','Comm Avg','comm_avg')
    }
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
    foreach ($row in $csatTab.rows) {
        $c = $row.c; if (-not $c) { continue }
        $eid  = ([string](Gviz-Val $c[$ci.eid])).Trim()
        $name = ([string](Gviz-Val $c[$ci.en])).Trim()
        $iso  = Gviz-Date $c[$ci.date]
        $rawAvg = Gviz-Val $c[$ci.avg]
        $avg = $null
        if ($rawAvg -ne '' -and $null -ne $rawAvg) {
            try { $avg = [double]$rawAvg } catch { $avg = $null }
        }
        $rag = 'NA'
        if ($null -ne $avg) {
            if ($avg -lt 2.5) { $rag = 'Red' } elseif ($avg -lt 4) { $rag = 'Amber' } else { $rag = 'Green' }
        }
        $rec = @{ date_iso=$iso; avg=$avg; name=$name }
        if ($eid) {
            if (-not $byEid.ContainsKey($eid) -or [string]$byEid[$eid].date_iso -lt $iso) { $byEid[$eid] = $rec }
            if (-not $allByEid.ContainsKey($eid)) { $allByEid[$eid] = New-Object System.Collections.Generic.List[hashtable] }
            $allByEid[$eid].Add(@{ date_iso=$iso; avg=$avg; rag=$rag })
        }
        if ($name) {
            # by_name keyed UPPERCASE (latest-reading lookup, unchanged)
            $kUp = $name.ToUpper()
            if (-not $byName.ContainsKey($kUp) -or [string]$byName[$kUp].date_iso -lt $iso) { $byName[$kUp] = $rec }
            # all_by_name keyed NORMALIZED (for date-filtered name fallback)
            $kNorm = NormCsatName $name
            if ($kNorm) {
                if (-not $allByName.ContainsKey($kNorm)) { $allByName[$kNorm] = New-Object System.Collections.Generic.List[hashtable] }
                $allByName[$kNorm].Add(@{ date_iso=$iso; avg=$avg; rag=$rag })
            }
        }
    }
    Write-Host "  CSAT: $($byEid.Count) by_eid | $($byName.Count) by_name | $($allByEid.Count) all_by_eid | $($allByName.Count) all_by_name"
}

# --- Build vini_tix from Ticket_Dump (gid=832733618) ---
# Schema: Ticket ID | Status | Created time | Resolved time | Closed time |
#         Last update time | Resolution time (in hrs) | Enterprise Name |
#         Product (Studio/Vini) | Enterprise ID
#
# Per enterprise (filtered to Product=Vini AND eid is in the LIVE set):
#   cr  = total tickets   (count)
#   op  = open tickets    (Status NOT IN Closed/Resolved)
#   ota = avg ageing hrs  (now - Created) over open tickets
#   res = avg resolution  (col G in hrs) over resolved/closed tickets
$tCols = $tixTab.cols
$ti = @{
    status   = Find-Col $tCols @('Status')
    created  = Find-Col $tCols @('Created time','Created')
    resolved = Find-Col $tCols @('Resolved time','Resolved')
    closed   = Find-Col $tCols @('Closed time','Closed')
    resHrs   = Find-Col $tCols @('Resolution time (in hrs)','Resolution time')
    # Col I "Resolution status" — values 'Within SLA' / 'SLA Violated' / null.
    # User spec: count "SLA Violated" per enterprise and use it in the
    # ticket RAG. Surfaced on each per-ticket row as `s = $true` so the
    # dashboard can aggregate by date range at render time.
    resoStat = Find-Col $tCols @('Resolution status')
    prod     = Find-Col $tCols @('Product (Studio/Vini)','Product')
    eid      = Find-Col $tCols @('Enterprise ID')
    enName   = Find-Col $tCols @('Enterprise Name','Enterrpise Name','Account Name','Account')
}

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

# gviz encodes Date(y,mo,day,h,m,s) for created/resolved times. Parse to
# a real [DateTime] so we can compute ageing for open tickets.
function GvizToDate($cell) {
    if (-not $cell) { return $null }
    $v = $cell.v
    if ($null -eq $v) { return $null }
    $s = [string]$v
    if ($s -match '^Date\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)') {
        return [DateTime]::new(
            [int]$matches[1], [int]$matches[2] + 1, [int]$matches[3],
            [int]$matches[4], [int]$matches[5], [int]$matches[6])
    }
    if ($s -match '^Date\((\d+),(\d+),(\d+)') {
        return [DateTime]::new([int]$matches[1], [int]$matches[2] + 1, [int]$matches[3])
    }
    return $null
}
# The "Resolution time (in hrs)" cell is formatted as [h]:mm:ss. The `f` field
# carries the display string ("58:22:50" = 58.38 hrs); the `v` (Date encoding)
# is unreliable for durations >24h. So parse the formatted string.
function ParseHrs($cell) {
    if (-not $cell) { return $null }
    $f = [string]$cell.f
    if (-not $f) { return $null }
    if ($f -match '^(\d+):(\d+):(\d+)') {
        return [double]$matches[1] + [double]$matches[2] / 60.0 + [double]$matches[3] / 3600.0
    }
    return $null
}

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

# Single pass over the dump → dispatch by product, resolve EID via the
# master sets (eid first, then name fallback).
$viniTix = @{}; $studioTix = @{}
$nowUtc = [DateTime]::UtcNow
$kept = @{ vini=0; studio=0 }; $skipped = @{ vini=0; studio=0; other=0 }
foreach ($row in $tixTab.rows) {
    $c = $row.c; if (-not $c) { continue }
    $prod = [string](Gviz-Val $c[$ti.prod])
    if (-not $prod) { continue }
    $eidRaw = [string](Gviz-Val $c[$ti.eid]).Trim()
    $nameKey = NormName ([string](Gviz-Val $c[$ti.enName]))

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
    } elseif ($prod -eq 'Studio') {
        if ($eidRaw -and $eidRaw -ne 'Not Required' -and $studioEidSet.Contains($eidRaw)) {
            $resolvedEid = $eidRaw
        } elseif ($nameKey -and $studioNameToEid.ContainsKey($nameKey)) {
            $resolvedEid = $studioNameToEid[$nameKey]
        }
        if (-not $resolvedEid) { $skipped.studio++; continue }
        $targetDict = $studioTix
    } else {
        $skipped.other++; continue
    }

    $created = GvizToDate $c[$ti.created]
    if (-not $created) {
        if ($prod -eq 'Vini') { $skipped.vini++ } else { $skipped.studio++ }
        continue
    }
    $createdIso = $created.ToString('yyyy-MM-dd')

    $status = ([string](Gviz-Val $c[$ti.status])).ToLower().Trim()
    # User-spec "#Open" excludes BOTH the terminal states (Closed, Resolved)
    # AND the raw "Open" status — leaving the actively-in-flight tickets
    # (Pending / Waiting / On Hold) as the bucket. This is what we ship as
    # the per-row `o` flag; the dashboard aggregates it into the #Open count.
    $isOpen = ($status -ne 'closed' -and $status -ne 'resolved' -and $status -ne 'open')

    # SLA Violated flag (col I "Resolution status" = 'SLA Violated').
    $resoStatVal = if ($ti.resoStat -ge 0) {
        ([string](Gviz-Val $c[$ti.resoStat])).Trim().ToLower()
    } else { '' }
    $isSlaViolated = ($resoStatVal -eq 'sla violated')

    $resHrs = 0.0; $ageHrs = 0.0
    if ($isOpen) {
        $ageHrs = ($nowUtc - $created).TotalHours
        if ($ageHrs -lt 0) { $ageHrs = 0.0 }
    } else {
        $parsed = ParseHrs $c[$ti.resHrs]
        if ($null -ne $parsed -and $parsed -gt 0) { $resHrs = $parsed }
    }

    if (-not $targetDict.ContainsKey($resolvedEid)) {
        $targetDict[$resolvedEid] = New-Object System.Collections.Generic.List[hashtable]
    }
    $targetDict[$resolvedEid].Add(@{ c = $createdIso; o = $isOpen; r = $resHrs; a = $ageHrs; s = $isSlaViolated })
    if ($prod -eq 'Vini') { $kept.vini++ } else { $kept.studio++ }
}
Write-Host "  vini_tix:   $($viniTix.Count) enterprises, $($kept.vini) tickets kept, $($skipped.vini) skipped"
Write-Host "  studio_tix: $($studioTix.Count) enterprises, $($kept.studio) tickets kept, $($skipped.studio) skipped"

# --- Build Studio s_rows from gid=603796861 ---
# Schema columns in the new source (1 row per Studio rooftop):
#   A Enterprise ID | B Enterprise Name | C Rooftop ID | D Rooftop Name |
#   E account_type | F account_subtype | G Customer Segment | H CSM Name |
#   I Region | J Quality Website Score | K Website Link | L Pendency (6 hrs) |
#   M Inventory Score | N Active VINs | O #Last Month Actual VINs |
#   P #Actual MTD VINs | Q #Contracted VINs | R Usage Factor |
#   S RoI Report Sent | T Payment T1 | U T2 | V T3 | W Payment RAG |
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
$sStudioSchema = @(
    'rid','rn','en',
    'mrr','arr',
    'av','cv','acv','lm_acv','uf',
    'pen','ws','ws_link','isc',
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
    isc     = Find-Col $sCols @('Inventory Score')
    av      = Find-Col $sCols @('Usage Active Vins','Active Vins','Active VINs')
    lm_acv  = Find-Col $sCols @('# Last month Actual Vins','Last month Actual Vins')
    acv     = Find-Col $sCols @('# Actual MTD VINs','Actual MTD VINs','# Actual')
    cv      = Find-Col $sCols @('# Contracted VINs','Contracted VINs','# Contracted')
    uf      = Find-Col $sCols @('# VIN Usage Factor','VIN Usage Factor','Usage Factor')
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
    $avVal = Gviz-Val $c[$si.av]
    $r[$idx['av']]      = $avVal
    $r[$idx['acv']]     = Gviz-Val $c[$si.acv]
    # # Contracted VINs derived from Active VINs (per user spec: 2/3 of av,
    # col N), NOT from sheet column Q and NOT from # Actual MTD VINs.
    # Empty/zero av → cv stays 0.
    $avNum = 0.0
    try { $avNum = [double]$avVal } catch { $avNum = 0.0 }
    $r[$idx['cv']]      = if ($avNum -gt 0) { [Math]::Round($avNum * 2.0 / 3.0) } else { 0 }
    $r[$idx['lm_acv']]  = if ($si.lm_acv -ge 0) { Gviz-Val $c[$si.lm_acv] } else { '' }
    $r[$idx['uf']]      = Gviz-Val $c[$si.uf]
    $r[$idx['pen']]     = Gviz-Val $c[$si.pen]
    $r[$idx['ws']]      = Gviz-Val $c[$si.ws]
    $r[$idx['ws_link']] = if ($si.ws_link -ge 0) { [string](Gviz-Val $c[$si.ws_link]) } else { '' }
    $r[$idx['isc']]     = Gviz-Val $c[$si.isc]
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
        foreach ($r in $dict[$k]) { $items.Add('{"date_iso":' + (JsEscape $r.date_iso) + ',"avg":' + (JsNum $r.avg) + ',"rag":' + (JsEscape $r.rag) + '}') }
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
            # Per-row so the dashboard can date-range aggregate at render time.
            $sBool = if ($r.s) { 'true' } else { 'false' }
            $items.Add('{"c":' + (JsEscape $r.c) + ',"o":' + $oBool + ',"r":' + (JsNum $r.r) + ',"a":' + (JsNum $r.a) + ',"s":' + $sBool + '}')
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

$json=$origJson
foreach ($k in 'v_rows','vini_stage','csat_by_eid','csat_by_name','csat_all_by_eid','csat_all_by_name','vini_tix','studio_tix','s_rows','s_schema','report_coverage','report_tracking') {
    $json=StripKey $json $k
}
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
$json = $json.Substring(0,$lastBrace) + $inserted + $json.Substring($lastBrace)

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
