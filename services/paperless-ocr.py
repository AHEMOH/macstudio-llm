#!/usr/bin/env python3
"""paperless-ocr — Apple-Vision searchable-PDF service for paperless-ngx.

Runs on the Mac (Apple Vision is macOS-only). Two independent loops share one OCR
core and a small paperless-ngx REST client:

  * gateway  — watch PAPERLESS_OCR_INBOX; OCR each new file; upload the searchable
               PDF to paperless; keep the pristine original in PAPERLESS_OCR_ARCHIVE.
               `<INBOX>/<DUPLEX_SUBDIR>` and `<INBOX>/<BATCH_SUBDIR>` are JOB folders:
               every file in them belongs to ONE document (fronts + backs interleaved for
               a simplex ADF, or plain concatenation). Jam-split fragments just add up;
               ambiguous jobs wait for a dashboard confirmation (status/command JSON).
  * retrofix — poll paperless for documents carrying PAPERLESS_OCR_TRIGGER_TAG;
               download the original, OCR it, re-upload as a new (searchable) copy,
               then retag the old document PAPERLESS_OCR_SUPERSEDED_TAG. A doc that
               already has a good text layer (digital-born) is left alone — only the
               trigger tag is cleared — so a whole mail source can be auto-tagged safely.

Digital-born PDFs (already carry a text layer, e.g. an emailed report/invoice) are
passed through UNTOUCHED; only scans/images (no text) are rasterized + Apple-Vision-OCR'd.

Apple Vision is the primary engine (best on printed text — fast, tiny RAM, exact) but it
is blind to faint handwriting and breaks math. So a VLM FALLBACK route (Gemma-4 via the
LiteLLM gateway) kicks in either automatically (when Vision reads suspiciously little) or
on demand (paperless tag PAPERLESS_OCR_VLM_TAG, or an inbox filename containing "_vlm").
The VLM has no per-word boxes, so its transcription is laid down as one invisible full-page
layer. See docs/ocr-benchmark.md for why this split (VLMs loop on dense tables; Vision
can't read handwriting).

OCR core (`ocr_pdf`): PyMuPDF renders each page to an image, `ocrmac` runs Apple
Vision (VNRecognizeTextRequest, "accurate") returning Unicode text + bounding boxes,
and the page is REBUILT as image + an INVISIBLE text layer (render_mode=3) with an
embedded Cyrillic-capable font. Rebuilding (rather than overlaying onto the source)
guarantees exactly one, clean text layer — any pre-existing garbled OCR layer (e.g.
Tesseract mojibake on scanned Cyrillic) is dropped, not mixed in. PyMuPDF writes a
correct ToUnicode CMap, so the result is genuinely searchable (unlike
ocrmypdf-appleocr, which emits mojibake for Cyrillic).

Runs from its own venv (needs `ocrmac`, `pymupdf`, `requests`). All config comes from
macstudio.conf via the wrapper's environment. Also usable as a one-shot CLI:

    paperless-ocr.py --ocr INPUT.(pdf|png|jpg) OUTPUT.pdf [--langs ru-RU,en-US]
"""
import base64
import io
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from pathlib import Path

import fitz  # PyMuPDF
import requests
from ocrmac import ocrmac

