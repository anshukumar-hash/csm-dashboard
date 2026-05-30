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
    # CSAT source: Metabase public-question CSV. The Google Sheets CSAT tab
    # (gid=701797891) is an IMPORTRANGE bridge that doesn't materialize for
    # anonymous gviz requests — Metabase is the source of truth.
    csat    = "https://metabase.arali.ai/public/question/8f665676-ab26-45bf-bbab-597b9fd6b723.csv"
}

# Use PowerShell Core's native ConvertFrom-Json (cross-platform, no .NET
# Framework assembly required). -AsHashtable returns nested hashtables so
# we get $obj['key'] semantics like JavaScriptSerializer used to give us.
function Parse-Json($s) { return $s | ConvertFrom-Json -AsHashtable -Depth 100 }

function Fetch-Gviz($url) {
    Write-Host "  fetch: $url"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $url" }
    $txt = $resp.Content
    $s = $txt.IndexOf('{'); $e = $txt.LastIndexOf('}')
    $p = Parse-Json $txt.Substring($s, $e - $s + 1)
    if ($p.status -ne 'ok') { throw "gviz status=$($p.status) for $url" }
    return $p.table
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

Write-Host "=== Fetching 5 data sources ==="
$viniTab   = Fetch-Gviz $urls.vini
$payTab    = Fetch-Gviz $urls.payment
$tixTab    = Fetch-Gviz $urls.tickets
$studioTab = Fetch-Gviz $urls.studio

# CSAT comes from Metabase (CSV), not gviz. See URL block above for why.
function Fetch-CsatCsv($url) {
    Write-Host "  fetch CSAT (Metabase CSV): $url"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 5
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $url" }
    return ($resp.Content | ConvertFrom-Csv)
}
$csatCsvRows = $null
try {
    $csatCsvRows = Fetch-CsatCsv $urls.csat
} catch {
    Write-Host "  CSAT: WARNING — Metabase fetch failed ($_). Will preserve existing snapshot."
    $csatCsvRows = $null
}
Write-Host "  vini rows=$($viniTab.rows.Count) | payment rows=$($payTab.rows.Count) | csat rows=$(if($csatCsvRows){$csatCsvRows.Count}else{'FAIL'}) | tickets rows=$($tixTab.rows.Count)"

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

$metaByRidAgent=@{}; $metaByRid=@{}; $metaByEn=@{}
foreach ($r in $vRows) {
    $rid=[string]$r[$ridIdxV]; if (-not $rid) { continue }
    $ag=[string]$r[$agentIdxV]; $day=[string]$r[$dayIdxV]
    $csm=[string]$r[$csmIdxV]; $region=[string]$r[$regionIdxV]; $seg=[string]$r[$segIdxV]
    $en=[string]$r[$enIdxV]; $ct=[string]$r[$ctIdxV]
    $key = $rid + '|' + $ag
    if (-not $metaByRidAgent.ContainsKey($key) -or $metaByRidAgent[$key].day -lt $day) {
        $metaByRidAgent[$key]=@{csm=$csm;region=$region;seg=$seg;day=$day;ct=$ct}
    }
    if (-not $metaByRid.ContainsKey($rid) -or $metaByRid[$rid].day -lt $day) {
        $metaByRid[$rid]=@{csm=$csm;region=$region;seg=$seg;day=$day;ct=$ct}
    }
    if ($en -and (-not $metaByEn.ContainsKey($en) -or $metaByEn[$en].day -lt $day)) {
        $metaByEn[$en]=@{csm=$csm;region=$region;seg=$seg;day=$day}
    }
}

$manualSeg = @{
    'c68580ae5'='SMB'; '9bc114fc6'='SMB'; '9d4468871'='SMB'; '82255fce5'='Ent'
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
    $rec['agent']=$agent; $rec['t1']=[string](Gviz-Val $c[$pi.t1])
    $rec['t2']=[string](Gviz-Val $c[$pi.t2]); $rec['t3']=[string](Gviz-Val $c[$pi.t3])
    $rec['ps']=[string](Gviz-Val $c[$pi.ps]); $rec['csm']=$csm
    $rec['region']=$region; $rec['seg']=$seg
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

# --- Build CSAT dicts from the Metabase CSV ---
# CSV schema:
#   date, company_name, company_external_id, csm_name,
#   meeting_csat, thread_csat, ticket_csat, call_csat
# Per-row Comm Avg = mean of the populated (non-blank) values among the 4
# CSAT component columns. Matches the prior Google Sheet's column I formula.
# RAG thresholds: avg<2.5 Red, <4 Amber, >=4 Green, no values → NA.
#
# If the Metabase fetch FAILED (network/auth/etc), we preserve the previously
# spliced CSAT dicts from $D so we don't wipe the dashboard JSON with empty
# data. Same protective pattern as the old Loading-state fallback.
if ($null -eq $csatCsvRows) {
    Write-Host "  CSAT: preserving existing snapshot (Metabase fetch failed)."
    $byEid=@{}; $byName=@{}; $allByEid=@{}
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
} else {
    $byEid=@{}; $byName=@{}; $allByEid=@{}
    foreach ($row in $csatCsvRows) {
        $eid  = if ($row.company_external_id) { ([string]$row.company_external_id).Trim() } else { '' }
        $name = if ($row.company_name)        { ([string]$row.company_name).Trim() }        else { '' }
        $iso  = if ($row.date) { [string]$row.date } else { '' }
        # Already YYYY-MM-DD from Metabase, but normalize just in case.
        if ($iso -and $iso -notmatch '^\d{4}-\d{2}-\d{2}') {
            try { $iso = ([DateTime]::Parse($iso)).ToString('yyyy-MM-dd') } catch { $iso = '' }
        }
        # Comm Avg = mean of the 4 components, ignoring blanks.
        $vals = @()
        foreach ($col in 'meeting_csat','thread_csat','ticket_csat','call_csat') {
            $v = $row.$col
            if ($null -ne $v -and "$v" -ne '') {
                try { $vals += [double]$v } catch { }
            }
        }
        $avg = $null
        if ($vals.Count -gt 0) {
            $sum = 0.0; foreach ($x in $vals) { $sum += $x }
            $avg = $sum / $vals.Count
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
            $k = $name.ToUpper()
            if (-not $byName.ContainsKey($k) -or [string]$byName[$k].date_iso -lt $iso) { $byName[$k] = $rec }
        }
    }
    Write-Host "  CSAT: $($byEid.Count) by_eid | $($byName.Count) by_name | $($allByEid.Count) all_by_eid"
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
    status  = Find-Col $tCols @('Status')
    created = Find-Col $tCols @('Created time','Created')
    resolved= Find-Col $tCols @('Resolved time','Resolved')
    closed  = Find-Col $tCols @('Closed time','Closed')
    resHrs  = Find-Col $tCols @('Resolution time (in hrs)','Resolution time')
    prod    = Find-Col $tCols @('Product (Studio/Vini)','Product')
    eid     = Find-Col $tCols @('Enterprise ID')
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
# (MTD / Last Month / L2L / custom) at render time. Pre-aggregating server-side
# was masking the user's expectation that "Avg Resolution = avg over tickets
# CREATED in the current period", not averaged across all-time history.
#
# Schema per row (compact field names to keep JSON size down):
#   c = created date (YYYY-MM-DD)
#   o = open bool (Status NOT IN Closed/Resolved)
#   r = resolution hrs (parsed from col G `[h]:mm:ss`; 0 for open)
#   a = ageing hrs at sync time (UtcNow - Created); 0 for non-open
$viniTix = @{}
$nowUtc = [DateTime]::UtcNow
$skipped = 0
$ticketsKept = 0
foreach ($row in $tixTab.rows) {
    $c = $row.c; if (-not $c) { $skipped++; continue }
    $prod = [string](Gviz-Val $c[$ti.prod])
    if ($prod -ne 'Vini') { $skipped++; continue }
    $eid = [string](Gviz-Val $c[$ti.eid]).Trim()
    if (-not $eid -or $eid -eq 'Not Required') { $skipped++; continue }
    if (-not $liveEids.Contains($eid)) { $skipped++; continue }

    $created = GvizToDate $c[$ti.created]
    if (-not $created) { $skipped++; continue }
    $createdIso = $created.ToString('yyyy-MM-dd')

    $status = ([string](Gviz-Val $c[$ti.status])).ToLower().Trim()
    $isOpen = ($status -ne 'closed' -and $status -ne 'resolved')

    $resHrs = 0.0; $ageHrs = 0.0
    if ($isOpen) {
        $ageHrs = ($nowUtc - $created).TotalHours
        if ($ageHrs -lt 0) { $ageHrs = 0.0 }
    } else {
        $parsed = ParseHrs $c[$ti.resHrs]
        if ($null -ne $parsed -and $parsed -gt 0) { $resHrs = $parsed }
    }

    if (-not $viniTix.ContainsKey($eid)) {
        $viniTix[$eid] = New-Object System.Collections.Generic.List[hashtable]
    }
    $viniTix[$eid].Add(@{ c = $createdIso; o = $isOpen; r = $resHrs; a = $ageHrs })
    $ticketsKept++
}
Write-Host "  vini_tix: $($viniTix.Count) live enterprises, $ticketsKept tickets kept, $skipped skipped"

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
# MRR/ARR are NOT in this sheet — per user spec we preserve them from the
# previously-spliced s_rows (matched by rid). New rooftops appear with mrr=0
# / arr=0 until the user provides an MRR/ARR source.
$sStudioSchema = @(
    'rid','rn','en',
    'mrr','arr',
    'av','cv','acv','lm_acv','uf',
    'pen','ws','ws_link','isc',
    'rs','t1','t2','t3','prag',
    'unr','cr','ota','res','trag',
    'red','mbr','cf','csm','ct','cst','seg','region'
)

# Build rid → {mrr, arr} lookup from the existing snapshot
$oldStudioMrrArr = @{}
if ($D.s_rows -and $D.s_schema) {
    $oldSch  = @($D.s_schema)
    $oldRid  = [array]::IndexOf($oldSch,'rid')
    $oldMrr  = [array]::IndexOf($oldSch,'mrr')
    $oldArr  = [array]::IndexOf($oldSch,'arr')
    if ($oldRid -ge 0 -and $oldMrr -ge 0 -and $oldArr -ge 0) {
        foreach ($r in $D.s_rows) {
            $rid = [string]$r[$oldRid]
            if ($rid) { $oldStudioMrrArr[$rid] = @{ mrr=$r[$oldMrr]; arr=$r[$oldArr] } }
        }
    }
}
Write-Host "  Studio: preserved MRR/ARR for $($oldStudioMrrArr.Count) existing rooftops"

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
    rs      = Find-Col $sCols @('RoI Report Sent (D/W/M)?','Report Sent','RoI Report Sent')
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

$sRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $studioTab.rows) {
    $c = $row.c; if (-not $c) { continue }
    $rid = [string](Gviz-Val $c[$si.rid])
    if (-not $rid) { continue }
    $mrr = 0; $arr = 0
    if ($oldStudioMrrArr.ContainsKey($rid)) {
        $mrr = $oldStudioMrrArr[$rid].mrr
        $arr = $oldStudioMrrArr[$rid].arr
    }

    $r = New-Object object[] $sStudioSchema.Count
    $idx = @{}; for ($i=0; $i -lt $sStudioSchema.Count; $i++) { $idx[$sStudioSchema[$i]] = $i }

    $r[$idx['rid']]     = $rid
    $r[$idx['rn']]      = [string](Gviz-Val $c[$si.rn])
    $r[$idx['en']]      = [string](Gviz-Val $c[$si.en])
    $r[$idx['mrr']]     = $mrr
    $r[$idx['arr']]     = $arr
    $r[$idx['av']]      = Gviz-Val $c[$si.av]
    $r[$idx['cv']]      = Gviz-Val $c[$si.cv]
    $r[$idx['acv']]     = Gviz-Val $c[$si.acv]
    $r[$idx['lm_acv']]  = if ($si.lm_acv -ge 0) { Gviz-Val $c[$si.lm_acv] } else { '' }
    $r[$idx['uf']]      = Gviz-Val $c[$si.uf]
    $r[$idx['pen']]     = Gviz-Val $c[$si.pen]
    $r[$idx['ws']]      = Gviz-Val $c[$si.ws]
    $r[$idx['ws_link']] = if ($si.ws_link -ge 0) { [string](Gviz-Val $c[$si.ws_link]) } else { '' }
    $r[$idx['isc']]     = Gviz-Val $c[$si.isc]
    $r[$idx['rs']]      = [string](Gviz-Val $c[$si.rs])
    $r[$idx['t1']]      = [string](Gviz-Val $c[$si.t1])
    $r[$idx['t2']]      = [string](Gviz-Val $c[$si.t2])
    $r[$idx['t3']]      = [string](Gviz-Val $c[$si.t3])
    $r[$idx['prag']]    = [string](Gviz-Val $c[$si.prag])
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
    $r[$idx['seg']]     = [string](Gviz-Val $c[$si.seg])
    $r[$idx['region']]  = [string](Gviz-Val $c[$si.region])

    $sRows.Add($r)
}
Write-Host "  Studio: built $($sRows.Count) s_rows (preserved MRR/ARR where match found)"

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
$jsonCsatAll=CsatAllToJson $allByEid

# vini_tix dict → JSON. Each entry is { rows: [{c,o,r,a}, ...] } where the
# dashboard then date-filters and aggregates client-side per active period.
function ViniTixToJson($dict) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $dict[$k]) {
            $oBool = if ($r.o) { 'true' } else { 'false' }
            $items.Add('{"c":' + (JsEscape $r.c) + ',"o":' + $oBool + ',"r":' + (JsNum $r.r) + ',"a":' + (JsNum $r.a) + '}')
        }
        $parts.Add((JsEscape $k) + ':{"rows":[' + ($items -join ',') + ']}')
    }
    return '{' + ($parts -join ',') + '}'
}
$jsonViniTix = ViniTixToJson $viniTix

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
foreach ($k in 'v_rows','vini_stage','csat_by_eid','csat_by_name','csat_all_by_eid','vini_tix','s_rows','s_schema') {
    $json=StripKey $json $k
}
$lastBrace=$json.LastIndexOf('}')
$inserted = ',"v_rows":' + $jsonVRows +
            ',"vini_stage":' + $jsonStage +
            ',"csat_by_eid":' + $jsonCsatEid +
            ',"csat_by_name":' + $jsonCsatName +
            ',"csat_all_by_eid":' + $jsonCsatAll +
            ',"vini_tix":' + $jsonViniTix +
            ',"s_rows":' + $jsonSRows +
            ',"s_schema":' + $jsonSSchema
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
Write-Host "  v_rows in scope: $($vRowsScoped.Count) | vini_stage: $($viniStage.Count) | CSAT: $($byEid.Count) | vini_tix: $($viniTix.Count) | s_rows: $($sRows.Count)"
