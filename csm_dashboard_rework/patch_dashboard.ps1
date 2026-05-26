$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"
$workDir  = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"
$backupPath = "$workDir\CSM_Dashboard.backup.html"

# Make a backup once
if (-not (Test-Path $backupPath)) {
    Copy-Item $dashPath $backupPath
    Write-Output ("Backup written: " + $backupPath)
} else {
    Write-Output "Backup already exists, not overwriting."
}

# ----- Load existing dashboard JSON -----
Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$jss.RecursionLimit = 100

$lines = [System.IO.File]::ReadAllLines($dashPath)
$prefix = "window.__DASHBOARD_DATA__ = "
# Find data line dynamically (line numbers shift as the file evolves)
$dataLineIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dataLineIdx = $i; break }
}
if ($dataLineIdx -lt 0) { throw "DASHBOARD_DATA line not found" }
$dataLine = $lines[$dataLineIdx]
$jsonStart = $dataLine.IndexOf("{")
if ($jsonStart -lt 0) { throw "JSON not found on data line" }
$jsonStr = $dataLine.Substring($jsonStart).TrimEnd(';').Trim()
Write-Output ("Existing JSON length: " + $jsonStr.Length)

$D = $jss.DeserializeObject($jsonStr)
$existingStage = if ($D.vini_stage -is [array]) { $D.vini_stage } else { $D.vini_stage.value }
$existingVRows = $D.v_rows
$vSchema = $D.v_schema
Write-Output ("Existing vini_stage rows: " + $existingStage.Count + " | v_rows: " + $existingVRows.Count)

# Build lookup: (rid|agent) -> existing-stage-row for CSM/region/seg enrichment
$existingByRidAgent = @{}
foreach ($s in $existingStage) {
    $key = ([string]$s['rid']) + '|' + ([string]$s['agent'])
    $existingByRidAgent[$key] = $s
}

# Also: rid -> first existing stage row (any agent) for fallback CSM
$existingByRid = @{}
foreach ($s in $existingStage) {
    $rid = [string]$s['rid']
    if (-not $existingByRid.ContainsKey($rid)) { $existingByRid[$rid] = $s }
}

# Backfill source for blank segments: most recent v_rows entry per (rid, agent).
# v_rows has a 'seg' column populated for every row (sourced from the daily
# Vini sheet's Customer Segment column).
$ridIdxV   = [array]::IndexOf($vSchema, 'rid')
$agentIdxV = [array]::IndexOf($vSchema, 'agent')
$segIdxV   = [array]::IndexOf($vSchema, 'seg')
$dayIdxV   = [array]::IndexOf($vSchema, 'day')
$ctIdxV    = [array]::IndexOf($vSchema, 'ct')
$cstIdxV   = [array]::IndexOf($vSchema, 'cst')
$enIdxV    = [array]::IndexOf($vSchema, 'en')
$segByRidAgent = @{}
$segByEn = @{}
$ctCstByRidAgent = @{}
if ($ridIdxV -ge 0 -and $segIdxV -ge 0) {
    foreach ($row in $existingVRows) {
        $rid = [string]$row[$ridIdxV]
        $agent = [string]$row[$agentIdxV]
        $seg = [string]$row[$segIdxV]
        $en  = [string]$row[$enIdxV]
        $day = [string]$row[$dayIdxV]
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        $k = $rid + '|' + $agent
        if (-not $segByRidAgent.ContainsKey($k) -or $segByRidAgent[$k].day -lt $day) {
            $segByRidAgent[$k] = @{ seg=$seg; day=$day; ct=[string]$row[$ctIdxV]; cst=[string]$row[$cstIdxV] }
            $ctCstByRidAgent[$k] = @{ ct=[string]$row[$ctIdxV]; cst=[string]$row[$cstIdxV] }
        }
        if ($en -and (-not $segByEn.ContainsKey($en) -or $segByEn[$en].day -lt $day)) {
            $segByEn[$en] = @{ seg=$seg; day=$day }
        }
    }
}