# --------------------------------------------------------------------------- config
URL = os.environ.get("PAPERLESS_OCR_URL", "").rstrip("/")
TOKEN = os.environ.get("PAPERLESS_OCR_TOKEN", "")
LANGS = [s.strip() for s in os.environ.get("PAPERLESS_OCR_LANGS", "ru-RU,en-US").split(",") if s.strip()]
RECMODE = os.environ.get("PAPERLESS_OCR_RECMODE", "accurate")  # accurate|fast (NOT livetext — headless-broken)
FONT = os.environ.get("PAPERLESS_OCR_FONT", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
DPI = int(os.environ.get("PAPERLESS_OCR_DPI", "300"))  # match a typical 300-dpi scan; 200 misses small text
JPEG_Q = int(os.environ.get("PAPERLESS_OCR_JPEG_Q", "75"))  # embedded page-image JPEG quality
# A PDF that ALREADY has a good text layer (digital-born, e.g. an emailed invoice from a
# report generator) is passed through untouched — rasterizing + re-OCRing it would only
# degrade perfect text. A scan (no text layer) gets Apple Vision OCR. This is the average
# stripped text chars/page above which a PDF counts as digital-born.
TEXT_MIN_CHARS = int(os.environ.get("PAPERLESS_OCR_TEXT_MIN_CHARS", "50"))
# After OCR, ask the LLM for a short descriptive name from the text and use it as BOTH the
# paperless title and the archived-original filename (instead of the scanner's "SCN_0001").
SMART_NAME = os.environ.get("PAPERLESS_OCR_SMART_NAME", "1") == "1"
# Delete archived originals older than this many days (0 = keep forever). The searchable
# copy already lives in paperless; the pristine scan is only kept locally as a safety net.
ARCHIVE_RETENTION_DAYS = int(os.environ.get("PAPERLESS_OCR_ARCHIVE_RETENTION_DAYS", "30"))

BASE = Path(os.environ.get("PAPERLESS_OCR_INBOX", "/Users/mac/paperless-ocr/inbox")).parent
INBOX = Path(os.environ.get("PAPERLESS_OCR_INBOX", str(BASE / "inbox")))
ARCHIVE = Path(os.environ.get("PAPERLESS_OCR_ARCHIVE", str(BASE / "originals")))
ERRORS = Path(os.environ.get("PAPERLESS_OCR_ERRORS", str(BASE / "errors")))
WORK = BASE / "work"

TRIGGER_TAG = os.environ.get("PAPERLESS_OCR_TRIGGER_TAG", "ocr:apple")
# The `*-force` variants re-OCR even when the doc already has a text layer (override the
# digital-born passthrough) — the only way to replace an existing (e.g. Tesseract) layer.
TRIGGER_FORCE_TAG = os.environ.get("PAPERLESS_OCR_TRIGGER_FORCE_TAG", "ocr:apple-force")
VLM_FORCE_TAG = os.environ.get("PAPERLESS_OCR_VLM_FORCE_TAG", "ocr:vlm-force")
DONE_TAG = os.environ.get("PAPERLESS_OCR_DONE_TAG", "ocr:done")
SUPERSEDED_TAG = os.environ.get("PAPERLESS_OCR_SUPERSEDED_TAG", "ocr:superseded")
# Dead-letter tag: applied when a retrofix permanently fails, so the doc isn't
# re-downloaded + re-OCR'd every poll forever (remove it to retry).
ERROR_TAG = os.environ.get("PAPERLESS_OCR_ERROR_TAG", "ocr:error")
DELETE_ORIGINAL = os.environ.get("PAPERLESS_OCR_DELETE_ORIGINAL", "0") == "1"
POLL = int(os.environ.get("PAPERLESS_OCR_POLL_SEC", "60"))
GATEWAY_POLL = min(10, POLL)
# A scanned file (esp. a slow 50-page scan over SMB) must be FULLY written before
# we touch it. A file counts as "settled" only when it has not been modified for
# STABLE_SEC seconds AND no process still holds it open (e.g. smbd mid-transfer).
STABLE_SEC = int(os.environ.get("PAPERLESS_OCR_STABLE_SEC", "30"))
# Double-sided (duplex) support for simplex ADFs (e.g. Canon MAXIFY GX2050): scan the
# fronts, then flip the stack and scan the backs — both passes into the INBOX/<subdir>
# folder. The files are interleaved here into ONE document (backs reversed, like
# paperless-ngx' collate), then OCR'd + uploaded. Needed because paperless' own collate
# is a consume-directory feature, unavailable over the API.
DUPLEX_SUBDIR = os.environ.get("PAPERLESS_OCR_DUPLEX_SUBDIR", "duplex")
DUPLEX_TIMEOUT = int(os.environ.get("PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC", "1800"))
DUPLEX_REVERSE = os.environ.get("PAPERLESS_OCR_DUPLEX_REVERSE", "1") == "1"
# --- Scan JOBS (duplex + stapel folders) ----------------------------------------------
# A jam-prone ADF (the GX2050 swallows pages, finalizes the PDF, the rest is re-scanned)
# turns ONE document into 2-4 fragment files. So the duplex folder is a JOB, not a pair:
# every settled file in it belongs to one document. The fronts/backs split is derived from
# the page counts (both halves must be equal — the split point is unique if it exists); only
# the unambiguous classic case (exactly 2 files, equal pages) runs by itself after a quiet
# period. Everything else is HELD and shown in the dashboard with a proposal for one-click
# confirmation. The dashboard talks to this worker through two JSON files in WORK/ (status
# out, command in) — it never touches the PDFs itself (stdlib-only, no PyMuPDF there).
JOB_QUIET = int(os.environ.get("PAPERLESS_OCR_JOB_QUIET_SEC", "180"))
DUPLEX_AUTO = os.environ.get("PAPERLESS_OCR_DUPLEX_AUTO", "1") == "1"
DROP_BLANK_BACKS = os.environ.get("PAPERLESS_OCR_DUPLEX_DROP_BLANK_BACKS", "1") == "1"
BLANK_MAX_DARK = float(os.environ.get("PAPERLESS_OCR_BLANK_MAX_DARK", "0.0003"))
PAGE_CHECK = os.environ.get("PAPERLESS_OCR_PAGE_CHECK", "1") == "1"
CHECK_TAG = os.environ.get("PAPERLESS_OCR_CHECK_TAG", "scan:check")
BATCH_SUBDIR = os.environ.get("PAPERLESS_OCR_BATCH_SUBDIR", "stapel")
STATUS_FILE = WORK / "scanjob-status.json"
COMMAND_FILE = WORK / "scanjob-command.json"
# Page editor "Arbeitsmappe": a workspace per opened job/file set under WORK/edit/<id>/ —
# sources (moved out of the job folders so nothing auto-processes them, or copied from
# originals/errors), per-page thumbnails + previews rendered here (the dashboard only serves
# the JPEGs), a pages.json manifest, and the committed plan. Kept ARCHIVE_RETENTION_DAYS so a
# scan can be re-edited and re-sent to paperless for a month. Previews are 1600 px wide
# (A4 ~195 dpi) since 2026-11-01 so the editor's 200 % zoom stays legible; more files can be
# added to an open workspace later (ws_add), so every source carries its own moved/origin/
# archived flags (older manifests fall back to the workspace-level values).
EDIT_DIR = WORK / "edit"
WS_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{4}$")
THUMB_W = int(os.environ.get("PAPERLESS_OCR_THUMB_WIDTH", "240"))
PREVIEW_W = int(os.environ.get("PAPERLESS_OCR_PREVIEW_WIDTH", "1600"))
# Per-page AI suggestion ("KI-Vorschlag") for an editor workspace: ONE Apple Vision pass per
# page — its box ORDER gives the orientation (the text itself is orientation-independent at
# 'accurate', measured 2026-11-01), the printed page numbers
# (same regexes as _page_check) order the numbered pages deterministically; ONE text call to
# the LLM only contributes document boundaries and positions for pages WITHOUT a number.
# Measured 2026-11-01 (main-fast, synthetic DE pages): asking gemma for the whole
# permutation returned INCOMPLETE lists in 2 of 3 runs — hence the split of responsibilities.
ANALYZE_MODEL = os.environ.get("PAPERLESS_OCR_ANALYZE_MODEL", "main-fast")
# "accurate" by default: Vision's "fast" level only knows en/fr/it/de/es/pt — with ru-RU in LANGS
# it raises, and Cyrillic pages would score garbage in both orientations anyway.
ANALYZE_RECMODE = os.environ.get("PAPERLESS_OCR_ANALYZE_RECMODE", "accurate")
ANALYZE_DPI = int(os.environ.get("PAPERLESS_OCR_ANALYZE_DPI", "150"))
ANALYZE_LLM = os.environ.get("PAPERLESS_OCR_ANALYZE_LLM", "1") == "1"
# MOTD: a short status block at SSH login (held jobs, errors, last result) with a link into
# the dashboard. Written as a flag file for motd-compose.sh, same mechanism the weekly
# autoupdate uses for its "ACTION NEEDED" block.
DASHBOARD_PORT = os.environ.get("DASHBOARD_PORT", "8090")
MOTD_STATUS_FILE = Path("/var/macstudio/paperless-ocr-status")
MOTD_COMPOSE = "/usr/local/sbin/motd-compose.sh"

# --- VLM fallback route (Gemma-4 via the LiteLLM gateway) -----------------------------
# Apple Vision is the best engine for PRINTED documents (fast, tiny RAM, exact) but it is
# BLIND to faint pencil handwriting and breaks math symbols (∀→"Kk", ℕ→"IN"). A large
# vision LLM (the already-loaded `main`/Gemma-4) reads handwriting + math well but LOOPS on
# dense tables — so it is NOT a replacement, only a fallback for the docs Vision can't read.
# Benchmark: see docs/ocr-benchmark.md. Two ways to route a doc to the VLM:
#   * AUTO   — after Vision, if the recognized text is suspiciously sparse (< VLM_MIN_CHARS
#              chars/page, i.e. a form/handwriting Vision couldn't read), re-do with the VLM.
#   * MANUAL — tag a paperless doc PAPERLESS_OCR_VLM_TAG (retro-fix), or name an inbox file
#              with "_vlm" in it (gateway), to FORCE the VLM route.
# The VLM gives no per-word boxes, so its text is laid down as one INVISIBLE full-page layer
# (searchable, but not positioned per word). Gateway/dense-blank pages can make the VLM
# hallucinate — keep VLM_MIN_CHARS modest and rely mainly on the tag for control.
VLM_AUTO = os.environ.get("PAPERLESS_OCR_VLM_AUTO", "1") == "1"
VLM_MODEL = os.environ.get("PAPERLESS_OCR_VLM_MODEL", "main-fast")
VLM_URL = os.environ.get("PAPERLESS_OCR_VLM_URL", "http://127.0.0.1:11434/v1/chat/completions")
VLM_TAG = os.environ.get("PAPERLESS_OCR_VLM_TAG", "ocr:vlm")
VLM_MIN_CHARS = int(os.environ.get("PAPERLESS_OCR_VLM_MIN_CHARS", "80"))
VLM_MAX_TOKENS = int(os.environ.get("PAPERLESS_OCR_VLM_MAX_TOKENS", "4000"))
VLM_TIMEOUT = int(os.environ.get("PAPERLESS_OCR_VLM_TIMEOUT_SEC", "300"))
VLM_PROMPT = os.environ.get(
    "PAPERLESS_OCR_VLM_PROMPT",
    "Transkribiere den GESAMTEN Text dieses Dokumentseiten-Bildes exakt, auch "
    "handschriftliche Eintraege. Gib mathematische Formeln als LaTeX aus. Nur die "
    "Transkription, keine Kommentare.")

# --- Pictures without text (drawings/paintings, photos, graphics) ----------------------
# When Vision reads (almost) nothing, ONE vision call first asks the VLM whether the page is
# a picture or a document. A picture gets an invisible "Bildbeschreibung: …" layer instead of
# a pointless transcription, a short title, and the tag PICTURE_TAG_PREFIX + kind
# (bild:zeichnung|foto|grafik) for paperless workflows to map onto type/person. A document
# (handwriting, forms) takes the VLM transcription route as before. Forced VLM routes skip it.
PICTURE_DETECT = os.environ.get("PAPERLESS_OCR_PICTURE_DETECT", "1") == "1"
PICTURE_TAG_PREFIX = os.environ.get("PAPERLESS_OCR_PICTURE_TAG_PREFIX", "bild:")
PICTURE_KINDS = ("zeichnung", "foto", "grafik")

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp"}
ACCEPT_EXTS = {".pdf"} | IMAGE_EXTS


def log(msg):
    # Timestamped so intermittent failures (e.g. the sporadic docs.home.arpa DNS
    # misses seen 2026-11) can be placed in time — the log used to have none.
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [paperless-ocr] {msg}", flush=True)


# ------------------------------------------------------------------------- OCR core
_ocr_font = None


def _get_ocr_font():
    """Cached fitz.Font for the embedded OCR font — used to measure text width so each
    observation's font can be fitted to its box (see _overlay)."""
    global _ocr_font
    if _ocr_font is None:
        _ocr_font = fitz.Font(fontfile=FONT)
    return _ocr_font


def _overlay(page, pix):
    """OCR a page's rendered pixmap with Apple Vision and overlay invisible Unicode
    text onto `page` (which is sized in points and already shows the image).
    Returns the number of text observations placed."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False, dir=str(WORK)) as tf:
        tmp = tf.name
        tf.write(pix.tobytes("png"))
    try:
        ann = ocrmac.OCR(tmp, recognition_level=RECMODE, language_preference=LANGS).recognize()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass

    # Embed the Cyrillic-capable font once for this page.
    page.insert_font(fontname="ocrf", fontfile=FONT)
    font = _get_ocr_font()
    W, H = page.rect.width, page.rect.height
    placed = 0
    for text, _conf, bbox in ann:
        s = text.strip()
        if not s:
            continue
        # Vision bbox: normalized (x, y, w, h), origin bottom-left. Flip to top-left.
        x, y, w, h = bbox
        rx0 = x * W
        rx1 = (x + w) * W
        ry0 = (1.0 - (y + h)) * H
        ry1 = (1.0 - y) * H
        boxw = max(1.0, rx1 - rx0)
        boxh = max(1.0, ry1 - ry0)
        # Fit the font to the box WIDTH (capped by height), so the whole observation stays
        # inside its box. Sizing from height alone let wide lines overrun the page edge, where
        # the overflow glyphs were CLIPPED — get_text() (how paperless indexes) then returned
        # truncated, scrambled words ("Gewürzmischu", "Sahnejogh"). A trailing space keeps
        # adjacent boxes from fusing into one token on extraction.
        st = s + " "
        w1 = font.text_length(st, fontsize=1) or 1.0
        fs = max(1.0, min(boxh * 0.95, boxw / w1))
        try:
            # render_mode=3 => invisible (searchable/selectable but not drawn).
            page.insert_text((rx0, ry1 - (ry1 - ry0) * 0.2), st,
                             fontname="ocrf", fontsize=fs, render_mode=3)
            placed += 1
        except Exception:
            pass  # a single bad glyph/box must not fail the page
    return placed


def _already_has_text(pdf_path):
    """True if a PDF already carries a usable text layer (digital-born) — averaged over
    pages, so a blank scan (~0 chars) is OCR'd but a real text PDF is left alone."""
    try:
        d = fitz.open(str(pdf_path))
    except Exception:
        return False
    try:
        if not d.is_pdf:
            return False
        pages = d.page_count or 1
        total = sum(len(p.get_text().strip()) for p in d)
        return (total / pages) >= TEXT_MIN_CHARS
    finally:
        d.close()


def make_searchable(src, dst, use_vlm=False, force=False, meta=None):
    """Produce a searchable PDF at `dst`. Returns (mode, count) where mode is
    'passthrough' | 'ocr' | 'vlm' | 'picture'. For 'picture', a passed `meta` dict gets
    "title" and "kind" (see PICTURE_DETECT).

    Two independent controls:
      * `use_vlm` — pick the engine: False = Apple Vision (fast; auto-escalates to the VLM
        only when the Vision pass is sparse, < VLM_MIN_CHARS chars/page); True = go straight
        to the Gemma-4 VLM route (handwriting/math).
      * `force`   — if True, re-OCR even when the PDF ALREADY has a text layer (ignore the
        digital-born passthrough). This is what the `*-force` tags set, so you can replace a
        bad existing layer (e.g. Tesseract mojibake) with Apple Vision / Gemma. If False, a
        digital-born PDF is passed through untouched (safe for mass-tagging)."""
    src, dst = Path(src), Path(dst)
    if not force and src.suffix.lower() == ".pdf" and _already_has_text(src):
        shutil.copy2(str(src), str(dst))
        return ("passthrough", 0)
    if use_vlm and VLM_URL:
        try:
            return ("vlm", vlm_ocr_pdf(src, dst))
        except Exception as e:
            log(f"VLM route failed ({e}); falling back to Apple Vision")
    n = ocr_pdf(src, dst)  # Apple Vision (fast, always run first as the printed-text pass)
    sparse = VLM_URL and not use_vlm and _avg_chars(dst) < VLM_MIN_CHARS
    if sparse and PICTURE_DETECT:
        try:
            pic = _classify_picture(src)
            if pic and pic["kind"] == "leer":
                log("blank page — keeping the Apple Vision result (no VLM transcription)")
                return ("ocr", n)
            if pic:
                log(f"picture detected ({pic['kind']}): '{pic['title']}'")
                chars = picture_pdf(src, dst, pic["description"])
                if meta is not None:
                    meta.update(title=pic["title"], kind=pic["kind"])
                return ("picture", chars)
        except Exception as e:
            log(f"picture detection failed ({e}); treating it as a document")
    if VLM_AUTO and sparse:
        try:
            log(f"Vision sparse (<{VLM_MIN_CHARS} chars/pg) — escalating to VLM {VLM_MODEL}")
            return ("vlm", vlm_ocr_pdf(src, dst))
        except Exception as e:
            log(f"VLM escalation failed ({e}); keeping the Apple Vision result")
    return ("ocr", n)


def _open_as_pdf(path):
    """Open a PDF or image as a PyMuPDF PDF document."""
    d = fitz.open(str(path))
    if d.is_pdf:
        return d
    pdfbytes = d.convert_to_pdf()
    d.close()
    return fitz.open("pdf", pdfbytes)


_BLANK_TABLE = bytes(1 if v < 128 else 0 for v in range(256))


def _is_blank_page(page):
    """(blank?, dark_fraction) for a page: render at 50 dpi gray, drop a 5 % margin on each
    side (ADF edge shadows), count pixels darker than mid-gray. Measured at this scale: a
    short 10-pt line ("Unterschrift: Max M.") is ~0.044 % of an A4 page, a full-width line
    ~0.25 %, dust/speckle ~0.01 %, and bleed-through from the front sits at gray 200+ (not
    counted). BLANK_MAX_DARK defaults to 0.0003 (0.03 %) — deliberately LOW: a kept blank
    page is harmless, a dropped back that only carried a signature or stamp is not."""
    pix = page.get_pixmap(matrix=fitz.Matrix(50 / 72, 50 / 72), colorspace=fitz.csGRAY, alpha=False)
    w, h = pix.width, pix.height
    mx, my = int(w * 0.05), int(h * 0.05)
    buf = pix.samples
    dark = total = 0
    for y in range(my, h - my):
        row = buf[y * w + mx: y * w + w - mx]
        total += len(row)
        dark += sum(row.translate(_BLANK_TABLE))
    frac = dark / total if total else 0.0
    return (frac < BLANK_MAX_DARK, frac)


def _concat_pdfs(paths):
    """Open every path (PDF or image) and append them into ONE in-memory PDF, in order."""
    out = fitz.open()
    for p in paths:
        d = _open_as_pdf(p)
        out.insert_pdf(d)
        d.close()
    return out


def _assemble_duplex(fronts, backs, dst, reverse=True, drop_blank=False):
    """Build the page-ordered duplex document at `dst` from the FRONT files and the BACK
    files (each list in scan order — fragments of one pass after a jam just concatenate).

    The backs pass scans the stack as it came out of the fronts pass, i.e. sheet N first; a
    jam does not reorder the remaining stack, so B1‖B2 is still one descending run N..1 and
    is reversed AS A WHOLE (never per fragment) when `reverse` — exactly the old behaviour
    once "the backs file" becomes "all back files". With reverse=False (user re-sorted the
    stack) the plain concatenation already reads 1..N.

    Returns {"pages": n, "dropped_backs": [1-based back-sheet numbers dropped as blank]}."""
    f = _concat_pdfs(fronts)
    b = _concat_pdfs(backs)
    order = list(range(b.page_count - 1, -1, -1)) if reverse else list(range(b.page_count))
    dropped = []
    if drop_blank:
        keep = []
        for sheet, idx in enumerate(order, start=1):
            blank, frac = _is_blank_page(b[idx])
            if blank:
                dropped.append(sheet)
                log(f"duplex: back of sheet {sheet} is blank (dark {frac:.4%}) — dropped")
            else:
                keep.append(idx)
        order = keep
    out = fitz.open()
    for i in range(max(f.page_count, len(order))):
        if i < f.page_count:
            out.insert_pdf(f, from_page=i, to_page=i)
        if i < len(order):
            out.insert_pdf(b, from_page=order[i], to_page=order[i])
    n = out.page_count
    out.save(str(dst))
    out.close()
    f.close()
    b.close()
    return {"pages": n, "dropped_backs": dropped}


def _assemble_concat(paths, dst):
    """Concatenate files in order into one PDF at `dst` (single-sided multi-file jobs)."""
    out = _concat_pdfs(paths)
    n = out.page_count
    out.save(str(dst))
    out.close()
    return {"pages": n, "dropped_backs": []}


def ocr_pdf(src, dst):
    """OCR a PDF or image into a searchable PDF at `dst`. Each page is rasterized and
    REBUILT (image + a single clean invisible text layer) so any pre-existing garbled
    text layer is dropped rather than mixed in. Returns total text boxes placed."""
    src, dst = Path(src), Path(dst)
    WORK.mkdir(parents=True, exist_ok=True)
    if src.suffix.lower() in IMAGE_EXTS:
        imgdoc = fitz.open(str(src))
        pdfbytes = imgdoc.convert_to_pdf()
        imgdoc.close()
        indoc = fitz.open("pdf", pdfbytes)
    else:
        indoc = fitz.open(str(src))
    out = fitz.open()
    zoom = DPI / 72.0
    total = 0
    for page in indoc:
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
        npage = out.new_page(width=page.rect.width, height=page.rect.height)
        # Embed the page as JPEG (keeps size sane); OCR still uses the full pixmap.
        npage.insert_image(npage.rect, stream=pix.tobytes("jpg", jpg_quality=JPEG_Q))
        total += _overlay(npage, pix)
    indoc.close()
    # Subset the embedded font — Arial Unicode.ttf is ~23 MB in full; subsetting to
    # the glyphs actually used drops the output from ~15 MB to <1 MB per page.
    try:
        out.subset_fonts()
    except Exception as e:
        log(f"subset_fonts skipped ({e}); output will be larger")
    out.save(str(dst), garbage=4, deflate=True)
    out.close()
    return total


def _avg_chars(pdf_path):
    """Average stripped text chars/page of a PDF (used to judge how much a Vision pass read)."""
    try:
        d = fitz.open(str(pdf_path))
    except Exception:
        return 0
    try:
        pages = d.page_count or 1
        return sum(len(p.get_text().strip()) for p in d) / pages
    finally:
        d.close()


# ----------------------------------------------------------------------- VLM OCR route
def _vlm_page_text(jpg_bytes):
    """Ask the vision LLM (Gemma-4 via the gateway) to transcribe one page image.
    Returns the transcription text ('' on failure)."""
    b64 = base64.b64encode(jpg_bytes).decode("ascii")
    payload = {
        "model": VLM_MODEL,
        "temperature": 0,
        "max_tokens": VLM_MAX_TOKENS,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": VLM_PROMPT},
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
        ]}],
    }
    r = requests.post(VLM_URL, data=json.dumps(payload),
                      headers={"Content-Type": "application/json"}, timeout=VLM_TIMEOUT)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"].strip()


