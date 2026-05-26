$ErrorActionPreference = 'Stop'
$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"

function Read-Tsv($path) {
    $lines = [System.IO.File]::ReadAllLines($path)
    $header = $lines[0] -split "`t"
    $rows = New-Object System.Collections.Generic.List[hashtable]
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $cells = $lines[$i] -split "`t"
        $h = @{}
        for ($j = 0; $j -lt $header.Count; $j++) {
            $val = if ($j -lt $cells.Count) { $cells[$j] } else { '' }
            $h[$header[$j]] = $val
        }
        $rows.Add($h)
    }
    return $rows
}

function To-Number($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0.0 }
    $clean = ($s -replace '[\$,%]', '').Trim()
    if ($clean -eq 'Infinity' -or $clean -eq 'NA' -or $clean -eq 'No' -or $clean -eq 'Yes' -or $clean -eq '') { return 0.0 }
    try { return [double]$clean } catch { return 0.0 }
}

function Parse-Day($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return [datetime]::MinValue }
    try {
        return [datetime]::ParseExact($s.Trim(), 'd MMM, yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        try { return [datetime]$s } catch { return [datetime]::MinValue }
    }
}

function RAG-Rank($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    switch ($s.Trim().ToLower()) {
        'red'    { return 4 }
        'amber'  { return 3 }
        'yellow' { return 3 }
        'orange' { return 3 }
        'green'  { return 2 }
        'na'     { return 1 }
        default  { return 0 }
    }
}
function Worst-RAG($values) {
    $best = ''; $rank = -1
    foreach ($v in $values) { $r = RAG-Rank $v; if ($r -gt $rank) { $rank = $r; $best = $v } }
    return $best
}

function Pay-Rank($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    switch ($s.Trim().ToLower()) {
        'overdue'             { return 3 }
        'no invoice raised'   { return 2 }
        'paid'                { return 1 }
        default               { return 0 }
    }
}
function Worst-Pay($values) {
    $best = ''; $rank = -1
    foreach ($v in $values) { $r = Pay-Rank $v; if ($r -gt $rank) { $rank = $r; $best = $v } }
    return $best
}

# ----- load -----
$vini1   = Read-Tsv "$dir\vini_1.tsv"
$vini2   = Read-Tsv "$dir\vini_2.tsv"
$payRows = Read-Tsv "$dir\payment_1.tsv"
Write-Output ("Loaded vini_1=" + $vini1.Count + " vini_2=" + $vini2.Count + " payment=" + $payRows.Count)

# Combine + dedupe Vini on (EntID|RTID|AgentType|Day)
$viniAll = New-Object System.Collections.Generic.List[hashtable]
$seen = New-Object System.Collections.Generic.HashSet[string]
foreach ($src in @($vini1, $vini2)) {
    foreach ($r in $src) {
        $key = ($r['Enterprise ID'] + '|' + $r['Rooftop ID'] + '|' + $r['Agent Type'] + '|' + $r['Day'])
        if ($seen.Add($key)) { $viniAll.Add($r) }
    }
}
Write-Output ("Combined+deduped vini rows: " + $viniAll.Count + " (from " + ($vini1.Count + $vini2.Count) + " raw)")

# Build master scope = enterprises present in Payment tab
$payEnts = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $payRows) {
    $entId = $r['Enterprise ID']
    if (-not [string]::IsNullOrWhiteSpace($entId)) { [void]$payEnts.Add($entId) }
}
Write-Output ("Payment-tab enterprises (master scope): " + $payEnts.Count)

# Filter Vini to scope
$viniInScope = New-Object System.Collections.Generic.List[hashtable]
foreach ($r in $viniAll) {
    if ($payEnts.Contains($r['Enterprise ID'])) { $viniInScope.Add($r) }
}
$viniDropped = $viniAll.Count - $viniInScope.Count
Write-Output ("Vini rows in scope: " + $viniInScope.Count + " (dropped " + $viniDropped + " rows for enterprises not in Payment)")

# Latest day per enterprise
$latestByEnt = @{}
foreach ($r in $viniInScope) {
    $entId = $r['Enterprise ID']
    $d = Parse-Day $r['Day']
    if (-not $latestByEnt.ContainsKey($entId) -or $d -gt $latestByEnt[$entId]) {
        $latestByEnt[$entId] = $d
    }
}
Write-Output ("Vini-active enterprises within scope: " + $latestByEnt.Count + " of " + $payEnts.Count)

