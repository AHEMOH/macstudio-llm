#!/usr/bin/env bash
# motd-compose.sh <base> <dst> — write <dst> (/etc/motd) = <base> (the rendered
# motd.txt) + an optional "action needed" block for the runtime flags the weekly
# autoupdate leaves behind. Called by setup.sh's render_motd and at the end of
# every weekly-autoupdate.sh run, so the block appears/clears without --apply.
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

if [ -f "$DST" ] && /usr/bin/cmp -s "$tmp" "$DST"; then exit 1; fi
/bin/chmod 644 "$tmp"
/usr/sbin/chown root:wheel "$tmp" 2>/dev/null || true
/bin/mv -f "$tmp" "$DST"
exit 0
