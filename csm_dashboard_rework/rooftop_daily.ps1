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
    if ($clean -eq 'Infinity' -or $clean -eq 'NA' -or $clean -eq '') { return 0.0 }
    try { return [double]$clean } catch { return 0.0 }
}
function RAG-Rank($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    switch ($s.Trim().ToLower()) {
        'red' { 4 } 'amber' { 3 } 'yellow' { 3 } 'orange' { 3 } 'green' { 2 } 'na' { 1 } default { 0 }
    }
}
function Worst-RAG($values) { $best=''; $rank=-1; foreach ($v in $values) { $r=RAG-Rank $v; if ($r -gt $rank) {$rank=$r;$best=$v} }; return $best }
function Pay-Rank($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return 0 }
    switch ($s.Trim().ToLower()) { 'overdue' { 3 } 'no invoice raised' { 2 } 'paid' { 1 } default { 0 } }
}
function Worst-Pay($values) { $best=''; $rank=-1; foreach ($v in $values) { $r=Pay-Rank $v; if ($r -gt $rank) {$rank=$r;$best=$v} }; return $best }

# ----- load -----
$vini1   = Read-Tsv "$dir\vini_1.tsv"
$vini2   = Read-Tsv "$dir\vini_2.tsv"
$payRows = Read-Tsv "$dir\payment_1.tsv"

# Combine + dedupe Vini
$viniAll = New-Object System.Collections.Generic.List[hashtable]
$seen = New-Object System.Collections.Generic.HashSet[string]
foreach ($src in @($vini1, $vini2)) {
    foreach ($r in $src) {
        $key = ($r['Enterprise ID'] + '|' + $r['Rooftop ID'] + '|' + $r['Agent Type'] + '|' + $r['Day'])
        if ($seen.Add($key)) { $viniAll.Add($r) }
    }
}
Write-Output ("Vini rows deduped: " + $viniAll.Count)

# Payment rollup at enterprise level (so we can broadcast)
$payByEnt = @{}
foreach ($r in $payRows) {
    $entId = $r['Enterprise ID']
    if ([string]::IsNullOrWhiteSpace($entId)) { continue }
    if (-not $payByEnt.ContainsKey($entId)) {
        $payByEnt[$entId] = @{
            'Account' = $r['Account']
            'Rooftops' = New-Object System.Collections.Generic.HashSet[string]
            'Agents'   = New-Object System.Collections.Generic.HashSet[string]
            'MRR'=0.0; 'ARR'=0.0
            'Stages' = New-Object System.Collections.Generic.HashSet[string]
            'T1s'=New-Object System.Collections.Generic.List[string]
            'T2s'=New-Object System.Collections.Generic.List[string]
            'T3s'=New-Object System.Collections.Generic.List[string]
            'Scores'=New-Object System.Collections.Generic.List[string]
        }
    }
    $p = $payByEnt[$entId]
    if (-not [string]::IsNullOrWhiteSpace($r['Rooftop Name'])) { [void]$p['Rooftops'].Add($r['Rooftop Name']) }
    if (-not [string]::IsNullOrWhiteSpace($r['Agent Opted']))  { [void]$p['Agents'].Add($r['Agent Opted']) }
    $p['MRR'] += (To-Number $r['MRR'])
    $p['ARR'] += (To-Number $r['ARR'])
    if (-not [string]::IsNullOrWhiteSpace($r['Stage'])) { [void]$p['Stages'].Add($r['Stage']) }
    $p['T1s'].Add($r['T1']); $p['T2s'].Add($r['T2']); $p['T3s'].Add($r['T3'])
    $p['Scores'].Add($r['Payment Score'])
}
Write-Output ("Payment enterprises: " + $payByEnt.Count)

# Pre-compute aggregated payment per enterprise for broadcast
$payAgg = @{}
foreach ($entId in $payByEnt.Keys) {
    $p = $payByEnt[$entId]
    $payAgg[$entId] = @{
        'Payment/Rooftops' = ($p['Rooftops'] | Sort-Object) -join '; '
        'Payment/Agents'   = ($p['Agents'] | Sort-Object) -join '; '
        'Payment/MRR'      = '$' + [math]::Round($p['MRR'], 0)
        'Payment/ARR'      = '$' + [math]::Round($p['ARR'], 0)
        'Payment/Stage'    = ($p['Stages'] | Sort-Object) -join '; '
        'Payment/T1'       = (Worst-Pay $p['T1s'])
        'Payment/T2'       = (Worst-Pay $p['T2s'])
        'Payment/T3'       = (Worst-Pay $p['T3s'])
        'Payment/Score'    = (Worst-RAG $p['Scores'])
        'Account'          = $p['Account']
    }
}