# ALSO seed from the fresh vini_1.tsv + vini_2.tsv extracts (the Drive MCP only
# returns ~85-95 most-recent rows, but those rows include the freshly-onboarded
# enterprises that the embedded snapshot doesn't have). This is what catches
# Next Gear Motors / PalmEasy / Dutch Miller / Toronto Honda → correct segment.
foreach ($freshTsv in @("$workDir\vini_1.tsv","$workDir\vini_2.tsv")) {
    if (-not (Test-Path $freshTsv)) { continue }
    $tl = [System.IO.File]::ReadAllLines($freshTsv)
    if ($tl.Count -lt 2) { continue }
    $th = $tl[0] -split "`t"
    $fRid = [array]::IndexOf($th, 'Rooftop ID')
    $fAgt = [array]::IndexOf($th, 'Agent Type')
    $fSeg = [array]::IndexOf($th, 'Customer Segment')
    $fEn  = [array]::IndexOf($th, 'Enterrpise Name')   # typo preserved in source
    if ($fEn -lt 0) { $fEn = [array]::IndexOf($th, 'Enterprise Name') }
    $fDay = [array]::IndexOf($th, 'Day')
    $fCt  = [array]::IndexOf($th, 'Customer Type')
    if ($fRid -lt 0 -or $fSeg -lt 0) { continue }
    for ($i = 1; $i -lt $tl.Count; $i++) {
        $c = $tl[$i] -split "`t"
        if ($c.Count -le $fSeg) { continue }
        $rid = $c[$fRid].Trim()
        $agent = if ($fAgt -ge 0) { $c[$fAgt].Trim() } else { '' }
        $seg = $c[$fSeg].Trim()
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        $en  = if ($fEn -ge 0 -and $c.Count -gt $fEn) { $c[$fEn].Trim() } else { '' }
        $day = if ($fDay -ge 0 -and $c.Count -gt $fDay) { $c[$fDay].Trim() } else { '' }
        $ct  = if ($fCt -ge 0 -and $c.Count -gt $fCt) { $c[$fCt].Trim() } else { '' }
        $k = $rid + '|' + $agent
        if (-not $segByRidAgent.ContainsKey($k) -or $segByRidAgent[$k].day -lt $day) {
            $segByRidAgent[$k] = @{ seg=$seg; day=$day; ct=$ct; cst='' }
            $ctCstByRidAgent[$k] = @{ ct=$ct; cst='' }
        }
        if ($en -and (-not $segByEn.ContainsKey($en) -or $segByEn[$en].day -lt $day)) {
            $segByEn[$en] = @{ seg=$seg; day=$day }
        }
    }
}
Write-Output ("Segment lookup built: " + $segByRidAgent.Count + " (rid,agent) keys, " + $segByEn.Count + " enterprise-name keys")

# ----- Load my Payment tab data -----
function Read-Tsv($path) {
    $tlines = [System.IO.File]::ReadAllLines($path)
    $hdr = $tlines[0] -split "`t"
    $rows = New-Object System.Collections.Generic.List[hashtable]
    for ($i = 1; $i -lt $tlines.Count; $i++) {
        $cells = $tlines[$i] -split "`t"
        $h = @{}
        for ($j = 0; $j -lt $hdr.Count; $j++) {
            $h[$hdr[$j]] = if ($j -lt $cells.Count) { $cells[$j] } else { '' }
        }
        $rows.Add($h)
    }
    return $rows
}
function To-Number($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    $clean = ($s -replace '[\$,]', '').Trim()
    try { return [double]$clean } catch { return 0 }
}

$payRows = Read-Tsv "$workDir\payment_1.tsv"
Write-Output ("Loaded payment rows: " + $payRows.Count)

# ----- Build new vini_stage from payment, enriched with CSM/region/seg from existing -----
$newStage = New-Object System.Collections.Generic.List[object]
$payEids = New-Object System.Collections.Generic.HashSet[string]
$unassignedStage = 0