def _place_fulltext(page, text):
    """Lay `text` as one INVISIBLE (render_mode=3), searchable full-page layer. The VLM
    gives no per-word boxes, so we don't position words — we just make the whole page
    findable. Font size is picked so the text fits the page area."""
    if not text.strip():
        return 0
    page.insert_font(fontname="ocrf", fontfile=FONT)
    rect = page.rect + (2, 2, -2, -2)
    area = max(1.0, rect.width * rect.height)
    # ~0.5*fs wide, ~1.15*fs tall per char cell; size so all chars fit ~90% of the area.
    fs = (0.9 * area / (len(text) * 0.5 * 1.15)) ** 0.5
    fs = max(3.0, min(9.0, fs))
    page.insert_textbox(rect, text, fontname="ocrf", fontsize=fs, render_mode=3)
    return len(text)


def vlm_ocr_pdf(src, dst):
    """Build a searchable PDF using the vision LLM instead of Apple Vision — for pages
    Vision can't read (handwriting, math). Each page is rebuilt as image + a full-page
    invisible text layer from the VLM transcription. Returns total chars placed."""
    src, dst = Path(src), Path(dst)
    WORK.mkdir(parents=True, exist_ok=True)
    if src.suffix.lower() in IMAGE_EXTS:
        imgdoc = fitz.open(str(src))
        pdfbytes = imgdoc.convert_to_pdf()
        imgdoc.close()
        indoc = fitz.open("pdf", pdfbytes)
    else:
        indoc = fitz.open(str(src))
    out = fitz.open()
    zoom = DPI / 72.0
    total = 0
    for page in indoc:
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
        jpg = pix.tobytes("jpg", jpg_quality=JPEG_Q)
        npage = out.new_page(width=page.rect.width, height=page.rect.height)
        npage.insert_image(npage.rect, stream=jpg)
        total += _place_fulltext(npage, _vlm_page_text(jpg))
    indoc.close()
    try:
        out.subset_fonts()
    except Exception as e:
        log(f"subset_fonts skipped ({e}); output will be larger")
    out.save(str(dst), garbage=4, deflate=True)
    out.close()
    return total


def _classify_picture(src):
    """ONE vision call on page 1: is this a picture (drawing/photo/graphic) or a document?
    Returns {"kind", "title", "description"} for a picture, {"kind": "leer"} for a blank
    page (so the VLM isn't asked to transcribe nothing), None for a document."""
    d = _open_as_pdf(src)
    try:
        zoom = ANALYZE_DPI / 72.0
        jpg = d[0].get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False).tobytes("jpg", jpg_quality=JPEG_Q)
    finally:
        d.close()
    prompt = (
        "Ist dieses Bild ein Dokument oder ein Bild? Antworte NUR mit JSON: "
        "{\"art\": \"zeichnung|foto|grafik|dokument|leer\", \"titel\": \"...\", \"beschreibung\": \"...\"}.\n"
        "art: 'dokument', sobald lesbarer Text, Handschrift oder ein Formular zu sehen ist; "
        "'leer' für eine leere oder fast leere Seite; 'zeichnung' für Zeichnungen, Malereien, "
        "Gemälde und Basteleien; 'foto' für Fotos; 'grafik' für alles andere Bildhafte "
        "(Diagramm, Logo, Plakat, Karte).\n"
        "titel: 3-8 Wörter auf Deutsch, die den Inhalt konkret benennen: Technik + Motiv, z. B. "
        "'Aquarell mit blauen und gelben Farbflächen', 'Buntstiftzeichnung Haus mit Sonne', "
        "'Foto Familie am Strand'.\n"
        "beschreibung: 2-3 Sätze auf Deutsch: was zu sehen ist (Motive, Personen, Tiere, "
        "Gegenstände, Umgebung), Farben, Technik und Stil. Nur beschreiben, was sichtbar ist — "
        "NICHT raten, wer es gemacht hat, wie alt jemand ist oder wo es entstanden ist.")
    b64 = base64.b64encode(jpg).decode("ascii")
    payload = {"model": VLM_MODEL, "temperature": 0, "max_tokens": 500,
               "response_format": {"type": "json_object"},
               "messages": [{"role": "user", "content": [
                   {"type": "text", "text": prompt},
                   {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
               ]}]}
    r = requests.post(VLM_URL, data=json.dumps(payload),
                      headers={"Content-Type": "application/json"}, timeout=VLM_TIMEOUT)
    r.raise_for_status()
    content = r.json()["choices"][0]["message"]["content"]
    try:
        data = json.loads(content)
    except ValueError:
        mm = re.search(r"\{.*\}", content, re.S)
        data = json.loads(mm.group(0)) if mm else {}
    kind = str(data.get("art") or "").strip().lower()
    if kind == "leer":
        return {"kind": "leer"}
    if kind not in PICTURE_KINDS:
        return None
    title = _safe_filename(str(data.get("titel") or "")) or kind.capitalize()
    desc = re.sub(r"\s+", " ", str(data.get("beschreibung") or "")).strip()[:500]
    return {"kind": kind, "title": title, "description": desc}


def picture_pdf(src, dst, description):
    """Rebuild every page as its image (no transcription) and put an invisible
    'Bildbeschreibung: …' layer on page 1, so the picture is findable in paperless.
    Returns chars placed."""
    indoc = _open_as_pdf(src)
    out = fitz.open()
    zoom = DPI / 72.0
    total = 0
    for i, page in enumerate(indoc):
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
        npage = out.new_page(width=page.rect.width, height=page.rect.height)
        npage.insert_image(npage.rect, stream=pix.tobytes("jpg", jpg_quality=JPEG_Q))
        if i == 0 and description:
            total += _place_fulltext(npage, f"Bildbeschreibung: {description}")
    indoc.close()
    try:
        out.subset_fonts()
    except Exception as e:
        log(f"subset_fonts skipped ({e}); output will be larger")
    out.save(str(dst), garbage=4, deflate=True)
    out.close()
    return total


# --------------------------------------------------------------- naming + housekeeping
def _safe_filename(s):
    """Sanitize an LLM-proposed name into a safe, single-line filename stem (no extension)."""
    s = (s or "").strip()
    if s:
        s = s.splitlines()[0].strip().strip("\"'`").strip()
    s = re.sub(r'[\\/:*?"<>|\t\r\n]+', " ", s)   # drop path-unsafe chars
    s = re.sub(r"\s+", " ", s).strip().rstrip(".")
    return s[:60].strip()


def _smart_name(pdf_path, fallback):
    """Ask the LLM for a short, human-readable name from the document's text. Falls back to
    `fallback` (the scanner's stem) if disabled, the text is too short, or the call fails."""
    if not SMART_NAME or not VLM_URL:
        return fallback
    try:
        d = fitz.open(str(pdf_path))
        txt = "\n".join(d[i].get_text() for i in range(min(2, d.page_count)))
        d.close()
    except Exception:
        return fallback
    if len(txt.strip()) < 20:
        return fallback  # near-empty page — nothing to name it after
    prompt = ("Schlage einen kurzen, sprechenden Dateinamen fuer dieses Dokument vor: "
              "3-6 Woerter, moeglichst mit Typ/Absender/Datum, KEINE Dateiendung, keine "
              "Anfuehrungszeichen, keine Erklaerung — NUR der Name. Beispiele: "
              "'Rechnung Airbrush City Juni 2026', 'Kfz-Versicherung Police 2026'.\n\n"
              "Dokumenttext:\n" + txt[:1500])
    try:
        payload = {"model": VLM_MODEL, "temperature": 0, "max_tokens": 40,
                   "messages": [{"role": "user", "content": prompt}]}
        r = requests.post(VLM_URL, data=json.dumps(payload),
                          headers={"Content-Type": "application/json"}, timeout=90)
        r.raise_for_status()
        name = _safe_filename(r.json()["choices"][0]["message"]["content"])
        return name or fallback
    except Exception as e:
        log(f"smart-name failed ({e}); keeping '{fallback}'")
        return fallback


def _unique_path(folder, stem, suffix):
    """A non-clobbering path in `folder` for <stem><suffix>, appending ' (2)', ' (3)'… ."""
    p = folder / f"{stem}{suffix}"
    i = 2
    while p.exists():
        p = folder / f"{stem} ({i}){suffix}"
        i += 1
    return p


# The daemon runs as ROOT (see the plist) so every file/dir it creates is owned by
# root:wheel, and shutil.copy2 also carries over the SMB source file's mode (often 0600).
# That leaves archived originals un-downloadable/-deletable over SMB by the TARGET_USER.
# _handoff / _ensure_user_dir hand the path back to that user (0644 file / 0755 dir),
# mirroring the repo's "644 + chown TARGET_USER" convention (see setup.sh:1313-1314).
TARGET_USER = os.environ.get("USER", "mac")


def _handoff(path):
    """Make `path` readable/deletable over SMB by the TARGET_USER (owner + 0644), undoing
    the root:wheel/0600 a root shutil.copy2/move leaves behind. Best-effort — a failure
    must never break processing."""
    try:
        os.chmod(path, 0o644)
        shutil.chown(path, user=TARGET_USER)
    except Exception as e:
        log(f"handoff chmod/chown failed for {path}: {e}")


def _ensure_user_dir(d):
    """mkdir -p `d`, then hand it to the TARGET_USER (0755) so files created under it are
    reachable over SMB. chown needs root — which the daemon is; best-effort otherwise."""
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o755)
        shutil.chown(d, user=TARGET_USER)
    except Exception as e:
        log(f"dir handoff chmod/chown failed for {d}: {e}")


def _pdf_pages(path):
    """Page count of a PDF/image (images open as 1 page), or -1 if it can't be opened."""
    try:
        d = fitz.open(str(path))
        try:
            return d.page_count
        finally:
            d.close()
    except Exception:
        return -1


# (size, mtime) -> page count, so files that sit in a job folder waiting for the user are not
# re-opened by PyMuPDF on every 10 s tick. A changed size/mtime invalidates the entry.
_pages_cache = {}


def _cached_pages(path, st):
    key = str(path)
    hit = _pages_cache.get(key)
    if hit and hit[0] == st.st_size and hit[1] == st.st_mtime:
        return hit[2]
    pages = _pdf_pages(path) if path.suffix.lower() == ".pdf" else 1
    if pages > 0:
        _pages_cache[key] = (st.st_size, st.st_mtime, pages)
    return pages


# ---------------------------------------------------------------- page-number check
# After OCR, read the page numbers the document itself carries ("Seite 3 von 18", "Page 3
# of 18", "Стр. 3", a bare "3" in the footer) and compare them with the physical order. A
# mis-assembled duplex job reads 1,18,2,17,…; a jam fragment uploaded alone says "Seite 1
# von 18" in a 7-page file. Deliberately conservative: only STRONG matches (explicit
# "Seite/Page X [von N]") can raise a warning, bare footer numbers merely support the chain.
_STRONG_OF_RE = re.compile(
    r"(?:Seite|Page|Blatt|Стр(?:аница)?\.?)\s*(\d{1,3})\s*(?:von|of|из|/)\s*(\d{1,3})\b", re.I)
# "Seite 7" without a total must BE the line (header/footer), not sit inside a sentence —
# "dies ist Seite 2 des Schreibens" split into a short Vision box must not count.
_STRONG_RE = re.compile(r"^\W*(?:Seite|Page|Стр(?:аница)?\.?)\s*(\d{1,3})\W*$", re.I)
_WEAK_RES = (re.compile(r"^\s*-?\s*(\d{1,3})\s*-?\s*$"),
             re.compile(r"^\s*(\d{1,3})\s*/\s*(\d{1,3})\s*$"))


def _page_number_of(text):
    """{'number', 'of', 'strong'} read from one page's text, or None."""
    m = _STRONG_OF_RE.search(text)
    if m:
        x, n = int(m.group(1)), int(m.group(2))
        if 1 <= x <= n <= 500:
            return {"number": x, "of": n, "strong": True}
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    # "Seite 7" without a total only counts when it sits on a short header/footer line —
    # "siehe Seite 7" inside a paragraph is a cross-reference, not a page number.
    for ln in lines:
        m = _STRONG_RE.match(ln)
        if m and 1 <= int(m.group(1)) <= 500:
            return {"number": int(m.group(1)), "of": None, "strong": True}
    for ln in lines[:2] + lines[-2:]:
        for rx in _WEAK_RES:
            m = rx.match(ln)
            if not m:
                continue
            x = int(m.group(1))
            n = int(m.group(2)) if m.lastindex and m.lastindex >= 2 else None
            if 1 <= x <= 200 and (n is None or x <= n <= 200):
                return {"number": x, "of": n, "strong": False}
    return None


def _page_check(pdf_path, allow_partial=False):
    """Compare the page numbers printed on the pages with their physical order.
    `allow_partial` skips the "says 'von N' but has M pages" rule — for documents the user
    deliberately split in the editor, every part still carries the bundle's total.
    Returns {"ok", "numbered", "detail", "pages": [{index, number, of, strong}]}."""
    try:
        d = fitz.open(str(pdf_path))
    except Exception as e:
        return {"ok": True, "numbered": 0, "detail": f"nicht prüfbar ({e})", "pages": []}
    try:
        total = d.page_count
        pages = []
        for i, p in enumerate(d):
            info = _page_number_of(p.get_text() or "")
            pages.append({"index": i, "number": info["number"] if info else None,
                          "of": info["of"] if info else None, "strong": bool(info and info["strong"])})
    finally:
        d.close()
    cand = [p for p in pages if p["number"] is not None]
    if len(cand) < 3:
        return {"ok": True, "numbered": len(cand), "detail": "zu wenige Seitenzahlen für eine Prüfung",
                "pages": pages}
    # The most common (number - index) offset is the chain; strong outliers contradict it.
    bases = {}
    for p in cand:
        b = p["number"] - p["index"]
        bases[b] = bases.get(b, 0) + 1
    base = max(bases.items(), key=lambda kv: kv[1])[0]
    problems = []
    for p in cand:
        if p["strong"] and p["number"] - p["index"] != base:
            problems.append(f"Seite {p['index'] + 1} trägt Nr. {p['number']} (erwartet {p['index'] + base})")
    ofs = {}
    for p in cand:
        if p["strong"] and p["of"]:
            ofs[p["of"]] = ofs.get(p["of"], 0) + 1
    if ofs and not allow_partial:
        n, c = max(ofs.items(), key=lambda kv: kv[1])
        if c >= 3 and n != total:
            problems.append(f"Seiten sagen 'von {n}', Dokument hat {total} Seiten")
    if problems:
        more = f" (+{len(problems) - 4} weitere)" if len(problems) > 4 else ""
        return {"ok": False, "numbered": len(cand), "detail": "; ".join(problems[:4]) + more, "pages": pages}
    return {"ok": True, "numbered": len(cand), "detail": f"{len(cand)} Seitenzahlen in Reihenfolge", "pages": pages}