# Output cols mirror original Vini schema + payment broadcast
$outCols = @(
    'Day','Agent Type','Rooftop ID','Rooftop Name','Enterprise ID','Enterprise Name',
    'Customer Type','Customer Subtype','Customer Segment','CSM Name','Region','Stage',
    'Final Status/RAG','Final Status/Churned',
    'Usage/# Touched','Usage/# Qualified','Usage/# Appt Booked','Usage/Conv Rate',
    'RoI?/Appt Value ($)','RoI?/RoI (Factor)','RoI?/Report Sent (D/W/M)?',
    'Tickets/# Created','Tickets/# Open','Tickets/Open Ticket Ageing (Hrs)','Tickets/Avg Resolution hrs','Tickets/Ticket RAG',
    'Communication/RAG','Leadership Connect/MBR','Leadership Connect/Contact Freq',
    'Payment/Rooftops','Payment/Agents','Payment/MRR','Payment/ARR','Payment/Stage','Payment/T1','Payment/T2','Payment/T3','Payment/Score'
)

$outRows = New-Object System.Collections.Generic.List[string[]]
$outRows.Add($outCols)

$dropped = 0
$kept = 0
foreach ($r in $viniAll) {
    $entId = $r['Enterprise ID']
    if (-not $payAgg.ContainsKey($entId)) { $dropped++; continue }  # filter to Payment-tab scope
    $kept++

    $csm = if ([string]::IsNullOrWhiteSpace($r['CSM Name'])) { 'Unassigned CSM' } else { $r['CSM Name'] }
    $p = $payAgg[$entId]
    $entName = if ([string]::IsNullOrWhiteSpace($r['Enterrpise Name'])) { $p['Account'] } else { $r['Enterrpise Name'] }

    $values = @(
        $r['Day'], $r['Agent Type'], $r['Rooftop ID'], $r['Rooftop Name'], $entId, $entName,
        $r['Customer Type'], $r['Customer Subtype'], $r['Customer Segment'], $csm, $r['Region'], $r['Stage'],
        $r['Final Status/RAG'], $r['Final Status/Churned'],
        $r['Usage/# Touched'], $r['Usage/# Qualified'], $r['Usage/# Appt Booked'], $r['Usage/Conv Rate'],
        $r['RoI?/Appt Value ($)'], $r['RoI?/RoI (Factor)'], $r['RoI?/Report Sent (D/W/M)?'],
        $r['Tickets/# Created'], $r['Tickets/# Open'], $r['Tickets/Open Ticket Ageing (Hrs)'], $r['Tickets/Avg Resolution hrs'], $r['Tickets/Ticket RAG'],
        $r['Communication/RAG'], $r['Leadership Connect/MBR'], $r['Leadership Connect/Contact Freq'],
        $p['Payment/Rooftops'], $p['Payment/Agents'], $p['Payment/MRR'], $p['Payment/ARR'], $p['Payment/Stage'], $p['Payment/T1'], $p['Payment/T2'], $p['Payment/T3'], $p['Payment/Score']
    )
    $arr = New-Object string[] $outCols.Count
    for ($i = 0; $i -lt $outCols.Count; $i++) { $arr[$i] = [string]$values[$i] }
    $outRows.Add($arr)
}

# Sort: Day desc, Enterprise Name asc, Rooftop Name asc, Agent Type asc
$header = $outRows[0]
$data = $outRows | Select-Object -Skip 1
$sorted = $data | Sort-Object @{Expression={ try { [datetime]::ParseExact($_[0],'d MMM, yyyy',[System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue } }; Descending=$true}, @{Expression={$_[5]}}, @{Expression={$_[3]}}, @{Expression={$_[1]}}

function CsvEscape($s) {
    if ($s -eq $null) { return '' }
    $t = [string]$s
    if ($t -match '[",\r\n]') { return '"' + ($t -replace '"', '""') + '"' }
    return $t
}

$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add((($header | ForEach-Object { CsvEscape $_ }) -join ','))
foreach ($r in $sorted) {
    $escaped = foreach ($c in $r) { CsvEscape $c }
    $csvLines.Add(($escaped -join ','))
}

[System.IO.File]::WriteAllLines("$dir\gid_1616842841_rooftop_daily.csv", $csvLines, [System.Text.UTF8Encoding]::new($false))
Write-Output ("Wrote CSV: gid_1616842841_rooftop_daily.csv with " + ($csvLines.Count - 1) + " rooftop-daily rows")
Write-Output ("Kept: " + $kept + " | Dropped (enterprise not in Payment tab): " + $dropped)

# QA
$unassigned = 0
foreach ($r in $sorted) { if ($r[9] -eq 'Unassigned CSM') { $unassigned++ } }
Write-Output ("Rows with Unassigned CSM: " + $unassigned)
