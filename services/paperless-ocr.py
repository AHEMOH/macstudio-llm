#!/usr/bin/env python3
"""paperless-ocr — Apple-Vision searchable-PDF service for paperless-ngx.

Runs on the Mac (Apple Vision is macOS-only). Two independent loops share one OCR
core and a small paperless-ngx REST client:

  * gateway  — watch PAPERLESS_OCR_INBOX; OCR each new file; upload the searchable
               PDF to paperless; keep the pristine original in PAPERLESS_OCR_ARCHIVE.
               A `<INBOX>/<DUPLEX_SUBDIR>` folder pairs two scans (fronts + backs)
               into one interleaved document — for simplex ADFs scanning both sides.
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
import shutil
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
DPI = int(os.environ.get("PAPERLESS_OCR_DPI", "200"))
JPEG_Q = int(os.environ.get("PAPERLESS_OCR_JPEG_Q", "75"))  # embedded page-image JPEG quality
# A PDF that ALREADY has a good text layer (digital-born, e.g. an emailed invoice from a
# report generator) is passed through untouched — rasterizing + re-OCRing it would only
# degrade perfect text. A scan (no text layer) gets Apple Vision OCR. This is the average
# stripped text chars/page above which a PDF counts as digital-born.
TEXT_MIN_CHARS = int(os.environ.get("PAPERLESS_OCR_TEXT_MIN_CHARS", "50"))

BASE = Path(os.environ.get("PAPERLESS_OCR_INBOX", "/Users/mac/paperless-ocr/inbox")).parent
INBOX = Path(os.environ.get("PAPERLESS_OCR_INBOX", str(BASE / "inbox")))
ARCHIVE = Path(os.environ.get("PAPERLESS_OCR_ARCHIVE", str(BASE / "originals")))
ERRORS = Path(os.environ.get("PAPERLESS_OCR_ERRORS", str(BASE / "errors")))
WORK = BASE / "work"

TRIGGER_TAG = os.environ.get("PAPERLESS_OCR_TRIGGER_TAG", "ocr:apple")
DONE_TAG = os.environ.get("PAPERLESS_OCR_DONE_TAG", "ocr:done")
SUPERSEDED_TAG = os.environ.get("PAPERLESS_OCR_SUPERSEDED_TAG", "ocr:superseded")
DELETE_ORIGINAL = os.environ.get("PAPERLESS_OCR_DELETE_ORIGINAL", "0") == "1"
POLL = int(os.environ.get("PAPERLESS_OCR_POLL_SEC", "60"))
GATEWAY_POLL = min(10, POLL)
# A scanned file (esp. a slow 50-page scan over SMB) must be FULLY written before
# we touch it. A file counts as "settled" only when it has not been modified for
# STABLE_SEC seconds AND no process still holds it open (e.g. smbd mid-transfer).
STABLE_SEC = int(os.environ.get("PAPERLESS_OCR_STABLE_SEC", "30"))
# Double-sided (duplex) support for simplex ADFs (e.g. Canon MAXIFY GX2050): scan the
# fronts, then flip the stack and scan the backs — both passes into the INBOX/<subdir>
# folder. The two files are interleaved here into ONE document (backs reversed, like
# paperless-ngx' collate), then OCR'd + uploaded. Needed because paperless' own collate
# is a consume-directory feature, unavailable over the API.
DUPLEX_SUBDIR = os.environ.get("PAPERLESS_OCR_DUPLEX_SUBDIR", "duplex")
DUPLEX_TIMEOUT = int(os.environ.get("PAPERLESS_OCR_DUPLEX_TIMEOUT_SEC", "1800"))
DUPLEX_REVERSE = os.environ.get("PAPERLESS_OCR_DUPLEX_REVERSE", "1") == "1"

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

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".webp"}
ACCEPT_EXTS = {".pdf"} | IMAGE_EXTS


def log(msg):
    print(f"[paperless-ocr] {msg}", flush=True)


# ------------------------------------------------------------------------- OCR core
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
    W, H = page.rect.width, page.rect.height
    placed = 0
    for text, _conf, bbox in ann:
        if not text.strip():
            continue
        # Vision bbox: normalized (x, y, w, h), origin bottom-left. Flip to top-left.
        x, y, w, h = bbox
        rx0 = x * W
        ry0 = (1.0 - (y + h)) * H
        ry1 = (1.0 - y) * H
        fs = max(4.0, (ry1 - ry0) * 0.9)
        try:
            # render_mode=3 => invisible (searchable/selectable but not drawn).
            page.insert_text((rx0, ry1 - (ry1 - ry0) * 0.2), text,
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


def make_searchable(src, dst, force_vlm=False):
    """Produce a searchable PDF at `dst`. Digital-born PDFs (already have text) are copied
    through untouched. Otherwise Apple Vision OCRs the scan; if `force_vlm` (a tag/filename
    hint) OR the Vision pass is sparse (< VLM_MIN_CHARS chars/page — a form/handwriting doc
    Vision couldn't read) and VLM_AUTO is on, re-do with the Gemma-4 vision route. Returns
    (mode, count) where mode is 'passthrough' | 'ocr' | 'vlm'."""
    src, dst = Path(src), Path(dst)
    if src.suffix.lower() == ".pdf" and _already_has_text(src):
        shutil.copy2(str(src), str(dst))
        return ("passthrough", 0)
    if force_vlm and VLM_URL:
        try:
            return ("vlm", vlm_ocr_pdf(src, dst))
        except Exception as e:
            log(f"forced VLM route failed ({e}); falling back to Apple Vision")
    n = ocr_pdf(src, dst)  # Apple Vision (fast, always run first as the printed-text pass)
    if VLM_AUTO and VLM_URL and not force_vlm and _avg_chars(dst) < VLM_MIN_CHARS:
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


def interleave(front, back, dst):
    """Merge a fronts file and a backs file (backs reversed unless DUPLEX_REVERSE=0)
    into one page-ordered PDF at `dst`, the way a duplex document reads."""
    f = _open_as_pdf(front)
    b = _open_as_pdf(back)
    out = fitz.open()
    backs = list(range(b.page_count - 1, -1, -1)) if DUPLEX_REVERSE else list(range(b.page_count))
    for i in range(max(f.page_count, len(backs))):
        if i < f.page_count:
            out.insert_pdf(f, from_page=i, to_page=i)
        if i < len(backs):
            out.insert_pdf(b, from_page=backs[i], to_page=backs[i])
    out.save(str(dst))
    out.close()
    f.close()
    b.close()


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


# ------------------------------------------------------------------- paperless client
_session = requests.Session()
if TOKEN:
    _session.headers["Authorization"] = f"Token {TOKEN}"
_session.headers["Accept"] = "application/json"


def _tag_id(name, create=True):
    r = _session.get(f"{URL}/api/tags/", params={"name__iexact": name})
    r.raise_for_status()
    res = r.json().get("results", [])
    if res:
        return res[0]["id"]
    if not create:
        return None
    r = _session.post(f"{URL}/api/tags/", json={"name": name})
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
        r = _session.post(f"{URL}/api/documents/post_document/", data=fields, files=files)
    r.raise_for_status()
    return r.text.strip().strip('"')  # consume task uuid


# --------------------------------------------------------------------------- loops
def _is_open(path):
    """True if any process still holds `path` open (e.g. smbd writing a scan)."""
    try:
        r = subprocess.run(["/usr/sbin/lsof", "--", str(path)],
                           capture_output=True, text=True, timeout=15)
        return bool(r.stdout.strip())
    except Exception:
        return False  # lsof missing/slow -> fall back to the mtime-quiet check


def _is_settled(path):
    """True once a file is safe to process: non-empty, quiet for STABLE_SEC, not
    held open. This is what prevents a half-transferred 50-page scan from being
    OCR'd mid-write."""
    try:
        st = path.stat()
    except OSError:
        return False
    if st.st_size == 0:
        return False
    if time.time() - st.st_mtime < STABLE_SEC:
        return False
    return not _is_open(path)


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
        try:
            ARCHIVE.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(p), str(ARCHIVE / p.name))
            out = WORK / (p.stem + ".ocr.pdf")
            # naming an inbox file with "_vlm" forces the Gemma-4 route (handwriting/math).
            mode, n = make_searchable(p, out, force_vlm="_vlm" in p.stem.lower())
            _upload(out, title=p.stem)
            detail = {"passthrough": "passed through (already had text)",
                      "vlm": f"VLM-OCR'd ({n} chars)"}.get(mode, f"OCR'd ({n} boxes)")
            log(f"gateway: {p.name} -> uploaded, {detail}; original archived")
            p.unlink()
            out.unlink(missing_ok=True)
        except Exception as e:
            log(f"gateway ERROR {p.name}: {e}")
            try:
                ERRORS.mkdir(parents=True, exist_ok=True)
                shutil.move(str(p), str(ERRORS / p.name))
            except Exception:
                pass


