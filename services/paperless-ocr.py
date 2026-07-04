#!/usr/bin/env python3
"""paperless-ocr — Apple-Vision searchable-PDF service for paperless-ngx.

Runs on the Mac (Apple Vision is macOS-only). Two independent loops share one OCR
core and a small paperless-ngx REST client:

  * gateway  — watch PAPERLESS_OCR_INBOX; OCR each new file; upload the searchable
               PDF to paperless; keep the pristine original in PAPERLESS_OCR_ARCHIVE.
  * retrofix — poll paperless for documents carrying PAPERLESS_OCR_TRIGGER_TAG;
               download the original, OCR it, re-upload as a new (searchable) copy,
               then retag the old document PAPERLESS_OCR_SUPERSEDED_TAG.

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
import io
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
            n = ocr_pdf(p, out)
            _upload(out, title=p.stem)
            log(f"gateway: {p.name} -> uploaded ({n} boxes); original archived")
            p.unlink()
            out.unlink(missing_ok=True)
        except Exception as e:
            log(f"gateway ERROR {p.name}: {e}")
            try:
                ERRORS.mkdir(parents=True, exist_ok=True)
                shutil.move(str(p), str(ERRORS / p.name))
            except Exception:
                pass


def retrofix_once():
    tid = _tag_id(TRIGGER_TAG, create=False)
    if not tid:
        return  # nobody tagged anything yet
    r = _session.get(f"{URL}/api/documents/", params={"tags__id__all": tid})
    r.raise_for_status()
    for doc in r.json().get("results", []):
        did = doc["id"]
        try:
            src = WORK / f"{did}.orig.pdf"
            WORK.mkdir(parents=True, exist_ok=True)
            with _session.get(f"{URL}/api/documents/{did}/download/",
                              params={"original": "true"}, stream=True) as resp:
                resp.raise_for_status()
                src.write_bytes(resp.content)
            out = WORK / f"{did}.ocr.pdf"
            n = ocr_pdf(src, out)
            new_tags = [t for t in doc.get("tags", []) if t != tid] + [_tag_id(DONE_TAG)]
            _upload(out, title=doc.get("title"), tags=new_tags,
                    created=doc.get("created"), correspondent=doc.get("correspondent"))
            # Retag the OLD doc so it is not reprocessed: drop trigger, add superseded.
            old_tags = [t for t in doc.get("tags", []) if t != tid] + [_tag_id(SUPERSEDED_TAG)]
            _session.patch(f"{URL}/api/documents/{did}/", json={"tags": old_tags}).raise_for_status()
            if DELETE_ORIGINAL:
                _session.delete(f"{URL}/api/documents/{did}/")
            log(f"retrofix: doc {did} -> searchable copy ({n} boxes); old retagged")
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
    for d in (INBOX, ARCHIVE, ERRORS, WORK):
        d.mkdir(parents=True, exist_ok=True)
    if not URL or not TOKEN:
        log("PAPERLESS_OCR_URL / PAPERLESS_OCR_TOKEN not set — idling. "
            "Set them in /usr/local/etc/macstudio.conf and restart.")
        while True:
            time.sleep(3600)
    log(f"starting: url={URL} langs={LANGS} recmode={RECMODE} dpi={DPI} "
        f"inbox={INBOX} trigger='{TRIGGER_TAG}' poll={POLL}s")
    threading.Thread(target=_loop, args=(gateway_once, GATEWAY_POLL, "gateway"), daemon=True).start()
    threading.Thread(target=_loop, args=(retrofix_once, POLL, "retrofix"), daemon=True).start()
    while True:
        time.sleep(60)


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--ocr":
        # one-shot CLI:  --ocr in.(pdf|img) out.pdf [--langs ru-RU,en-US]
        args = sys.argv[2:]
        if "--langs" in args:
            i = args.index("--langs")
            LANGS = [s.strip() for s in args[i + 1].split(",") if s.strip()]
            del args[i:i + 2]
        if len(args) != 2:
            sys.exit("usage: paperless-ocr.py --ocr INPUT OUTPUT.pdf [--langs ru-RU,en-US]")
        WORK.mkdir(parents=True, exist_ok=True)
        count = ocr_pdf(args[0], args[1])
        log(f"CLI: {args[0]} -> {args[1]} ({count} text boxes, langs={LANGS})")
    else:
        main()
