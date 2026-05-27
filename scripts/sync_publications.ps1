<#
NAS → Hugo Publications Sync (PowerShell)
Scans Publications_SCIE/ and Publications_학진/ on Synology NAS,
generates Hugo markdown entries, copies PDFs.
Pass -Push to commit + push to GitHub.
#>

param([switch]$Push)

$NAS_PUB_ROOT = "C:\Users\USER\SynologyDrive\01_연구\논문"
$SITE_ROOT = "C:\Users\USER\PharmEPI_Website"
$PUB_OUT_DIR = "$SITE_ROOT\content\publications"
$PDF_STATIC_DIR = "$SITE_ROOT\static\pdf"

$SOURCES = @(
    @{ Folder = "Publications_SCIE"; Label = "SCIE" },
    @{ Folder = "Publications_학진"; Label = "Domestic" }
)

New-Item -ItemType Directory -Path $PUB_OUT_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $PDF_STATIC_DIR -Force | Out-Null

$entriesWritten = 0
$seenSlugs = @{}

foreach ($source in $SOURCES) {
    $src = Join-Path $NAS_PUB_ROOT $source.Folder
    $label = $source.Label
    if (-not (Test-Path -LiteralPath $src)) { continue }

    $files = Get-ChildItem -LiteralPath $src -Recurse -File -Filter "*.pdf"
    foreach ($pdf in $files) {
        $stem = $pdf.BaseName

        # Parse filename (inline)
        $date = "2000-01-01"; $year = 2000; $month = 1
        $author = ""; $journal = ""; $topic = $stem

        if ($stem -match '^(\d{6})_([^_]+)_([^_]+(?:_[^_]+)*?)_(.+)$') {
            $yyyymm = $matches[1]
            $year = [int]$yyyymm.Substring(0,4)
            $month = [int]$yyyymm.Substring(4,2)
            $date = "$($yyyymm.Substring(0,4))-$($yyyymm.Substring(4,2))-01"
            $author = $matches[2]
            $journal = ($matches[3] -replace '_', ' ')
            $topic = ($matches[4] -replace '_', ' ')
        } elseif ($stem -match '^(\d{4})_(.+)$') {
            $year = [int]$matches[1]
            $date = "$($matches[1])-01-01"
            $topic = $matches[2]
        }

        # Make slug (inline)
        $slug = $stem.ToLower()
        $slug = $slug -replace '[^\w\s\-가-힣]', ''
        $slug = $slug -replace '[\s_]+', '-'
        $slug = $slug.Trim('-')
        if ($slug.Length -gt 80) { $slug = $slug.Substring(0, 80) }

        $seenSlugs[$slug] = $true

        # Copy PDF
        $destPdf = Join-Path $PDF_STATIC_DIR "$slug.pdf"
        $needCopy = $true
        if (Test-Path -LiteralPath $destPdf) {
            $existing = Get-Item -LiteralPath $destPdf
            if ($existing.LastWriteTime -ge $pdf.LastWriteTime) { $needCopy = $false }
        }
        if ($needCopy) {
            Copy-Item -LiteralPath $pdf.FullName -Destination $destPdf -Force
        }

        # Build summary
        if ($author -and $journal) {
            $summary = "$author et al. - $journal ($year)"
        } elseif ($author) {
            $summary = "$author et al. ($year)"
        } else {
            $summary = "$topic ($year)"
        }

        $authorStr = if ($author) { "$author et al." } else { "Various authors" }
        $journalStr = if ($journal) { "*$journal*" } else { "_(legacy entry)_" }
        $monthStr = if ($month -gt 1) { "-{0:D2}" -f $month } else { "" }

        $tagsLine = "[`"$label`", `"$year`"]"

        # Escape quotes in title/summary
        $titleEsc = $topic -replace '"', '\"'
        $summaryEsc = $summary -replace '"', '\"'

        $md = @"
---
title: "$titleEsc"
date: $date
draft: false
summary: "$summaryEsc"
tags: $tagsLine
categories: ["$label"]
---

**Authors:** $authorStr

**Journal:** $journalStr ($year$monthStr)

**Topic:** $topic

[Download PDF](/pdf/$slug.pdf)
"@

        $out = Join-Path $PUB_OUT_DIR "$slug.md"
        $existingContent = ""
        if (Test-Path -LiteralPath $out) {
            $existingContent = Get-Content -LiteralPath $out -Raw
        }
        if ($existingContent -ne $md) {
            Set-Content -LiteralPath $out -Value $md -Encoding UTF8
            $entriesWritten++
            Write-Host "[write] $slug.md"
        }
    }
}

# Remove obsolete entries
$existingMds = Get-ChildItem -LiteralPath $PUB_OUT_DIR -Filter "*.md"
foreach ($md in $existingMds) {
    if ($md.Name -eq "_index.md") { continue }
    if (-not $seenSlugs.ContainsKey($md.BaseName)) {
        Remove-Item -LiteralPath $md.FullName -Force
        $pdfRemove = Join-Path $PDF_STATIC_DIR "$($md.BaseName).pdf"
        if (Test-Path -LiteralPath $pdfRemove) { Remove-Item -LiteralPath $pdfRemove -Force }
        Write-Host "[remove] $($md.Name)"
    }
}

Write-Host ""
Write-Host "Synced $entriesWritten publications. Total: $($seenSlugs.Count)"

if ($Push) {
    Push-Location $SITE_ROOT
    git add -A
    git diff --cached --quiet
    $hasChanges = $LASTEXITCODE -ne 0
    if ($hasChanges) {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
        git commit -m "auto: sync publications from NAS ($ts)"
        git push
        Write-Host "Pushed to GitHub."
    } else {
        Write-Host "No changes to push."
    }
    Pop-Location
}

