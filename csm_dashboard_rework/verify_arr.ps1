$ErrorActionPreference = 'Stop'
$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"

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
    try { return [double]($s -replace '[\$,]', '').Trim() } catch { return 0 }
}

$pay = Read-Tsv "$dir\payment_1.tsv"

# Method A: Per-row stage attribution (the CORRECT way per user expectation)
$liveArrA = 0.0; $churnArrA = 0.0; $liveMrrA = 0.0; $churnMrrA = 0.0
foreach ($r in $pay) {
    $stage = ([string]$r['Stage']).Trim()
    $arr = To-Number $r['ARR']
    $mrr = To-Number $r['MRR']
    if ($stage -eq 'Live')    { $liveArrA += $arr; $liveMrrA += $mrr }
    if ($stage -eq 'Churned') { $churnArrA += $arr; $churnMrrA += $mrr }
}
$totA = $liveArrA + $churnArrA

# Method B: Aggregate by rooftop, any-agent-churned → all-rooftop-churned (current dashboard logic)
$byRid = @{}
foreach ($r in $pay) {
    $rid = $r['Team ID']
    if ([string]::IsNullOrWhiteSpace($rid)) { continue }
    if (-not $byRid.ContainsKey($rid)) {
        $byRid[$rid] = @{ arr=0.0; mrr=0.0; stage='' }
    }
    $g = $byRid[$rid]
    $g['arr'] += (To-Number $r['ARR'])
    $g['mrr'] += (To-Number $r['MRR'])
    $st = ([string]$r['Stage']).Trim()
    if ($st -eq 'Churned') { $g['stage'] = 'Churned' }
    elseif ($st -and $g['stage'] -ne 'Churned') { $g['stage'] = $st }
}
$liveArrB = 0.0; $churnArrB = 0.0; $liveMrrB = 0.0; $churnMrrB = 0.0
foreach ($v in $byRid.Values) {
    if ($v['stage'] -eq 'Live')    { $liveArrB += $v['arr']; $liveMrrB += $v['mrr'] }
    if ($v['stage'] -eq 'Churned') { $churnArrB += $v['arr']; $churnMrrB += $v['mrr'] }
}
$totB = $liveArrB + $churnArrB

Write-Output "=== METHOD A: Per (rooftop x agent) row (CORRECT) ==="
Write-Output ("  Live ARR    : $" + ('{0:N0}' -f $liveArrA))
Write-Output ("  Churned ARR : $" + ('{0:N0}' -f $churnArrA))
Write-Output ("  Total ARR   : $" + ('{0:N0}' -f $totA))
Write-Output ("  Live MRR    : $" + ('{0:N0}' -f $liveMrrA))
Write-Output ""
Write-Output "=== METHOD B: Per rooftop, any-agent-churned spreads (CURRENT DASHBOARD BUG) ==="
Write-Output ("  Live ARR    : $" + ('{0:N0}' -f $liveArrB))
Write-Output ("  Churned ARR : $" + ('{0:N0}' -f $churnArrB))
Write-Output ("  Total ARR   : $" + ('{0:N0}' -f $totB))
Write-Output ("  Live MRR    : $" + ('{0:N0}' -f $liveMrrB))
Write-Output ""
Write-Output "=== ROOFTOPS WHERE THE BUG TRIGGERS (mixed-stage rooftops) ==="
$mixCount = 0
foreach ($rid in $byRid.Keys) {
    $hasL = ($pay | Where-Object { $_['Team ID'] -eq $rid -and ([string]$_['Stage']).Trim() -eq 'Live' }).Count
    $hasC = ($pay | Where-Object { $_['Team ID'] -eq $rid -and ([string]$_['Stage']).Trim() -eq 'Churned' }).Count
    if ($hasL -gt 0 -and $hasC -gt 0) {
        $mixCount++
        $en = ($pay | Where-Object { $_['Team ID'] -eq $rid } | Select-Object -First 1)['Account']
        $liveArr = ($pay | Where-Object { $_['Team ID'] -eq $rid -and ([string]$_['Stage']).Trim() -eq 'Live' } | Measure-Object -Property @{Expression={To-Number $_['ARR']}} -Sum).Sum
        $churnArr = ($pay | Where-Object { $_['Team ID'] -eq $rid -and ([string]$_['Stage']).Trim() -eq 'Churned' } | Measure-Object -Property @{Expression={To-Number $_['ARR']}} -Sum).Sum
        Write-Output ("  rid=" + $rid + " (" + $en + "): Live agents=$hasL ($liveArr) | Churned agents=$hasC ($churnArr)")
    }
}
Write-Output ("Mixed-stage rooftops: " + $mixCount)
