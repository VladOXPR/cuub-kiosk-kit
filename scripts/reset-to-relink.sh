#!/usr/bin/env bash
# Restore Relink as the launcher and remove CUUB (including device owner).
#
# Needed before a sleeper seed on a tablet that already ran CUUB kiosk:
# adb uninstall fails while CUUB is device owner.
#
# Usage:
#   ./scripts/reset-to-relink.sh
#   ./scripts/reset-to-relink.sh 98b8f6a
#
# Does not disable com.yszc.serialports. If device-owner removal fails,
# factory-reset the tablet (the only remaining way to clear DO).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/provision-common.sh
source "$ROOT/scripts/lib/provision-common.sh"

ADMIN="$CUUB_PKG/.kiosk.StationDeviceAdminReceiver"

DEVICE="$(pick_device "${1:-}")"
ADB=(adb -s "$DEVICE")
echo "=== Reset to Relink: $DEVICE ==="
"${ADB[@]}" get-state >/dev/null

# setup-kiosk.sh uninstalls Relink and keeps its APK in $RELINK_BACKUP_DIR/<station>/.
read -r relink_path relink_user <<< "$(relink_on_disk "$DEVICE")"
if [[ -z "$relink_path" || "$relink_user" != "installed=true" ]]; then
  echo "[0/5] Relink is not installed; restoring it …"
  "${ADB[@]}" shell cmd package install-existing "$RELINK_PKG" >/dev/null 2>&1 || true
  read -r relink_path relink_user <<< "$(relink_on_disk "$DEVICE")"
  if [[ -z "$relink_path" || "$relink_user" != "installed=true" ]]; then
    station="$("${ADB[@]}" shell cat /sdcard/Download/station.txt 2>/dev/null | tr -d '\r' | head -1 || true)"
    backup="$RELINK_BACKUP_DIR/$station"
    apks=("$backup"/*.apk)
    [[ -e "${apks[0]}" ]] || { echo "No Relink backup in $backup" >&2; exit 1; }
    if [[ ${#apks[@]} -gt 1 ]]; then
      "${ADB[@]}" install-multiple -r "${apks[@]}"
    else
      "${ADB[@]}" install -r "${apks[0]}"
    fi
  fi
fi

echo "[1/5] Unhide / enable Relink (while CUUB may still be device owner) …"
"${ADB[@]}" shell pm enable --user 0 "$RELINK_PKG" || true
"${ADB[@]}" shell pm unhide --user 0 "$RELINK_PKG" || true
"${ADB[@]}" root >/dev/null 2>&1 || true
sleep 1
"${ADB[@]}" wait-for-device >/dev/null 2>&1 || true
"${ADB[@]}" shell pm enable --user 0 "$RELINK_PKG" || true
"${ADB[@]}" shell pm unhide --user 0 "$RELINK_PKG" || true

echo "[2/5] Remove CUUB device owner …"
if "${ADB[@]}" shell dpm remove-active-admin "$ADMIN"; then
  echo "  device owner removed"
else
  echo "WARN: dpm remove-active-admin failed. Userdebug Relink firmware usually allows this." >&2
  echo "  dumpsys device_policy:" >&2
  "${ADB[@]}" shell dumpsys device_policy 2>/dev/null | head -20 >&2 || true
fi

echo "[3/5] Uninstall $CUUB_PKG …"
KEEP_CUUB=0
if "${ADB[@]}" uninstall "$CUUB_PKG"; then
  echo "  uninstalled"
else
  echo "WARN: uninstall blocked (device owner). Leaving CUUB installed; sleeper seed will overlay it." >&2
  KEEP_CUUB=1
  "${ADB[@]}" shell am force-stop "$CUUB_PKG" || true
fi

echo "[4/5] Pin Relink as HOME …"
relink_home="$(resolve_relink_home "$DEVICE")"
"${ADB[@]}" shell cmd package set-home-activity "$relink_home" || true
echo "  HOME=$relink_home"

echo "[5/5] Start Relink …"
"${ADB[@]}" shell am force-stop com.android.settings || true
"${ADB[@]}" shell am force-stop "$CUUB_PKG" || true
"${ADB[@]}" shell am start -n "$relink_home" || \
  "${ADB[@]}" shell monkey -p "$RELINK_PKG" -c android.intent.category.LAUNCHER 1 || true

sleep 2
home="$(home_package "$DEVICE")"
echo "  HOME now=$home enabled=$(relink_enabled "$DEVICE") hidden=$(relink_hidden "$DEVICE")"
if [[ "$home" != "$RELINK_PKG" ]]; then
  echo "WARN: HOME is not Relink (got ${home:-none})." >&2
fi
if [[ "$KEEP_CUUB" -eq 0 ]] && "${ADB[@]}" shell pm path "$CUUB_PKG" >/dev/null 2>&1; then
  echo "ERROR: $CUUB_PKG is still installed" >&2
  exit 1
fi

echo ""
if [[ "$KEEP_CUUB" -eq 1 ]]; then
  echo "Done. Relink should be the POS. CUUB stays as device owner (needed for silent OTA)."
else
  echo "Done. Relink should be the POS. CUUB is gone."
fi
echo "  Sleeper seed: ./scripts/provision-station.sh --sleeper $DEVICE"
