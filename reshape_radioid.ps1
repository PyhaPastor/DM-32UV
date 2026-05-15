<#
.SYNOPSIS
    Download radioid.net user.csv and convert it into a digital contact list
    importable by the Baofeng DM-32UV CPS DMR software.

.DESCRIPTION
    Headers and value formats verified against CPS DMR v1.45 export.
    Output is UTF-8 without BOM, CRLF line endings, unquoted values.
    By default, downloads user.csv only if it is missing. Use -Refresh to
    force a re-download.

.PARAMETER InputFile
    Local path for the radioid.net dump. Default: .\user.csv

.PARAMETER OutputFile
    Path to the CSV to be imported into the CPS. Default: .\dm32_contacts.csv

.PARAMETER DownloadUrl
    URL of the radioid.net dump. The ?v= cache-buster is optional.
    Default: https://radioid.net/static/user.csv

.PARAMETER Refresh
    Force re-download even if InputFile already exists.

.PARAMETER NoDownload
    Never download. Fail if InputFile is missing.

.PARAMETER Countries
    Country names to include (matched against the COUNTRY column in the
    radioid.net dump). Pass @() to disable country filtering.

.PARAMETER MaxContacts
    Hard cap on output rows. DM-32UV holds 50,000 max.

.EXAMPLE
    .\reshape_radioid.ps1
    Default run: downloads if needed, filters Baltics + Nordics + Germany.

.EXAMPLE
    .\reshape_radioid.ps1 -Refresh
    Force re-download of the radioid.net dump.

.EXAMPLE
    .\reshape_radioid.ps1 -Countries "Estonia","Finland" -MaxContacts 10000
#>

param(
    [string]$InputFile   = ".\user.csv",
    [string]$OutputFile  = ".\dm32_contacts.csv",
    [string]$DownloadUrl = "https://radioid.net/static/user.csv",
    [switch]$Refresh,
    [switch]$NoDownload,
    [string[]]$Countries = @("Estonia","Finland","Latvia","Lithuania","Sweden","Germany"),
    [int]$MaxContacts    = 50000
)

# --- download radioid.net dump if needed ----------------------------------
$needDownload = $Refresh -or (-not (Test-Path -LiteralPath $InputFile))

if ($needDownload -and $NoDownload) {
    Write-Error "Input file '$InputFile' missing and -NoDownload specified."
    exit 1
}

if ($needDownload) {
    # PS 5.1 defaults to TLS 1.0/1.1; radioid.net wants TLS 1.2+
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    Write-Host "Downloading $DownloadUrl ..."
    try {
        $ProgressPreference = 'SilentlyContinue'   # progress bar slows IWR ~10x in PS 5.1
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $InputFile -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Error "Download failed: $_"
        exit 1
    }
    $sizeMB = ((Get-Item -LiteralPath $InputFile).Length / 1MB).ToString('F1')
    Write-Host "Saved $sizeMB MB to $InputFile"
} else {
    $age = (Get-Date) - (Get-Item -LiteralPath $InputFile).LastWriteTime
    Write-Host ("Using existing {0} (age: {1:N1} days). Use -Refresh to re-download." -f $InputFile, $age.TotalDays)
}

# --- resolve output path --------------------------------------------------
$outDir = Split-Path -Path $OutputFile -Parent
if ([string]::IsNullOrEmpty($outDir)) { $outDir = (Get-Location).Path }
$outDir  = (Resolve-Path -LiteralPath $outDir).Path
$outName = Split-Path -Path $OutputFile -Leaf
$outPath = Join-Path -Path $outDir -ChildPath $outName

# --- country filter -------------------------------------------------------
$countryFilter = $null
if ($Countries -and $Countries.Count -gt 0) {
    $countryFilter = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Countries, [System.StringComparer]::OrdinalIgnoreCase
    )
}

# --- transform ------------------------------------------------------------
# Headers, order, and value types must match what the CPS exports exactly:
# No., ID, Repeater, Name, City, Province, Country, Remark, Type, Alert Call
# Note: 'Repeater' is the callsign column (bad localization).
# Note: 'Alert Call' is an integer (0), NOT the string "None".
$rowNum = 0
$reshaped = Import-Csv -Path $InputFile -Encoding UTF8 | ForEach-Object {
    if ($rowNum -ge $MaxContacts) { return }
    if ($countryFilter -and -not $countryFilter.Contains($_.COUNTRY)) { return }

    $rowNum++
    $name = ("{0} {1}" -f $_.FIRST_NAME, $_.LAST_NAME).Trim()

    [pscustomobject][ordered]@{
        'No.'        = $rowNum