def _assert_pagecount(src, out, mode):
    """Guard against silent page loss: an OCR/VLM output must have exactly as many pages as
    its source (passthrough copies the whole file, so it is equal by construction). Raises on
    a mismatch so the caller routes the UNTOUCHED source into errors/ instead of uploading a
    truncated document and then deleting the only original."""
    if mode == "passthrough":
        return
    src_n, out_n = _pdf_pages(src), _pdf_pages(out)
    if src_n <= 0 or out_n != src_n:
        raise RuntimeError(f"page-count mismatch: source={src_n} output={out_n} ({mode}) "
                           f"— refusing to upload a truncated result")


_last_prune = 0.0


def prune_archive():
    """Delete archived originals older than ARCHIVE_RETENTION_DAYS (0 = keep forever).
    Runs at most hourly. The searchable copy is safe in paperless; this only trims the
    local pristine-scan safety net."""
    global _last_prune
    if ARCHIVE_RETENTION_DAYS <= 0 or not ARCHIVE.exists():
        return
    now = time.time()
    if now - _last_prune < 3600:
        return
    _last_prune = now
    cutoff = now - ARCHIVE_RETENTION_DAYS * 86400
    removed = 0
    try:
        for f in ARCHIVE.iterdir():
            if f.is_file() and not f.name.startswith(".") and f.stat().st_mtime < cutoff:
                f.unlink()
                removed += 1
    except Exception as e:
        log(f"archive prune error: {e}")
    if removed:
        log(f"archive: pruned {removed} original(s) older than {ARCHIVE_RETENTION_DAYS} days")
    # Editor workspaces follow the same window (pages.json mtime = last edit/commit).
    pruned = 0
    try:
        if EDIT_DIR.exists():
            for d in EDIT_DIR.iterdir():
                mf = d / "pages.json"
                if d.is_dir() and WS_ID_RE.match(d.name) and (not mf.exists() or mf.stat().st_mtime < cutoff):
                    shutil.rmtree(d, ignore_errors=True)
                    pruned += 1
    except Exception as e:
        log(f"workspace prune error: {e}")
    if pruned:
        log(f"editor: pruned {pruned} workspace(s) older than {ARCHIVE_RETENTION_DAYS} days")


# ------------------------------------------------------------------- paperless client
_session = requests.Session()
if TOKEN:
    _session.headers["Authorization"] = f"Token {TOKEN}"
_session.headers["Accept"] = "application/json"

# Every REST call gets a timeout — a hung/slow paperless-ngx must never block the
# poll or gateway thread indefinitely. Uploads/downloads (large scans) get more.
REST_TIMEOUT = int(os.environ.get("PAPERLESS_OCR_REST_TIMEOUT_SEC", "30"))
REST_XFER_TIMEOUT = int(os.environ.get("PAPERLESS_OCR_REST_XFER_TIMEOUT_SEC", "300"))


def _tag_id(name, create=True):
    r = _session.get(f"{URL}/api/tags/", params={"name__iexact": name}, timeout=REST_TIMEOUT)
    r.raise_for_status()
    res = r.json().get("results", [])
    if res:
        return res[0]["id"]
    if not create:
        return None
    r = _session.post(f"{URL}/api/tags/", json={"name": name}, timeout=REST_TIMEOUT)
    r.raise_for_status()
    return r.json()["id"]


def _upload(path, title=None, tags=None, created=None, correspondent=None):
    fields = []
    if title:
        fields.append(("title", title))
    if created:
        fields.append(("created", created))
    if correspondent:
        fields.append(("correspondent", str(correspondent)))
    for t in (tags or []):
        fields.append(("tags", str(t)))
    with open(path, "rb") as fh:
        files = {"document": (Path(path).name, fh, "application/pdf")}
        r = _session.post(f"{URL}/api/documents/post_document/", data=fields, files=files, timeout=REST_XFER_TIMEOUT)
    r.raise_for_status()
    return r.text.strip().strip('"')  # consume task uuid


# --------------------------------------------------------------------------- loops
_lsof_warned = False


def _is_open(path):
    """True if any process still holds `path` open (e.g. smbd streaming a multi-page scan)
    — OR if we cannot tell. This is the authoritative "still being written" signal: a scanner
    that keeps the file open for the whole job means `close` is the de-facto "scan finished"
    event, and no time heuristic can beat it.

    Fails SAFE: if lsof is missing, slow (timeout), or errors, report OPEN so an in-flight scan
    is never processed. lsof is a core macOS binary (/usr/sbin/lsof), so a persistent failure is
    unlikely; it is logged once per failure streak so it stays diagnosable without log spam."""
    global _lsof_warned
    try:
        # -F p => one "p<pid>" line per holder; no output (exit 1) when nothing holds it open.
        r = subprocess.run(["/usr/sbin/lsof", "-F", "p", "--", str(path)],
                           capture_output=True, text=True, timeout=15)
    except Exception as e:
        if not _lsof_warned:
            log(f"lsof check failed ({e}); treating files as OPEN until it recovers (fail-safe)")
            _lsof_warned = True
        return True  # in doubt -> never process
    _lsof_warned = False
    return any(line.startswith("p") for line in r.stdout.splitlines())


# Per-path signature (size, page_count) from the previous poll — a file counts as settled
# only once this is UNCHANGED across two consecutive polls (see _is_settled). This is what
# stops a multi-page PDF that a scanner streams page-by-page over SMB from being processed
# after only page 1 has landed (mtime-quiet alone can be fooled by an inter-page pause).
_settle_seen = {}


def _is_settled(path):
    """True once a file is safe to process. Two lines of defense against grabbing a multi-page
    scan after only its first page has landed:

      * PRIMARY — the open handle (`_is_open`): while any process holds the file open we never
        touch it. For a scanner that keeps the file open for the whole job, its `close` is the
        real "scan finished" event; fail-safe means an unknown lsof state also blocks.
      * FALLBACK (for scanners that close the file between pages) — the file must additionally
        be non-empty, mtime-quiet for STABLE_SEC, a fully-parseable PDF, and unchanged in size
        + page count across two polls. STABLE_SEC must therefore exceed the longest pause a
        scanner leaves between pages, or a mid-scan snapshot could look 'quiet' (see the
        INTEGRATIONS.md note)."""
    key = str(path)
    try:
        st = path.stat()
    except OSError:
        _settle_seen.pop(key, None)
        return False
    if st.st_size == 0:
        return False
    if time.time() - st.st_mtime < STABLE_SEC:
        return False
    if _is_open(path):
        return False
    # A PDF is only valid once its trailer/xref is written; a half-streamed one fails to
    # open or reports fewer pages. Images have no such structure -> page count is fixed at 1.
    pages = _cached_pages(path, st)
    if pages <= 0:
        _settle_seen[key] = None
        return False  # not a complete/parseable PDF yet — wait for the next poll
    sig = (st.st_size, pages)
    prev = _settle_seen.get(key)
    _settle_seen[key] = sig
    if prev != sig:
        return False  # size/page-count still changing -> give it one more poll cycle
    # Keep the signature: a job-folder file may stay here (settled but waiting for the user)
    # for a long time, and forgetting it made the verdict flap every other tick. If the
    # scanner appends to it again, the changed signature re-arms the two-poll rule.
    return True


def _settle_prune(live_keys):
    """Drop settle/page-cache entries for paths that no longer exist (consumed, moved by the
    dashboard, deleted) so a same-named future scan starts with a clean slate."""
    for cache in (_settle_seen, _pages_cache):
        for k in [k for k in cache if k not in live_keys]:
            cache.pop(k, None)


def gateway_once():
    if not INBOX.exists():
        return
    for p in sorted(INBOX.iterdir()):
        if p.is_dir() or p.name.startswith("."):
            continue
        if p.suffix.lower() not in ACCEPT_EXTS:
            continue  # ignore scanner temp/partial files with other extensions
        if not _is_settled(p):
            continue  # still being written (or too fresh) — try again next poll
        _set_processing({"kind": "inbox", "id": "inbox", "since": time.time(),
                         "files": [p.name], "progress": "OCR"})
        result = {"ts": time.time(), "job": "inbox", "files": [p.name], "title": None, "pages": 0,
                  "dropped_blank": [], "page_check": None, "tags": [], "error": None}
        try:
            # inbox filename hints: "_vlm" -> Gemma route; "_force" -> re-OCR even if text exists.
            stem_l = p.stem.lower()
            n, name, check = _process_and_upload(p, p.stem, use_vlm="_vlm" in stem_l,
                                                 force="_force" in stem_l)
            # archive the pristine original under the descriptive name (retention prunes it),
            # then hand it to the TARGET_USER so it is downloadable/deletable over SMB.
            ARCHIVE.mkdir(parents=True, exist_ok=True)
            dst = _unique_path(ARCHIVE, name, p.suffix)
            shutil.copy2(str(p), str(dst))
            _handoff(dst)
            result.update(title=name, pages=_pdf_pages(p), page_check=check,
                          tags=[CHECK_TAG] if check and not check["ok"] else [])
            log(f"gateway: {p.name} -> '{name}' uploaded ({n}); original archived")
            p.unlink()
        except Exception as e:
            result["error"] = str(e)
            log(f"gateway ERROR {p.name}: {e}")
            try:
                ERRORS.mkdir(parents=True, exist_ok=True)
                dst = ERRORS / p.name
                shutil.move(str(p), str(dst))
                _handoff(dst)  # keep the failed original reachable over SMB, too
            except Exception:
                pass
        finally:
            _settle_seen.pop(str(p), None)
            _pages_cache.pop(str(p), None)
            _push_result(result)
            _set_processing(None)


def _process_and_upload(src_pdf, title, use_vlm=False, force=False, fixed_title=None, allow_partial=False):
    """Make `src_pdf` searchable, run the page-number check, upload with a short
    descriptive title (tagged CHECK_TAG when the check found a problem). `fixed_title`
    (editor) is used verbatim instead of asking the LLM.
    Returns (detail_str, name, check_dict_or_None)."""
    out = WORK / (Path(title).stem + ".ocr.pdf")
    meta = {}
    try:
        mode, n = make_searchable(src_pdf, out, use_vlm=use_vlm, force=force, meta=meta)
        _assert_pagecount(src_pdf, out, mode)  # never upload a silently-truncated result
        check = _page_check(out, allow_partial=allow_partial) if PAGE_CHECK else None
        name = fixed_title or meta.get("title") or _smart_name(out, Path(title).stem)
        tags = []
        if check and not check["ok"]:
            tags.append(_tag_id(CHECK_TAG))
            log(f"page-check '{name}': {check['detail']} -> tagged '{CHECK_TAG}'")
        if meta.get("kind"):
            tags.append(_tag_id(PICTURE_TAG_PREFIX + meta["kind"]))
        _upload(out, title=name, tags=tags)
    finally:
        out.unlink(missing_ok=True)
    detail = {"passthrough": "passed through (already had text)",
              "vlm": f"VLM-OCR'd ({n} chars)",
              "picture": f"picture, described ({n} chars)"}.get(mode, f"OCR'd ({n} boxes)")
    return detail, name, check


# ---------------------------------------------------------------------- scan jobs
# One document = every settled file in a job folder. See the JOB_QUIET comment block up top
# for the why. State is in-memory (the folders are the source of truth); the dashboard
# sees it through STATUS_FILE and talks back through COMMAND_FILE.
_job_hold = {}          # job -> True while the user paused auto-processing (dashboard "Anhalten")
_job_states = {}        # job -> last computed state dict (what STATUS_FILE shows)
_last_results = []      # newest first, capped
_last_command = None    # outcome of the last dashboard command (shown as a toast)
_processing = None      # {"kind","id","since","files","progress"} while a blocking step runs
_motd_last = None       # last MOTD status text written (write only on change)


def _job_dirs():
    return {"duplex": (INBOX / DUPLEX_SUBDIR, "duplex"),
            "stapel": (INBOX / BATCH_SUBDIR, "concat")}


def _fmt_secs(s):
    s = int(max(0, s))
    return f"{s // 60} min" if s >= 120 else f"{s} s"


def _list_job_files(jdir):
    """Every candidate file in a job folder, oldest first, with settle verdict + page count."""
    out = []
    if not jdir.exists():
        return out
    now = time.time()
    for p in jdir.iterdir():
        if p.is_dir() or p.name.startswith(".") or p.suffix.lower() not in ACCEPT_EXTS:
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        settled = _is_settled(p)
        out.append({"path": p, "name": p.name, "size": st.st_size, "mtime": int(st.st_mtime),
                    "age": int(now - st.st_mtime), "settled": settled,
                    "pages": _cached_pages(p, st)})
    out.sort(key=lambda f: (f["mtime"], f["name"]))
    return out


def _duplex_split(pages):
    """Index k such that the first k files hold exactly half of all pages (fronts), the rest
    the other half (backs). Prefix sums rise strictly, so k is unique if it exists."""
    total = sum(pages)
    if len(pages) < 2 or total <= 0 or total % 2:
        return None
    acc = 0
    for k, n in enumerate(pages, start=1):
        acc += n
        if acc == total // 2:
            return k if k < len(pages) else None
        if acc > total // 2:
            return None
    return None


