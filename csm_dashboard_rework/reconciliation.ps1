$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"
$lines = Get-Content "$dir\gid_1616842841_reworked.csv"
$hdr = $lines[0] -split ','
function Idx($name) { return [array]::IndexOf($hdr, $name) }
$iEntId   = Idx 'Enterprise ID'
$iName    = Idx 'Enterprise Name'
$iCSM     = Idx 'CSM Name'
$iSrc     = Idx 'Vini Data Present?'
$iLatest  = Idx 'Latest Day'
$iSeg     = Idx 'Customer Segment'
$iPayARR  = Idx 'Payment/ARR'

function ParseCsvLine($l) {
    $result = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $inQ = $false
    for ($i = 0; $i -lt $l.Length; $i++) {
        $c = $l[$i]
        if ($inQ) {
            if ($c -eq '"' -and $i+1 -lt $l.Length -and $l[$i+1] -eq '"') { [void]$sb.Append('"'); $i++ }
            elseif ($c -eq '"') { $inQ = $false }
            else { [void]$sb.Append($c) }
        } else {
            if ($c -eq '"') { $inQ = $true }
            elseif ($c -eq ',') { $result.Add($sb.ToString()); [void]$sb.Clear() }
            else { [void]$sb.Append($c) }
        }
    }
    $result.Add($sb.ToString())
    return ,@($result.ToArray())
}

$viniOnly  = New-Object System.Collections.Generic.List[string]
$payOnly   = New-Object System.Collections.Generic.List[string]
$bothNoCsm = New-Object System.Collections.Generic.List[string]

for ($i = 1; $i -lt $lines.Count; $i++) {
    $cells = ParseCsvLine $lines[$i]
    if ($cells.Count -lt $hdr.Count) { continue }
    $src = $cells[$iSrc]
    $csm = $cells[$iCSM]
    $name = $cells[$iName]
    $ent = $cells[$iEntId]
    $seg = $cells[$iSeg]
    $arr = $cells[$iPayARR]
    $latest = $cells[$iLatest]
    $line = "$ent | $name | seg=$seg | latest=$latest | CSM=$csm | PayARR=$arr"
    if ($src -eq 'No') { $payOnly.Add($line) }
    if ($src -eq 'Yes' -and $csm -eq 'Unassigned CSM') { $bothNoCsm.Add($line) }
}

Write-Output ("=== Payment-only enterprises (in Payment tab, no daily Vini activity in window) : " + $payOnly.Count + " ===")
$payOnly | ForEach-Object { Write-Output "  $_" }
Write-Output ""
Write-Output ("=== Matched enterprises but missing CSM in Vini source : " + $bothNoCsm.Count + " ===")
$bothNoCsm | ForEach-Object { Write-Output "  $_" }
