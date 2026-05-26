$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"
$sheetId = '1kdGwx6rxBy8MWKq8WyR04xq4QgWSfnh1W4nHsOqj_HE'
$urls = @{
    vini    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=1616842841&headers=2"
    payment = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=674556270"
    csat    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=701797891"
}

Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$jss.RecursionLimit = 200

function Fetch-Gviz($url) {
    Write-Output ("Fetching $url ...")
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop -TimeoutSec 60
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode)" }
    $txt = $resp.Content
    $start = $txt.IndexOf('{')
    $end = $txt.LastIndexOf('}')
    $payload = $jss.DeserializeObject($txt.Substring($start, $end - $start + 1))
    if ($payload.status -ne 'ok') { throw "gviz status: $($payload.status)" }
    Write-Output ("  cols=" + $payload.table.cols.Count + " rows=" + $payload.table.rows.Count)
    return $payload.table
}

# Tolerant column-label match: strip non-alphanumeric, lowercase
function Norm-Lbl($s) { return ($s -replace '[^a-zA-Z0-9]+', '').ToLower() }
function Find-Col($cols, $candidates) {
    foreach ($c in @($candidates)) {
        $want = Norm-Lbl $c
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $got = Norm-Lbl ($cols[$i].label + '')
            if ($got -eq $want) { return $i }
        }
    }
    # suffix fallback for things like "Payment T1" matching "T1"
    foreach ($c in @($candidates)) {
        $want = Norm-Lbl $c
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $got = Norm-Lbl ($cols[$i].label + '')
            if ($got.EndsWith($want) -and ($got.Length - $want.Length) -le 12) { return $i }
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

# =====================================================================
# 1) Vini daily (gid=1616842841) -> v_rows in dashboard v_schema order
# =====================================================================
$viniTab = Fetch-Gviz $urls.vini
$cols = $viniTab.cols
# Existing v_schema: day, agent, stage, rid, rn, eid, en, ct, cst, seg, csm, region,
# mrr, arr, rag, churn, t, q, a, cv, av, roi, rs, t1, t2, t3, ps, cr, op, ota, res, trag, red, mbr, cf
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
# Existing v_schema from current dashboard
$lines = [System.IO.File]::ReadAllLines($dashPath)
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
$dl = $lines[$dlIdx]
$jsonStr = $dl.Substring($dl.IndexOf('{')).TrimEnd(';').Trim()
$D = $jss.DeserializeObject($jsonStr)
$vSchema = $D.v_schema

$idx = @{}
foreach ($k in $vSchema) { $idx[$k] = Find-Col $cols $labelOf[$k] }
Write-Output "Vini column resolution:"
foreach ($k in $vSchema) { Write-Output ("  " + $k.PadRight(8) + " -> col idx " + $idx[$k]) }

$vRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $viniTab.rows) {
    $cells = $row.c
    $newRow = New-Object object[] $vSchema.Count
    for ($k = 0; $k -lt $vSchema.Count; $k++) {
        $field = $vSchema[$k]
        $i = $idx[$field]
        if ($i -lt 0) { $newRow[$k] = ''; continue }
        $cell = if ($cells -and $i -lt $cells.Count) { $cells[$i] } else { $null }
        if ($field -eq 'day') {
            $newRow[$k] = Gviz-Date $cell
        } else {
            $newRow[$k] = Gviz-Val $cell
        }
    }
    # CSM blank handling
    $csmIdx2 = [array]::IndexOf($vSchema, 'csm')
    $cv = [string]$newRow[$csmIdx2]
    if ([string]::IsNullOrWhiteSpace($cv) -or $cv.Trim().ToLower() -in 'csm not assigned','not assigned','unassigned','na','tbd') {
        $newRow[$csmIdx2] = 'Unassigned CSM'
    }
    $vRows.Add($newRow)
}
Write-Output ("v_rows built: " + $vRows.Count)

