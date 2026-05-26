$ErrorActionPreference = 'Stop'
$srcFile = "$env:USERPROFILE\.claude\projects\C--Users-Anshu-Kumar-Documents-Claude\a89d2803-abac-4efe-9e24-d4b60eb67b02\tool-results\mcp-cf38d8bc-2a26-44e5-bc0f-60ac41ba183e-read_file_content-1779566609198.txt"
$outDir = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework"

$obj = Get-Content -Raw $srcFile | ConvertFrom-Json
$text = $obj.fileContent
$lines = $text -split "`n"

# Helper to strip markdown table pipes and unescape
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

# Section 1: gid=1616842841 part A  (L2..L86, header at L0, separator at L1)
# Section 3: gid=1616842841 part B  (L210..L291, header at L208, separator at L209)
# Section 2: gid=674556270 Payment  (L90..L206, header at L88, separator at L89)

$viniHeaderA = Parse-MdRow $lines[0]
$viniHeaderB = Parse-MdRow $lines[208]
$payHeader   = Parse-MdRow $lines[88]

Write-Output ("Vini Header A cols: " + $viniHeaderA.Count)
Write-Output ("Vini Header B cols: " + $viniHeaderB.Count)
Write-Output ("Payment Header cols: " + $payHeader.Count)
Write-Output ""
Write-Output "Vini Header A:"; $viniHeaderA | ForEach-Object { Write-Output ("  - " + $_) }
Write-Output ""
Write-Output "Vini Header B:"; $viniHeaderB | ForEach-Object { Write-Output ("  - " + $_) }
Write-Output ""
Write-Output "Payment Header:"; $payHeader | ForEach-Object { Write-Output ("  - " + $_) }

# Write raw parsed data to TSV for processing
function Write-Tsv($outPath, $header, $startLine, $endLine) {
    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add(($header -join "`t"))
    for ($i = $startLine; $i -le $endLine; $i++) {
        $r = Parse-MdRow $lines[$i]
        if ($r -eq $null) { continue }
        # Pad if short
        while ($r.Count -lt $header.Count) { $r += '' }
        $rows.Add(($r -join "`t"))
    }
    [System.IO.File]::WriteAllLines($outPath, $rows, [System.Text.UTF8Encoding]::new($false))
    Write-Output ("Wrote " + $rows.Count + " rows to " + $outPath)
}

Write-Tsv "$outDir\vini_a.tsv"  $viniHeaderA 2   86
Write-Tsv "$outDir\vini_b.tsv"  $viniHeaderB 210 291
Write-Tsv "$outDir\payment.tsv" $payHeader   90  206
