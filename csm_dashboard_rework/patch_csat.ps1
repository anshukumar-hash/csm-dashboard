$ErrorActionPreference = 'Stop'
$dashPath = "C:\Users\Anshu Kumar\Documents\Claude\CSM_Dashboard.html"
$csatPath = "C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework\csat.tsv"
if (-not (Test-Path $csatPath)) { throw "CSAT TSV missing - run extract_csat.ps1 first" }

# ----- Parse CSAT TSV -----
$lines = [System.IO.File]::ReadAllLines($csatPath)
$hdr = $lines[0] -split "`t"
function Idx($n) { return [array]::IndexOf($hdr, $n) }
$iDate=Idx 'date'; $iName=Idx 'company_name'; $iEid=Idx 'company_external_id'
$iCsm=Idx 'csm_name'; $iMeet=Idx 'meeting_csat'; $iThr=Idx 'thread_csat'
$iTkt=Idx 'ticket_csat'; $iCall=Idx 'call_csat'; $iAvg=Idx 'Comm Avg.'

function Parse-CsatDate($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return [datetime]::MinValue }
    try { return [datetime]::ParseExact($s.Trim(), 'd MMM, yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { try { return [datetime]$s } catch { return [datetime]::MinValue } }
}

# Latest-date wins per enterprise (for single-value display in KPI etc.) +
# full history kept in $allByEid so the Rooftop View can show RAG distribution
# across all of that enterprise's CSAT readings.
$byEid  = @{}
$byName = @{}
$allByEid = @{}   # eid -> List of {date, avg, rag}
for ($i = 1; $i -lt $lines.Count; $i++) {
    $c = $lines[$i] -split "`t"
    while ($c.Count -lt $hdr.Count) { $c += '' }
    $eid  = $c[$iEid].Trim(); $name = $c[$iName].Trim(); $date = $c[$iDate].Trim()
    $iso = (Parse-CsatDate $date).ToString('yyyy-MM-dd')
    $avg = $null
    $rawAvg = $c[$iAvg].Trim()
    if (-not [string]::IsNullOrWhiteSpace($rawAvg)) {
        try { $avg = [double]$rawAvg } catch { $avg = $null }
    }
    $rec = @{
        date=$date; date_iso=$iso; avg=$avg
        meeting=$c[$iMeet].Trim(); thread=$c[$iThr].Trim()
        ticket=$c[$iTkt].Trim(); call=$c[$iCall].Trim()
        csm=$c[$iCsm].Trim(); name=$name
    }
    if ($eid) {
        if (-not $byEid.ContainsKey($eid) -or [string]$byEid[$eid].date_iso -lt $iso) { $byEid[$eid] = $rec }
        if (-not $allByEid.ContainsKey($eid)) { $allByEid[$eid] = New-Object System.Collections.Generic.List[hashtable] }
        $allByEid[$eid].Add(@{ date_iso=$iso; avg=$avg })
    }
    if ($name) {
        $k = $name.ToUpper()
        if (-not $byName.ContainsKey($k) -or [string]$byName[$k].date_iso -lt $iso) { $byName[$k] = $rec }
    }
}
Write-Output ("Loaded " + ($lines.Count - 1) + " CSAT rows from $csatPath")
Write-Output ("Distinct enterprises by EID:  " + $byEid.Count)
Write-Output ("Distinct enterprises by Name: " + $byName.Count)

# ----- Build JSON manually (avoid PowerShell serializer issues) -----
function JsEscape($s) {
    if ($s -eq $null) { return 'null' }
    $t = [string]$s
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $t.ToCharArray()) {
        switch ($ch) {
            '\' { [void]$sb.Append('\\') }
            '"' { [void]$sb.Append('\"') }
            "`r" { [void]$sb.Append('\r') }
            "`n" { [void]$sb.Append('\n') }
            "`t" { [void]$sb.Append('\t') }
            default {
                $code = [int]$ch
                if ($code -lt 32) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function RecToJson($rec) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'date','date_iso','meeting','thread','ticket','call','csm','name') {
        $parts.Add((JsEscape $k) + ':' + (JsEscape $rec[$k]))
    }
    $avgStr = if ($rec.avg -eq $null) { 'null' } else { [string]$rec.avg }
    $parts.Add((JsEscape 'avg') + ':' + $avgStr)
    return '{' + ($parts -join ',') + '}'
}
function DictToJson($dict) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $dict.Keys) {
        $parts.Add((JsEscape $k) + ':' + (RecToJson $dict[$k]))
    }
    return '{' + ($parts -join ',') + '}'
}
$jsonEid  = DictToJson $byEid
$jsonName = DictToJson $byName
# Build csat_all_by_eid = { eid: [ {date,avg,rag}, ... ] }
function AllToJson($all) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($k in $all.Keys) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($r in $all[$k]) {
            $a = $r.avg
            $rag = 'NA'
            if ($a -ne $null) {
                if ($a -lt 2.5) { $rag = 'Red' }
                elseif ($a -lt 4) { $rag = 'Amber' }
                else { $rag = 'Green' }
            }
            $avgStr = if ($a -eq $null) { 'null' } else { [string]$a }
            $items.Add('{' + (JsEscape 'date_iso') + ':' + (JsEscape $r.date_iso) + ',' + (JsEscape 'avg') + ':' + $avgStr + ',' + (JsEscape 'rag') + ':' + (JsEscape $rag) + '}')
        }
        $parts.Add((JsEscape $k) + ':[' + ($items -join ',') + ']')
    }
    return '{' + ($parts -join ',') + '}'
}
$jsonAllEid = AllToJson $allByEid
Write-Output ("csat_by_eid JSON length:     " + $jsonEid.Length)
Write-Output ("csat_by_name JSON length:    " + $jsonName.Length)
Write-Output ("csat_all_by_eid JSON length: " + $jsonAllEid.Length)

