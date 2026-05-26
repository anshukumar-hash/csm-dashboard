$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"

$lines = [System.IO.File]::ReadAllLines($dashPath)
$dlIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
$dl = $lines[$dlIdx]
$json = $dl.Substring($dl.IndexOf("{")).TrimEnd(';').Trim()

Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$D = $jss.DeserializeObject($json)
$stage = if ($D.vini_stage -is [array]) { $D.vini_stage } else { $D.vini_stage.value }

# Mirror the NEW JS logic: accumulate on duplicate (rid|agent), Churned beats Live.
$byKey = @{}
foreach ($s in $stage) {
	$rid = [string]$s['rid']
	if ([string]::IsNullOrWhiteSpace($rid)) { continue }
	$key = $rid + '|' + [string]$s['agent']
	if ($byKey.ContainsKey($key)) {
		$e = $byKey[$key]
		$e['mrr'] += [double]$s['mrr']
		$e['arr'] += [double]$s['arr']
		if ([string]$s['stage'] -eq 'Churned') { $e['stage'] = 'Churned' }
		continue
	}
	$byKey[$key] = @{
		rid = $rid
		stage = [string]$s['stage']
		mrr = [double]$s['mrr']
		arr = [double]$s['arr']
	}
}
$rows = $byKey.Values

$totalArr = 0.0; $totalMrr = 0.0; $churnedArr = 0.0; $liveArr = 0.0
$rids = New-Object System.Collections.Generic.HashSet[string]
$churnedRids = New-Object System.Collections.Generic.HashSet[string]
$churnedN = 0
foreach ($r in $rows) {
	$totalArr += $r['arr']
	$totalMrr += $r['mrr']
	[void]$rids.Add($r['rid'])
	if ($r['stage'] -match 'churn') {
		$churnedArr += $r['arr']
		[void]$churnedRids.Add($r['rid'])
		$churnedN++
	} else { $liveArr += $r['arr'] }
}

Write-Output ("vini_stage rows: " + $stage.Count)
Write-Output ("Aggregated (rid x agent) contracts: " + $rows.Count)
Write-Output ""
Write-Output "=== POST-PATCH DASHBOARD NUMBERS ==="
Write-Output ("Total ARR        : `$" + ('{0:N0}' -f $totalArr) + "   (user expected ~`$1.058M)")
Write-Output ("Live ARR (T-C)   : `$" + ('{0:N0}' -f $liveArr)  + "   (user expected ~`$941K)")
Write-Output ("Churned ARR      : `$" + ('{0:N0}' -f $churnedArr) + "   (user expected ~`$117K)")
Write-Output ("Total MRR        : `$" + ('{0:N0}' -f $totalMrr))
Write-Output ("Distinct rooftops: " + $rids.Count)
Write-Output ("Churned rooftops : " + $churnedRids.Count)
Write-Output ("Agent contracts  : " + $rows.Count)
Write-Output ("Churned contracts: " + $churnedN)
