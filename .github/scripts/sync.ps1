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
    csat    = "https://docs.google.com/spreadsheets/d/$sheetId/gviz/tq?tqx=out:json&gid=701797891&headers=1"
}

Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$jss.RecursionLimit = 200

function Fetch-Gviz($url) {
    Write-Host "  fetch: $url"
    $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
    if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode) for $url" }
    $txt = $resp.Content
    $s = $txt.IndexOf('{'); $e = $txt.LastIndexOf('}')
    $p = $jss.DeserializeObject($txt.Substring($s, $e - $s + 1))
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

Write-Host "=== Fetching 3 tabs ==="
$viniTab = Fetch-Gviz $urls.vini
$payTab  = Fetch-Gviz $urls.payment
$csatTab = Fetch-Gviz $urls.csat
Write-Host "  vini rows=$($viniTab.rows.Count) | payment rows=$($payTab.rows.Count) | csat rows=$($csatTab.rows.Count)"

# --- Read existing dashboard JSON to learn the v_schema ---
$lines = [System.IO.File]::ReadAllLines($primary)
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
if ($dlIdx -lt 0) { throw "DASHBOARD_DATA line not found" }
$dl = $lines[$dlIdx]
$origJson = $dl.Substring($dl.IndexOf('{')).TrimEnd(';').Trim()
$D = $jss.DeserializeObject($origJson)
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
    [void]$viniStage.Add($rec)
}
Write-Host "  vini_stage rows: $($viniStage.Count) | enterprises: $($payEids.Count)"

# Filter v_rows to payment scope
$eidIdxV=[array]::IndexOf($vSchema,'eid')
$vRowsScoped = New-Object System.Collections.Generic.List[object]
foreach ($r in $vRows) { if ($payEids.Contains([string]$r[$eidIdxV])) { [void]$vRowsScoped.Add($r) } }
Write-Host "  v_rows in scope: $($vRowsScoped.Count)"

# --- Build CSAT dicts ---
$cCols=$csatTab.cols
$ci = @{
    date=Find-Col $cCols @('date'); en=Find-Col $cCols @('company_name')
    eid=Find-Col $cCols @('company_external_id'); csm=Find-Col $cCols @('csm_name')
    avg=Find-Col $cCols @('Comm Avg.')
}
$byEid=@{}; $byName=@{}; $allByEid=@{}
foreach ($row in $csatTab.rows) {
    $c=$row.c; if (-not $c) { continue }
    $eid=[string](Gviz-Val $c[$ci.eid]).Trim(); $name=[string](Gviz-Val $c[$ci.en]).Trim()
    $iso=Gviz-Date $c[$ci.date]
    $rawAvg=Gviz-Val $c[$ci.avg]
    $avg=$null
    if ($rawAvg -ne '' -and $null -ne $rawAvg) { try { $avg=[double]$rawAvg } catch { $avg=$null } }
    $rag='NA'
    if ($null -ne $avg) {
        if ($avg -lt 2.5) { $rag='Red' } elseif ($avg -lt 4) { $rag='Amber' } else { $rag='Green' }
    }
    $rec=@{date_iso=$iso;avg=$avg;name=$name}
    if ($eid) {
        if (-not $byEid.ContainsKey($eid) -or [string]$byEid[$eid].date_iso -lt $iso) { $byEid[$eid]=$rec }
        if (-not $allByEid.ContainsKey($eid)) { $allByEid[$eid]=New-Object System.Collections.Generic.List[hashtable] }
        $allByEid[$eid].Add(@{date_iso=$iso;avg=$avg;rag=$rag})
    }
    if ($name) {
        $k=$name.ToUpper()
        if (-not $byName.ContainsKey($k) -or [string]$byName[$k].date_iso -lt $iso) { $byName[$k]=$rec }
    }
}
Write-Host "  CSAT: $($byEid.Count) by_eid | $($byName.Count) by_name"

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
    if ($null -eq $v -or $v -eq '') { return 'null' }
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

$sb2=New-Object System.Text.StringBuilder
[void]$sb2.Append('[')
for ($i=0;$i -lt $viniStage.Count;$i++) {
    if ($i -gt 0) { [void]$sb2.Append(',') }
    $rec=$viniStage[$i]
    $parts=New-Object System.Collections.Generic.List[string]
    foreach ($k in 'rid','en','rn','eid','stage','agent','t1','t2','t3','ps','csm','region','seg') { $parts.Add((JsEscape $k) + ':' + (JsEscape $rec[$k])) }
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
foreach ($k in 'v_rows','vini_stage','csat_by_eid','csat_by_name','csat_all_by_eid') {
    $json=StripKey $json $k
}
$lastBrace=$json.LastIndexOf('}')
$inserted = ',"v_rows":' + $jsonVRows +
            ',"vini_stage":' + $jsonStage +
            ',"csat_by_eid":' + $jsonCsatEid +
            ',"csat_by_name":' + $jsonCsatName +
            ',"csat_all_by_eid":' + $jsonCsatAll
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
Write-Host "  v_rows in scope: $($vRowsScoped.Count) | vini_stage: $($viniStage.Count) | CSAT: $($byEid.Count)"
