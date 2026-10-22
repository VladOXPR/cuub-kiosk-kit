#!/usr/bin/env bash
# Set up one kiosk tablet for CUUB, start to finish. Plug in the tablet and run:
#
#   ./scripts/setup-kiosk.sh                       # the one tablet on USB
#   ./scripts/setup-kiosk.sh 88b9226               # adb serial, if several are plugged in
#   ./scripts/setup-kiosk.sh --skip-cabinet-check  # install even if the cabinet is not on CUUB
#
#   1. Checks the laptop (adb, gcloud login) and reads the station ID from the tablet.
#   2. Waits until the cabinet is on the CUUB broker; the pilot app cannot rent otherwise.
#   3. Installs the CUUB pilot app (1.0.2-pilot, updates from the prod manifest) and configures
#      Android: permissions, Home, no lock screen, T-Mobile IoT data. In a kiosk kit
#      (scripts/build-kiosk-kit.sh) it installs the kit's APK instead of building one.
#   4. Backs up the Relink app (kit: relink-backup/<station>/, repo: .seed-cache/relink-backup/)
#      and uninstalls it.
#   5. Waits for the kiosk's first heartbeat in cuub-api.
#   6. Asks you to swap the laptop for the M2 reader and power-cycle the station, then
#      waits until the cabinet answers cuub-api again and the reader connects.
#
# Safe to run again on the same tablet. Undo: ./scripts/reset-to-relink.sh
# Needs gcloud (gcloud auth login) and curl. Outside a kit also adb and Android Studio (JDK).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/provision-common.sh
source "$ROOT/scripts/lib/provision-common.sh"

PROJECT="${GCP_PROJECT:-keyextract-482721}"
API_URL="${CUUB_API_URL:-https://platform.cuub.tech}"
BROKER_VM=mqtt
BROKER_ZONE=us-central1-a

CHECK_CABINET=1
DEVICE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --skip-cabinet-check) CHECK_CABINET=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) DEVICE_ARG="$arg" ;;
  esac
done

step() { echo; echo "=== $* ==="; }
die() { echo; echo "STOP: $*" >&2; exit 1; }

MACHINE_TOKEN=""
STATION=""
PYTHON=""

station_json() {
  curl -fsS "$API_URL/stations/by-manufacture/$STATION" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "$MACHINE_TOKEN")
}

# json_field '<station json>' cabinet.seenAt → value, or empty when missing.
json_field() {
  "$PYTHON" - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(0)
d = d.get("data", d)
for key in sys.argv[2].split("."):
    d = d.get(key) if isinstance(d, dict) else None
if d is not None:
    print(str(d).lower() if isinstance(d, bool) else d)
PY
}

cabinet_seen() {
  [[ -n "$(json_field "$(station_json 2>/dev/null || true)" cabinet.seenAt)" ]] && return 0
  gcloud compute ssh "$BROKER_VM" --zone "$BROKER_ZONE" --project "$PROJECT" --quiet \
    --command "sudo docker logs --since 24h deploy-mosquitto-1 2>&1 | grep -c \"u.$STATION.)\"" 2>/dev/null \
    | tail -1 | grep -qv '^0$'
}

step "1/6 Laptop and tablet"
command -v gcloud >/dev/null || die "the Google Cloud CLI (gcloud) is not installed: https://cloud.google.com/sdk/docs/install"
for cmd in adb curl; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed"
done
MACHINE_TOKEN="$(gcloud secrets versions access latest --secret machine-api-token --project "$PROJECT" 2>/dev/null)" \
  || die "gcloud could not read the API token. Run: gcloud auth login
  (with a Google account that has access to project $PROJECT)"
