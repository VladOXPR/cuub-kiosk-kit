#!/usr/bin/env bash
# One-time ADB provision so a station reboots with no taps.
#
# The APK cannot grant itself runtime permissions, disable the lock screen,
# or claim HOME. Do this once per tablet (seed/redeploy call it). After that,
# power-off / reboot should bring the kiosk back unattended.
#
# Also seeds T-Mobile IoT APN iot.t-mobile.com (missing from Relink firmware)
# and turns cellular data on for the active SIM.
#
# Usage:
#   ./scripts/kiosk-unattended.sh              # the one connected adb device
#   ./scripts/kiosk-unattended.sh 98b93cd
#   ./scripts/kiosk-unattended.sh --sleeper    # Relink stays HOME; CUUB is background OTA
#
# Does not disable com.yszc.serialports.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/provision-common.sh
source "$ROOT/scripts/lib/provision-common.sh"

SLEEPER=0
DEVICE_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sleeper) SLEEPER=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      DEVICE_ARG="$1"
      shift
      ;;
  esac
done

# Relink apns-conf.xml has consumer fast.t-mobile.com, not T-Mobile IoT.
# WRITE_APN_SETTINGS needs root (userdebug). Idempotent. Safe if the SIM is Telnyx.
provision_tmobile_iot_apn() {
  echo "  T-Mobile IoT APN …"
  "${ADB[@]}" root >/dev/null 2>&1 || true
  sleep 1
  "${ADB[@]}" wait-for-device >/dev/null 2>&1 || true

  if ! "${ADB[@]}" shell id 2>/dev/null | grep -q 'uid=0'; then
    echo "  WARN: not root — cannot insert iot.t-mobile.com (need Relink userdebug)" >&2
    "${ADB[@]}" shell settings put global mobile_data 1 || true
    "${ADB[@]}" shell svc data enable || true
    return 0
  fi

  local sub
  sub="$("${ADB[@]}" shell settings get global multi_sim_data_call 2>/dev/null | tr -d '\r')"
  [[ -z "$sub" || "$sub" == "null" || "$sub" == "-1" ]] && sub=1

  ensure_iot_apn_row() {
    local mcc="$1" mnc="$2" name="$3"
    local numeric="${mcc}${mnc}"
    local row id
    row="$("${ADB[@]}" shell content query --uri content://telephony/carriers \
      --projection _id:numeric:apn \
      --where "apn='iot.t-mobile.com' AND numeric='${numeric}'" 2>/dev/null | tr -d '\r' || true)"
    if [[ "$row" == *iot.t-mobile.com* ]]; then
      id="$(printf '%s\n' "$row" | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1)"
      echo "$id"
      return 0
    fi
    "${ADB[@]}" shell "content insert --uri content://telephony/carriers --bind name:s:${name} --bind numeric:s:${numeric} --bind mcc:s:${mcc} --bind mnc:s:${mnc} --bind apn:s:iot.t-mobile.com --bind type:s:default,supl --bind protocol:s:IPV6 --bind roaming_protocol:s:IPV6 --bind carrier_enabled:i:1 --bind current:i:1 --bind edited:i:1 --bind sub_id:i:${sub}" >/dev/null || true
    row="$("${ADB[@]}" shell content query --uri content://telephony/carriers \
      --projection _id:numeric:apn \
      --where "apn='iot.t-mobile.com' AND numeric='${numeric}'" 2>/dev/null | tr -d '\r' || true)"
    printf '%s\n' "$row" | sed -n 's/.*_id=\([0-9]*\).*/\1/p' | head -1
  }

  local id_260 id_882 prefer_id sim
  id_260="$(ensure_iot_apn_row 310 260 TMO-IoT || true)"
  id_882="$(ensure_iot_apn_row 311 882 TMO-IoT-882 || true)"
  echo "  APN rows 310260=${id_260:-none} 311882=${id_882:-none} sub_id=$sub"

  sim="$("${ADB[@]}" shell getprop gsm.sim.operator.numeric 2>/dev/null | tr -d '\r,' )"
  prefer_id=""
  case "$sim" in
    311882) prefer_id="$id_882" ;;
    310260) prefer_id="$id_260" ;;
  esac
  if [[ -n "$prefer_id" ]]; then
    "${ADB[@]}" shell "content insert --uri content://telephony/carriers/preferapn --bind apn_id:i:${prefer_id}" >/dev/null || true
    echo "  preferred APN id=$prefer_id (SIM numeric=$sim)"
  else
    echo "  SIM numeric=${sim:-none} — left preferred APN unchanged"
  fi

  # mobile_data = master switch. mobile_dataN = that SIM slot/subscription.
  # T-Mobile IoT on 028 was sub 3 with mobile_data3=0, so IMS came up and
  # internet never did.
  "${ADB[@]}" shell settings put global mobile_data 1 || true
  "${ADB[@]}" shell settings put global "mobile_data${sub}" 1 || true
  "${ADB[@]}" shell settings put global mobile_data1 1 || true
  "${ADB[@]}" shell settings put global mobile_data2 1 || true
  "${ADB[@]}" shell settings put global mobile_data3 1 || true
  "${ADB[@]}" shell settings put global data_roaming 1 || true
  "${ADB[@]}" shell settings put global "data_roaming${sub}" 1 || true
  # Toggling data can drop the tablet off USB (seen on 131). Run the toggle on the
  # tablet itself so data is re-enabled even when adb loses the link halfway.
  "${ADB[@]}" shell "setsid sh -c 'svc data enable; svc data disable; sleep 2; svc data enable' </dev/null >/dev/null 2>&1 &" || true
  sleep 5
  wait_for_usb "$DEVICE"
}

