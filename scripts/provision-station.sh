#!/usr/bin/env bash
# Configure a Relink tablet for unattended CUUB POS + install the latest app.
#
# One command per station in a batch. Does everything seed/redeploy used to
# require separately:
#   - disable Relink launcher (APK stays on disk)
#   - install latest CUUB POS (OTA default, or build from git checkout)
#   - grant location for good, location services on, no lock screen, stay awake
#   - set CUUB as HOME
#   - seed T-Mobile IoT APN (iot.t-mobile.com) + enable cellular data
#   - verify cabinet SN, yszc bridge, permissions, HOME
#
# Usage:
#   ./scripts/provision-station.sh                    # one connected device
#   ./scripts/provision-station.sh 98b8f6a            # USB serial prefix
#   ./scripts/provision-station.sh adb-98b8f6a-…._tcp # wireless adb
#
# Options:
#   --source ota      Latest APK from GitHub OTA repo (default; cached per batch)
#   --source local    Build release APK from this git checkout
#   --apk FILE        Install this APK as is (the prebuilt pilot APK in a kiosk kit)
#   --sleeper         Background CUUB (Relink stays HOME). Builds local -PSLEEPER_MODE=true
#   --fresh           Uninstall CUUB before install (clears ONE_TIME location on 028-style tablets)
#   --config-only     Skip APK install; re-run Android kiosk config only
#
# Needs: adb. OTA mode needs curl + internet on first tablet (APK cached in .seed-cache/).
# Do not disable com.yszc.serialports.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/provision-common.sh
source "$ROOT/scripts/lib/provision-common.sh"

SOURCE="ota"
APK_FILE=""
FRESH=0
CONFIG_ONLY=0
SLEEPER=0
DEVICE_ARG=""

usage() {
  sed -n '2,25p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE="${2:-}"
      shift 2
      ;;
    --apk)
      APK_FILE="${2:-}"
      SOURCE="apk"
      shift 2
      ;;
    --fresh) FRESH=1; shift ;;
    --sleeper) SLEEPER=1; shift ;;
    --config-only) CONFIG_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; DEVICE_ARG="${1:-}"; break ;;
    -*)
      echo "Unknown option: $1" >&2
      usage 1
      ;;
    *)
      DEVICE_ARG="$1"
      shift
      ;;
  esac
done

if [[ "$SOURCE" == "apk" ]]; then
  [[ -f "$APK_FILE" ]] || { echo "--apk: no file at '$APK_FILE'" >&2; exit 1; }
  [[ "$SLEEPER" -eq 0 ]] || { echo "--apk cannot be combined with --sleeper" >&2; exit 1; }
elif [[ "$SOURCE" != "ota" && "$SOURCE" != "local" ]]; then
  echo "--source must be ota or local" >&2
  exit 1
fi

if [[ "$SLEEPER" -eq 1 && "$SOURCE" == "ota" ]]; then
  echo "sleeper: GitHub OTA APK is the kiosk — building local -PSLEEPER_MODE=true instead"
  SOURCE="local"
fi

DEVICE="$(pick_device "$DEVICE_ARG")"
ADB=(adb -s "$DEVICE")
if [[ "$SLEEPER" -eq 1 ]]; then
  echo "=== CUUB sleeper provision: $DEVICE (source=$SOURCE) ==="
else
  echo "=== CUUB station provision: $DEVICE (source=$SOURCE) ==="
fi
"${ADB[@]}" get-state >/dev/null

