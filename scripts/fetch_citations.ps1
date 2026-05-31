<#
Fetch full AMA citations from Crossref.

Strategy:
  1. Extract DOI from PDF bytes (most reliable)
  2. If found, query Crossref by DOI for exact metadata
  3. If not found, fallback to title+author+year query (best-effort)
  4. Cache in data/citations.json so we don't re-query each run
#>

param([switch]$Force)

$NAS_PUB_ROOT = "C:\Users\USER\SynologyDrive\01_연구\논문"
$SITE_ROOT = "C:\Users\USER\PharmEPI_Website"
$CACHE_FILE = "$SITE_ROOT\data\citations.json"

$SOURCES = @(
    @{ Folder = "Publications_SCIE"; Label = "SCIE" },
    @{ Folder = "Publications_학진"; Label = "Domestic" }
)

# Load existing cache
$cache = @{}
if ((Test-Path -LiteralPath $CACHE_FILE) -and -not $Force) {
    try {
        $obj = Get-Content -LiteralPath $CACHE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
        $obj.PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value }
        Write-Host "Loaded cache: $($cache.Count) entries"
    } catch {
        Write-Host "Cache load failed; starting fresh"
    }
}

New-Item -ItemType Directory -Path (Split-Path $CACHE_FILE) -Force | Out-Null

function Make-Slug($stem) {
    $s = $stem.ToLower()
    $s = $s -replace '[^\w\s\-가-힣]', ''
    $s = $s -replace '[\s_]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80) }
    return $s
}

function Extract-DOI($pdfPath) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($pdfPath)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $patterns = @(
            'doi\.org/(10\.\d{4,9}/[-._;()/:A-Za-z0-9]+)',
            'DOI:?\s*(10\.\d{4,9}/[-._;()/:A-Za-z0-9]+)',
            'doi:\s*(10\.\d{4,9}/[-._;()/:A-Za-z0-9]+)'
        )
        foreach ($p in $patterns) {
            if ($text -match $p) {
                $doi = $matches[1] -replace '[)\.,;]+$', ''
                # Clean trailing parens or stray chars
                $doi = $doi -replace '\.pdf$', ''
                return $doi
            }
        }
    } catch {
        Write-Host "  [pdf-read error] $($_.Exception.Message)"
    }
    return $null
}

function Get-CrossrefByDOI($doi) {
    $url = "https://api.crossref.org/works/$doi"
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "PharmEPI-LAB-Website/1.0 (mailto:njeon@pusan.ac.kr)" } -TimeoutSec 15
        return $resp.message
    } catch {
        Write-Host "  [Crossref DOI lookup failed] $($_.Exception.Message)"
        return $null
    }
}

function Build-Entry($item, $label) {
    $authors = @()
    if ($item.author) {
        foreach ($a in $item.author) {
            $given = ""
            if ($a.given) {
                # AMA: surname + initials (no periods, no spaces)
                $initials = ($a.given -split '[\s\-\.]+' | Where-Object { $_ }) | ForEach-Object {
                    if ($_.Length -gt 0) { $_.Substring(0,1).ToUpper() }
                }
                $given = ($initials -join '')
            }
            $family = $a.family
            if ($family) {
                $authors += if ($given) { "$family $given" } else { $family }
            }
        }
    }
    $title = if ($item.title) { ($item.title[0] -replace '\s+', ' ').Trim() } else { "" }
    $journal = if ($item.'container-title') { $item.'container-title'[0] } else { "" }
    $journalShort = if ($item.'short-container-title') { $item.'short-container-title'[0] } else { $journal }
    $year = $null
    if ($item.'published-print' -and $item.'published-print'.'date-parts') {
        $year = $item.'published-print'.'date-parts'[0][0]
    } elseif ($item.'published-online' -and $item.'published-online'.'date-parts') {
        $year = $item.'published-online'.'date-parts'[0][0]
    } elseif ($item.issued -and $item.issued.'date-parts') {
        $year = $item.issued.'date-parts'[0][0]
    }

    return @{
        matched = $true
        title = $title
        authors = $authors
        journal = $journal
        journalShort = $journalShort
        year = $year
        volume = $item.volume
        issue = $item.issue
        pages = $item.page
        doi = $item.DOI
        label = $label
    }
}

$processed = 0
$matched = 0
$doiFound = 0

foreach ($source in $SOURCES) {
    $src = Join-Path $NAS_PUB_ROOT $source.Folder
    if (-not (Test-Path -LiteralPath $src)) { continue }

    $files = Get-ChildItem -LiteralPath $src -Recurse -File -Filter "*.pdf"
    foreach ($pdf in $files) {
        $stem = $pdf.BaseName
        $slug = Make-Slug $stem
        $processed++

        if ($cache.ContainsKey($slug) -and -not $Force) {
            $entry = $cache[$slug]
            if ($entry.matched) { $matched++ }
            continue
        }

        Write-Host "[scan] $stem"
        $doi = Extract-DOI $pdf.FullName

        if ($doi) {
            $doiFound++
            Write-Host "  DOI: $doi"
            $item = Get-CrossrefByDOI $doi
            Start-Sleep -Milliseconds 500
            if ($item) {
                $entry = Build-Entry $item $source.Label
                $cache[$slug] = $entry
                $matched++
                Write-Host "  [matched] $($entry.title)"
                continue
            }
        }

        # Fallback: record raw filename info
        $year = $null; $author = ""; $journal = ""; $topic = $stem
        if ($stem -match '^(\d{6})_([^_]+)_([^_]+(?:_[^_]+)*?)_(.+)$') {
            $year = [int]$matches[1].Substring(0,4)
            $author = $matches[2]
            $journal = ($matches[3] -replace '_', ' ')
            $topic = ($matches[4] -replace '_', ' ')
        } elseif ($stem -match '^(\d{4})_(.+)$') {
            $year = [int]$matches[1]
            $topic = $matches[2]
        }
        Write-Host "  no DOI; using filename"
        $cache[$slug] = @{
            matched = $false
            title = $topic
            authors = if ($author) { @($author) } else { @() }
            journal = $journal
            year = $year
            label = $source.Label
        }
    }
}

# Save cache
$cache | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $CACHE_FILE -Encoding UTF8
Write-Host ""
Write-Host "Processed: $processed | DOIs found: $doiFound | Matched: $matched | Cache: $($cache.Count)"