def _job_state(job, jdir, mode):
    files = _list_job_files(jdir)
    st = {"dir": str(jdir), "mode": mode, "files": [], "total_pages": 0, "state": "empty",
          "reason": "", "quiet_remaining": -1, "lone_timeout_remaining": None,
          "held": bool(_job_hold.get(job)), "proposal": None}
    for f in files:
        st["files"].append({k: v for k, v in f.items() if k != "path"})
    if not files:
        return st
    settled = [f for f in files if f["settled"]]
    st["total_pages"] = sum(max(0, f["pages"]) for f in files)
    quiet_rem = max(0, JOB_QUIET - min(f["age"] for f in files))
    st["quiet_remaining"] = quiet_rem
    names = [f["name"] for f in settled]
    pages = [f["pages"] for f in settled]
    if mode == "duplex":
        k = _duplex_split(pages) if settled else None
        if k:
            st["proposal"] = {"fronts": names[:k], "backs": names[k:], "reverse": DUPLEX_REVERSE}
    else:
        st["proposal"] = {"order": names}
    if len(settled) < len(files):
        n = len(files) - len(settled)
        st["state"], st["reason"] = "waiting", f"{n} Datei(en) werden noch geschrieben"
        return st
    if st["held"]:
        st["state"], st["reason"] = "held", "angehalten (Dashboard) – Freigeben oder manuell zusammenführen"
        return st
    if mode == "concat":
        if quiet_rem > 0:
            st["state"], st["reason"] = "waiting", f"Abschluss in {_fmt_secs(quiet_rem)} (Sammelzeit)"
        else:
            st["state"], st["reason"] = "auto-pending", "wird zu einem Dokument zusammengefügt"
        return st
    if len(settled) == 1:
        rem = max(0, DUPLEX_TIMEOUT - settled[0]["age"])
        st["lone_timeout_remaining"] = rem
        if rem > 0:
            st["state"], st["reason"] = "waiting", f"wartet auf die Rückseiten (einseitig in {_fmt_secs(rem)})"
        else:
            st["state"], st["reason"] = "lone", "einzelne Datei – wird einseitig verarbeitet"
        return st
    if len(settled) == 2 and pages[0] == pages[1]:
        if not DUPLEX_AUTO:
            st["state"], st["reason"] = "held", "Auto-Zusammenführung aus – bitte bestätigen"
        elif quiet_rem > 0:
            st["state"], st["reason"] = "waiting", f"Auto-Zusammenführung in {_fmt_secs(quiet_rem)}"
        else:
            st["state"], st["reason"] = "auto-pending", "wird zusammengeführt"
        return st
    st["state"] = "held"
    if st["proposal"]:
        front_n = sum(pages[:len(st["proposal"]["fronts"])])
        st["reason"] = (f"{len(settled)} Dateien – bitte bestätigen (Vorschlag: {front_n} Seiten vorne, "
                        f"{st['total_pages'] - front_n} hinten)")
    elif len(settled) == 2:
        st["reason"] = f"ungleiche Seitenzahl {pages[0]} ≠ {pages[1]} – bitte bestätigen"
    else:
        st["reason"] = (f"{st['total_pages']} Seiten in {len(settled)} Dateien, keine Teilung in zwei "
                        f"gleiche Hälften – bitte bestätigen")
    return st


def _push_result(result):
    _last_results.insert(0, result)
    del _last_results[20:]


def _set_processing(info, progress=None):
    """Update the 'blocking step running' marker and publish it immediately, so the dashboard
    can show progress / lock its buttons while OCR runs for minutes."""
    global _processing
    if info is None:
        _processing = None
    else:
        _processing = info
    if progress is not None and _processing:
        _processing["progress"] = progress
    _write_status()


def _run_job(job, jdir, plan, origin):
    """The ONE execution path for every job (auto, lone timeout, dashboard command, stapel):
    archive sources -> assemble -> OCR/check/upload -> delete sources. Any failure moves ALL
    sources of the job to errors/ (never leaves them to be retried every tick)."""
    if plan["kind"] == "merge":
        srcs = list(plan["fronts"]) + list(plan["backs"])
    else:
        srcs = list(plan["order"])
    names = [p.name for p in srcs]
    _set_processing({"kind": "job", "id": job, "since": time.time(), "files": names, "progress": "Zusammenbau"})
    result = {"ts": time.time(), "job": job, "origin": origin, "files": names, "title": None,
              "pages": 0, "dropped_blank": [], "page_check": None, "tags": [], "error": None}
    combined = WORK / f"job_{job}_combined.pdf"
    try:
        ARCHIVE.mkdir(parents=True, exist_ok=True)
        for s in srcs:
            d = _unique_path(ARCHIVE, s.stem, s.suffix)
            shutil.copy2(str(s), str(d))
            _handoff(d)
        if plan["kind"] == "merge":
            info = _assemble_duplex(plan["fronts"], plan["backs"], combined,
                                    reverse=plan.get("reverse", DUPLEX_REVERSE), drop_blank=DROP_BLANK_BACKS)
        else:
            info = _assemble_concat(srcs, combined)
        expected = sum(_pdf_pages(s) for s in srcs) - len(info["dropped_backs"])
        if info["pages"] != expected:
            raise RuntimeError(f"assembly page count {info['pages']} != expected {expected}")
        stems = " ".join(s.stem.lower() for s in srcs)
        _set_processing(_processing, progress=f"OCR ({info['pages']} Seiten)")
        detail, name, check = _process_and_upload(combined, srcs[0].stem,
                                                  use_vlm="_vlm" in stems, force="_force" in stems)
        result.update(title=name, pages=info["pages"], dropped_blank=info["dropped_backs"],
                      page_check=check, tags=[CHECK_TAG] if check and not check["ok"] else [])
        for s in srcs:
            s.unlink(missing_ok=True)
        log(f"job {job} ({origin}): {' + '.join(names)} -> '{name}' {info['pages']} pages, {detail}"
            + (f", blank backs dropped {info['dropped_backs']}" if info["dropped_backs"] else ""))
    except Exception as e:
        result["error"] = str(e)
        log(f"job {job} ERROR {' + '.join(names)}: {e}")
        try:
            ERRORS.mkdir(parents=True, exist_ok=True)
            for s in srcs:
                if s.exists():
                    d = _unique_path(ERRORS, s.stem, s.suffix)
                    shutil.move(str(s), str(d))
                    _handoff(d)
        except Exception as e2:
            log(f"job {job}: could not move sources to errors/: {e2}")
    finally:
        combined.unlink(missing_ok=True)
        for s in srcs:
            _settle_seen.pop(str(s), None)
            _pages_cache.pop(str(s), None)
        _push_result(result)
        _set_processing(None)


def _read_command():
    """Consume COMMAND_FILE (the dashboard writes it atomically). Always unlinked, even when
    malformed — a bad command must not be retried forever."""
    if not COMMAND_FILE.exists():
        return None
    try:
        cmd = json.loads(COMMAND_FILE.read_text(encoding="utf-8"))
        if not isinstance(cmd, dict):
            raise ValueError("kein JSON-Objekt")
    except Exception as e:
        cmd = {"_error": f"Befehlsdatei unlesbar: {e}"}
    finally:
        try:
            COMMAND_FILE.unlink()
        except OSError:
            pass
    return cmd


def _apply_command(cmd):
    """Validate a dashboard command against the folders AS THEY ARE NOW. Returns
    (job, jdir, plan) to run, or None. Outcome goes to _last_command either way."""
    global _last_command
    dirs = _job_dirs()
    action = cmd.get("action")
    job = cmd.get("job")

    def reject(msg):
        global _last_command
        _last_command = {"ts": time.time(), "action": action, "job": job, "ok": False, "msg": msg}
        log(f"command {action} on {job} rejected: {msg}")
        return None

    if "_error" in cmd:
        return reject(cmd["_error"])
    if job not in dirs:
        return reject(f"unbekannter Job '{job}'")
    jdir, mode = dirs[job]
    if action == "hold":
        _job_hold[job] = True
        _last_command = {"ts": time.time(), "action": action, "job": job, "ok": True, "msg": "angehalten"}
        return None
    if action == "release":
        _job_hold.pop(job, None)
        _last_command = {"ts": time.time(), "action": action, "job": job, "ok": True, "msg": "freigegeben"}
        return None
    if action not in ("merge", "concat"):
        return reject(f"unbekannte Aktion '{action}'")
    files = {f["name"]: f for f in _list_job_files(jdir)}
    expect = cmd.get("expect") or {}

    def check(names):
        if not isinstance(names, list) or not names or any(not isinstance(n, str) for n in names):
            return "leere oder ungültige Dateiliste"
        if len(set(names)) != len(names):
            return "Datei doppelt angegeben"
        for n in names:
            f = files.get(n)
            if not f:
                return f"'{n}' ist nicht (mehr) vorhanden"
            if not f["settled"]:
                return f"'{n}' wird noch geschrieben – bitte warten"
            e = expect.get(n)
            if e is not None and list(e) != [f["size"], f["pages"]]:
                return f"'{n}' hat sich seit der Anzeige geändert – bitte erneut prüfen"
        return None

    if action == "merge":
        if mode != "duplex":
            return reject("Zusammenführen gibt es nur im Duplex-Ordner")
        fronts, backs = cmd.get("fronts"), cmd.get("backs")
        err = check(fronts) or check(backs)
        if err:
            return reject(err)
        if set(fronts) & set(backs):
            return reject("eine Datei kann nicht vorne UND hinten sein")
        pf = sum(files[n]["pages"] for n in fronts)
        pb = sum(files[n]["pages"] for n in backs)
        if pf != pb and not cmd.get("force"):
            return reject(f"ungleiche Seitenzahl vorne {pf} / hinten {pb} – mit 'trotzdem' erzwingen")
        _last_command = {"ts": time.time(), "action": action, "job": job, "ok": True,
                         "msg": f"Zusammenführung gestartet ({pf} + {pb} Seiten)"}
        return (job, jdir, {"kind": "merge", "fronts": [files[n]["path"] for n in fronts],
                            "backs": [files[n]["path"] for n in backs],
                            "reverse": bool(cmd.get("reverse", DUPLEX_REVERSE))})
    order = cmd.get("order")
    err = check(order)
    if err:
        return reject(err)
    _last_command = {"ts": time.time(), "action": action, "job": job, "ok": True,
                     "msg": f"{len(order)} Datei(en) werden hintereinander verarbeitet"}
    return (job, jdir, {"kind": "concat", "order": [files[n]["path"] for n in order]})


# ---------------------------------------------------------------- page editor (workspaces)
def _ws_dir(wsid):
    if not isinstance(wsid, str) or not WS_ID_RE.match(wsid):
        return None
    d = EDIT_DIR / wsid
    return d if (d / "pages.json").is_file() else None


def _ws_read(wsdir):
    return json.loads((wsdir / "pages.json").read_text(encoding="utf-8"))


def _ws_write(wsdir, manifest):
    tmp = wsdir / "pages.json.tmp"
    tmp.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, wsdir / "pages.json")


def _ws_list():
    """Summary of every workspace for the status file (newest first)."""
    out = []
    if not EDIT_DIR.exists():
        return out
    for d in EDIT_DIR.iterdir():
        if not d.is_dir() or not WS_ID_RE.match(d.name):
            continue
        try:
            m = _ws_read(d)
        except Exception:
            continue
        out.append({"id": m["id"], "created": m["created"], "origin": m["origin"], "state": m["state"],
                    "files": [s["name"] for s in m["sources"]], "page_count": len(m["pages"]),
                    "title": m.get("title"), "committed": m.get("committed"), "error": m.get("error"),
                    "age": int(time.time() - m["created"])})
    out.sort(key=lambda w: w["created"], reverse=True)
    return out


def _render_page_jpegs(page, wsdir, img):
    """Thumbnail + preview JPEG for one source page (page rotation already applied by
    get_pixmap, so the editor shows the page as a viewer would)."""
    w = max(1.0, page.rect.width)
    for sub, width in (("thumbs", THUMB_W), ("preview", PREVIEW_W)):
        s = width / w
        pix = page.get_pixmap(matrix=fitz.Matrix(s, s), colorspace=fitz.csRGB, alpha=False)
        (wsdir / sub / f"{img}.jpg").write_bytes(pix.tobytes("jpg", jpg_quality=70))


def _ws_ingest(wsdir, srcs, move, origin, k0=0):
    """Take source Paths into wsdir/source (move, or copy for originals/errors; a name that
    already exists in the workspace gets ' (2)' appended) and render thumbnail + preview per
    page with img ids p{k0+1}, p{k0+2}, … . Returns (sources, per_src_pages, taken) where
    `taken` = [(src_path, dest_path)] for _ws_rollback. Shared by ws_open and ws_add."""
    sources, per_src_pages, taken, k = [], {}, [], k0
    for p in srcs:
        dst = wsdir / "source" / p.name
        if dst.exists():
            dst = _unique_path(wsdir / "source", p.stem, p.suffix)
        if move:
            shutil.move(str(p), str(dst))
        else:
            shutil.copy2(str(p), str(dst))
        taken.append((p, dst))
        _settle_seen.pop(str(p), None)
        _pages_cache.pop(str(p), None)
    for _p, dst in taken:
        d = _open_as_pdf(dst)
        entries = []
        for i, page in enumerate(d):
            k += 1
            img = f"p{k}"
            _set_processing(_processing, progress=f"Vorschau {k - k0}")
            _render_page_jpegs(page, wsdir, img)
            entries.append({"img": img, "src": dst.name, "page": i, "rotate": 0,
                            "w": int(page.rect.width), "h": int(page.rect.height)})
        d.close()
        per_src_pages[dst.name] = entries
        sources.append({"name": dst.name, "pages": len(entries), "size": dst.stat().st_size,
                        "role": None, "moved": bool(move), "origin": origin, "archived": False})
    return sources, per_src_pages, taken