if [[ "$CONFIG_ONLY" -eq 0 ]]; then
  if [[ "$SLEEPER" -eq 1 ]]; then
    echo "[1/4] Leave Relink launcher enabled …"
  else
    echo "[1/4] Disable Relink launcher …"
    "${ADB[@]}" shell pm disable-user --user 0 "$RELINK_PKG" || {
      echo "WARN: could not disable $RELINK_PKG" >&2
    }
  fi

  echo "[2/4] Install CUUB POS …"
  APK=""
  if [[ "$SOURCE" == "apk" ]]; then
    APK="$APK_FILE"
  elif [[ "$SOURCE" == "ota" ]]; then
    APK="$(download_ota_apk "$ROOT/.seed-cache")"
  else
    ensure_java_home
    GRADLE_FLAGS=()
    if [[ "$SLEEPER" -eq 1 ]]; then
      GRADLE_FLAGS+=(-PSLEEPER_MODE=true)
      echo "  sleeper build (versionCode stays 2; does not match GitHub kiosk)"
    elif [[ -n "${OTA_MANIFEST_URL+set}" && -z "$OTA_MANIFEST_URL" ]]; then
      echo "  pilot build: OTA off, version ${OTA_VERSION_NAME:-default}"
    else
      if manifest_line="$(fetch_ota_manifest "$ROOT/.seed-cache" 2>/dev/null || true)"; then
        ota_code="${manifest_line%% *}"
        ota_name="${manifest_line#* }"
        [[ -n "$ota_code" ]] && GRADLE_FLAGS+=(-POTA_VERSION_CODE="$ota_code")
        [[ -n "$ota_name" && "$ota_name" != "$ota_code" ]] && GRADLE_FLAGS+=(-POTA_VERSION_NAME="$ota_name")
        echo "  matching OTA version for local build: ${ota_name:-?} (${ota_code:-?})"
      fi
    fi
    [[ -n "${STATION_ID:-}" ]] && GRADLE_FLAGS+=(-PSTATION_ID="$STATION_ID")
    [[ -n "${STRIPE_LOCATION_ID:-}" ]] && GRADLE_FLAGS+=(-PSTRIPE_LOCATION_ID="$STRIPE_LOCATION_ID")
    # OTA_MANIFEST_URL set but empty builds an APK whose self-updater is off.
    [[ -n "${OTA_MANIFEST_URL+set}" ]] && GRADLE_FLAGS+=(-POTA_MANIFEST_URL="$OTA_MANIFEST_URL")
    [[ -n "${KEEP_CUUB_HOME:-}" ]] && GRADLE_FLAGS+=(-PKEEP_CUUB_HOME="$KEEP_CUUB_HOME")
    [[ -n "${KIOSK_API_TOKEN:-}" ]] && GRADLE_FLAGS+=(-PKIOSK_API_TOKEN="$KIOSK_API_TOKEN")
    [[ -n "${CUUB_GATEWAY_MODE:-}" ]] && GRADLE_FLAGS+=(-PCUUB_GATEWAY_MODE="$CUUB_GATEWAY_MODE")
    [[ -n "${OTA_MANIFEST_URL+set}" && -n "${OTA_VERSION_NAME:-}" ]] && GRADLE_FLAGS+=(-POTA_VERSION_NAME="$OTA_VERSION_NAME")
    echo "  building release from git checkout …"
    (cd "$ROOT" && ./gradlew :app:assembleRelease ${GRADLE_FLAGS[@]+"${GRADLE_FLAGS[@]}"})
    APK="$ROOT/app/build/outputs/apk/release/app-release.apk"
    if [[ ! -f "$APK" ]]; then
      echo "ERROR: build failed — no APK at $APK" >&2
      exit 1
    fi
  fi

  if [[ "$FRESH" -eq 1 ]]; then
    echo "  --fresh: uninstalling $CUUB_PKG to reset permission state …"
    "${ADB[@]}" uninstall "$CUUB_PKG" || true
    "${ADB[@]}" install "$APK"
  else
    # Auto-fresh when ONE_TIME location would revoke on reboot (028-style tablets).
    loc="$(location_line "$DEVICE" || true)"
    if [[ "$loc" == *"ONE_TIME"* ]]; then
      echo "  ONE_TIME location detected — uninstall/reinstall for clean grant …"
      "${ADB[@]}" uninstall "$CUUB_PKG" || true
      "${ADB[@]}" install "$APK"
    else
      install_cuub_apk "$APK" "$DEVICE"
    fi
  fi
else
  echo "[1/4] Skip install (--config-only)"
  echo "[2/4] Skip install"
fi

echo "[3/4] Android kiosk config …"
if [[ "$SLEEPER" -eq 1 ]]; then
  bash "$ROOT/scripts/kiosk-unattended.sh" --sleeper "$DEVICE"
else
  bash "$ROOT/scripts/kiosk-unattended.sh" "$DEVICE"
fi

echo "[4/4] Start + verify …"
"${ADB[@]}" shell am force-stop com.android.settings || true
if [[ "$SLEEPER" -eq 1 ]]; then
  "${ADB[@]}" shell am start-foreground-service -n "$CUUB_PKG/.update.OtaService" \
    || "${ADB[@]}" shell am startservice -n "$CUUB_PKG/.update.OtaService" || true
  relink_home="$(resolve_relink_home "$DEVICE")"
  "${ADB[@]}" shell am start -n "$relink_home" || true
  verify_sleeper "$DEVICE"
  echo ""
  echo "Done. Relink is still the POS. CUUB is a background OTA agent."
  echo "  Cutover later: ./scripts/cutover-station.sh --source local $DEVICE"
  echo "  Logs: adb -s $DEVICE logcat -s OtaUpdater,BootReceiver,KioskTakeover"
else
  "${ADB[@]}" shell am start -n "$CUUB_PKG/.MainActivity" || true
  verify_kiosk "$DEVICE"
  # setup-kiosk.sh has more steps after this; do not tell the operator to unplug yet.
  [[ -n "${SETUP_KIOSK:-}" ]] && exit 0
  echo ""
  echo "Done. Unplug and move to the next station."
  echo "  Cold-boot smoke: power-cycle with no Settings open — Rent white in ~1 min."
  echo "  Re-enable Relink: adb -s $DEVICE shell pm enable $RELINK_PKG"
  echo "  Logs: adb -s $DEVICE logcat -s RentalViewModel,EnergoClient,HardwareManager,PaymentManager"
fi
