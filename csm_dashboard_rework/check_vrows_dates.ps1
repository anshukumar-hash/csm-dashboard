$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"
$lines = [System.IO.File]::ReadAllLines($dashPath)
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break } }
$dl = $lines[$dlIdx]
$json = $dl.Substring($dl.IndexOf("{")).TrimEnd(';').Trim()
Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$D = $jss.DeserializeObject($json)
$iDay = [array]::IndexOf($D.v_schema, 'day')

$dayCount = @{}
foreach ($r in $D.v_rows) {
    $d = [string]$r[$iDay]
    if (-not $dayCount.ContainsKey($d)) { $dayCount[$d] = 0 }
    $dayCount[$d]++
}

$sortedDays = $dayCount.Keys | Sort-Object
Write-Output ("v_rows total rows: " + $D.v_rows.Count)
Write-Output ("Distinct days: " + $sortedDays.Count)
Write-Output ("Earliest day: " + $sortedDays[0])
Write-Output ("Latest day:   " + $sortedDays[-1])
Write-Output ""
Write-Output "Row count per day:"
foreach ($d in $sortedDays) {
    Write-Output ("  " + $d + " : " + $dayCount[$d])
}

Write-Output ""
Write-Output "=== By month ==="
$byMonth = @{}
foreach ($d in $sortedDays) {
    $m = $d.Substring(0, 7)  # YYYY-MM
    if (-not $byMonth.ContainsKey($m)) { $byMonth[$m] = 0 }
    $byMonth[$m] += $dayCount[$d]
}
foreach ($m in ($byMonth.Keys | Sort-Object)) {
    Write-Output ("  " + $m + " : " + $byMonth[$m] + " rows")
}