# ----- Patch dashboard: replace or insert the two csat keys -----
$htmlLines = [System.IO.File]::ReadAllLines($dashPath)
$dlIdx = -1
for ($i = 0; $i -lt $htmlLines.Count; $i++) {
    if ($htmlLines[$i] -match 'window\.__DASHBOARD_DATA__\s*=') { $dlIdx = $i; break }
}
$prefix = "window.__DASHBOARD_DATA__ = "
$dl = $htmlLines[$dlIdx]
$json = $dl.Substring($dl.IndexOf("{")).TrimEnd(';').Trim()

# Strip existing csat keys via regex matching of the structure
$pattern = ',"csat_by_eid":\{[^\}]*\}(\{[^\}]*\})*,"csat_by_name":\{[^\}]*\}(\{[^\}]*\})*'
# Simpler: regex with brace-balancing is hard. Use a substring approach instead.
function StripKey($s, $key) {
    $marker = '"' + $key + '":{'
    $start = $s.IndexOf($marker)
    if ($start -lt 0) { return $s }
    # Walk braces to find matching close
    $depth = 0
    $i = $start + $marker.Length - 1  # position of opening brace
    while ($i -lt $s.Length) {
        $ch = $s[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { $end = $i; break }
        }
        $i++
    }
    # Strip from preceding comma (if any) through end of value
    $stripStart = $start
    if ($start -gt 0 -and $s[$start-1] -eq ',') { $stripStart = $start - 1 }
    elseif ($s[$end+1] -eq ',') { $end = $end + 1 }
    return $s.Substring(0, $stripStart) + $s.Substring($end + 1)
}
$json = StripKey $json 'csat_by_eid'
$json = StripKey $json 'csat_by_name'
$json = StripKey $json 'csat_all_by_eid'

# Insert before final }
$lastBrace = $json.LastIndexOf('}')
$inserted = ',"csat_by_eid":' + $jsonEid + ',"csat_by_name":' + $jsonName + ',"csat_all_by_eid":' + $jsonAllEid
$json = $json.Substring(0, $lastBrace) + $inserted + $json.Substring($lastBrace)

$htmlLines[$dlIdx] = $prefix + $json + ';'
[System.IO.File]::WriteAllLines($dashPath, $htmlLines, [System.Text.UTF8Encoding]::new($false))
Write-Output ("Patched dashboard: " + $dashPath)

# ----- QA -----
$rag = @{ Green=0; Amber=0; Red=0; NA=0 }
foreach ($v in $byEid.Values) {
    $a = $v.avg
    if ($a -eq $null) { $rag.NA++ }
    elseif ($a -lt 2.5) { $rag.Red++ }
    elseif ($a -lt 4)   { $rag.Amber++ }
    else { $rag.Green++ }
}
Write-Output ""
Write-Output "=== CSAT RAG distribution (across $($byEid.Count) enterprises) ==="
Write-Output ("Green : " + $rag.Green)
Write-Output ("Amber : " + $rag.Amber)
Write-Output ("Red   : " + $rag.Red)
Write-Output ("NA    : " + $rag.NA)

# Match vs Payment-scope (Vini master)
$payEids = New-Object System.Collections.Generic.HashSet[string]
$payLines = [System.IO.File]::ReadAllLines("C:\Users\Anshu Kumar\Documents\Claude\csm_dashboard_rework\payment_1.tsv")
$payHdr = $payLines[0] -split "`t"
$payEidIdx = [array]::IndexOf($payHdr, 'Enterprise ID')
for ($i = 1; $i -lt $payLines.Count; $i++) {
    $c = $payLines[$i] -split "`t"
    if ($c.Count -gt $payEidIdx) { [void]$payEids.Add($c[$payEidIdx].Trim()) }
}
$matched = 0
foreach ($k in $byEid.Keys) { if ($payEids.Contains($k)) { $matched++ } }
$payMissingCsat = 0
foreach ($k in $payEids) { if (-not $byEid.ContainsKey($k)) { $payMissingCsat++ } }
Write-Output ""
Write-Output "=== Match against Vini Payment master ==="
Write-Output ("Vini-scope enterprises             : " + $payEids.Count)
Write-Output ("Vini enterprises with CSAT score   : " + $matched)
Write-Output ("Vini enterprises WITHOUT CSAT (NA) : " + $payMissingCsat)