DEVICE="$(pick_device "${DEVICE_ARG:-}")"
ADB=(adb -s "$DEVICE")
if [[ "$SLEEPER" -eq 1 ]]; then
  echo "Kiosk unattended provision (sleeper): $DEVICE"
else
  echo "Kiosk unattended provision: $DEVICE"
fi
"${ADB[@]}" get-state >/dev/null

# Runtime permissions — persist across reboot. Never use the on-screen
# "Allow this time" option; that expires and Stripe then refuses the M2.
# Revoke first so tablets that picked ONE_TIME (028) get a clean adb grant.
"${ADB[@]}" shell pm revoke "$CUUB_PKG" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
"${ADB[@]}" shell pm revoke "$CUUB_PKG" android.permission.ACCESS_COARSE_LOCATION 2>/dev/null || true
"${ADB[@]}" shell pm grant "$CUUB_PKG" android.permission.ACCESS_FINE_LOCATION || true
"${ADB[@]}" shell pm grant "$CUUB_PKG" android.permission.ACCESS_COARSE_LOCATION || true
# Mark as user-set so Android does not treat this as "Allow this time".
"${ADB[@]}" shell pm set-permission-flags "$CUUB_PKG" \
  android.permission.ACCESS_FINE_LOCATION user-set user-fixed || true
"${ADB[@]}" shell pm set-permission-flags "$CUUB_PKG" \
  android.permission.ACCESS_COARSE_LOCATION user-set user-fixed || true
"${ADB[@]}" shell cmd appops set "$CUUB_PKG" FINE_LOCATION allow || true
"${ADB[@]}" shell cmd appops set "$CUUB_PKG" COARSE_LOCATION allow || true

"${ADB[@]}" shell appops set "$CUUB_PKG" MANAGE_EXTERNAL_STORAGE allow || true
"${ADB[@]}" shell appops set "$CUUB_PKG" REQUEST_INSTALL_PACKAGES allow || true

# Silent OTA: CUUB must own the package and (on Android 11) be device owner.
# `adb install -i com.cuub.station` sets installer of record. Do not `adb root`
# before this — set-installer then fails with Unknown calling UID: 0, and unroot
# drops wireless debugging.
"${ADB[@]}" shell cmd package set-installer "$CUUB_PKG" "$CUUB_PKG" || true
if "${ADB[@]}" shell dpm set-device-owner "$CUUB_PKG/.kiosk.StationDeviceAdminReceiver"; then
  echo "  device owner set — OTA will install with no prompt"
else
  echo "WARN: could not set device owner (another admin/account?). Silent OTA needs this." >&2
  echo "  adb -s $DEVICE shell dumpsys device_policy | head" >&2
fi

# Stripe also needs location *services* on, not just the permission.
"${ADB[@]}" shell settings put secure location_mode 3 || true
"${ADB[@]}" shell cmd location set-location-enabled true || true

# No PIN / swipe. requestDismissKeyguard cannot type a lock for us.
"${ADB[@]}" shell locksettings set-disabled true || true
"${ADB[@]}" shell settings put secure lockscreen.disabled 1 || true

# Stay awake on cabinet power. App also sets FLAG_KEEP_SCREEN_ON.
"${ADB[@]}" shell settings put global stay_on_while_plugged_in 7 || true
"${ADB[@]}" shell settings put system screen_off_timeout 2147483647 || true
# No ANR / crash / PermissionController dialogs — nobody is on site to tap them.
"${ADB[@]}" shell settings put global hide_error_dialogs 1 || true
"${ADB[@]}" shell settings put global anr_show_background 0 || true

# Relink is the OEM launcher. Kiosk disables it so reboot is ours.
# Sleeper leaves Relink as HOME; CUUB polls OTA in the background.
if [[ "$SLEEPER" -eq 1 ]]; then
  echo "  sleeper — Relink stays launcher"
  "${ADB[@]}" shell pm enable --user 0 "$RELINK_PKG" || true
  "${ADB[@]}" shell pm unhide --user 0 "$RELINK_PKG" || true
  relink_home="$(resolve_relink_home "$DEVICE")"
  "${ADB[@]}" shell cmd package set-home-activity "$relink_home" || true
  echo "  HOME pinned to $relink_home"
else
  "${ADB[@]}" shell pm disable-user --user 0 "$RELINK_PKG" || true
  "${ADB[@]}" shell cmd package set-home-activity "$CUUB_PKG/.MainActivity" || true
fi

provision_tmobile_iot_apn

if [[ "$SLEEPER" -eq 1 ]]; then
  "${ADB[@]}" shell am start-foreground-service -n "$CUUB_PKG/.update.OtaService" \
    || "${ADB[@]}" shell am startservice -n "$CUUB_PKG/.update.OtaService" || true
  echo "Done. Reboot should come up on Relink; CUUB polls OTA in the background."
else
  echo "Done. Reboot should come up on CUUB POS with location granted."
  echo "  Re-enable Relink: adb -s $DEVICE shell pm enable $RELINK_PKG"
fi