# =====================================================================
# 2) Payment (gid=674556270) -> vini_stage rows
# =====================================================================
$payTab = Fetch-Gviz $urls.payment
$pCols = $payTab.cols
$pi = @{
    eid   = Find-Col $pCols @('Enterprise ID')
    en    = Find-Col $pCols @('Account')
    rid   = Find-Col $pCols @('Team ID')
    rn    = Find-Col $pCols @('Rooftop Name')
    agent = Find-Col $pCols @('Agent Opted')
    mrr   = Find-Col $pCols @('MRR')
    arr   = Find-Col $pCols @('ARR')
    stage = Find-Col $pCols @('Stage')
    t1    = Find-Col $pCols @('Payment T1','T1')
    t2    = Find-Col $pCols @('Payment T2','T2')
    t3    = Find-Col $pCols @('Payment T3','T3')
    ps    = Find-Col $pCols @('Payment Score')
}
Write-Output "Payment column resolution:"
foreach ($k in $pi.Keys) { Write-Output ("  " + $k.PadRight(6) + " -> col idx " + $pi[$k]) }

# CSM / region / seg per (rid,agent) -- look up from FRESH v_rows (gviz)
$ridIdxV = [array]::IndexOf($vSchema, 'rid')
$agentIdxV = [array]::IndexOf($vSchema, 'agent')
$csmIdxV = [array]::IndexOf($vSchema, 'csm')
$regionIdxV = [array]::IndexOf($vSchema, 'region')
$segIdxV = [array]::IndexOf($vSchema, 'seg')
$dayIdxV = [array]::IndexOf($vSchema, 'day')
$enIdxV = [array]::IndexOf($vSchema, 'en')
$ctIdxV = [array]::IndexOf($vSchema, 'ct')

$metaByRidAgent = @{}; $metaByRid = @{}; $metaByEn = @{}
foreach ($r in $vRows) {
    $rid = [string]$r[$ridIdxV]; if (-not $rid) { continue }
    $agent = [string]$r[$agentIdxV]
    $day = [string]$r[$dayIdxV]
    $csm = [string]$r[$csmIdxV]; $region = [string]$r[$regionIdxV]; $seg = [string]$r[$segIdxV]
    $en = [string]$r[$enIdxV]; $ct = [string]$r[$ctIdxV]
    $key = $rid + '|' + $agent
    if (-not $metaByRidAgent.ContainsKey($key) -or $metaByRidAgent[$key].day -lt $day) {
        $metaByRidAgent[$key] = @{ csm=$csm; region=$region; seg=$seg; day=$day; ct=$ct }
    }
    if (-not $metaByRid.ContainsKey($rid) -or $metaByRid[$rid].day -lt $day) {
        $metaByRid[$rid] = @{ csm=$csm; region=$region; seg=$seg; day=$day; ct=$ct }
    }
    if ($en -and (-not $metaByEn.ContainsKey($en) -or $metaByEn[$en].day -lt $day)) {
        $metaByEn[$en] = @{ csm=$csm; region=$region; seg=$seg; day=$day }
    }
}
Write-Output ("Meta keys: byRidAgent=" + $metaByRidAgent.Count + " byRid=" + $metaByRid.Count + " byEn=" + $metaByEn.Count)

$manualSeg = @{
    'c68580ae5' = 'SMB'; '9bc114fc6' = 'SMB'; '9d4468871' = 'SMB'; '82255fce5' = 'Ent'
}

function Parse-Money($v) {
    if ($null -eq $v -or $v -eq '') { return 0 }
    $c = ([string]$v -replace '[\$,]', '').Trim()
    try { return [double]$c } catch { return 0 }
}

