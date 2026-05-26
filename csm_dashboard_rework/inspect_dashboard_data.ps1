$ErrorActionPreference = 'Stop'
$path = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"
$lines = [System.IO.File]::ReadAllLines($path)
$dataLine = $lines[286]  # 0-indexed: file line 287 = array index 286
$prefix = "window.__DASHBOARD_DATA__ = "
$idx = $dataLine.IndexOf($prefix)
$json = $dataLine.Substring($idx + $prefix.Length).TrimEnd(';').Trim()
Write-Output ("Raw JSON length: " + $json.Length)

$json | Set-Content -Path "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework\dashboard_data.json" -Encoding UTF8 -NoNewline
Write-Output "Saved to dashboard_data.json"

# Use .NET JSON parser (handles large input better than ConvertFrom-Json)
Add-Type -AssemblyName System.Web.Extensions
$jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jss.MaxJsonLength = [int]::MaxValue
$jss.RecursionLimit = 100
$D = $jss.DeserializeObject($json)

Write-Output ""
Write-Output "=== TOP-LEVEL KEYS ==="
foreach ($k in $D.Keys) {
    $v = $D[$k]
    $type = if ($v -is [array]) { "array(" + $v.Count + ")" }
            elseif ($v -is [System.Collections.IDictionary]) { "object(" + $v.Count + " keys)" }
            else { $v.GetType().Name }
    Write-Output ("  " + $k + " : " + $type)
}

Write-Output ""
Write-Output "=== s_schema ==="
$D.s_schema -join ", "

Write-Output ""
Write-Output "=== v_schema ==="
$D.v_schema -join ", "

Write-Output ""
Write-Output "=== vini_stage sample row (idx 0) ==="
$stage = if ($D.vini_stage -is [array]) { $D.vini_stage } else { $D.vini_stage.value }
Write-Output ("vini_stage count: " + $stage.Count)
if ($stage.Count -gt 0) {
    foreach ($k in $stage[0].Keys) {
        Write-Output ("  " + $k + " : " + $stage[0][$k])
    }
}

Write-Output ""
Write-Output "=== v_rows count and 1 sample ==="
Write-Output ("v_rows count: " + $D.v_rows.Count)
if ($D.v_rows.Count -gt 0) {
    Write-Output ("First row: " + (($D.v_rows[0] | ForEach-Object { [string]$_ }) -join " | "))
}

Write-Output ""
Write-Output "=== vini_tix sample ==="
$tixKeys = @($D.vini_tix.Keys)
Write-Output ("vini_tix enterprise IDs: " + $tixKeys.Count)
if ($tixKeys.Count -gt 0) {
    $k0 = $tixKeys[0]
    Write-Output ("Sample [" + $k0 + "]:")
    foreach ($f in $D.vini_tix[$k0].Keys) {
        Write-Output ("  " + $f + " : " + $D.vini_tix[$k0][$f])
    }
}