def _process_and_upload(src_pdf, title, archive_names):
    """Make `src_pdf` searchable, upload to paperless. Returns boxes placed."""
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    out = WORK / (Path(title).stem + ".ocr.pdf")
    _mode, n = make_searchable(src_pdf, out)
    _upload(out, title=title)
    out.unlink(missing_ok=True)
    return n


def duplex_once():
    """Pair up the two oldest settled files in INBOX/<DUPLEX_SUBDIR> as fronts+backs,
    interleave into one document, OCR + upload. A lone file older than DUPLEX_TIMEOUT
    is treated as single-sided (the backs pass never came)."""
    ddir = INBOX / DUPLEX_SUBDIR
    if not ddir.exists():
        return
    files = [p for p in sorted(ddir.iterdir(), key=lambda x: x.stat().st_mtime)
             if not p.is_dir() and not p.name.startswith(".")
             and p.suffix.lower() in ACCEPT_EXTS and _is_settled(p)]
    if len(files) >= 2:
        front, back = files[0], files[1]
        try:
            for s in (front, back):
                shutil.copy2(str(s), str((ARCHIVE / s.name)))
            combined = WORK / "duplex_combined.pdf"
            interleave(front, back, combined)
            n = _process_and_upload(combined, front.stem, [front, back])
            combined.unlink(missing_ok=True)
            log(f"duplex: {front.name} + {back.name} -> 1 document ({n} boxes)")
            front.unlink(); back.unlink()
        except Exception as e:
            log(f"duplex ERROR {front.name}+{back.name}: {e}")
            ERRORS.mkdir(parents=True, exist_ok=True)
            for s in (front, back):
                try:
                    shutil.move(str(s), str(ERRORS / s.name))
                except Exception:
                    pass
    elif len(files) == 1:
        p = files[0]
        if time.time() - p.stat().st_mtime > DUPLEX_TIMEOUT:
            try:
                shutil.copy2(str(p), str(ARCHIVE / p.name))
                n = _process_and_upload(p, p.stem, [p])
                log(f"duplex: lone {p.name} timed out -> uploaded single-sided ({n} boxes)")
                p.unlink()
            except Exception as e:
                log(f"duplex lone ERROR {p.name}: {e}")