$viniStage = New-Object System.Collections.Generic.List[object]
$payEids = New-Object System.Collections.Generic.HashSet[string]
foreach ($row in $payTab.rows) {
    $c = $row.c
    if (-not $c) { continue }
    $eid = [string](Gviz-Val $c[$pi.eid])
    $rid = [string](Gviz-Val $c[$pi.rid])
    if (-not $eid -or -not $rid) { continue }
    [void]$payEids.Add($eid)
    $agent = [string](Gviz-Val $c[$pi.agent])
    $meta = $metaByRidAgent[$rid + '|' + $agent]
    if (-not $meta) { $meta = $metaByRid[$rid] }
    $en = [string](Gviz-Val $c[$pi.en])
    if (-not $meta -and $en -and $metaByEn.ContainsKey($en)) { $meta = $metaByEn[$en] }
    $csm = if ($meta) { $meta.csm } else { '' }
    if ([string]::IsNullOrWhiteSpace($csm) -or $csm.Trim().ToLower() -in 'csm not assigned','not assigned','unassigned','na','tbd') {
        $csm = 'Unassigned CSM'
    }
    $region = if ($meta -and $meta.region) { $meta.region } else { 'AMER' }
    $seg = if ($meta -and $meta.seg -and $meta.seg -ne 'Other') { $meta.seg } else { '' }
    if (-not $seg -and $manualSeg.ContainsKey($eid)) { $seg = $manualSeg[$eid] }
    if (-not $seg -and $meta -and $meta.ct) {
        if ($meta.ct -eq 'GROUP_DEALER') { $seg = 'Ent' }
        elseif ($meta.ct -eq 'INDIVIDUAL_DEALER') { $seg = 'SMB' }
    }
    if (-not $seg) { $seg = 'Other' }

    $rec = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $rec['rid'] = $rid
    $rec['en']  = $en
    $rec['rn']  = [string](Gviz-Val $c[$pi.rn])
    $rec['eid'] = $eid
    $rec['mrr'] = Parse-Money (Gviz-Val $c[$pi.mrr])
    $rec['arr'] = Parse-Money (Gviz-Val $c[$pi.arr])
    $rec['stage'] = [string](Gviz-Val $c[$pi.stage])
    $rec['agent'] = $agent
    $rec['t1'] = [string](Gviz-Val $c[$pi.t1])
    $rec['t2'] = [string](Gviz-Val $c[$pi.t2])
    $rec['t3'] = [string](Gviz-Val $c[$pi.t3])
    $rec['ps'] = [string](Gviz-Val $c[$pi.ps])
    $rec['csm'] = $csm
    $rec['region'] = $region
    $rec['seg'] = $seg
    [void]$viniStage.Add($rec)
}
Write-Output ("vini_stage rows: " + $viniStage.Count + " | enterprises: " + $payEids.Count)

# Filter v_rows to payment scope
$eidIdxV = [array]::IndexOf($vSchema, 'eid')
$vRowsScoped = New-Object System.Collections.Generic.List[object]
foreach ($r in $vRows) {
    if ($payEids.Contains([string]$r[$eidIdxV])) { [void]$vRowsScoped.Add($r) }
}
Write-Output ("v_rows in Payment scope: " + $vRowsScoped.Count + " (dropped " + ($vRows.Count - $vRowsScoped.Count) + ")")