# Aggregate Vini at enterprise level on its latest day
$viniRollup = @{}
foreach ($r in $viniInScope) {
    $entId = $r['Enterprise ID']
    $d = Parse-Day $r['Day']
    if ($d -ne $latestByEnt[$entId]) { continue }
    if (-not $viniRollup.ContainsKey($entId)) {
        $viniRollup[$entId] = @{
            'Enterprise ID'=$entId; 'Enterprise Name'=$r['Enterrpise Name']; 'CSM Name'=$r['CSM Name']
            'Customer Type'=$r['Customer Type']; 'Customer Subtype'=$r['Customer Subtype']; 'Customer Segment'=$r['Customer Segment']
            'Region'=$r['Region']; 'Stage'=$r['Stage']; 'Latest Day'=$r['Day']
            'Rooftops'=New-Object System.Collections.Generic.HashSet[string]
            'Agent Types'=New-Object System.Collections.Generic.HashSet[string]
            'FinalRAGs'=New-Object System.Collections.Generic.List[string]
            'Churned'=New-Object System.Collections.Generic.List[string]
            'Usage_Touched'=0.0; 'Usage_Qualified'=0.0; 'Usage_ApptBooked'=0.0
            'Usage_ConvRate_sum'=0.0; 'Usage_ConvRate_cnt'=0
            'RoI_ApptValue'=0.0; 'RoI_Factor_sum'=0.0; 'RoI_Factor_cnt'=0
            'RoI_ReportSent'=New-Object System.Collections.Generic.List[string]
            'Tickets_Created'=0.0; 'Tickets_Open'=0.0
            'Tickets_OpenAge'=0.0; 'Tickets_OpenAge_cnt'=0
            'Tickets_AvgRes'=New-Object System.Collections.Generic.List[string]
            'TicketRAGs'=New-Object System.Collections.Generic.List[string]
            'CommRAGs'=New-Object System.Collections.Generic.List[string]
            'MBRs'=New-Object System.Collections.Generic.List[string]
            'ContactFreqs'=New-Object System.Collections.Generic.List[string]
        }
    }
    $g = $viniRollup[$entId]
    if (-not [string]::IsNullOrWhiteSpace($r['Rooftop Name'])) { [void]$g['Rooftops'].Add($r['Rooftop Name']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Agent Type']))   { [void]$g['Agent Types'].Add($r['Agent Type']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Final Status/RAG'])) { $g['FinalRAGs'].Add($r['Final Status/RAG']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Final Status/Churned'])) { $g['Churned'].Add($r['Final Status/Churned']) }
    $g['Usage_Touched']    += (To-Number $r['Usage/# Touched'])
    $g['Usage_Qualified']  += (To-Number $r['Usage/# Qualified'])
    $g['Usage_ApptBooked'] += (To-Number $r['Usage/# Appt Booked'])
    $cv = To-Number $r['Usage/Conv Rate']
    if ($cv -gt 0) { $g['Usage_ConvRate_sum'] += $cv; $g['Usage_ConvRate_cnt']++ }
    $g['RoI_ApptValue']    += (To-Number $r['RoI?/Appt Value ($)'])
    $rf = $r['RoI?/RoI (Factor)']
    if ($rf -ne 'Infinity') {
        $rfn = To-Number $rf
        if ($rfn -gt 0) { $g['RoI_Factor_sum'] += $rfn; $g['RoI_Factor_cnt']++ }
    }
    if (-not [string]::IsNullOrWhiteSpace($r['RoI?/Report Sent (D/W/M)?'])) { $g['RoI_ReportSent'].Add($r['RoI?/Report Sent (D/W/M)?']) }
    $g['Tickets_Created'] += (To-Number $r['Tickets/# Created'])
    $g['Tickets_Open']    += (To-Number $r['Tickets/# Open'])
    $oa = To-Number $r['Tickets/Open Ticket Ageing (Hrs)']
    if ($oa -gt 0) { $g['Tickets_OpenAge'] += $oa; $g['Tickets_OpenAge_cnt']++ }
    if (-not [string]::IsNullOrWhiteSpace($r['Tickets/Avg Resolution hrs'])) { $g['Tickets_AvgRes'].Add($r['Tickets/Avg Resolution hrs']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Tickets/Ticket RAG'])) { $g['TicketRAGs'].Add($r['Tickets/Ticket RAG']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Communication/RAG']))  { $g['CommRAGs'].Add($r['Communication/RAG']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Leadership Connect/MBR']))         { $g['MBRs'].Add($r['Leadership Connect/MBR']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Leadership Connect/Contact Freq'])){ $g['ContactFreqs'].Add($r['Leadership Connect/Contact Freq']) }
}

