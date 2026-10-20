#!/usr/bin/env bash
# Shared helpers for station provisioning scripts.

RELINK_PKG="com.zhichengcloud.pos.client"
CUUB_PKG="com.cuub.station"
YSZC_PKG="com.yszc.serialports"

# A kiosk kit (scripts/build-kiosk-kit.sh) is these scripts plus a prebuilt
# pilot APK and Google's adb, so it runs on a laptop with no Android tools.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIT_APK="$KIT_ROOT/apk/cuub-station.apk"
if [[ -f "$KIT_APK" ]]; then
  RELINK_BACKUP_DIR="$KIT_ROOT/relink-backup"
else
  RELINK_BACKUP_DIR="$KIT_ROOT/.seed-cache/relink-backup"
fi
case "$(uname -s)" in
  Darwin) _kit_adb="$KIT_ROOT/tools/macos/platform-tools" ;;
  Linux) _kit_adb="$KIT_ROOT/tools/linux/platform-tools" ;;
  *) _kit_adb="" ;;
esac
if [[ -n "$_kit_adb" && -f "$_kit_adb/adb" ]]; then
  # A kit that was downloaded or AirDropped is quarantined, and copies can lose the exec bit.
  xattr -dr com.apple.quarantine "$KIT_ROOT/tools" 2>/dev/null || true
  chmod +x "$_kit_adb/adb" 2>/dev/null || true
  PATH="$_kit_adb:$PATH"
fi

# Python for JSON: gcloud always has one; a bare macOS python3 may only be the
# Xcode tools installer stub.
kit_python() {
  local py
  py="$(gcloud info --format='value(basic.python_location)' 2>/dev/null || true)"
  if [[ -n "$py" && -x "$py" ]]; then
    echo "$py"
  else
    command -v python3 || true
  fi
}
OTA_APK_URL="https://github.com/VladOXPR/cuub-station-ota/raw/ota/cuub-station.apk"
# "-" not ":-": an exported empty value (install-cuub-pilot.sh) builds an APK with the self-updater off.
OTA_MANIFEST_URL="${OTA_MANIFEST_URL-https://raw.githubusercontent.com/VladOXPR/cuub-station-ota/ota/ota-manifest.json}"

pick_device() {
  if [[ -n "${1:-}" ]]; then
    echo "$1"
    return
  fi
  local usb
  usb="$(adb devices -l | awk '$2=="device" && / usb:/{print $1}')"
  local usb_n
  usb_n="$(printf '%s\n' "$usb" | awk 'NF' | wc -l | tr -d ' ')"
  if [[ "$usb_n" == "1" ]]; then
    printf '%s\n' "$usb" | awk 'NF'
    return
  fi
  local devices
  devices="$(adb devices | awk 'NR>1 && $2=="device" {print $1}')"
  local n
  n="$(printf '%s\n' "$devices" | awk 'NF' | wc -l | tr -d ' ')"
  if [[ "$n" == "1" ]]; then
    printf '%s\n' "$devices" | awk 'NF'
    return
  fi
  echo "Plug in one USB station, pass the adb serial, or pair wireless debugging first." >&2
  adb devices -l >&2
  exit 1
}

fetch_ota_manifest() {
  local cache_dir="$1"
  mkdir -p "$cache_dir"
  if curl -fsSL "$OTA_MANIFEST_URL" -o "$cache_dir/ota-manifest.json"; then
    python3 -c "
import json, sys
d = json.load(open('$cache_dir/ota-manifest.json'))
print(d.get('versionCode', ''), d.get('versionName', ''))
" 2>/dev/null || true
  else
    echo "WARN: could not fetch OTA manifest" >&2
    return 1
  fi
}