# =====================================================================
# 3) CSAT (gid=701797891) -> by_eid / by_name / all_by_eid
# =====================================================================
$csatTab = Fetch-Gviz $urls.csat
$cCols = $csatTab.cols
$ci = @{
    date = Find-Col $cCols @('date')
    en   = Find-Col $cCols @('company_name')
    eid  = Find-Col $cCols @('company_external_id')
    csm  = Find-Col $cCols @('csm_name')
    avg  = Find-Col $cCols @('Comm Avg.')
}
$byEid = @{}; $byName = @{}; $allByEid = @{}
foreach ($row in $csatTab.rows) {
    $c = $row.c
    if (-not $c) { continue }
    $eid = [string](Gviz-Val $c[$ci.eid]).Trim()
    $name = [string](Gviz-Val $c[$ci.en]).Trim()
    $iso = Gviz-Date $c[$ci.date]
    $rawAvg = Gviz-Val $c[$ci.avg]
    $avg = $null
    if ($rawAvg -ne '' -and $null -ne $rawAvg) {
        try { $avg = [double]$rawAvg } catch { $avg = $null }
    }
    $rag = 'NA'
    if ($null -ne $avg) {
        if ($avg -lt 2.5) { $rag = 'Red' }
        elseif ($avg -lt 4) { $rag = 'Amber' }
        else { $rag = 'Green' }
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
Write-Output ("CSAT: " + $byEid.Count + " enterprises (eid) | " + $byName.Count + " (name)")

# =====================================================================
# 4) Build JSON manually (avoids serializer quirks with PSObject types)
# =====================================================================
function JsEscape($s) {
    if ($null -eq $s) { return 'null' }
    $t = [string]$s
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $t.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '"' { [void]$sb.Append('\"') }
            "`r" { [void]$sb.Append('\r') }
            "`n" { [void]$sb.Append('\n') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int]$ch
                if ($code -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function JsNum($v) {
    if ($null -eq $v -or $v -eq '') { return 'null' }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    try { return [string]([double]$v) } catch { return (JsEscape $v) }
}

# v_rows: array of arrays (positional)
function RowToJsArr($r) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($cell in $r) {
        if ($null -eq $cell) { $parts.Add('""') }
        elseif ($cell -is [string]) { $parts.Add((JsEscape $cell)) }
        elseif ($cell -is [int] -or $cell -is [long] -or $cell -is [double] -or $cell -is [float] -or $cell -is [decimal]) {
            $parts.Add([string]$cell)
        } elseif ($cell -is [bool]) {
            $parts.Add($(if ($cell) {'true'} else {'false'}))
        } else {
            $parts.Add((JsEscape ([string]$cell)))
        }
    }
    return '[' + ($parts -join ',') + ']'
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('[')
for ($i = 0; $i -lt $vRowsScoped.Count; $i++) {
    if ($i -gt 0) { [void]$sb.Append(',') }
    [void]$sb.Append((RowToJsArr $vRowsScoped[$i]))
}
[void]$sb.Append(']')
$jsonVRows = $sb.ToString()
Write-Output ("v_rows JSON length: " + $jsonVRows.Length)

# vini_stage: array of objects
$sb2 = New-Object System.Text.StringBuilder
[void]$sb2.Append('[')
for ($i = 0; $i -lt $viniStage.Count; $i++) {
    if ($i -gt 0) { [void]$sb2.Append(',') }
    $rec = $viniStage[$i]
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'rid','en','rn','eid','stage','agent','t1','t2','t3','ps','csm','region','seg') {
        $parts.Add((JsEscape $k) + ':' + (JsEscape $rec[$k]))
    }
    foreach ($k in 'mrr','arr') {
        $parts.Add((JsEscape $k) + ':' + (JsNum $rec[$k]))
    }
    [void]$sb2.Append('{' + ($parts -join ',') + '}')
}
[void]$sb2.Append(']')
$jsonStage = $sb2.ToString()
Write-Output ("vini_stage JSON length: " + $jsonStage.Length)

# CSAT dicts
function CsatRecToJson($rec) {
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((JsEscape 'date_iso') + ':' + (JsEscape $rec.date_iso))
    $parts.Add((JsEscape 'avg') + ':' + (JsNum $rec.avg))
    $parts.Add((JsEscape 'name') + ':' + (JsEscape $rec.name))
    return '{' + ($parts -join ',') + '}'
}
function CsatDictToJson($dict) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) { $parts.Add((JsEscape $k) + ':' + (CsatRecToJson $dict[$k])) }
    return '{' + ($parts -join ',') + '}'
}
function CsatAllToJson($dict) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $dict[$k]) {
            $items.Add('{"date_iso":' + (JsEscape $r.date_iso) + ',"avg":' + (JsNum $r.avg) + ',"rag":' + (JsEscape $r.rag) + '}')
        }
        $parts.Add((JsEscape $k) + ':[' + ($items -join ',') + ']')
    }
    return '{' + ($parts -join ',') + '}'
}

$jsonCsatEid = CsatDictToJson $byEid
$jsonCsatName = CsatDictToJson $byName
$jsonCsatAll  = CsatAllToJson $allByEid

# =====================================================================
# 5) Splice into existing dashboard JSON
# =====================================================================
$origJson = $dl.Substring($dl.IndexOf('{')).TrimEnd(';').Trim()

