$ErrorActionPreference = 'Stop'
# Find newest cached export
$cacheDir = "$env:USERPROFILE\.claude\projects\C--Users-Anshu-Kumar-Documents-Claude\a89d2803-abac-4efe-9e24-d4b60eb67b02\tool-results"
$srcFile = Get-ChildItem $cacheDir -Filter "mcp-cf38d8bc*read_file_content*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("Using cached export: " + $srcFile.Name + " (" + $srcFile.LastWriteTime + ")")

$outDir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"

$obj = Get-Content -Raw $srcFile.FullName | ConvertFrom-Json
$text = $obj.fileContent
$lines = $text -split "`n"
Write-Output ("Total lines: " + $lines.Count)

function Parse-MdRow($line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $line = $line.Trim()
    if ($line.StartsWith('|')) { $line = $line.Substring(1) }
    if ($line.EndsWith('|')) { $line = $line.Substring(0, $line.Length - 1) }
    $cells = $line -split '\s\|\s'
    $cleaned = foreach ($c in $cells) {
        $c2 = $c -replace '\\#', '#' -replace '\\_', '_' -replace '\\\$', '$' -replace '\\!', '!' -replace '\\\.', '.' -replace '&#13;', ''
        $c2 = $c2 -replace '<span[^>]*>', '' -replace '</span>', ''
        $c2.Trim()
    }
    return ,@($cleaned)
}

# Find tab boundaries: each tab starts where the line matches header pattern (pipe row),
# followed by a separator row (| :-: | :-: | ...), preceded by blank or BOF.
$tabs = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    $cur = $lines[$i]
    $nxt = $lines[$i+1]
    if ($cur -match '^\|.*\|$' -and $nxt -match '^\|\s*:-:\s*\|') {
        # tab header detected at $i
        $tabs.Add(@{ HeaderLine = $i; DataStart = $i + 2 })
    }
}
# Set DataEnd for each tab = (next header line - 1) or end of file, then walk back past trailing blanks
for ($t = 0; $t -lt $tabs.Count; $t++) {
    if ($t + 1 -lt $tabs.Count) {
        $end = $tabs[$t + 1].HeaderLine - 1
    } else {
        $end = $lines.Count - 1
    }
    while ($end -ge $tabs[$t].DataStart -and [string]::IsNullOrWhiteSpace($lines[$end])) { $end-- }
    $tabs[$t].DataEnd = $end
}

Write-Output ("Detected tabs: " + $tabs.Count)
for ($t = 0; $t -lt $tabs.Count; $t++) {
    $hdr = Parse-MdRow $lines[$tabs[$t].HeaderLine]
    Write-Output ("  Tab #" + ($t+1) + " : L" + $tabs[$t].HeaderLine + " data L" + $tabs[$t].DataStart + ".." + $tabs[$t].DataEnd + " (" + ($tabs[$t].DataEnd - $tabs[$t].DataStart + 1) + " rows, " + $hdr.Count + " cols) firstCol=[" + $hdr[0] + "]")
}

# Identify tabs by signature columns
function Match-Header($hdrRow, $sigCols) {
    $hdrSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($h in $hdrRow) { [void]$hdrSet.Add($h) }
    foreach ($s in $sigCols) { if (-not $hdrSet.Contains($s)) { return $false } }
    return $true
}

$viniSig = @('Day','Agent Type','Rooftop ID','Enterprise ID','Customer Segment')  # tolerant — accept both 29-col and 26-col variants
$paySig  = @('Enterprise ID','Account','Team ID','Rooftop Name','Agent Opted','MRR','ARR','T1','T2','T3','Payment Score')

$viniTabs = @()
$payTabs  = @()
for ($t = 0; $t -lt $tabs.Count; $t++) {
    $hdr = Parse-MdRow $lines[$tabs[$t].HeaderLine]
    if (Match-Header $hdr $viniSig) { $viniTabs += $t }
    if (Match-Header $hdr $paySig)  { $payTabs  += $t }
}
Write-Output ("Vini-format tab indices: " + ($viniTabs -join ','))
Write-Output ("Payment-format tab indices: " + ($payTabs  -join ','))

function Write-Tsv($outPath, $tabIdx) {
    $hdrRow = Parse-MdRow $lines[$tabs[$tabIdx].HeaderLine]
    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add(($hdrRow -join "`t"))
    for ($i = $tabs[$tabIdx].DataStart; $i -le $tabs[$tabIdx].DataEnd; $i++) {
        $r = Parse-MdRow $lines[$i]
        if ($r -eq $null) { continue }
        while ($r.Count -lt $hdrRow.Count) { $r += '' }
        $rows.Add(($r -join "`t"))
    }
    [System.IO.File]::WriteAllLines($outPath, $rows, [System.Text.UTF8Encoding]::new($false))
    Write-Output ("  Wrote " + ($rows.Count - 1) + " data rows to " + (Split-Path $outPath -Leaf))
}

# Write each Vini tab and each Payment tab to its own file
$idx = 0
foreach ($t in $viniTabs) {
    $idx++
    Write-Tsv "$outDir\vini_$idx.tsv" $t
}
$idx = 0
foreach ($t in $payTabs) {
    $idx++
    Write-Tsv "$outDir\payment_$idx.tsv" $t
}
