$ErrorActionPreference = 'Stop'
$path = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework\payment_1.tsv"
$lines = [System.IO.File]::ReadAllLines($path)
$hdr = $lines[0] -split "`t"

function Idx($n) { return [array]::IndexOf($hdr, $n) }
$iEid = Idx 'Enterprise ID'
$iAcc = Idx 'Account'
$iTid = Idx 'Team ID'
$iRn  = Idx 'Rooftop Name'
$iAgt = Idx 'Agent Opted'
$iStg = Idx 'Stage'

$totRows = 0; $live=0; $churn=0; $blank=0; $other=0
$liveOther = New-Object System.Collections.Generic.List[string]
$blankAgent = New-Object System.Collections.Generic.List[string]
$keys = New-Object System.Collections.Generic.List[string]
$dupGroups = @{}

for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = $lines[$i] -split "`t"
    $totRows++
    $stg = $c[$iStg].Trim()
    $agt = $c[$iAgt].Trim()
    $key = $c[$iTid] + '|' + $agt
    $keys.Add($key)

    if ([string]::IsNullOrWhiteSpace($agt)) {
        $blank++
        $blankAgent.Add("row " + ($i+1) + ": rid=" + $c[$iTid] + " (" + $c[$iAcc] + " / " + $c[$iRn] + ") stage=" + $stg)
    }
    if     ($stg -eq 'Live')    { $live++ }
    elseif ($stg -eq 'Churned') { $churn++ }
    elseif ([string]::IsNullOrWhiteSpace($stg)) {
        $other++
        $liveOther.Add("row " + ($i+1) + " BLANK stage: " + $c[$iAcc] + "/" + $c[$iRn] + "/" + $agt)
    } else {
        $other++
        $liveOther.Add("row " + ($i+1) + " other='" + $stg + "': " + $c[$iAcc] + "/" + $c[$iRn] + "/" + $agt)
    }

    if (-not $dupGroups.ContainsKey($key)) { $dupGroups[$key] = New-Object System.Collections.Generic.List[int] }
    $dupGroups[$key].Add($i+1)
}

$uniqueKeys = ($keys | Sort-Object -Unique).Count
$dupKeys = $dupGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

Write-Output "=== RAW counts in payment_1.tsv ==="
Write-Output ("Total rows         : " + $totRows)
Write-Output ("Stage=Live         : " + $live)
Write-Output ("Stage=Churned      : " + $churn)
Write-Output ("Stage=blank/other  : " + $other)
Write-Output ("Blank Agent Opted  : " + $blank)
Write-Output ("Unique (rid|agent) : " + $uniqueKeys)
Write-Output ""
Write-Output "=== Other-stage rows (if any) ==="
$liveOther | ForEach-Object { Write-Output ("  " + $_) }
Write-Output ""
Write-Output "=== Blank Agent rows (if any) ==="
$blankAgent | ForEach-Object { Write-Output ("  " + $_) }
Write-Output ""
Write-Output "=== Duplicate (rid|agent) keys ==="
foreach ($d in $dupKeys) {
    $stages = ($d.Value | ForEach-Object {
        $row = $lines[$_-1] -split "`t"
        $row[$iStg] + "/$" + $row[6]
    }) -join ', '
    Write-Output ("  key=" + $d.Key + " rows=" + ($d.Value -join ',') + " [stage/ARR: " + $stages + "]")
}
Write-Output ""
Write-Output "=== After (rid|agent) dedup with Churned-wins ==="
$keep = @{}
for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = $lines[$i] -split "`t"
    $key = $c[$iTid] + '|' + $c[$iAgt].Trim()
    $stg = $c[$iStg].Trim()
    if ($keep.ContainsKey($key)) {
        if ($stg -eq 'Churned') { $keep[$key] = 'Churned' }
    } else {
        $keep[$key] = $stg
    }
}
$dedupedLive  = ($keep.Values | Where-Object { $_ -eq 'Live' }).Count
$dedupedChurn = ($keep.Values | Where-Object { $_ -eq 'Churned' }).Count
$dedupedOther = ($keep.Values | Where-Object { $_ -ne 'Live' -and $_ -ne 'Churned' }).Count
Write-Output ("After dedup - Live   : " + $dedupedLive)
Write-Output ("After dedup - Churned: " + $dedupedChurn)
Write-Output ("After dedup - other  : " + $dedupedOther)
Write-Output ("After dedup - total  : " + $keep.Count)
