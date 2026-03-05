## Validate all ARG queries in the v2/ARG queries folder
## Runs each .kql file against Azure Resource Graph
## Uses direct az invocation with stderr redirect for proper error detection

$queryDir = Join-Path $PSScriptRoot "ARG queries"
$results = @()

$kqlFiles = Get-ChildItem -Path $queryDir -Filter "*.kql" | Sort-Object Name

foreach ($file in $kqlFiles) {
    $queryText = Get-Content -Path $file.FullName -Raw
    
    # Strip full-line comments
    $cleanLines = ($queryText -split "`n") | Where-Object { $_ -notmatch '^\s*//' }
    # Strip inline comments (// to end-of-line) but preserve :// in URLs
    $cleanLines = $cleanLines | ForEach-Object { $_ -replace '(?<!:)//.*$', '' }
    $cleanQuery = ($cleanLines -join " ").Trim()
    # Collapse multiple spaces
    $cleanQuery = $cleanQuery -replace '\s+', ' '
    # Replace KQL double quotes with single quotes — KQL treats both identically.
    # This prevents embedded " from breaking the PowerShell quoting, which would
    # expose | characters as pipeline operators.
    $cleanQuery = $cleanQuery -replace '"', "'"
    
    Write-Host "Testing: $($file.Name)..." -NoNewline
    
    try {
        $tmpErr = [System.IO.Path]::GetTempFileName()
        
        # Temporarily suppress error-stream display so native stderr doesn't echo
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $stdout = az graph query -q "$cleanQuery" --first 5 -o json 2>$tmpErr
        $ec = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP
        $stderr = Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue
        Remove-Item $tmpErr -ErrorAction SilentlyContinue
        
        if ($ec -eq 0 -and $stdout) {
            $jsonOut = $stdout | Out-String
            $parsed = $jsonOut | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $parsed -and $null -ne $parsed.total_records) {
                $count = $parsed.total_records
                Write-Host " PASS ($count total records)" -ForegroundColor Green
                $results += [PSCustomObject]@{ File = $file.Name; Status = "PASS"; Records = $count; Error = "" }
            } else {
                Write-Host " PASS (OK)" -ForegroundColor Green
                $results += [PSCustomObject]@{ File = $file.Name; Status = "PASS"; Records = 0; Error = "" }
            }
        } else {
            $errMsg = if ($stderr) { $stderr.Trim() } else { "Exit code: $ec" }
            # Extract structured error detail if possible
            try {
                $errJson = $errMsg | ConvertFrom-Json -ErrorAction Stop
                if ($errJson.details) {
                    $errMsg = ($errJson.details | ForEach-Object { "$($_.code): $($_.message)" }) -join " | "
                } elseif ($errJson.message) {
                    $errMsg = $errJson.message
                }
            } catch {}
            if ($errMsg.Length -gt 300) { $errMsg = $errMsg.Substring(0,300) + "..." }
            Write-Host " FAIL" -ForegroundColor Red
            Write-Host "  $errMsg" -ForegroundColor Yellow
            $results += [PSCustomObject]@{ File = $file.Name; Status = "FAIL"; Records = -1; Error = $errMsg }
        }
    } catch {
        Write-Host " ERROR" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        $results += [PSCustomObject]@{ File = $file.Name; Status = "ERROR"; Records = -1; Error = $_.Exception.Message }
    }
}

Write-Host "`n========== RESULTS SUMMARY =========="
$pass = ($results | Where-Object { $_.Status -eq "PASS" }).Count
$fail = ($results | Where-Object { $_.Status -ne "PASS" }).Count
Write-Host "Total: $($results.Count) | Pass: $pass | Fail: $fail"
if ($fail -gt 0) {
    Write-Host ""
    Write-Host "FAILURES:" -ForegroundColor Red
    $results | Where-Object { $_.Status -ne "PASS" } | ForEach-Object { Write-Host "  $($_.File): $($_.Error)" -ForegroundColor Yellow }
}
Write-Host ""

$results | Format-Table -AutoSize -Property File, Status, Records, Error

$results | ConvertTo-Json -Depth 3 | Out-File (Join-Path $PSScriptRoot "validation-results.json") -Encoding UTF8
Write-Host "Results saved to validation-results.json"