def _ws_rollback(taken, move):
    """Undo _ws_ingest's file step after a failure: moved files go back where they came
    from (never lose a scan), copies are simply dropped."""
    for p, dst in taken:
        try:
            if move:
                if dst.exists() and not p.exists():
                    shutil.move(str(dst), str(p))
            else:
                dst.unlink(missing_ok=True)
        except OSError as e:
            log(f"workspace rollback: could not restore {p.name}: {e}")


def _ws_create(origin, srcs, move, roles=None):
    """Create a workspace from source Paths (in the user's order). `move` = take the files
    out of their folder (job folders/inbox); otherwise copy (originals/errors stay put).
    Initial page order: the duplex interleave when `roles` splits fronts/backs, else the
    plain concatenation. Returns the manifest."""
    wsid = time.strftime("%Y%m%d-%H%M%S") + "-" + os.urandom(2).hex()
    wsdir = EDIT_DIR / wsid
    for sub in ("source", "thumbs", "preview"):
        (wsdir / sub).mkdir(parents=True, exist_ok=True)
    _set_processing({"kind": "ws_open", "id": wsid, "since": time.time(),
                     "files": [p.name for p in srcs], "progress": "Dateien übernehmen"})
    taken = []
    try:
        sources, per_src_pages, taken = _ws_ingest(wsdir, srcs, move, origin)
        for (p, _dst), s in zip(taken, sources):
            s["role"] = (roles or {}).get(p.name)
        fronts = [s["name"] for s in sources if s["role"] == "front"]
        backs = [s["name"] for s in sources if s["role"] == "back"]
        if fronts and backs:
            f = [e for n in fronts for e in per_src_pages[n]]
            b = [e for n in backs for e in per_src_pages[n]]
            if DUPLEX_REVERSE:
                b = b[::-1]
            pages = []
            for i in range(max(len(f), len(b))):
                if i < len(f):
                    pages.append(f[i])
                if i < len(b):
                    pages.append(b[i])
        else:
            pages = [e for s in sources for e in per_src_pages[s["name"]]]
        for n, e in enumerate(pages, start=1):
            e["n"] = n
        m = {"version": 1, "id": wsid, "created": int(time.time()), "origin": origin, "moved": bool(move),
             "state": "ready", "sources": sources, "pages": pages,
             "title": Path(srcs[0].name).stem, "committed": None, "error": None}
        _ws_write(wsdir, m)
        log(f"workspace {wsid}: opened from {origin} ({', '.join(p.name for p in srcs)}, {len(pages)} pages)")
        return m
    except Exception:
        # Never lose the user's scans: put moved sources back, then drop the half-made workspace.
        _ws_rollback(taken, move)
        shutil.rmtree(wsdir, ignore_errors=True)
        raise
    finally:
        _set_processing(None)


def _ws_add(wsdir, m, origin, srcs, move):
    """Append more source files (and their pages) to an existing workspace. Page ids
    continue after the highest existing pN, so nothing in the editor's current plan moves;
    the editor appends the new pages to its last document. Returns the number of pages
    added. The manifest is only rewritten when everything succeeded."""
    k0 = max((int(e["img"][1:]) for e in m["pages"]), default=0)
    n0 = max((int(e.get("n", 0)) for e in m["pages"]), default=0)
    _set_processing({"kind": "ws_add", "id": m["id"], "since": time.time(),
                     "files": [p.name for p in srcs], "progress": "Dateien übernehmen"})
    taken = []
    try:
        sources, per_src_pages, taken = _ws_ingest(wsdir, srcs, move, origin, k0)
        new = [e for s in sources for e in per_src_pages[s["name"]]]
        for n, e in enumerate(new, start=n0 + 1):
            e["n"] = n
        m["sources"].extend(sources)
        m["pages"].extend(new)
        m["updated"] = int(time.time())
        _ws_write(wsdir, m)
        log(f"workspace {m['id']}: added {', '.join(s['name'] for s in sources)} from {origin} ({len(new)} pages)")
        return len(new)
    except Exception:
        _ws_rollback(taken, move)
        raise
    finally:
        _set_processing(None)


def _ws_commit(wsdir, m, docs):
    """Build one PDF per doc from the page plan (each page = source page + extra rotation),
    OCR/check/upload each, archive moved sources to originals/, mark the workspace
    committed (it stays for re-editing until the retention prune)."""
    wsid = m["id"]
    by_img = {e["img"]: e for e in m["pages"]}
    opened = {}
    results = []
    m["state"], m["error"] = "committing", None
    _ws_write(wsdir, m)
    _set_processing({"kind": "ws_commit", "id": wsid, "since": time.time(),
                     "files": [s["name"] for s in m["sources"]], "progress": "Zusammenbau"})
    try:
        for s in m["sources"]:
            opened[s["name"]] = _open_as_pdf(wsdir / "source" / s["name"])
        for di, doc in enumerate(docs, start=1):
            out = fitz.open()
            for pg in doc["pages"]:
                e = by_img[pg["img"]]
                out.insert_pdf(opened[e["src"]], from_page=e["page"], to_page=e["page"])
                if pg.get("rotate"):
                    np_ = out[-1]
                    np_.set_rotation((np_.rotation + int(pg["rotate"])) % 360)
            tmp = WORK / f"ws_{wsid}_doc{di}.pdf"
            out.save(str(tmp))
            out.close()
            title = _safe_filename(doc.get("title") or "") or None
            _set_processing(_processing, progress=f"Dokument {di}/{len(docs)}: OCR ({len(doc['pages'])} Seiten)")
            try:
                stems = " ".join(s["name"].lower() for s in m["sources"])
                detail, name, check = _process_and_upload(tmp, title or m.get("title") or wsid, fixed_title=title,
                                                          use_vlm="_vlm" in stems, force="_force" in stems,
                                                          allow_partial=len(docs) > 1)
                results.append({"title": name, "pages": len(doc["pages"]), "detail": detail,
                                "plan": doc["pages"], "page_check": check,
                                "tags": [CHECK_TAG] if check and not check["ok"] else [], "error": None})
                log(f"workspace {wsid}: doc {di}/{len(docs)} -> '{name}' {len(doc['pages'])} pages, {detail}")
            except Exception as e:
                results.append({"title": title, "pages": len(doc["pages"]), "plan": doc["pages"],
                                "page_check": None, "tags": [], "error": str(e)})
                log(f"workspace {wsid}: doc {di}/{len(docs)} ERROR: {e}")
            finally:
                tmp.unlink(missing_ok=True)
        # Moved-in sources (job folders/inbox) get their copy in originals/ exactly once —
        # per source, since ws_add can bring new moved files into an already-archived
        # workspace. Old manifests without per-source flags fall back to the workspace-level ones.
        for s in m["sources"]:
            if not s.get("moved", m.get("moved")) or s.get("archived", m.get("archived")):
                continue
            ARCHIVE.mkdir(parents=True, exist_ok=True)
            src = wsdir / "source" / s["name"]
            dst = _unique_path(ARCHIVE, Path(s["name"]).stem, Path(s["name"]).suffix)
            shutil.copy2(str(src), str(dst))
            _handoff(dst)
            s["archived"] = True
        m["archived"] = True
        failed = [r for r in results if r["error"]]
        m["committed"] = {"ts": int(time.time()), "docs": results}
        m["state"] = "error" if failed else "committed"
        m["error"] = f"{len(failed)} von {len(results)} Dokument(en) fehlgeschlagen" if failed else None
        _push_result({"ts": time.time(), "job": "editor", "origin": m["origin"], "files": [s["name"] for s in m["sources"]],
                      "title": ", ".join(str(r["title"]) for r in results), "pages": sum(r["pages"] for r in results),
                      "dropped_blank": [], "page_check": next((r["page_check"] for r in results if r["page_check"] and not r["page_check"]["ok"]), None),
                      "tags": sorted({t for r in results for t in r["tags"]}), "error": m["error"]})
    except Exception as e:
        m["state"], m["error"] = "error", str(e)
        log(f"workspace {wsid} commit ERROR: {e}")
    finally:
        for d in opened.values():
            d.close()
        _ws_write(wsdir, m)
        _set_processing(None)


_analyze_level = ANALYZE_RECMODE


def _vision_read(pix):
    """Apple Vision over a rendered pixmap: (text, chars, boxes). boxes = normalized
    (x, y, w, h) per observation IN READING ORDER (origin bottom-left) — Vision 'accurate'
    reads rotated text just as well as upright text, so the TEXT carries no orientation
    signal, but the box order does (see _orientation_from_boxes)."""
    global _analyze_level
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False, dir=str(WORK)) as tf:
        tmp = tf.name
        tf.write(pix.tobytes("png"))
    try:
        try:
            ann = ocrmac.OCR(tmp, recognition_level=_analyze_level, language_preference=LANGS).recognize()
        except ValueError as e:
            if _analyze_level == "accurate":
                raise
            log(f"analyze: Vision '{_analyze_level}' rejected the language list ({e}); using 'accurate'")
            _analyze_level = "accurate"
            ann = ocrmac.OCR(tmp, recognition_level=_analyze_level, language_preference=LANGS).recognize()
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    text = "\n".join(t.strip() for t, _c, _b in ann if t.strip())
    boxes = [tuple(b) for t, _c, b in ann if t.strip()]
    return text, len(text), boxes


def _orientation_from_boxes(boxes):
    """(rotation to ADD so the page reads upright, confidence 0..1) from the reading-order
    geometry of Vision's boxes. Measured 2026-11-01 (synthetic DE letter, 150 dpi):
      upright            -> later boxes sit LOWER  (y decreasing along reading order)
      upside down (180)  -> later boxes sit HIGHER (y increasing)
      rotated 90 cw      -> boxes progress along x, DEcreasing (header at the right) -> add 270
      rotated 270 cw     -> x INcreasing -> add 90
    Compared over ALL box pairs (rank correlation), so a few boxes sharing one line don't
    dilute the vote. Mixed layouts (columns/tables) give low confidence and are left alone."""
    n = len(boxes)
    if n < 3:
        return 0, 0.0
    ys = [b[1] for b in boxes]
    xs = [b[0] for b in boxes]
    ydown = yup = xdown = xup = 0
    for i in range(n):
        for j in range(i + 1, n):
            dy, dx = ys[j] - ys[i], xs[j] - xs[i]
            if dy < -0.005:
                ydown += 1
            elif dy > 0.005:
                yup += 1
            if dx < -0.005:
                xdown += 1
            elif dx > 0.005:
                xup += 1
    yt, xt = ydown + yup, xdown + xup
    if yt == 0 and xt == 0:
        return 0, 0.0
    # Lines stacked along y (portrait reading) vs along x (page lying on its side).
    if max(ydown, yup) / max(1, yt) >= max(xdown, xup) / max(1, xt) and yt:
        return (180, yup / yt) if yup > ydown else (0, ydown / yt)
    return (270, xdown / xt) if xdown > xup else (90, xup / xt)


def _analyze_page(page):
    """Orientation + text + page number for one source page (as currently displayed).
    ONE Vision pass: the text is orientation-independent, the box geometry gives the rotation."""
    s = ANALYZE_DPI / 72.0
    pix = page.get_pixmap(matrix=fitz.Matrix(s, s), colorspace=fitz.csGRAY, alpha=False)
    text, chars, boxes = _vision_read(pix)
    rot, conf = _orientation_from_boxes(boxes)
    if conf < 0.7 or chars < 20:
        rot = 0
    if rot:
        # Re-read upright: small rotated footers ("Seite 2 von 3") are the one thing Vision
        # does NOT read reliably on a rotated page, and that's exactly what orders the pages.
        pix = page.get_pixmap(matrix=fitz.Matrix(s, s).prerotate(rot), colorspace=fitz.csGRAY, alpha=False)
        text, chars, _ = _vision_read(pix)
    num = _page_number_of(text) or {}
    blank, dark = _is_blank_page(page)
    return {"rotate": rot, "rot_confidence": round(conf, 3), "chars": chars,
            "number": num.get("number"), "of": num.get("of"), "strong": bool(num.get("strong")),
            "blank": blank and chars < 20, "dark": round(dark, 5),
            "first": text[:300], "last": text[-200:] if len(text) > 300 else ""}


