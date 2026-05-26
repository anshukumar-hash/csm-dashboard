$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"

# 1) From embedded v_rows in dashboard
$lines = [System.IO.File]::ReadAllLines($dashPath)
# Find the data line dynamically
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
if ($dlIdx -lt 0) { throw "Could not find DASHBOARD_DATA line" }
$dl = $lines[$dlIdx]
$json = $dl.Substring($dl.IndexOf("{")).TrimEnd(';').Trim()
Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$D = $jss.DeserializeObject($json)
$vSchema = $D.v_schema
$iDay = [array]::IndexOf($vSchema, 'day')
$iEid = [array]::IndexOf($vSchema, 'eid')
$iAgt = [array]::IndexOf($vSchema, 'agent')
$iRid = [array]::IndexOf($vSchema, 'rid')
$iRn  = [array]::IndexOf($vSchema, 'rn')
$iT   = [array]::IndexOf($vSchema, 't')
$iQ   = [array]::IndexOf($vSchema, 'q')
$iA   = [array]::IndexOf($vSchema, 'a')

$targetEid = '5b81be4b1'  # Dream Automotive
Write-Output "=== EMBEDDED v_rows for Dream Automotive ($targetEid) ==="
$totalsByDay = @{}
$rowCount = 0
foreach ($r in $D.v_rows) {
    if ([string]$r[$iEid] -ne $targetEid) { continue }
    $rowCount++
    $day = [string]$r[$iDay]
    if (-not $totalsByDay.ContainsKey($day)) { $totalsByDay[$day] = @{ t=0; q=0; a=0 } }
    $totalsByDay[$day].t += [double]$r[$iT]
    $totalsByDay[$day].q += [double]$r[$iQ]
    $totalsByDay[$day].a += [double]$r[$iA]
}
Write-Output ("Rows for this enterprise: " + $rowCount)
Write-Output ("Distinct days: " + $totalsByDay.Count)
Write-Output ""
$sortedDays = $totalsByDay.Keys | Sort-Object -Descending | Select-Object -First 5
Write-Output "Top 5 most recent days for Dream Automotive (sums across all rooftop x agent):"
foreach ($d in $sortedDays) {
    $t = $totalsByDay[$d]
    Write-Output ("  $d : Touched=" + $t.t + "  Qualified=" + $t.q + "  Appt Booked=" + $t.a)
}

# 2) MTD totals (1-21 May 2026 per TODAY)
Write-Output ""
Write-Output "=== MTD (2026-05-01 to 2026-05-21) totals from embedded v_rows ==="
$mtdT = 0; $mtdQ = 0; $mtdA = 0
foreach ($d in $totalsByDay.Keys) {
    if ($d -ge '2026-05-01' -and $d -le '2026-05-21') {
        $mtdT += $totalsByDay[$d].t
        $mtdQ += $totalsByDay[$d].q
        $mtdA += $totalsByDay[$d].a
    }
}
Write-Output ("MTD Touched=$mtdT  Qualified=$mtdQ  Appt Booked=$mtdA")

# 3) Last Month (April) totals
Write-Output ""
Write-Output "=== Last Month (2026-04-01 to 2026-04-30) totals from embedded v_rows ==="
$lmT = 0; $lmQ = 0; $lmA = 0
foreach ($d in $totalsByDay.Keys) {
    if ($d -ge '2026-04-01' -and $d -le '2026-04-30') {
        $lmT += $totalsByDay[$d].t
        $lmQ += $totalsByDay[$d].q
        $lmA += $totalsByDay[$d].a
    }
}
Write-Output ("LM Touched=$lmT  Qualified=$lmQ  Appt Booked=$lmA")

# 4) Cross-check against gid=1616842841 source (vini_1 + vini_2 TSVs deduped)
Write-Output ""
Write-Output "=== Cross-check against gid=1616842841 source (vini_1+vini_2 TSV) ==="
$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"
$srcDays = @{}
foreach ($f in @("$dir\vini_1.tsv", "$dir\vini_2.tsv")) {
    if (-not (Test-Path $f)) { continue }
    $sl = [System.IO.File]::ReadAllLines($f)
    $sh = $sl[0] -split "`t"
    $sIDay = [array]::IndexOf($sh, 'Day')
    $sIEid = [array]::IndexOf($sh, 'Enterprise ID')
    $sIT   = [array]::IndexOf($sh, 'Usage/# Touched')
    $sIQ   = [array]::IndexOf($sh, 'Usage/# Qualified')
    $sIA   = [array]::IndexOf($sh, 'Usage/# Appt Booked')
    $sIRid = [array]::IndexOf($sh, 'Rooftop ID')
    $sIAgt = [array]::IndexOf($sh, 'Agent Type')
    for ($i = 1; $i -lt $sl.Count; $i++) {
        $c = $sl[$i] -split "`t"
        if ([string]$c[$sIEid] -ne $targetEid) { continue }
        $dKey = $c[$sIDay] + '|' + $c[$sIRid] + '|' + $c[$sIAgt]
        if ($srcDays.ContainsKey($dKey)) { continue }  # dedupe across vini_1+vini_2
        $srcDays[$dKey] = @{
            day = $c[$sIDay]
            t = [double]($c[$sIT] -replace '[^\d.\-]', '')
            q = [double]($c[$sIQ] -replace '[^\d.\-]', '')
            a = [double]($c[$sIA] -replace '[^\d.\-]', '')
        }
    }
}
$srcByDay = @{}
foreach ($r in $srcDays.Values) {
    $d = $r.day
    if (-not $srcByDay.ContainsKey($d)) { $srcByDay[$d] = @{ t=0; q=0; a=0 } }
    $srcByDay[$d].t += $r.t
    $srcByDay[$d].q += $r.q
    $srcByDay[$d].a += $r.a
}
Write-Output ("Source rows for Dream Automotive (deduped): " + $srcDays.Count)
foreach ($d in ($srcByDay.Keys | Sort-Object -Descending)) {
    $t = $srcByDay[$d]
    Write-Output ("  $d : Touched=" + $t.t + "  Qualified=" + $t.q + "  Appt Booked=" + $t.a)
}
