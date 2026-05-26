$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"
$segByRA = @{}
$segByEn = @{}
foreach ($f in @("$dir\vini_1.tsv","$dir\vini_2.tsv")) {
    if (-not (Test-Path $f)) { continue }
    $tl = [System.IO.File]::ReadAllLines($f)
    $th = $tl[0] -split "`t"
    $fRid = [array]::IndexOf($th, 'Rooftop ID')
    $fAgt = [array]::IndexOf($th, 'Agent Type')
    $fSeg = [array]::IndexOf($th, 'Customer Segment')
    $fEn = [array]::IndexOf($th, 'Enterrpise Name')
    $fDay = [array]::IndexOf($th, 'Day')
    for ($i = 1; $i -lt $tl.Count; $i++) {
        $c = $tl[$i] -split "`t"
        if ($c.Count -le $fSeg) { continue }
        $rid = $c[$fRid].Trim()
        $agt = $c[$fAgt].Trim()
        $seg = $c[$fSeg].Trim()
        $en  = $c[$fEn].Trim()
        $day = $c[$fDay].Trim()
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        $k = $rid + '|' + $agt
        if (-not $segByRA.ContainsKey($k) -or $segByRA[$k].day -lt $day) {
            $segByRA[$k] = @{seg=$seg;day=$day}
        }
        if ($en -and (-not $segByEn.ContainsKey($en) -or $segByEn[$en].day -lt $day)) {
            $segByEn[$en] = @{seg=$seg;day=$day}
        }
    }
}
Write-Output ("segByRA keys: " + $segByRA.Count + " | segByEn keys: " + $segByEn.Count)
Write-Output ""
Write-Output "=== (rid|agent) key lookup ==="
foreach ($k in @('5a4c21a96f|Sales Inbound','5a4c21a96f|Service Inbound','26fe9492b9|Service Inbound','26fe9492b9|Service Outbound','e08ec18b4f|Sales Inbound','e08ec18b4f|Sales Outbound','e08ec18b4f|Service Inbound','09652c78f4|Sales Inbound')) {
    if ($segByRA.ContainsKey($k)) { Write-Output ("  '$k' = " + $segByRA[$k].seg) }
    else { Write-Output ("  '$k' = NOT FOUND") }
}
Write-Output ""
Write-Output "=== Enterprise-name lookup ==="
foreach ($en in @('PalmEasy Motors PA LLC','Palmeasy Motors','Toronto Honda','Dutch Miller Auto Group','Dutch Miller Kia Charlotte','Next Gear Motors')) {
    if ($segByEn.ContainsKey($en)) { Write-Output ("  '$en' = " + $segByEn[$en].seg) }
    else { Write-Output ("  '$en' = NOT FOUND") }
}