PYTHON="$(kit_python)"
[[ -n "$PYTHON" ]] || die "no Python found; gcloud normally brings its own. Reinstall the Google Cloud CLI."
DEVICE="$(pick_device "$DEVICE_ARG")"
ADB=(adb -s "$DEVICE")
"${ADB[@]}" get-state >/dev/null
STATION="$("${ADB[@]}" shell cat /sdcard/Download/station.txt 2>/dev/null | tr -d '\r' | head -1 || true)"
[[ "$STATION" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] \
  || die "the tablet has no station ID in /sdcard/Download/station.txt"
json="$(station_json)" || die "could not find $STATION in cuub-api (missing station, or no internet on the laptop)"
echo "  tablet $DEVICE is station $STATION"
echo "  venue: $(json_field "$json" currentLocation.title), plan: $(json_field "$json" pricePlan.name)"
echo "  kiosk app now: $(json_field "$json" appVersion)"
if [[ "$("${ADB[@]}" shell getprop ro.build.type | tr -d '\r')" != "userdebug" ]]; then
  echo "  WARN: not a userdebug build; the APN step and a downgrade from OTA 0.9.x can fail" >&2
fi

step "2/6 Cabinet on the CUUB broker"
if [[ "$CHECK_CABINET" -eq 0 ]]; then
  echo "  skipped (--skip-cabinet-check)"
elif cabinet_seen; then
  echo "  cabinet has logged in to mqtt.cuub.tech"
else
  echo "  Not on the CUUB broker yet. Power-cycle the station; waiting up to 5 min …"
  seen=0
  for _ in $(seq 1 20); do
    sleep 15
    if cabinet_seen; then seen=1; break; fi
  done
  [[ "$seen" -eq 1 ]] || die "the cabinet never logged in to mqtt.cuub.tech. Read back WriteAddress
  (mqtt.cuub.tech / 8883) and WriteSecurity, power-cycle, and run this again. Nothing on the tablet changed."
  echo "  cabinet has logged in to mqtt.cuub.tech"
fi

step "3/6 CUUB pilot app"
if [[ -f "$KIT_APK" ]]; then
  OTA_VERSION_NAME="$(tr -d '[:space:]' < "$ROOT/apk/version.txt")"
  echo "  installing $OTA_VERSION_NAME from this kit"
  SETUP_KIOSK=1 bash "$ROOT/scripts/provision-station.sh" --apk "$KIT_APK" "$DEVICE" \
    || die "install or verify failed (see the FAIL lines above). Relink was disabled but not uninstalled; fix and run again."
else
  export_pilot_build_env "$PROJECT"
  echo "  building $OTA_VERSION_NAME, updates from $OTA_MANIFEST_URL"
  SETUP_KIOSK=1 bash "$ROOT/scripts/provision-station.sh" --source local "$DEVICE" \
    || die "install or verify failed (see the FAIL lines above). Relink was disabled but not uninstalled; fix and run again."
fi

step "4/6 Remove Relink"
wait_for_usb "$DEVICE"
read -r relink_path relink_user <<< "$(relink_on_disk "$DEVICE")"
if [[ -z "$relink_path" ]]; then
  echo "  Relink is not on the tablet"
else
  backup="$RELINK_BACKUP_DIR/$STATION"
  backed_up=0
  if ls "$backup"/*.apk >/dev/null 2>&1; then
    backed_up=1
  else
    mkdir -p "$backup"
    relink_apks="$("${ADB[@]}" shell "ls '$relink_path'/*.apk" 2>/dev/null | tr -d '\r' || true)"
    backed_up=1
    [[ -n "$relink_apks" ]] || backed_up=0
    while IFS= read -r apk; do
      [[ -n "$apk" ]] || continue
      if ! pulled="$("${ADB[@]}" pull "$apk" "$backup/" 2>&1)"; then
        echo "$pulled" >&2
        backed_up=0
      fi
    done <<< "$relink_apks"
    "${ADB[@]}" shell dumpsys package "$RELINK_PKG" | tr -d '\r' \
      | awk '/versionCode=|versionName=/ && n < 2 {print; n++}' > "$backup/version.txt" || true
  fi
  if [[ "$backed_up" -eq 0 ]]; then
    echo "  WARN: could not back up Relink from $relink_path, so it stays installed (disabled and hidden, it cannot start)" >&2
  else
    echo "  Relink backed up in ${backup#"$KIT_ROOT/"}"
    if [[ "$relink_user" == "installed=false" ]]; then
      echo "  Relink already uninstalled"
    elif "${ADB[@]}" shell pm uninstall -k --user 0 "$RELINK_PKG" | tr -d '\r' | grep -q Success; then
      echo "  uninstalled $RELINK_PKG"
    else
      echo "  WARN: Android refused the uninstall; Relink stays disabled and hidden, so it still cannot start" >&2
    fi
  fi
fi
home="$(home_package "$DEVICE")"
[[ "$home" == "$CUUB_PKG" ]] || die "Home is ${home:-none}, not CUUB"
echo "  Home is CUUB"
if [[ "$(device_owner_pkg "$DEVICE")" == *"$CUUB_PKG"* ]]; then
  ota_status="yes"
else
  ota_status="NO: CUUB is not device owner, so an OTA update would wait for a tap on the screen"
fi

step "5/6 First heartbeat in cuub-api"
beat=0
for _ in $(seq 1 24); do
  json="$(station_json 2>/dev/null || true)"
  if [[ "$(json_field "$json" appVersion)" == "$OTA_VERSION_NAME" && "$(json_field "$json" online)" == "true" ]]; then
    beat=1
    break
  fi
  sleep 5
done
[[ "$beat" -eq 1 ]] || die "no heartbeat from $OTA_VERSION_NAME after 2 min. Check the tablet's internet:
  adb -s $DEVICE shell 'cmd phone data disable; cmd phone data enable'"
echo "  kiosk online on $OTA_VERSION_NAME"

step "6/6 Power-cycle, card reader"
# The cabinet's broker session runs through com.yszc.serialports on the tablet,
# and the cabinet only logs in at power-up. Removing Relink drops that session.
echo "  1. Unplug the laptop from the tablet and plug the M2 card reader into the tablet's USB."
echo "  2. Power-cycle the station (off 10 s, then on). The cabinet has to log in again"
echo "     now that Relink is gone; until then it cannot rent."
since="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
echo "  Waiting up to 10 min for the cabinet and the reader (Ctrl-C is safe; the kiosk is set up) …"
cabinet="" reader="" nudged=0
for i in $(seq 1 120); do
  json="$(station_json 2>/dev/null || true)"
  seen="$(json_field "$json" cabinet.seenAt)"
  if [[ -n "$seen" ]] && (( ${seen//[^0-9]/} >= ${since//[^0-9]/} )); then
    status=answering
  else
    status="silent since ${seen:-never}"
  fi
  [[ "$status" != "$cabinet" ]] && echo "  cabinet: $status"
  cabinet="$status"
  status="$(json_field "$json" readerStatus)"
  [[ "$status" != "$reader" ]] && echo "  reader: ${status:-unknown}"
  reader="$status"
  [[ "$cabinet" == answering && "$reader" == connected ]] && break
  if [[ "$cabinet" != answering && "$i" -eq 48 && "$nudged" -eq 0 ]]; then
    echo "  Cabinet still silent after 4 min: power-cycle the station once more."
    nudged=1
  fi
  sleep 5
done

json="$(station_json 2>/dev/null || true)"
echo
echo "=== $STATION done ==="
echo "  kiosk    $(json_field "$json" appVersion), online=$(json_field "$json" online)"
echo "  ota      $ota_status"
echo "  reader   $(json_field "$json" readerStatus)"
echo "  cabinet  online=$(json_field "$json" cabinet.online), slots=$(json_field "$json" cabinet.slots), banks=$(json_field "$json" cabinet.occupied)"
[[ "$reader" == "connected" ]] || echo "  The reader is not ready: check the M2 is on the tablet's USB and charged."
[[ "$cabinet" == answering ]] || die "the cabinet has not answered since the power-cycle, so the station cannot rent.
  Power-cycle it again and watch the dashboard. If it stays offline, check the serial cable
  between the tablet and the cabinet board, and that com.yszc.serialports is installed."
echo "  Last step: one test rent and return."
