$dir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"
$a = Get-Content "$dir\vini_a.tsv"
$b = Get-Content "$dir\vini_b.tsv"

$aKeys = @{}
$aDates = New-Object System.Collections.Generic.HashSet[string]
$aEnts  = New-Object System.Collections.Generic.HashSet[string]
for ($i=1; $i -lt $a.Count; $i++) {
    $cells = $a[$i] -split "`t"
    $k = $cells[4] + '|' + $cells[2] + '|' + $cells[1] + '|' + $cells[0]
    $aKeys[$k] = $true
    [void]$aDates.Add($cells[0])
    [void]$aEnts.Add($cells[4])
}

$bKeys = @{}
$bDates = New-Object System.Collections.Generic.HashSet[string]
$bEnts  = New-Object System.Collections.Generic.HashSet[string]
$overlapKeys = 0
$bOnly = 0
for ($i=1; $i -lt $b.Count; $i++) {
    $cells = $b[$i] -split "`t"
    $k = $cells[4] + '|' + $cells[2] + '|' + $cells[1] + '|' + $cells[0]
    $bKeys[$k] = $true
    [void]$bDates.Add($cells[0])
    [void]$bEnts.Add($cells[4])
    if ($aKeys.ContainsKey($k)) { $overlapKeys++ } else { $bOnly++ }
}

Write-Output ("S1 row keys: " + $aKeys.Count)
Write-Output ("S3 row keys: " + $bKeys.Count)
Write-Output ("S3 rows overlapping S1 on (EntID|RTID|AgentType|Day): " + $overlapKeys)
Write-Output ("S3 rows unique to S3: " + $bOnly)
Write-Output ""
Write-Output ("S1 unique enterprises: " + $aEnts.Count)
Write-Output ("S3 unique enterprises: " + $bEnts.Count)

$onlyA = New-Object System.Collections.Generic.HashSet[string] $aEnts
$onlyA.ExceptWith($bEnts)
$onlyB = New-Object System.Collections.Generic.HashSet[string] $bEnts
$onlyB.ExceptWith($aEnts)
Write-Output ("Enterprises only in S1: " + $onlyA.Count)
Write-Output ("Enterprises only in S3: " + $onlyB.Count)

Write-Output ""
Write-Output ("S1 dates: " + (($aDates | Sort-Object) -join ', '))
Write-Output ("S3 dates: " + (($bDates | Sort-Object) -join ', '))