download_ota_apk() {
  local cache_dir="$1"
  local cache_apk="$cache_dir/cuub-station.apk"
  local cache_code="$cache_dir/versionCode"
  mkdir -p "$cache_dir"

  local remote_code="" remote_name=""
  if manifest_line="$(fetch_ota_manifest "$cache_dir")"; then
    remote_code="${manifest_line%% *}"
    remote_name="${manifest_line#* }"
    echo "  OTA remote ${remote_name} (${remote_code})"
  fi

  local cached_code=""
  [[ -f "$cache_code" ]] && cached_code="$(cat "$cache_code")"
  if [[ -s "$cache_apk" && -n "$remote_code" && "$remote_code" == "$cached_code" ]]; then
    echo "  using cached APK versionCode=$cached_code"
  else
    echo "  downloading OTA APK …"
    curl -fL --progress-bar "$OTA_APK_URL" -o "$cache_apk"
    test -s "$cache_apk"
    [[ -n "$remote_code" ]] && printf '%s\n' "$remote_code" > "$cache_code"
  fi
  echo "$cache_apk"
}

install_cuub_apk() {
  local apk="$1"
  shift
  local adb=(adb)
  [[ $# -gt 0 ]] && adb=(adb -s "$1")

  if ! "${adb[@]}" install -r -d -i "$CUUB_PKG" "$apk"; then
    echo "Signature mismatch — removing old CUUB and retrying …"
    "${adb[@]}" uninstall "$CUUB_PKG" || true
    "${adb[@]}" install -i "$CUUB_PKG" "$apk"
  fi
}

# Pilot build: self-updater off (exported empty OTA_MANIFEST_URL), CUUB stays Home,
# the CUUB gateway owns cmd/22 and cmd/13, kiosk token from Secret Manager.
export_pilot_build_env() {
  local project="$1" token
  token="$(gcloud secrets versions access latest --secret kiosk-api-token --project "$project")"
  [[ -n "$token" ]] || { echo "Could not read kiosk-api-token from Secret Manager" >&2; return 1; }
  export OTA_MANIFEST_URL=""
  export KEEP_CUUB_HOME=true
  export CUUB_GATEWAY_MODE=true
  export OTA_VERSION_NAME="${OTA_VERSION_NAME:-1.0.1-pilot}"
  export KIOSK_API_TOKEN="$token"
}

# Toggling mobile data or restarting adbd can drop the tablet off USB for a while.
wait_for_usb() {
  local device="$1" _
  for _ in $(seq 1 30); do
    [[ "$(adb -s "$device" get-state 2>/dev/null)" == "device" ]] && return 0
    sleep 2
  done
  echo "  Tablet dropped off USB. Unplug and replug the cable; waiting …" >&2
  adb -s "$device" wait-for-device
}

ensure_java_home() {
  if [[ -n "${JAVA_HOME:-}" ]]; then
    return 0
  fi
  if [[ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  fi
}

# Callers run under pipefail: a reader that quits early (awk exit, grep -q)
# kills the writer with SIGPIPE and fails the whole pipeline. Read to the end.
home_package() {
  adb -s "$1" shell cmd package resolve-activity -c android.intent.category.HOME -a android.intent.action.MAIN 2>/dev/null \
    | tr -d '\r' \
    | awk -F= '/packageName=/ && !found {print $2; found=1}'
}

# Relink's HOME/LAUNCHER component. Fallback MainActivity matches OEM Relink.
resolve_relink_home() {
  local device="$1"
  local adb=(adb -s "$device")
  local comp
  comp="$("${adb[@]}" shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null \
    | tr -d '\r' | awk -v p="$RELINK_PKG" 'index($0, p) && !found { print $1; found=1 }')"
  if [[ -z "$comp" ]]; then
    comp="$("${adb[@]}" shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null \
      | tr -d '\r' | awk -v p="$RELINK_PKG" 'index($0, p) && !found { print $1; found=1 }')"
  fi
  if [[ -z "$comp" ]]; then
    echo "${RELINK_PKG}/.MainActivity"
  else
    echo "$comp"
  fi
}

device_owner_pkg() {
  local dump pkg
  dump="$(adb -s "$1" shell dumpsys device_policy 2>/dev/null | tr -d '\r')"
  pkg="$(printf '%s\n' "$dump" | awk '
    /Device Owner:/ && !found {
      getline
      if ($0 ~ /package=/) { sub(/.*package=/, ""); gsub(/[[:space:]].*/, ""); print; found=1 }
    }
  ')"
  if [[ -z "$pkg" && "$dump" == *"$CUUB_PKG"* ]]; then
    if [[ "$(printf '%s' "$dump" | tr '[:upper:]' '[:lower:]')" == *"device owner"* ]]; then
      pkg="$CUUB_PKG"
    fi
  fi
  echo "$pkg"
}

relink_hidden() {
  local line
  line="$(adb -s "$1" shell "dumpsys package $RELINK_PKG | grep -m1 hidden=" 2>/dev/null | tr -d '\r')"
  line="${line#*hidden=}"
  echo "${line%% *}"
}

# "<code path> installed=true|false" for Relink on user 0, or nothing when it is
# not on the tablet. `pm path` cannot be used: it skips Relink once CUUB hides it.
relink_on_disk() {
  adb -s "$1" shell dumpsys package "$RELINK_PKG" 2>/dev/null | tr -d '\r' \
    | awk -v pkg="Package [$RELINK_PKG]" '
      index($0, pkg) { inpkg = 1 }
      inpkg && /^ *codePath=/ && path == "" { path = $0; sub(/^ *codePath=/, "", path) }
      inpkg && /^ *User 0:/ && user == "" { user = ($0 ~ /installed=true/) ? "installed=true" : "installed=false" }
      END { if (path != "") print path, (user == "" ? "installed=true" : user) }'
}

relink_enabled() {
  if [[ "$(adb -s "$1" shell pm list packages -d 2>/dev/null)" == *"$RELINK_PKG"* ]]; then
    echo "DISABLED"
  else
    echo "enabled"
  fi
}

location_line() {
  adb -s "$1" shell dumpsys package "$CUUB_PKG" 2>/dev/null \
    | awk '/android.permission.ACCESS_FINE_LOCATION:/ && !found {print; found=1}' \
    | tr -d '\r'
}

verify_kiosk() {
  local device="$1"
  local adb=(adb -s "$device")
  local fail=0

  echo "Verify …"
  local station
  station="$("${adb[@]}" shell cat /sdcard/Download/station.txt 2>/dev/null | tr -d '\r' | head -1 || true)"
  if [[ -z "$station" ]]; then
    echo "  FAIL: missing /sdcard/Download/station.txt (Relink should have written CUBT…)" >&2
    fail=1
  else
    echo "  cabinet $station"
  fi

  if ! "${adb[@]}" shell pm path "$YSZC_PKG" >/dev/null 2>&1; then
    echo "  FAIL: $YSZC_PKG missing — hardware bridge not installed" >&2
    fail=1
  else
    echo "  $YSZC_PKG present"
  fi

  local relink_state
  relink_state="$(relink_enabled "$device")"
  echo "  Relink enabled=$relink_state"
  echo "  Relink hidden=$(relink_hidden "$device")"

  local loc
  loc="$(location_line "$device")"
  echo "  $loc"
  if [[ "$loc" != *"granted=true"* ]]; then
    echo "  FAIL: location not granted — Stripe will stay on Reader connecting…" >&2
    fail=1
  fi
  if [[ "$loc" == *"ONE_TIME"* ]]; then
    echo "  WARN: location still has ONE_TIME — may revoke on reboot. Re-run with --fresh." >&2
  fi

  local home
  home="$(home_package "$device")"
  echo "  HOME=$home"
  if [[ "$home" != "$CUUB_PKG" ]]; then
    echo "  FAIL: CUUB is not the HOME app" >&2
    fail=1
  fi

  local hidden
  hidden="$(relink_hidden "$device")"
  if [[ "$hidden" == "true" || "$relink_state" == *DISABLED* ]]; then
    echo "  Relink not launching (hidden=$hidden enabled=$relink_state)"
  else
    echo "  WARN: Relink still enabled and not hidden — cutover may not have taken" >&2
  fi

  local version
  version="$("${adb[@]}" shell dumpsys package "$CUUB_PKG" | awk '/versionName=/ && !found {print $1; found=1}' | tr -d '\r')"
  echo "  $version"

  local owner
  owner="$(device_owner_pkg "$device")"
  echo "  device owner=${owner:-none}"

  local net="" _
  for _ in 1 2 3 4 5 6; do
    net="$("${adb[@]}" shell "dumpsys connectivity | grep -m1 'Active default network'" 2>/dev/null | tr -d '\r' | sed 's/.*: //' || true)"
    [[ -n "$net" && "$net" != "none" ]] && break
    sleep 3
  done
  if [[ -z "$net" || "$net" == "none" ]]; then
    echo "  FAIL: no internet — adb -s $device shell 'cmd phone data disable; cmd phone data enable'" >&2
    fail=1
  else
    echo "  internet up (network $net)"
  fi

  if [[ "$fail" -ne 0 ]]; then
    echo "Provision incomplete — fix FAIL items before unplugging." >&2
    return 1
  fi
  return 0
}

verify_sleeper() {
  local device="$1"
  local adb=(adb -s "$device")
  local fail=0

  echo "Verify sleeper …"
  local station
  station="$("${adb[@]}" shell cat /sdcard/Download/station.txt 2>/dev/null | tr -d '\r' | head -1 || true)"
  if [[ -z "$station" ]]; then
    echo "  FAIL: missing /sdcard/Download/station.txt (Relink should have written CUBT…)" >&2
    fail=1
  else
    echo "  cabinet $station"
  fi

  if ! "${adb[@]}" shell pm path "$YSZC_PKG" >/dev/null 2>&1; then
    echo "  FAIL: $YSZC_PKG missing — hardware bridge not installed" >&2
    fail=1
  else
    echo "  $YSZC_PKG present"
  fi

  if ! "${adb[@]}" shell pm path "$CUUB_PKG" >/dev/null 2>&1; then
    echo "  FAIL: $CUUB_PKG not installed" >&2
    fail=1
  else
    echo "  $CUUB_PKG installed"
  fi

  local relink_state hidden
  relink_state="$(relink_enabled "$device")"
  hidden="$(relink_hidden "$device")"
  echo "  Relink enabled=$relink_state hidden=$hidden"
  if [[ "$hidden" == "true" ]]; then
    echo "  FAIL: Relink is hidden — sleeper must leave Relink visible" >&2
    fail=1
  fi
  if [[ "$relink_state" == *DISABLED* ]]; then
    echo "  FAIL: Relink is disabled — sleeper must leave Relink enabled" >&2
    fail=1
  fi

  local home
  home="$(home_package "$device")"
  echo "  HOME=$home"
  if [[ "$home" != "$RELINK_PKG" ]]; then
    echo "  FAIL: Relink is not the HOME app (got ${home:-none})" >&2
    fail=1
  fi

  local owner
  owner="$(device_owner_pkg "$device")"
  echo "  device owner=${owner:-none}"
  if [[ "$owner" != *"$CUUB_PKG"* ]]; then
    echo "  FAIL: CUUB is not device owner — silent OTA / later cutover will prompt" >&2
    fail=1
  fi

  local loc
  loc="$(location_line "$device")"
  echo "  $loc"
  if [[ "$loc" != *"granted=true"* ]]; then
    echo "  FAIL: location not granted" >&2
    fail=1
  fi

  local version
  version="$("${adb[@]}" shell dumpsys package "$CUUB_PKG" | awk '/versionName=/ && !found {print $1; found=1}' | tr -d '\r')"
  echo "  $version"

  if [[ "$fail" -ne 0 ]]; then
    echo "Sleeper provision incomplete — fix FAIL items before unplugging." >&2
    return 1
  fi
  return 0
}