foreach ($p in $payRows) {
    $eid = $p['Enterprise ID']
    $rid = $p['Team ID']
    if ([string]::IsNullOrWhiteSpace($eid) -or [string]::IsNullOrWhiteSpace($rid)) { continue }
    [void]$payEids.Add($eid)

    $agent = $p['Agent Opted']
    $key = $rid + '|' + $agent
    $existing = $existingByRidAgent[$key]
    if ($existing -eq $null) { $existing = $existingByRid[$rid] }

    $csm    = if ($existing -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$existing['csm']))    { [string]$existing['csm'] }    else { '' }
    $region = if ($existing -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$existing['region'])) { [string]$existing['region'] } else { 'AMER' }
    # Treat existing seg='Other' as "needs lookup" — that's the placeholder
    # value the previous run wrote when no real segment was available. On the
    # next run we want to re-try the lookup chain, not keep "Other" sticky.
    $seg = ''
    if ($existing -ne $null) {
        $existingSeg = [string]$existing['seg']
        if (-not [string]::IsNullOrWhiteSpace($existingSeg) -and $existingSeg -ne 'Other') {
            $seg = $existingSeg
        }
    }
    # Backfill segment from v_rows if still blank or "Other".
    if ([string]::IsNullOrWhiteSpace($seg)) {
        $vk = $rid + '|' + $agent
        if ($segByRidAgent.ContainsKey($vk)) { $seg = $segByRidAgent[$vk].seg }
        elseif ($segByEn.ContainsKey($p['Account'])) { $seg = $segByEn[$p['Account']].seg }
    }
    # Final fallback: classify by Customer Type if we have it
    if ([string]::IsNullOrWhiteSpace($seg)) {
        $vk = $rid + '|' + $agent
        if ($ctCstByRidAgent.ContainsKey($vk)) {
            $ct = $ctCstByRidAgent[$vk].ct
            if ($ct -eq 'GROUP_DEALER') { $seg = 'Ent' }
            elseif ($ct -eq 'INDIVIDUAL_DEALER') { $seg = 'SMB' }
            elseif ($ct -like '*Reseller*') { $seg = 'Resellers' }
        }
    }
    # Manual override for enterprises that have NO Vini daily rows in any
    # available source. Sourced from the user-confirmed segments in the
    # daily Vini sheet (gid=1616842841). Backfill the real Customer Segment
    # for these in CS_Vini_Stage to make this fallback unnecessary.
    if ([string]::IsNullOrWhiteSpace($seg)) {
        $manualSegByEid = @{
            'c68580ae5' = 'SMB'   # Next Gear Motors
            '9bc114fc6' = 'SMB'   # PalmEasy Motors PA LLC
            '9d4468871' = 'SMB'   # Dutch Miller Auto Group / Kia Charlotte
            '82255fce5' = 'Ent'   # Toronto Honda
        }
        if ($manualSegByEid.ContainsKey($eid)) { $seg = $manualSegByEid[$eid] }
    }
    # Last-resort: still no segment available anywhere.
    if ([string]::IsNullOrWhiteSpace($seg)) { $seg = 'Other' }

    # Normalize any placeholder CSM value to a single canonical label
    $csmLow = $csm.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($csm) -or
        $csmLow -eq 'csm not assigned' -or
        $csmLow -eq 'not assigned' -or
        $csmLow -eq 'unassigned' -or
        $csmLow -eq 'na' -or
        $csmLow -eq 'tbd') {
        $csm = 'Unassigned CSM'; $unassignedStage++
    }

    $row = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    $row['rid']    = $rid
    $row['en']     = $p['Account']
    $row['rn']     = $p['Rooftop Name']
    $row['eid']    = $eid
    $row['mrr']    = (To-Number $p['MRR'])
    $row['arr']    = (To-Number $p['ARR'])
    $row['stage']  = $p['Stage']
    $row['agent']  = $agent
    $row['t1']     = $p['T1']
    $row['t2']     = $p['T2']
    $row['t3']     = $p['T3']
    $row['ps']     = $p['Payment Score']
    $row['csm']    = $csm
    $row['region'] = $region
    $row['seg']    = $seg
    [void]$newStage.Add($row)
}
Write-Output ("New vini_stage rows: " + $newStage.Count + " | unique EIDs: " + $payEids.Count + " | Unassigned CSM filled: " + $unassignedStage)

# ----- Filter v_rows to Payment scope, fix CSM blanks -----
$eidIdx = [array]::IndexOf($vSchema, 'eid')
$csmIdx = [array]::IndexOf($vSchema, 'csm')
if ($eidIdx -lt 0 -or $csmIdx -lt 0) { throw "v_schema missing 'eid' or 'csm'" }

$newVRows = New-Object System.Collections.Generic.List[object]
$droppedVRows = 0
$unassignedV = 0
foreach ($row in $existingVRows) {
    $eid = [string]$row[$eidIdx]
    if (-not $payEids.Contains($eid)) { $droppedVRows++; continue }
    $newRow = @($row)  # shallow copy
    $cv = [string]$newRow[$csmIdx]
    $cvLow = $cv.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($cv) -or
        $cvLow -eq 'csm not assigned' -or
        $cvLow -eq 'not assigned' -or
        $cvLow -eq 'unassigned' -or
        $cvLow -eq 'na' -or
        $cvLow -eq 'tbd') {
        $newRow[$csmIdx] = 'Unassigned CSM'
        $unassignedV++
    }
    [void]$newVRows.Add($newRow)
}
Write-Output ("v_rows kept: " + $newVRows.Count + " | dropped (not in Payment scope): " + $droppedVRows + " | Unassigned CSM filled: " + $unassignedV)

