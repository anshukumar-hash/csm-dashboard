$ErrorActionPreference = 'Stop'
$cacheDir = "$env:USERPROFILE\.claude\projects\C--Users-Anshu-Kumar-Documents-Claude\a89d2803-abac-4efe-9e24-d4b60eb67b02\tool-results"
$srcFile = Get-ChildItem $cacheDir -Filter "mcp-cf38d8bc*read_file_content*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$outDir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"

$obj = Get-Content -Raw $srcFile.FullName | ConvertFrom-Json
$text = $obj.fileContent
$lines = $text -split "`n"

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

# Find CSAT tab: header has 'company_external_id' and 'Comm Avg.'
$csatHdrLine = -1
for ($i = 0; $i -lt $lines.Count - 1; $i++) {
    if ($lines[$i] -match 'company..?external..?id' -and $lines[$i] -match 'Comm\s+Avg') {
        $csatHdrLine = $i
        break
    }
}
if ($csatHdrLine -lt 0) { throw "CSAT tab header not found" }

# Find next blank or different-shaped row = end of tab
$dataStart = $csatHdrLine + 2
$dataEnd = $dataStart
for ($i = $dataStart; $i -lt $lines.Count; $i++) {
    if ([string]::IsNullOrWhiteSpace($lines[$i])) { break }
    if (-not $lines[$i].StartsWith('|')) { break }
    $dataEnd = $i
}

Write-Output ("CSAT header at L$csatHdrLine, data L$dataStart..L$dataEnd (" + ($dataEnd - $dataStart + 1) + " rows)")
$header = Parse-MdRow $lines[$csatHdrLine]
Write-Output ("Cols: " + ($header -join ' | '))

$rows = New-Object System.Collections.Generic.List[string]
$rows.Add(($header -join "`t"))
for ($i = $dataStart; $i -le $dataEnd; $i++) {
    $r = Parse-MdRow $lines[$i]
    if ($r -eq $null) { continue }
    while ($r.Count -lt $header.Count) { $r += '' }
    $rows.Add(($r -join "`t"))
}
[System.IO.File]::WriteAllLines("$outDir\csat.tsv", $rows, [System.Text.UTF8Encoding]::new($false))
Write-Output ("Wrote " + ($rows.Count - 1) + " data rows to csat.tsv")