def _analyze_llm(entries):
    """ONE text call: document boundaries + positions for pages without a page number.
    Returns (splits:set, place:dict img->pos, notes:dict, info)."""
    info = {"ok": False, "ms": 0, "error": None}
    if not ANALYZE_LLM or not VLM_URL:
        info["error"] = "aus"
        return set(), {}, {}, info
    unnumbered = [e["img"] for e in entries if e["number"] is None and not e["blank"]]
    lines = []
    for e in entries:
        if e["blank"]:
            continue
        nr = f"Seitenzahl {e['number']}" + (f" von {e['of']}" if e["of"] else "") if e["number"] is not None else "keine Seitenzahl"
        snippet = re.sub(r"\s+", " ", e["first"])[:220]
        tail = re.sub(r"\s+", " ", e["last"])[:120]
        lines.append(f"[{e['img']}] Position {e['pos']}, {nr}. Anfang: \"{snippet}\"" + (f" Ende: \"{tail}\"" if tail else ""))
    prompt = (
        "Du prüfst die Seiten eines Scan-Stapels. Jede Zeile ist eine Seite mit ihrer aktuellen Position, "
        "der aufgedruckten Seitenzahl (falls erkannt) und dem Textanfang.\n\n"
        "Aufgabe 1 – Dokumentgrenzen: Nenne die Seiten, mit denen ein NEUES Dokument beginnt. Eine Grenze gibt es NUR "
        "bei einem anderen Absender, Betreff, Briefkopf oder Empfänger oder wenn eine Seite erkennbar 'Seite 1' ist. "
        "KEINE Grenze bei bloßem Themenwechsel, Kapitelwechsel oder ähnlichem Text. Die erste Seite zählt nicht als Grenze.\n"
        f"Aufgabe 2 – Nur für Seiten OHNE Seitenzahl ({', '.join(unnumbered) or 'keine'}): an welche Position (1-basiert, "
        f"bezogen auf alle {len(entries)} Seiten) gehört die Seite inhaltlich? Lass sie weg, wenn unklar.\n\n"
        "Antworte NUR mit JSON: {\"splits\": [\"p7\"], \"place\": {\"p3\": 5}, \"notes\": {\"p7\": \"kurze Begründung\"}}. "
        "notes maximal 12 Wörter je Eintrag, auf Deutsch.\n\nSeiten:\n" + "\n".join(lines))
    payload = {"model": ANALYZE_MODEL, "temperature": 0, "max_tokens": 600,
               "response_format": {"type": "json_object"},
               "messages": [{"role": "user", "content": prompt}]}
    t0 = time.time()
    try:
        r = requests.post(VLM_URL, data=json.dumps(payload), headers={"Content-Type": "application/json"},
                          timeout=VLM_TIMEOUT)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
        try:
            data = json.loads(content)
        except ValueError:
            mm = re.search(r"\{.*\}", content, re.S)
            data = json.loads(mm.group(0)) if mm else {}
        imgs = {e["img"] for e in entries}
        splits = {s for s in (data.get("splits") or []) if isinstance(s, str) and s in imgs}
        place = {}
        for k, v in (data.get("place") or {}).items():
            if k in unnumbered and isinstance(v, (int, float)) and 1 <= int(v) <= len(entries):
                place[k] = int(v)
        notes = {k: str(v)[:120] for k, v in (data.get("notes") or {}).items() if k in imgs and isinstance(v, str)}
        info.update(ok=True, ms=int((time.time() - t0) * 1000))
        return splits, place, notes, info
    except Exception as e:
        info.update(ms=int((time.time() - t0) * 1000), error=str(e)[:200])
        log(f"analyze: LLM step failed ({e}) — page numbers + orientation only")
        return set(), {}, {}, info


def _ws_analyze(wsdir, m):
    """Per-page suggestion for a workspace -> analysis.json (orientation, number, blank,
    suggested position, document boundary, reason)."""
    wsid = m["id"]
    _set_processing({"kind": "ws_analyze", "id": wsid, "since": time.time(),
                     "files": [s["name"] for s in m["sources"]], "progress": "Seite 1/%d" % len(m["pages"])})
    opened = {}
    try:
        for s in m["sources"]:
            opened[s["name"]] = _open_as_pdf(wsdir / "source" / s["name"])
        entries = []
        for i, e in enumerate(m["pages"], start=1):
            _set_processing(_processing, progress=f"Seite {i}/{len(m['pages'])} (Vision)")
            a = _analyze_page(opened[e["src"]][e["page"]])
            a.update(img=e["img"], pos=i)
            entries.append(a)
        _set_processing(_processing, progress="Reihenfolge + Dokumentgrenzen (LLM)")
        splits, place, notes, llm = _analyze_llm(entries)
        # Deterministic order. Page numbering restarts per document, so numbered pages are
        # first GROUPED into documents — by their printed total ("von N") when they have one,
        # otherwise by the segment they sit in (segments = scan order cut at LLM boundaries and
        # at every explicit "Seite 1" restart) — then sorted by number inside each group; groups
        # keep their order of first appearance. Blanks go last; unnumbered pages land at the LLM
        # position or stay where they are.
        seg = 0
        for e in entries:
            if e["img"] in splits or (e["strong"] and e["number"] == 1 and e["pos"] > 1):
                seg += 1
            e["seg"] = seg
        numbered = [e for e in entries if e["number"] is not None and not e["blank"]]
        groups = {}
        for e in numbered:
            key = ("of", e["of"]) if e["of"] else ("seg", e["seg"])
            e["group"] = key
            groups.setdefault(key, []).append(e)
        ordered_groups = sorted(groups.values(), key=lambda g: min(x["pos"] for x in g))
        order, group_first = [], set()
        for gi, g in enumerate(ordered_groups):
            g_sorted = sorted(g, key=lambda x: (x["number"], x["pos"]))
            if gi > 0:
                group_first.add(g_sorted[0]["img"])
            order.extend(g_sorted)
        rest = [e for e in entries if e not in numbered]
        for e in sorted(rest, key=lambda e: (e["blank"], place.get(e["img"], e["pos"]))):
            if e["blank"]:
                order.append(e)
            else:
                idx = place.get(e["img"], e["pos"]) - 1
                order.insert(max(0, min(idx, len(order))), e)
        result = {"ts": int(time.time()), "model": ANALYZE_MODEL if llm["ok"] else None, "llm": llm,
                  "order": [e["img"] for e in order], "pages": {}}
        for k, e in enumerate(order, start=1):
            strong_first = e["strong"] and e["number"] == 1 and k > 1
            # Numbered pages take their boundary from the number grouping only — the LLM's
            # "new sender" verdict on page 2 of a letter must not cut that letter in two.
            if e["number"] is not None:
                split = (strong_first or e["img"] in group_first) and k > 1
            else:
                split = e["img"] in splits and k > 1
            reasons = []
            if e["blank"]:
                reasons.append("leere Seite")
            if e["rotate"]:
                reasons.append(f"Text steht auf dem Kopf/quer ({e['rotate']}°, Sicherheit {int(e['rot_confidence'] * 100)} %)")
            if e["number"] is not None:
                reasons.append(f"Seitenzahl {e['number']}" + (f" von {e['of']}" if e["of"] else ""))
            elif not e["blank"]:
                reasons.append("keine Seitenzahl erkannt" + (f", LLM-Position {place[e['img']]}" if e["img"] in place else ""))
            if split:
                reasons.append("neues Dokument" + (" (Seite 1)" if strong_first else ""))
            if notes.get(e["img"]):
                reasons.append(notes[e["img"]])
            result["pages"][e["img"]] = {
                "rotate": e["rotate"], "rot_confidence": e["rot_confidence"], "number": e["number"], "of": e["of"],
                "strong": e["strong"], "chars": e["chars"], "blank": e["blank"],
                "suggested_pos": k, "in_place": k == e["pos"], "split_before": split,
                "reason": "; ".join(reasons)}
        moved = sum(1 for v in result["pages"].values() if not v["in_place"])
        rotated = sum(1 for v in result["pages"].values() if v["rotate"])
        blanks = sum(1 for v in result["pages"].values() if v["blank"])
        nsplit = sum(1 for v in result["pages"].values() if v["split_before"])
        result["summary"] = (f"{len(entries) - moved} von {len(entries)} Seiten am Platz, {moved} umsortieren, "
                             f"{rotated} drehen, {blanks} leer, {nsplit} Dokumentgrenze(n)"
                             + (f" · LLM {llm['ms'] / 1000:.1f} s" if llm["ok"] else " · ohne LLM"))
        tmp = wsdir / "analysis.json.tmp"
        tmp.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, wsdir / "analysis.json")
        log(f"workspace {wsid}: analyzed — {result['summary']}")
        return result
    finally:
        for d in opened.values():
            d.close()
        _set_processing(None)


def _ws_discard(wsdir, m):
    """Delete a workspace. Sources that were MOVED in and never sent go back where they
    came from (nothing is lost); copied or already-sent ones are simply dropped."""
    if m["state"] not in ("committed",):
        for s in m["sources"]:
            if not s.get("moved", m.get("moved")) or s.get("archived", m.get("archived")):
                continue
            back = {"duplex": INBOX / DUPLEX_SUBDIR, "stapel": INBOX / BATCH_SUBDIR}.get(s.get("origin", m["origin"]), INBOX)
            back.mkdir(parents=True, exist_ok=True)
            src = wsdir / "source" / s["name"]
            if src.exists():
                dst = _unique_path(back, Path(s["name"]).stem, Path(s["name"]).suffix)
                shutil.move(str(src), str(dst))
                os.utime(dst, None)
                _handoff(dst)
    shutil.rmtree(wsdir, ignore_errors=True)
    log(f"workspace {m['id']}: discarded")


def _apply_ws_command(cmd):
    """ws_open / ws_add / ws_analyze / ws_commit / ws_discard. Validation mirrors _apply_command;
    outcome -> _last_command."""
    global _last_command
    action = cmd.get("action")

    def done(ok, msg):
        global _last_command
        _last_command = {"ts": time.time(), "action": action, "job": "editor", "ok": ok, "msg": msg}
        if not ok:
            log(f"command {action} rejected: {msg}")

    def resolve_sources():
        """ws_open / ws_add: validate folder + file list against the folder AS IT IS NOW.
        Returns (origin, move, names, files_by_name); raises ValueError with the user message."""
        origin = cmd.get("from")
        folders = {"duplex": (INBOX / DUPLEX_SUBDIR, True, True), "stapel": (INBOX / BATCH_SUBDIR, True, True),
                   "inbox": (INBOX, True, True), "originals": (ARCHIVE, False, False), "errors": (ERRORS, False, False)}
        if origin not in folders:
            raise ValueError(f"unbekannter Ordner '{origin}'")
        fdir, move, need_settled = folders[origin]
        names = cmd.get("files")
        if not isinstance(names, list) or not names or len(set(names)) != len(names):
            raise ValueError("ungültige Dateiliste")
        files = {f["name"]: f for f in _list_job_files(fdir)}
        expect = cmd.get("expect") or {}
        for n in names:
            f = files.get(n)
            if not f:
                raise ValueError(f"'{n}' ist nicht (mehr) vorhanden")
            if need_settled and not f["settled"]:
                raise ValueError(f"'{n}' wird noch geschrieben – bitte warten")
            e = expect.get(n)
            if e is not None and list(e) != [f["size"], f["pages"]]:
                raise ValueError(f"'{n}' hat sich seit der Anzeige geändert – bitte erneut prüfen")
        return origin, move, names, files

    if action == "ws_open":
        try:
            origin, move, names, files = resolve_sources()
        except ValueError as e:
            return done(False, str(e))
        roles = None
        if origin == "duplex":
            roles = cmd.get("roles") if isinstance(cmd.get("roles"), dict) else None
            if not roles:
                k = _duplex_split([files[n]["pages"] for n in names])
                if k:
                    roles = {n: ("front" if i < k else "back") for i, n in enumerate(names)}
        try:
            m = _ws_create(origin, [files[n]["path"] for n in names], move, roles)
        except Exception as e:
            return done(False, f"Arbeitsmappe konnte nicht angelegt werden: {e}")
        return done(True, f"Arbeitsmappe {m['id']} angelegt ({len(m['pages'])} Seiten)")

    wsdir = _ws_dir(cmd.get("id"))
    if not wsdir:
        return done(False, "Arbeitsmappe nicht gefunden")
    m = _ws_read(wsdir)
    if action == "ws_discard":
        back = m["state"] != "committed" and any(
            s.get("moved", m.get("moved")) and not s.get("archived", m.get("archived")) for s in m["sources"])
        _ws_discard(wsdir, m)
        return done(True, "Arbeitsmappe verworfen" + (" – Dateien zurück im Ordner" if back else ""))
    if action == "ws_add":
        if m["state"] == "committing":
            return done(False, "wird gerade gesendet")
        try:
            origin, move, names, files = resolve_sources()
        except ValueError as e:
            return done(False, str(e))
        try:
            n = _ws_add(wsdir, m, origin, [files[x]["path"] for x in names], move)
        except Exception as e:
            return done(False, f"Dateien konnten nicht hinzugefügt werden: {e}")
        return done(True, f"{n} Seiten hinzugefügt")
    if action == "ws_analyze":
        if m["state"] == "committing":
            return done(False, "wird gerade gesendet")
        _last_command = {"ts": time.time(), "action": action, "job": "editor", "ok": True,
                         "msg": f"Analyse gestartet ({len(m['pages'])} Seiten)"}
        try:
            res = _ws_analyze(wsdir, m)
        except Exception as e:
            return done(False, f"Analyse fehlgeschlagen: {e}")
        return done(True, "Analyse fertig: " + res["summary"])
    if action != "ws_commit":
        return done(False, f"unbekannte Aktion '{action}'")
    if m["state"] == "committing":
        return done(False, "wird gerade gesendet")
    docs = cmd.get("docs")
    imgs = {e["img"] for e in m["pages"]}
    used = set()
    if not isinstance(docs, list) or not docs:
        return done(False, "kein Dokument angegeben")
    for doc in docs:
        pages = doc.get("pages") if isinstance(doc, dict) else None
        if not isinstance(pages, list) or not pages:
            return done(False, "ein Dokument hat keine Seiten")
        for pg in pages:
            img = pg.get("img") if isinstance(pg, dict) else None
            if img not in imgs:
                return done(False, f"unbekannte Seite '{img}'")
            if img in used:
                return done(False, f"Seite '{img}' doppelt verwendet")
            used.add(img)
            if pg.get("rotate", 0) not in (0, 90, 180, 270):
                return done(False, "ungültige Drehung")
    n_docs, n_pages = len(docs), len(used)
    _last_command = {"ts": time.time(), "action": action, "job": "editor", "ok": True,
                     "msg": f"Senden gestartet: {n_docs} Dokument(e), {n_pages} Seiten"}
    _ws_commit(wsdir, m, docs)