# ----- MERGE fresh rows from vini_1.tsv + vini_2.tsv into v_rows -----
# The embedded snapshot maxes out at ~22 May; the fresh Drive MCP pull contains
# 23-25 May rows. Without this merge those days show 0 in the dashboard when the
# browser-side gviz fetch fails (e.g. sheet permission flips, no network).
# Dedup key: (day|rid|agent). Day formats are normalized to ISO YYYY-MM-DD.
function Norm-Day($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    try {
        $d = [datetime]::ParseExact($s.Trim(), 'd MMM, yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
        return $d.ToString('yyyy-MM-dd')
    } catch {
        # Already ISO?
        if ($s -match '^\d{4}-\d{2}-\d{2}') { return $s }
        return $s
    }
}
function Parse-Money($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    $c = ($s -replace '[\$,]', '').Trim()
    try { return [double]$c } catch { return 0 }
}
function Parse-Pct($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    $c = ($s -replace '%', '').Trim()
    try { return [double]$c / 100 } catch { return 0 }
}
# Build existing day|rid|agent set to avoid dup-inserts
$existingKeys = New-Object System.Collections.Generic.HashSet[string]
$ridIdx2 = [array]::IndexOf($vSchema, 'rid')
$agentIdx2 = [array]::IndexOf($vSchema, 'agent')
$dayIdx2 = [array]::IndexOf($vSchema, 'day')
foreach ($row in $newVRows) {
    $k = ([string]$row[$dayIdx2]) + '|' + ([string]$row[$ridIdx2]) + '|' + ([string]$row[$agentIdx2])
    [void]$existingKeys.Add($k)
}
$addedFresh = 0
foreach ($freshTsv in @("$workDir\vini_1.tsv","$workDir\vini_2.tsv")) {
    if (-not (Test-Path $freshTsv)) { continue }
    $tl = [System.IO.File]::ReadAllLines($freshTsv)
    if ($tl.Count -lt 2) { continue }
    $th = $tl[0] -split "`t"
    # Build sheet-col -> vSchema-key map (only fields the sheet has)
    $sheetIdx = @{}
    $colMap = @{
        'Day'='day'; 'Agent Type'='agent'; 'Rooftop ID'='rid'; 'Rooftop Name'='rn'
        'Enterprise ID'='eid'; 'Enterrpise Name'='en'; 'Customer Type'='ct'
        'Customer Subtype'='cst'; 'Customer Segment'='seg'; 'CSM Name'='csm'
        'Region'='region'; 'Stage'='stage'
        'Final Status/RAG'='rag'; 'Final Status/Churned'='churn'
        'Usage/# Touched'='t'; 'Usage/# Qualified'='q'; 'Usage/# Appt Booked'='a'
        'Usage/Conv Rate'='cv'
        'RoI?/Appt Value ($)'='av'; 'RoI?/RoI (Factor)'='roi'; 'RoI?/Report Sent (D/W/M)?'='rs'
        'Tickets/# Created'='cr'; 'Tickets/# Open'='op'
        'Tickets/Open Ticket Ageing (Hrs)'='ota'; 'Tickets/Avg Resolution hrs'='res'
        'Tickets/Ticket RAG'='trag'
        'Communication/RAG'='red'
        'Leadership Connect/MBR'='mbr'; 'Leadership Connect/Contact Freq'='cf'
    }
    # also accept the slash-less variants from the 26-col tab
    $altLabels = @{
        'RAG'='rag'; 'Churned'='churn'
        '# Touched'='t'; '# Qualified'='q'; '# Appt Booked'='a'; 'Conv Rate'='cv'
        'Appt Value ($)'='av'; 'RoI (Factor)'='roi'; 'Report Sent (D/W/M)?'='rs'
        '# Created'='cr'; '# Open'='op'
        'Open Ticket Ageing (Hrs)'='ota'; 'Avg Resolution hrs'='res'; 'Ticket RAG'='trag'
    }
    for ($j = 0; $j -lt $th.Count; $j++) {
        $lbl = $th[$j].Trim()
        if ($colMap.ContainsKey($lbl)) { $sheetIdx[$colMap[$lbl]] = $j }
        elseif ($altLabels.ContainsKey($lbl)) { $sheetIdx[$altLabels[$lbl]] = $j }
    }
    # For each row, build new vRow in v_schema order
    for ($i = 1; $i -lt $tl.Count; $i++) {
        $c = $tl[$i] -split "`t"
        $isoDay = ''
        if ($sheetIdx.ContainsKey('day') -and $c.Count -gt $sheetIdx['day']) {
            $isoDay = Norm-Day $c[$sheetIdx['day']]
        }
        $rid = if ($sheetIdx.ContainsKey('rid') -and $c.Count -gt $sheetIdx['rid']) { $c[$sheetIdx['rid']].Trim() } else { '' }
        $agt = if ($sheetIdx.ContainsKey('agent') -and $c.Count -gt $sheetIdx['agent']) { $c[$sheetIdx['agent']].Trim() } else { '' }
        $eidFresh = if ($sheetIdx.ContainsKey('eid') -and $c.Count -gt $sheetIdx['eid']) { $c[$sheetIdx['eid']].Trim() } else { '' }
        if (-not $payEids.Contains($eidFresh)) { continue }   # respect Payment scope
        $key = $isoDay + '|' + $rid + '|' + $agt
        if ($existingKeys.Contains($key)) { continue }
        [void]$existingKeys.Add($key)
        # Build row in v_schema order
        $newRow = New-Object object[] $vSchema.Count
        for ($k = 0; $k -lt $vSchema.Count; $k++) {
            $field = $vSchema[$k]
            $val = ''
            if ($sheetIdx.ContainsKey($field) -and $c.Count -gt $sheetIdx[$field]) {
                $val = $c[$sheetIdx[$field]].Trim()
            }
            if ($field -eq 'day')  { $val = $isoDay }
            elseif ($field -in 't','q','a','op','cr')    { $val = Parse-Money $val }
            elseif ($field -eq 'cv')                     { $val = Parse-Pct $val }
            elseif ($field -in 'av','roi')               { $val = Parse-Money $val }
            elseif ([string]::IsNullOrWhiteSpace($val) -and $field -eq 'csm') { $val = 'Unassigned CSM' }
            $newRow[$k] = $val
        }
        [void]$newVRows.Add($newRow)
        $addedFresh++
    }
}
Write-Output ("Fresh rows merged from vini_1/vini_2: " + $addedFresh)

# ----- Replace in D -----
# Rebuild D into a clean Dictionary so the serializer doesn't trip on PSObject methods.
$cleanD = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$cleanD['s_schema']  = $D['s_schema']
$cleanD['s_rows']    = $D['s_rows']
$cleanD['v_schema']  = $D['v_schema']
$cleanD['vs_schema'] = $D['vs_schema']
$cleanD['vs_rows']   = $D['vs_rows']
$cleanD['vini_tix']  = $D['vini_tix']
$cleanD['vini_stage'] = $newStage.ToArray()
$cleanD['v_rows']     = $newVRows.ToArray()

# ----- Serialize back to JSON -----
$newJson = $jss.Serialize($cleanD)
Write-Output ("New JSON length: " + $newJson.Length)

$lines[$dataLineIdx] = $prefix + $newJson + ';'
[System.IO.File]::WriteAllLines($dashPath, $lines, [System.Text.UTF8Encoding]::new($false))
Write-Output ("Patched: " + $dashPath)

# ----- QA -----
Write-Output ""
Write-Output "=== QA SUMMARY ==="
Write-Output ("Enterprises in Payment master scope : " + $payEids.Count)
Write-Output ("vini_stage rows (was 124)            : " + $newStage.Count)
Write-Output ("v_rows kept (was 4696)               : " + $newVRows.Count)
Write-Output ("CSM blanks filled in vini_stage      : " + $unassignedStage)
Write-Output ("CSM blanks filled in v_rows          : " + $unassignedV)

# ----- Spot check I-40 Auto -----
Write-Output ""
Write-Output "=== SPOT CHECK: I 40 Auto ==="
$i40Stage = $newStage | Where-Object { $_.eid -eq 'b7a9c31a8' }
foreach ($r in $i40Stage) {
    Write-Output ("  stage eid=" + $r.eid + " rid=" + $r.rid + " agent=" + $r.agent + " csm=" + $r.csm + " mrr=" + $r.mrr + " arr=" + $r.arr)
}
$i40V = $newVRows | Where-Object { [string]$_[$eidIdx] -eq 'b7a9c31a8' } | Select-Object -First 3
foreach ($r in $i40V) {
    Write-Output ("  v_row day=" + $r[0] + " agent=" + $r[1] + " csm=" + $r[$csmIdx] + " touched=" + $r[16])
}
