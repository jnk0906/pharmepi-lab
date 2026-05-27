"""
NAS → Hugo Publications Sync Script
====================================

Scans Publications_SCIE/ and Publications_학진/ on the Synology NAS,
parses YYYYMM_Author_Journal_Topic.pdf filenames, and generates Hugo
markdown entries under content/publications/.

After generating files, commits + pushes to GitHub. Netlify rebuilds
the live site automatically.

Usage:
    python sync_publications.py

Schedule with Windows Task Scheduler to run daily/hourly.
"""

import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

# ---- Configuration ----
NAS_PUB_ROOT = Path(r"C:\Users\USER\SynologyDrive\01_연구\논문")
SITE_ROOT = Path(r"C:\Users\USER\PharmEPI_Website")
PUB_OUT_DIR = SITE_ROOT / "content" / "publications"
PDF_STATIC_DIR = SITE_ROOT / "static" / "pdf"
COMMIT_MSG = "auto: sync publications from NAS"

SOURCES = [
    ("Publications_SCIE", "SCIE"),
    ("Publications_학진", "Domestic"),
]

# ---- Filename Parsing ----
# Examples:
#   202604_Jeon_BMC_InfDis_CAPA.pdf  →  date=2026-04, author=Jeon, journal=BMC_InfDis, topic=CAPA
#   2019_AKI prediction model.pdf    →  date=2019,    topic=AKI prediction model
NEW_FORMAT = re.compile(r"^(?P<yyyymm>\d{6})_(?P<author>[^_]+)_(?P<journal>[^_]+(?:_[^_]+)*?)_(?P<topic>.+)$")
OLD_FORMAT = re.compile(r"^(?P<year>\d{4})_(?P<topic>.+)$")


def parse_filename(stem: str):
    """Parse a publication PDF filename into structured fields."""
    m = NEW_FORMAT.match(stem)
    if m:
        yyyymm = m.group("yyyymm")
        return {
            "date": f"{yyyymm[:4]}-{yyyymm[4:6]}-01",
            "year": int(yyyymm[:4]),
            "month": int(yyyymm[4:6]),
            "author": m.group("author"),
            "journal": m.group("journal").replace("_", " "),
            "topic": m.group("topic").replace("_", " "),
        }
    m = OLD_FORMAT.match(stem)
    if m:
        return {
            "date": f"{m.group('year')}-01-01",
            "year": int(m.group("year")),
            "month": 1,
            "author": "",
            "journal": "",
            "topic": m.group("topic"),
        }
    # Fallback for unrecognized formats
    return {
        "date": "2000-01-01",
        "year": 2000,
        "month": 1,
        "author": "",
        "journal": "",
        "topic": stem,
    }


def make_slug(stem: str) -> str:
    """Generate a URL-safe slug from the filename stem."""
    s = re.sub(r"[^\w\s-]", "", stem.lower())
    s = re.sub(r"[\s_]+", "-", s).strip("-")
    return s[:80]


def generate_entry(pdf_path: Path, source_label: str) -> dict:
    """Build the markdown content for one publication."""
    stem = pdf_path.stem
    parsed = parse_filename(stem)
    slug = make_slug(stem)

    # Copy PDF into static/pdf so it can be served
    PDF_STATIC_DIR.mkdir(parents=True, exist_ok=True)
    dest_pdf = PDF_STATIC_DIR / f"{slug}.pdf"
    if not dest_pdf.exists() or dest_pdf.stat().st_mtime < pdf_path.stat().st_mtime:
        shutil.copy2(pdf_path, dest_pdf)

    title = parsed["topic"]
    if parsed["author"]:
        title_full = f"{parsed['topic']}"
    else:
        title_full = parsed["topic"]

    summary_parts = []
    if parsed["author"]:
        summary_parts.append(f"{parsed['author']} et al.")
    if parsed["journal"]:
        summary_parts.append(f"*{parsed['journal']}*")
    summary_parts.append(f"({parsed['year']})")
    summary = " — ".join([" ".join(summary_parts[:2]), summary_parts[-1]]) if len(summary_parts) > 1 else summary_parts[0]

    md = f"""---
title: "{title_full}"
date: {parsed['date']}
draft: false
summary: "{summary}"
tags: ["{source_label}", "{parsed['year']}"]
categories: ["{source_label}"]
authors: ["{parsed['author']}"] if parsed['author'] else []
---

**Authors:** {parsed['author']} et al.

**Journal:** *{parsed['journal']}* ({parsed['year']}{f'-{parsed["month"]:02d}' if parsed['month'] > 1 else ''})

**Topic:** {parsed['topic']}

📄 [Download PDF](/pdf/{slug}.pdf)
"""
    return {"slug": slug, "md": md, "parsed": parsed}


def sync():
    """Main sync routine."""
    PUB_OUT_DIR.mkdir(parents=True, exist_ok=True)
    entries_written = 0
    seen_slugs = set()

    for folder_name, source_label in SOURCES:
        src = NAS_PUB_ROOT / folder_name
        if not src.exists():
            print(f"[skip] {src} not found")
            continue

        for pdf in src.rglob("*.pdf"):
            entry = generate_entry(pdf, source_label)
            seen_slugs.add(entry["slug"])
            out = PUB_OUT_DIR / f"{entry['slug']}.md"

            # Only write if content changed
            new_content = entry["md"]
            if out.exists() and out.read_text(encoding="utf-8") == new_content:
                continue
            out.write_text(new_content, encoding="utf-8")
            entries_written += 1
            print(f"[write] {out.name}")

    # Remove obsolete entries (PDFs that no longer exist)
    for md_file in PUB_OUT_DIR.glob("*.md"):
        if md_file.name == "_index.md":
            continue
        if md_file.stem not in seen_slugs:
            md_file.unlink()
            pdf_to_remove = PDF_STATIC_DIR / f"{md_file.stem}.pdf"
            if pdf_to_remove.exists():
                pdf_to_remove.unlink()
            print(f"[remove] {md_file.name}")

    print(f"\nSynced {entries_written} new/updated publications.")
    return entries_written


def git_push():
    """Commit and push changes to GitHub."""
    try:
        subprocess.run(["git", "add", "-A"], cwd=SITE_ROOT, check=True)
        result = subprocess.run(
            ["git", "diff", "--cached", "--quiet"],
            cwd=SITE_ROOT,
        )
        if result.returncode == 0:
            print("No changes to commit.")
            return
        ts = datetime.now().strftime("%Y-%m-%d %H:%M")
        msg = f"{COMMIT_MSG} ({ts})"
        subprocess.run(["git", "commit", "-m", msg], cwd=SITE_ROOT, check=True)
        subprocess.run(["git", "push"], cwd=SITE_ROOT, check=True)
        print(f"Pushed: {msg}")
    except subprocess.CalledProcessError as e:
        print(f"Git operation failed: {e}")


if __name__ == "__main__":
    sync()
    git_push()