# Payment rollup at enterprise level (all enterprises in Payment tab)
$payRollup = @{}
foreach ($r in $payRows) {
    $entId = $r['Enterprise ID']
    if ([string]::IsNullOrWhiteSpace($entId)) { continue }
    if (-not $payRollup.ContainsKey($entId)) {
        $payRollup[$entId] = @{
            'Enterprise ID'=$entId; 'Account'=$r['Account']
            'Rooftops'=New-Object System.Collections.Generic.HashSet[string]
            'Agents'=New-Object System.Collections.Generic.HashSet[string]
            'MRR'=0.0; 'ARR'=0.0
            'Stages'=New-Object System.Collections.Generic.HashSet[string]
            'T1s'=New-Object System.Collections.Generic.List[string]
            'T2s'=New-Object System.Collections.Generic.List[string]
            'T3s'=New-Object System.Collections.Generic.List[string]
            'Scores'=New-Object System.Collections.Generic.List[string]
        }
    }
    $p = $payRollup[$entId]
    if (-not [string]::IsNullOrWhiteSpace($r['Rooftop Name'])) { [void]$p['Rooftops'].Add($r['Rooftop Name']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Agent Opted']))  { [void]$p['Agents'].Add($r['Agent Opted']) }
    $p['MRR'] += (To-Number $r['MRR'])
    $p['ARR'] += (To-Number $r['ARR'])
    if (-not [string]::IsNullOrWhiteSpace($r['Stage'])) { [void]$p['Stages'].Add($r['Stage']) }
    $p['T1s'].Add($r['T1']); $p['T2s'].Add($r['T2']); $p['T3s'].Add($r['T3'])
    $p['Scores'].Add($r['Payment Score'])
}
Write-Output ("Payment rollup enterprises: " + $payRollup.Count)

# Final scope = Payment-tab enterprises (per user instruction #2/#3)
$outCols = @(
    'Enterprise ID','Enterprise Name','CSM Name','Customer Type','Customer Subtype','Customer Segment','Region','Stage','Latest Day',
    '# Rooftops','Rooftops','# Agent Types','Agent Types',
    'Final Status/RAG','Final Status/Churned',
    'Usage/# Touched','Usage/# Qualified','Usage/# Appt Booked','Usage/Conv Rate (avg)',
    'RoI?/Appt Value ($)','RoI?/RoI (Factor avg)','RoI?/Report Sent (D/W/M)?',
    'Tickets/# Created','Tickets/# Open','Tickets/Open Ticket Ageing (Hrs avg)','Tickets/Avg Resolution hrs','Tickets/Ticket RAG',
    'Communication/RAG','Leadership Connect/MBR','Leadership Connect/Contact Freq',
    'Payment/Rooftops','Payment/Agents','Payment/MRR','Payment/ARR','Payment/Stage','Payment/T1','Payment/T2','Payment/T3','Payment/Score',
    'Vini Data Present?'
)

$outRows = New-Object System.Collections.Generic.List[string[]]
$outRows.Add($outCols)

foreach ($entId in $payEnts) {
    $v = $viniRollup[$entId]
    $p = $payRollup[$entId]

    $row = @{}
    foreach ($c in $outCols) { $row[$c] = '' }
    $row['Enterprise ID'] = $entId

    if ($v -ne $null) {
        $row['Enterprise Name']    = $v['Enterprise Name']
        $row['CSM Name']           = $v['CSM Name']
        $row['Customer Type']      = $v['Customer Type']
        $row['Customer Subtype']   = $v['Customer Subtype']
        $row['Customer Segment']   = $v['Customer Segment']
        $row['Region']             = $v['Region']
        $row['Stage']              = $v['Stage']
        $row['Latest Day']         = $v['Latest Day']
        $row['# Rooftops']         = $v['Rooftops'].Count
        $row['Rooftops']           = ($v['Rooftops'] | Sort-Object) -join '; '
        $row['# Agent Types']      = $v['Agent Types'].Count
        $row['Agent Types']        = ($v['Agent Types'] | Sort-Object) -join '; '
        $row['Final Status/RAG']   = (Worst-RAG $v['FinalRAGs'])
        $row['Final Status/Churned'] = (($v['Churned'] | Sort-Object -Unique) -join '; ')
        $row['Usage/# Touched']    = $v['Usage_Touched']
        $row['Usage/# Qualified']  = $v['Usage_Qualified']
        $row['Usage/# Appt Booked'] = $v['Usage_ApptBooked']
        if ($v['Usage_ConvRate_cnt'] -gt 0) {
            $row['Usage/Conv Rate (avg)'] = [math]::Round($v['Usage_ConvRate_sum'] / $v['Usage_ConvRate_cnt'], 2)
        }
        $row['RoI?/Appt Value ($)'] = '$' + [math]::Round($v['RoI_ApptValue'], 0)
        if ($v['RoI_Factor_cnt'] -gt 0) {
            $row['RoI?/RoI (Factor avg)'] = [math]::Round($v['RoI_Factor_sum'] / $v['RoI_Factor_cnt'], 2)
        }
        $row['RoI?/Report Sent (D/W/M)?'] = (($v['RoI_ReportSent'] | Sort-Object -Unique) -join '; ')
        $row['Tickets/# Created']  = $v['Tickets_Created']
        $row['Tickets/# Open']     = $v['Tickets_Open']
        if ($v['Tickets_OpenAge_cnt'] -gt 0) {
            $row['Tickets/Open Ticket Ageing (Hrs avg)'] = [math]::Round($v['Tickets_OpenAge'] / $v['Tickets_OpenAge_cnt'], 2)
        }
        $row['Tickets/Avg Resolution hrs'] = (($v['Tickets_AvgRes'] | Sort-Object -Unique) -join '; ')
        $row['Tickets/Ticket RAG']     = (Worst-RAG $v['TicketRAGs'])
        $row['Communication/RAG']      = (Worst-RAG $v['CommRAGs'])
        $row['Leadership Connect/MBR'] = (($v['MBRs'] | Sort-Object -Unique) -join '; ')
        $row['Leadership Connect/Contact Freq'] = (($v['ContactFreqs'] | Sort-Object -Unique) -join '; ')
        $row['Vini Data Present?'] = 'Yes'
    } else {
        $row['Vini Data Present?'] = 'No'
    }

    # Payment columns (always present since we iterate payEnts)
    if ([string]::IsNullOrWhiteSpace($row['Enterprise Name'])) { $row['Enterprise Name'] = $p['Account'] }
    $row['Payment/Rooftops'] = ($p['Rooftops'] | Sort-Object) -join '; '
    $row['Payment/Agents']   = ($p['Agents']   | Sort-Object) -join '; '
    $row['Payment/MRR']      = '$' + [math]::Round($p['MRR'], 0)
    $row['Payment/ARR']      = '$' + [math]::Round($p['ARR'], 0)
    $row['Payment/Stage']    = ($p['Stages']   | Sort-Object) -join '; '
    $row['Payment/T1']       = (Worst-Pay $p['T1s'])
    $row['Payment/T2']       = (Worst-Pay $p['T2s'])
    $row['Payment/T3']       = (Worst-Pay $p['T3s'])
    $row['Payment/Score']    = (Worst-RAG $p['Scores'])

    # CSM blank handling
    if ([string]::IsNullOrWhiteSpace($row['CSM Name'])) { $row['CSM Name'] = 'Unassigned CSM' }

    $rowArr = New-Object string[] $outCols.Count
    for ($i = 0; $i -lt $outCols.Count; $i++) { $rowArr[$i] = [string]$row[$outCols[$i]] }
    $outRows.Add($rowArr)
}

function CsvEscape($s) {
    if ($s -eq $null) { return '' }
    $t = [string]$s
    if ($t -match '[",\r\n]') { return '"' + ($t -replace '"', '""') + '"' }
    return $t
}

$csvLines = New-Object System.Collections.Generic.List[string]
foreach ($r in $outRows) {
    $escaped = foreach ($c in $r) { CsvEscape $c }
    $csvLines.Add(($escaped -join ','))
}
[System.IO.File]::WriteAllLines("$dir\gid_1616842841_reworked.csv", $csvLines, [System.Text.UTF8Encoding]::new($false))
Write-Output ("Wrote CSV: gid_1616842841_reworked.csv with " + ($csvLines.Count - 1) + " data rows")

# QA
$unassigned = 0; $noVini = 0
foreach ($r in $outRows[1..($outRows.Count-1)]) {
    $rowMap = @{}
    for ($i = 0; $i -lt $outCols.Count; $i++) { $rowMap[$outCols[$i]] = $r[$i] }
    if ($rowMap['CSM Name'] -eq 'Unassigned CSM') { $unassigned++ }
    if ($rowMap['Vini Data Present?'] -eq 'No') { $noVini++ }
}
Write-Output ""
Write-Output "=== QA ==="
Write-Output ("Total enterprises in output: " + ($outRows.Count - 1))
Write-Output ("Unassigned CSM rows: " + $unassigned)
Write-Output ("Enterprises with no Vini activity (Payment-only): " + $noVini)