def jobs_once():
    global _last_command
    cmd = _read_command()
    if cmd and str(cmd.get("action", "")).startswith("ws_"):
        try:
            _apply_ws_command(cmd)
        except Exception as e:
            _last_command = {"ts": time.time(), "action": cmd.get("action"), "job": "editor", "ok": False, "msg": str(e)}
            log(f"workspace command failed: {e}\n{traceback.format_exc()}")
    elif cmd:
        todo = _apply_command(cmd)
        if todo:
            job, jdir, plan = todo
            _run_job(job, jdir, plan, "dashboard")
    for job, (jdir, mode) in _job_dirs().items():
        st = _job_state(job, jdir, mode)
        _job_states[job] = st
        if st["state"] not in ("auto-pending", "lone"):
            continue
        by_name = {f["name"]: f for f in _list_job_files(jdir)}
        prop = st["proposal"] or {}
        if mode == "duplex" and st["state"] == "auto-pending":
            plan = {"kind": "merge", "fronts": [by_name[n]["path"] for n in prop["fronts"]],
                    "backs": [by_name[n]["path"] for n in prop["backs"]], "reverse": DUPLEX_REVERSE}
        else:
            names = prop.get("order") or [f["name"] for f in st["files"] if f["settled"]]
            plan = {"kind": "concat", "order": [by_name[n]["path"] for n in names if n in by_name]}
        if not (plan.get("order") or plan.get("fronts")):
            continue
        _run_job(job, jdir, plan, "auto" if st["state"] == "auto-pending" else "lone-timeout")
        _job_states[job] = _job_state(job, jdir, mode)


def _errors_count():
    try:
        return sum(1 for f in ERRORS.iterdir() if f.is_file() and not f.name.startswith("."))
    except OSError:
        return 0


def _write_status():
    """Publish the worker's view for the dashboard (atomic replace) and refresh the MOTD."""
    doc = {"version": 1, "ts": int(time.time()),
           "config": {"quiet_sec": JOB_QUIET, "stable_sec": STABLE_SEC, "duplex_timeout_sec": DUPLEX_TIMEOUT,
                      "duplex_auto": DUPLEX_AUTO, "reverse": DUPLEX_REVERSE, "drop_blank_backs": DROP_BLANK_BACKS,
                      "page_check": PAGE_CHECK, "check_tag": CHECK_TAG,
                      "retention_days": ARCHIVE_RETENTION_DAYS},
           "jobs": _job_states, "workspaces": _ws_list(), "processing": _processing,
           "last_command": _last_command, "last_results": _last_results,
           "errors": _errors_count()}
    try:
        WORK.mkdir(parents=True, exist_ok=True)
        tmp = STATUS_FILE.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, STATUS_FILE)
    except Exception as e:
        log(f"status write failed: {e}")
    _write_motd_status()


def _motd_text():
    url = f"http://{socket.gethostname()}:{DASHBOARD_PORT}/#paperless"
    lines = []
    for job, st in _job_states.items():
        n = len(st.get("files") or [])
        if st["state"] == "held":
            lines.append(f"⚠ {job}: {n} Datei(en) warten auf Bestätigung ({st['total_pages']} Seiten) – {st['reason']}")
        elif st["state"] in ("waiting", "lone") and n:
            lines.append(f"{job}: {n} Datei(en) gesammelt – {st['reason']}")
    nerr = _errors_count()
    if nerr:
        lines.append(f"⚠ {nerr} Datei(en) in errors/ – im Dashboard prüfen")
    open_ws = [w for w in _ws_list() if w["state"] in ("ready", "error")]
    if open_ws:
        w = open_ws[0]
        more = f" (+{len(open_ws) - 1} weitere)" if len(open_ws) > 1 else ""
        since = time.strftime("%d.%m. %H:%M", time.localtime(w["created"]))
        lines.append(f"⚠ Arbeitsmappe {w['id']}: {w['page_count']} Seiten, offen seit {since}{more}"
                     + (f" – FEHLER: {w['error']}" if w["state"] == "error" else ""))
    if _processing:
        lines.append(f"Verarbeitung läuft: {', '.join(_processing.get('files') or [])} ({_processing.get('progress', '')})")
    if _last_results:
        r = _last_results[0]
        when = time.strftime("%d.%m. %H:%M", time.localtime(r["ts"]))
        if r.get("error"):
            lines.append(f"⚠ letzte Verarbeitung {when} FEHLER: {', '.join(r['files'])} – {r['error'][:80]}")
        else:
            flag = f" ⚠ {CHECK_TAG}" if r.get("tags") else ""
            lines.append(f"letzte Verarbeitung {when}: „{r.get('title')}“ ({r.get('pages')} Seiten){flag}")
    if not lines:
        lines.append("keine offenen Jobs")
    # ⚠ lines first (the composer prints them in order).
    lines.sort(key=lambda s: 0 if s.startswith("⚠") else 1)
    return url + "\n" + "\n".join(lines[:5]) + "\n"


def _write_motd_status():
    global _motd_last
    try:
        text = _motd_text()
        if text == _motd_last:
            return
        MOTD_STATUS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = MOTD_STATUS_FILE.with_suffix(".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.chmod(tmp, 0o644)
        os.replace(tmp, MOTD_STATUS_FILE)
        _motd_last = text
        if os.access(MOTD_COMPOSE, os.X_OK):
            subprocess.run([MOTD_COMPOSE, "/etc/motd.macstudio.base", "/etc/motd"],
                           capture_output=True, timeout=20)  # exit 1 = unchanged, fine
    except Exception as e:
        log(f"motd status failed: {e}")


def gateway_tick():
    gateway_once()
    jobs_once()
    prune_archive()  # delete archived originals older than the retention window (hourly)
    live = set()
    for d in [INBOX] + [jd for jd, _ in _job_dirs().values()]:
        try:
            live.update(str(p) for p in d.iterdir())
        except OSError:
            pass
    _settle_prune(live)
    _write_status()


def retrofix_once():
    # Four triggers, two axes — engine (apple/vlm) x force (respect vs override the
    # digital-born passthrough):
    #   ocr:apple        -> Apple Vision, skip if the doc already has text (safe, mass-taggable)
    #   ocr:apple-force  -> Apple Vision, re-OCR even if text exists (replace e.g. Tesseract)
    #   ocr:vlm          -> Gemma-4, skip if the doc already has text
    #   ocr:vlm-force    -> Gemma-4, re-OCR even if text exists
    ids = {
        "apple":       _tag_id(TRIGGER_TAG, create=False),
        "apple_force": _tag_id(TRIGGER_FORCE_TAG, create=False),
        "vlm":         _tag_id(VLM_TAG, create=False),
        "vlm_force":   _tag_id(VLM_FORCE_TAG, create=False),
    }
    trigger_ids = {t for t in ids.values() if t}
    if not trigger_ids:
        return  # none of the trigger tags exist yet (nobody tagged anything)
    docs = {}
    for qtid in trigger_ids:
        r = _session.get(f"{URL}/api/documents/", params={"tags__id__all": qtid}, timeout=REST_TIMEOUT)
        r.raise_for_status()
        for doc in r.json().get("results", []):
            docs[doc["id"]] = doc
    for did, doc in docs.items():
        dtags = doc.get("tags", [])
        has = lambda k: bool(ids[k]) and ids[k] in dtags
        use_vlm = has("vlm") or has("vlm_force")
        force = has("apple_force") or has("vlm_force")
        try:
            src = WORK / f"{did}.orig.pdf"
            WORK.mkdir(parents=True, exist_ok=True)
            with _session.get(f"{URL}/api/documents/{did}/download/",
                              params={"original": "true"}, stream=True, timeout=REST_XFER_TIMEOUT) as resp:
                resp.raise_for_status()
                src.write_bytes(resp.content)
            out = WORK / f"{did}.ocr.pdf"
            meta = {}
            mode, n = make_searchable(src, out, use_vlm=use_vlm, force=force, meta=meta)
            base_tags = [t for t in dtags if t not in trigger_ids]
            if mode == "passthrough":
                # Already has a good text layer and NOT forced — nothing to re-OCR. Just
                # clear the trigger tag(s); no duplicate upload. This makes it safe to
                # auto-tag a whole mail source ocr:apple — scans get re-OCR'd, digital-born
                # ones are simply released. (Use the *-force tags to re-OCR anyway.)
                _session.patch(f"{URL}/api/documents/{did}/",
                               json={"tags": base_tags}, timeout=REST_TIMEOUT).raise_for_status()
                log(f"retrofix: doc {did} already has text -> skipped (triggers cleared; "
                    f"use a *-force tag to re-OCR anyway)")
            else:
                new_tags = base_tags + [_tag_id(DONE_TAG)]
                if meta.get("kind"):
                    new_tags.append(_tag_id(PICTURE_TAG_PREFIX + meta["kind"]))
                _upload(out, title=meta.get("title") or doc.get("title"), tags=new_tags,
                        created=doc.get("created"), correspondent=doc.get("correspondent"))
                # Retag the OLD doc so it is not reprocessed: drop triggers, add superseded.
                _session.patch(f"{URL}/api/documents/{did}/",
                               json={"tags": base_tags + [_tag_id(SUPERSEDED_TAG)]}, timeout=REST_TIMEOUT).raise_for_status()
                if DELETE_ORIGINAL:
                    _session.delete(f"{URL}/api/documents/{did}/", timeout=REST_TIMEOUT)
                unit = "chars" if mode in ("vlm", "picture") else "boxes"
                log(f"retrofix: doc {did} -> searchable copy via {mode} ({n} {unit}); old retagged")
            src.unlink(missing_ok=True)
            out.unlink(missing_ok=True)
        except Exception as e:
            log(f"retrofix ERROR doc {did}: {e}")
            # Dead-letter so this doc isn't re-downloaded + re-OCR'd every poll
            # forever: drop the trigger tag(s), add ERROR_TAG. Remove the tag in
            # paperless to retry. (dtags/trigger_ids are set before the try.)
            try:
                err_base = [t for t in dtags if t not in trigger_ids]
                _session.patch(f"{URL}/api/documents/{did}/",
                               json={"tags": err_base + [_tag_id(ERROR_TAG)]},
                               timeout=REST_TIMEOUT).raise_for_status()
                log(f"retrofix: doc {did} tagged '{ERROR_TAG}' (won't retry until you remove it)")
            except Exception as e2:
                log(f"retrofix: could not dead-letter doc {did}: {e2}")


def _sleep_or_command(interval):
    """Sleep up to `interval` s, but return within ~1 s once the dashboard has written a
    command file — editor/job actions are picked up right away instead of waiting for the
    rest of the gateway tick (up to 10 s), and the single-thread command handling stays."""
    end = time.monotonic() + interval
    while True:
        left = end - time.monotonic()
        if left <= 0 or COMMAND_FILE.exists():
            return
        time.sleep(min(1.0, left))


def _loop(fn, interval, name, wake_on_command=False):
    while True:
        try:
            fn()
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
            # Transient network/DNS miss: one line, no ~25-line traceback. The loop
            # retries after `interval` either way.
            log(f"{name} loop: paperless unreachable ({type(e).__name__}): {e}")
        except Exception as e:
            log(f"{name} loop error: {e}\n{traceback.format_exc()}")
        if wake_on_command:
            _sleep_or_command(interval)
        else:
            time.sleep(interval)


def main():
    # Create the working dirs owned by the TARGET_USER (the daemon is root) so archived
    # originals dropped into them stay reachable/deletable over SMB.
    for d in (INBOX, INBOX / DUPLEX_SUBDIR, INBOX / BATCH_SUBDIR, ARCHIVE, ERRORS, WORK):
        _ensure_user_dir(d)
    EDIT_DIR.mkdir(parents=True, exist_ok=True)
    if not URL or not TOKEN:
        log("PAPERLESS_OCR_URL / PAPERLESS_OCR_TOKEN not set — idling. "
            "Set them in /usr/local/etc/macstudio.conf and restart.")
        while True:
            time.sleep(3600)
    vlm = f"{VLM_MODEL} (auto<{VLM_MIN_CHARS}ch, tag '{VLM_TAG}')" if (VLM_AUTO or VLM_URL) else "off"
    ret = f"{ARCHIVE_RETENTION_DAYS}d" if ARCHIVE_RETENTION_DAYS > 0 else "keep-forever"
    log(f"starting: url={URL} langs={LANGS} recmode={RECMODE} dpi={DPI} "
        f"inbox={INBOX} duplex={INBOX / DUPLEX_SUBDIR} stapel={INBOX / BATCH_SUBDIR} "
        f"tags=[{TRIGGER_TAG},{TRIGGER_FORCE_TAG},{VLM_TAG},{VLM_FORCE_TAG}] "
        f"vlm-fallback={vlm} smart-name={'on' if SMART_NAME else 'off'} "
        f"archive-retention={ret} poll={POLL}s job-quiet={JOB_QUIET}s "
        f"duplex-auto={'on' if DUPLEX_AUTO else 'off'} page-check={'on' if PAGE_CHECK else 'off'}")
    _write_status()  # a fresh ts right away, so the dashboard never shows a stale worker
    threading.Thread(target=_loop, args=(gateway_tick, GATEWAY_POLL, "gateway", True), daemon=True).start()
    threading.Thread(target=_loop, args=(retrofix_once, POLL, "retrofix"), daemon=True).start()
    while True:
        time.sleep(60)


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--ocr":
        # one-shot CLI:  --ocr in.(pdf|img) out.pdf [--langs ru-RU,en-US] [--vlm]
        args = sys.argv[2:]
        use_vlm = False
        if "--vlm" in args:  # force the Gemma-4 route (handwriting/math)
            use_vlm = True
            args.remove("--vlm")
        if "--langs" in args:
            i = args.index("--langs")
            LANGS = [s.strip() for s in args[i + 1].split(",") if s.strip()]
            del args[i:i + 2]
        if len(args) != 2:
            sys.exit("usage: paperless-ocr.py --ocr INPUT OUTPUT.pdf [--langs ru-RU,en-US] [--vlm]")
        WORK.mkdir(parents=True, exist_ok=True)
        if use_vlm:
            count = vlm_ocr_pdf(args[0], args[1])
            log(f"CLI: {args[0]} -> {args[1]} ({count} chars via VLM {VLM_MODEL})")
        else:
            count = ocr_pdf(args[0], args[1])
            log(f"CLI: {args[0]} -> {args[1]} ({count} text boxes, langs={LANGS})")
    else:
        main()
