# CUUB kiosk kit

Sets up a station's kiosk tablet for CUUB, start to finish: installs the CUUB
pilot app, removes Relink, configures Android, and checks the kiosk, the card
reader and the cabinet in cuub-api. Everything it needs is in this folder,
except the Google Cloud CLI.

## Once per computer

1. Get this folder: unzip `cuub-kiosk-kit.zip`, or clone the private repo
   `git clone https://github.com/VladOXPR/cuub-kiosk-kit.git`.
2. Install the Google Cloud CLI: <https://cloud.google.com/sdk/docs/install>
   (with Homebrew: `brew install --cask google-cloud-sdk`).

## Once per day

```bash
gcloud auth login
```

Use a Google account with access to the `keyextract-482721` project.

## Cabinet (WriteMQTTSNTool, before the script)

The broker CA for **WriteFile** is `cabinet/cuub-mqtt-ca.crt` in this folder.
WriteMQTTSNTool runs in Windows (Parallels) and cannot open Mac paths; there
your Mac home folder is `\\Mac\Home`. With this folder in `~/Desktop`, paste:

```text
\\Mac\Home\Desktop\cuub-kiosk-kit\cabinet\cuub-mqtt-ca.crt
```

The rest of the write: **WriteSecurity** user = station ID, password = the
dashboard's Broker login card, SSL type `2`. **WriteAddress** `mqtt.cuub.tech`,
port `8883`. Read each back, then power-cycle the station.

## Per station

1. The cabinet must already be on the CUUB broker (written with
   WriteMQTTSNTool and power-cycled, see above). The script checks this first.
2. Plug the tablet into the computer by USB.
3. Open Terminal and run the script. You can type `bash ` and drag
   `setup-kiosk.sh` into the window:

   ```bash
   bash /path/to/cuub-kiosk-kit/setup-kiosk.sh
   ```

4. Do what it asks:
   - **"Tablet dropped off USB"**: unplug and replug the cable.
   - **At the end**: unplug the computer from the tablet, plug the M2 card
     reader into the tablet, and power-cycle the station. It waits until the
     cabinet and the reader are both online.
5. When it prints `=== CUBT… done ===`, do one test rent and return.

Running it again on the same tablet is safe.

## If it stops

It prints `STOP:` with what to do. The common ones:

| Message | What to do |
|---|---|
| `gcloud could not read the API token` | Run `gcloud auth login`, then the script again. |
| `Plug in one USB station…` | No tablet (or more than one) on USB. Check the cable. |
| `the cabinet never logged in to mqtt.cuub.tech` | Re-check the cabinet's broker settings, power-cycle, run again. |
| `the cabinet has not answered since the power-cycle` | Power-cycle the station again. The cabinet goes online through the tablet's serial cable and mobile data. |

## Undo

With the tablet plugged in: `bash /path/to/cuub-kiosk-kit/reset-to-relink.sh`.
It puts Relink back from the copy saved in `relink-backup/` when the station
was set up from this folder.

## Notes

- Runs on macOS (Apple Silicon or Intel). Linux works the same, but adb needs
  USB permission for the tablet (a udev rule). Not Windows.
- `kit-info.txt` says which app version and build this folder carries.
- The app in `apk/` contains the kiosk API token, like every pilot tablet.
  Share this folder the way you would hand over a tablet, not publicly.
