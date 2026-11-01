#!/usr/bin/env bash
# motd-compose.sh <base> <dst> — write <dst> (/etc/motd) = <base> (the rendered
# motd.txt) + an optional "action needed" block for the runtime flags the weekly
# autoupdate leaves behind + an optional Paperless-OCR scan-job block. Called by
# setup.sh's render_motd, at the end of every weekly-autoupdate.sh run, and by
# paperless-ocr.py on every status change — so the blocks appear/clear without --apply.
# Writes only on a real diff; exit 0 = changed, 1 = unchanged/nothing to do.
set -u

BASE=${1:-/etc/motd.macstudio.base}
DST=${2:-/etc/motd}
FLAG_DIR=/var/macstudio
[ -r "$BASE" ] || exit 1

tmp=$(/usr/bin/mktemp -t macstudio-motd) || exit 1
trap '/bin/rm -f "$tmp"' EXIT

/bin/cat "$BASE" >"$tmp"
if [ -f "$FLAG_DIR/update-pending" ] || [ -f "$FLAG_DIR/reboot-pending" ]; then
  {
    echo "  ⚠ ACTION NEEDED"
    if [ -f "$FLAG_DIR/update-pending" ]; then
      # update-pending holds one line per downloaded macOS update label.
      while IFS= read -r label; do
        [ -n "$label" ] || continue
        echo "    macOS update ready: $label"
        echo "      sudo softwareupdate -i \"$label\" -R   (asks password, reboots)"
      done <"$FLAG_DIR/update-pending"
    fi
    if [ -f "$FLAG_DIR/reboot-pending" ]; then
      echo "    A restart is pending since $(/bin/cat "$FLAG_DIR/reboot-pending"): sudo reboot"
    fi
    echo "══════════════════════════════════════════════════════════════════"
  } >>"$tmp"
fi

# Paperless-OCR scan-job status (written by paperless-ocr.py whenever it changes, which
# then re-runs this composer): line 1 = dashboard URL, the rest = status lines (⚠ first).
PO_STATUS=$FLAG_DIR/paperless-ocr-status
if [ -s "$PO_STATUS" ]; then
  {
    echo "  Paperless-OCR"
    url=""; first=1
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$first" = 1 ]; then url=$line; first=0; continue; fi
      [ -n "$line" ] || continue
      echo "    $line"
    done <"$PO_STATUS"
    [ -n "$url" ] && echo "    → $url"
    echo "══════════════════════════════════════════════════════════════════"
  } >>"$tmp"
fi

if [ -f "$DST" ] && /usr/bin/cmp -s "$tmp" "$DST"; then exit 1; fi
/bin/chmod 644 "$tmp"
/usr/sbin/chown root:wheel "$tmp" 2>/dev/null || true
/bin/mv -f "$tmp" "$DST"
exit 0