def gateway_tick():
    gateway_once()
    duplex_once()


def retrofix_once():
    # Two triggers: TRIGGER_TAG (re-OCR with Apple Vision) and VLM_TAG (force the Gemma-4
    # route — for handwriting/math docs). A doc carrying VLM_TAG takes the VLM route.
    tid = _tag_id(TRIGGER_TAG, create=False)
    vlm_tid = _tag_id(VLM_TAG, create=False)
    trigger_ids = {t for t in (tid, vlm_tid) if t}
    if not trigger_ids:
        return  # nobody tagged anything yet
    docs = {}
    for qtid in trigger_ids:
        r = _session.get(f"{URL}/api/documents/", params={"tags__id__all": qtid})
        r.raise_for_status()
        for doc in r.json().get("results", []):
            docs[doc["id"]] = doc
    for did, doc in docs.items():
        force_vlm = bool(vlm_tid) and vlm_tid in doc.get("tags", [])
        try:
            src = WORK / f"{did}.orig.pdf"
            WORK.mkdir(parents=True, exist_ok=True)
            with _session.get(f"{URL}/api/documents/{did}/download/",
                              params={"original": "true"}, stream=True) as resp:
                resp.raise_for_status()
                src.write_bytes(resp.content)
            out = WORK / f"{did}.ocr.pdf"
            mode, n = make_searchable(src, out, force_vlm=force_vlm)
            base_tags = [t for t in doc.get("tags", []) if t not in trigger_ids]
            if mode == "passthrough":
                # Already has a good text layer (digital-born) — nothing to re-OCR.
                # Just clear the trigger tag(s); no duplicate upload. This makes it safe
                # to auto-tag a whole mail source ocr:apple — scans get re-OCR'd,
                # digital-born ones are simply released.
                _session.patch(f"{URL}/api/documents/{did}/",
                               json={"tags": base_tags}).raise_for_status()
                log(f"retrofix: doc {did} already has text -> skipped (triggers cleared)")
            else:
                new_tags = base_tags + [_tag_id(DONE_TAG)]
                _upload(out, title=doc.get("title"), tags=new_tags,
                        created=doc.get("created"), correspondent=doc.get("correspondent"))
                # Retag the OLD doc so it is not reprocessed: drop triggers, add superseded.
                _session.patch(f"{URL}/api/documents/{did}/",
                               json={"tags": base_tags + [_tag_id(SUPERSEDED_TAG)]}).raise_for_status()
                if DELETE_ORIGINAL:
                    _session.delete(f"{URL}/api/documents/{did}/")
                unit = "chars" if mode == "vlm" else "boxes"
                log(f"retrofix: doc {did} -> searchable copy via {mode} ({n} {unit}); old retagged")
            src.unlink(missing_ok=True)
            out.unlink(missing_ok=True)
        except Exception as e:
            log(f"retrofix ERROR doc {did}: {e}")


def _loop(fn, interval, name):
    while True:
        try:
            fn()
        except Exception as e:
            log(f"{name} loop error: {e}\n{traceback.format_exc()}")
        time.sleep(interval)


def main():
    for d in (INBOX, INBOX / DUPLEX_SUBDIR, ARCHIVE, ERRORS, WORK):
        d.mkdir(parents=True, exist_ok=True)
    if not URL or not TOKEN:
        log("PAPERLESS_OCR_URL / PAPERLESS_OCR_TOKEN not set — idling. "
            "Set them in /usr/local/etc/macstudio.conf and restart.")
        while True:
            time.sleep(3600)
    vlm = f"{VLM_MODEL} (auto<{VLM_MIN_CHARS}ch, tag '{VLM_TAG}')" if (VLM_AUTO or VLM_URL) else "off"
    log(f"starting: url={URL} langs={LANGS} recmode={RECMODE} dpi={DPI} "
        f"inbox={INBOX} duplex={INBOX / DUPLEX_SUBDIR} trigger='{TRIGGER_TAG}' "
        f"vlm-fallback={vlm} poll={POLL}s")
    threading.Thread(target=_loop, args=(gateway_tick, GATEWAY_POLL, "gateway"), daemon=True).start()
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