function StripKey($s, $key) {
    $marker = '"' + $key + '":'
    $start = $s.IndexOf($marker)
    if ($start -lt 0) { return $s }
    $i = $start + $marker.Length
    while ($i -lt $s.Length -and $s[$i] -in ' ',"`t","`r","`n") { $i++ }
    if ($i -ge $s.Length) { return $s }
    $open = $s[$i]
    if ($open -eq '{' -or $open -eq '[') {
        $close = if ($open -eq '{') { '}' } else { ']' }
        $depth = 0
        $inStr = $false
        $esc = $false
        $end = -1
        for ($j = $i; $j -lt $s.Length; $j++) {
            $ch = $s[$j]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq '"') { $inStr = $false }
            } else {
                if ($ch -eq '"') { $inStr = $true }
                elseif ($ch -eq $open) { $depth++ }
                elseif ($ch -eq $close) { $depth--; if ($depth -eq 0) { $end = $j; break } }
            }
        }
        if ($end -lt 0) { return $s }
    } else {
        # scalar value - find until , or }
        $end = $i
        while ($end -lt $s.Length -and $s[$end] -notin ',','}','`r','`n') { $end++ }
        $end--
    }
    $stripStart = $start
    if ($start -gt 0 -and $s[$start-1] -eq ',') { $stripStart = $start - 1 }
    elseif ($end + 1 -lt $s.Length -and $s[$end+1] -eq ',') { $end = $end + 1 }
    return $s.Substring(0, $stripStart) + $s.Substring($end + 1)
}

$json = $origJson
foreach ($k in 'v_rows','vini_stage','csat_by_eid','csat_by_name','csat_all_by_eid') {
    $json = StripKey $json $k
}
# Insert before final }
$lastBrace = $json.LastIndexOf('}')
$inserted = ',"v_rows":' + $jsonVRows +
            ',"vini_stage":' + $jsonStage +
            ',"csat_by_eid":' + $jsonCsatEid +
            ',"csat_by_name":' + $jsonCsatName +
            ',"csat_all_by_eid":' + $jsonCsatAll
$json = $json.Substring(0, $lastBrace) + $inserted + $json.Substring($lastBrace)

$prefix = 'window.__DASHBOARD_DATA__ = '
$lines[$dlIdx] = $prefix + $json + ';'
[System.IO.File]::WriteAllLines($dashPath, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Output ""
Write-Output ("=== PATCHED: " + $dashPath + " ===")
Write-Output ("Final JSON length: " + $json.Length)

# =====================================================================
# 6) QA — recent days, segment totals, ARR
# =====================================================================
$byDay = @{}
$iA = [array]::IndexOf($vSchema,'a')
$iQ = [array]::IndexOf($vSchema,'q')
$iT = [array]::IndexOf($vSchema,'t')
foreach ($r in $vRowsScoped) {
    $d = [string]$r[$dayIdxV]
    if (-not $byDay.ContainsKey($d)) { $byDay[$d] = @{rows=0;appts=0;q=0;t=0} }
    $byDay[$d].rows++
    $byDay[$d].appts   += Parse-Money $r[$iA]
    $byDay[$d].q       += Parse-Money $r[$iQ]
    $byDay[$d].t       += Parse-Money $r[$iT]
}
$recent = $byDay.Keys | Where-Object { $_ -ge '2026-05-22' } | Sort-Object
Write-Output ""
Write-Output "=== Recent days (>=2026-05-22) in v_rows ==="
foreach ($d in $recent) { $b = $byDay[$d]; Write-Output ("  $d : " + $b.rows + " rows | appts=" + $b.appts + " | qual=" + $b.q + " | touched=" + $b.t) }

# Segment breakdown
$segs = @{}; $tL=0; $tC=0; $totalArr = 0.0
foreach ($s in $viniStage) {
    $seg = [string]$s['seg']; $stg = [string]$s['stage']
    $totalArr += [double]$s['arr']
    if (-not $segs.ContainsKey($seg)) { $segs[$seg] = @{Live=0;Churned=0} }
    if ($stg -eq 'Live') { $segs[$seg].Live++; $tL++ }
    elseif ($stg -eq 'Churned') { $segs[$seg].Churned++; $tC++ }
}
Write-Output ""
Write-Output "=== vini_stage segment breakdown ==="
foreach ($k in ($segs.Keys|Sort-Object)) { $g=$segs[$k]; Write-Output ("  " + $k.PadRight(12) + " Live=" + $g.Live + "  Churned=" + $g.Churned) }
Write-Output ("  TOTAL        Live=" + $tL + "  Churned=" + $tC)
Write-Output ("Total Payment ARR: $" + ('{0:N0}' -f $totalArr))
