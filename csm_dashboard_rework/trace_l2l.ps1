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
$iEid = [array]::IndexOf($D.v_schema, 'eid')
$iAgt = [array]::IndexOf($D.v_schema, 'agent')
$iRid = [array]::IndexOf($D.v_schema, 'rid')
$iA   = [array]::IndexOf($D.v_schema, 'a')
$iT   = [array]::IndexOf($D.v_schema, 't')

Write-Output ("v_schema index for 'a' (Appt Booked): " + $iA)
Write-Output ("v_schema index for 'day': " + $iDay)
Write-Output ""

# Total appts across all rows in March 2026
$marchAppts = 0; $marchTouched = 0; $marchRows = 0
$aprilAppts = 0; $aprilTouched = 0; $aprilRows = 0
$mayAppts = 0; $mayTouched = 0; $mayRows = 0
$sampleMarch = @()
foreach ($r in $D.v_rows) {
    $d = [string]$r[$iDay]
    $a = [double]$r[$iA]
    $t = [double]$r[$iT]
    if ($d -ge '2026-03-01' -and $d -le '2026-03-31') {
        $marchAppts += $a; $marchTouched += $t; $marchRows++
        if ($sampleMarch.Count -lt 5) { $sampleMarch += ($d + " agent=" + $r[$iAgt] + " rid=" + $r[$iRid] + " eid=" + $r[$iEid] + " a=" + $a + " t=" + $t) }
    } elseif ($d -ge '2026-04-01' -and $d -le '2026-04-30') {
        $aprilAppts += $a; $aprilTouched += $t; $aprilRows++
    } elseif ($d -ge '2026-05-01' -and $d -le '2026-05-31') {
        $mayAppts += $a; $mayTouched += $t; $mayRows++
    }
}

Write-Output ("=== TOTALS FROM EMBEDDED v_rows ===")
Write-Output ("March 2026: $marchRows rows, Appt Booked=$marchAppts, Touched=$marchTouched")
Write-Output ("April 2026: $aprilRows rows, Appt Booked=$aprilAppts, Touched=$aprilTouched")
Write-Output ("May 2026 : $mayRows rows, Appt Booked=$mayAppts, Touched=$mayTouched")
Write-Output ""
Write-Output "Sample March rows:"
$sampleMarch | ForEach-Object { Write-Output ("  " + $_) }

# Verify what types these fields are in JSON (string vs number)
Write-Output ""
$first = $D.v_rows[0]
Write-Output ("First v_row sample (raw):")
Write-Output ("  day=" + $first[$iDay] + " [type=" + $first[$iDay].GetType().Name + "]")
Write-Output ("  a=" + $first[$iA] + " [type=" + $first[$iA].GetType().Name + "]")
Write-Output ("  rid=" + $first[$iRid] + " [type=" + $first[$iRid].GetType().Name + "]")
Write-Output ("  agent=" + $first[$iAgt] + " [type=" + $first[$iAgt].GetType().Name + "]")

# How many distinct (rid, agent) keys exist in March v_rows?
$marchKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $D.v_rows) {
    $d = [string]$r[$iDay]
    if ($d -lt '2026-03-01' -or $d -gt '2026-03-31') { continue }
    [void]$marchKeys.Add([string]$r[$iRid] + '|' + [string]$r[$iAgt])
}
Write-Output ""
Write-Output ("Distinct (rid|agent) keys with March data: " + $marchKeys.Count)

# How many of those keys are in VINI_STAGE (the byKey seed)?
$stage = if ($D.vini_stage -is [array]) { $D.vini_stage } else { $D.vini_stage.value }
$stageKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($s in $stage) {
    if ([string]::IsNullOrWhiteSpace([string]$s['rid'])) { continue }
    [void]$stageKeys.Add([string]$s['rid'] + '|' + [string]$s['agent'])
}
Write-Output ("Distinct (rid|agent) keys in vini_stage: " + $stageKeys.Count)

$intersect = 0
foreach ($k in $marchKeys) { if ($stageKeys.Contains($k)) { $intersect++ } }
Write-Output ("March v_rows keys that EXIST in vini_stage (should match): " + $intersect)
Write-Output ("March v_rows keys that are MISSING from vini_stage (dropped): " + ($marchKeys.Count - $intersect))

# What is "agent" value for v_rows? Is it formatted differently?
Write-Output ""
Write-Output "=== Unique agent values in v_rows vs vini_stage ==="
$vAgents = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $D.v_rows) { [void]$vAgents.Add([string]$r[$iAgt]) }
Write-Output ("v_rows agent values: " + (($vAgents | Sort-Object) -join ' | '))
$sAgents = New-Object System.Collections.Generic.HashSet[string]
foreach ($s in $stage) { [void]$sAgents.Add([string]$s['agent']) }
Write-Output ("vini_stage agent values: " + (($sAgents | Sort-Object) -join ' | '))
