# Cabinet → CUUB broker (Windows)

Do this before `setup-kiosk.sh`. WriteMQTTSNTool writes the cabinet's broker
settings over the Relink debug cable. It only runs on Windows; on a Mac use a
Parallels Windows 11 VM (UTM cannot pass the cable through).

| File | What it is |
|---|---|
| `WriteMQTTSNTool_tng_v3.0_boxed-S06.exe` | The supplier's cabinet writer |
| `CH341SER/` | Driver for the debug cable (CH340 USB-serial), Intel and ARM Windows |
| `cuub-mqtt-ca.crt` | CUUB broker CA, the same file for every cabinet |
| `supplier-guide.pdf` | The supplier's procedure, with screenshots |

## Once per Windows machine

1. **Windows.** Parallels → new Windows 11 VM (on Apple Silicon it downloads
   the ARM version, which is right). No product key needed.
2. **Copy this folder to `C:\cabinet`.** In Windows File Explorer, your Mac
   home folder is `\\Mac\Home`, for example
   `\\Mac\Home\Desktop\cuub-kiosk-kit\cabinet`. Copy it, then paste it on
   `C:\` so the files are in `C:\cabinet`.
3. **Driver.** Start → type `powershell` → right-click **Windows PowerShell**
   → **Run as administrator**, then:

   ```powershell
   pnputil /add-driver C:\cabinet\CH341SER\CH341SER.INF /install
   ```

   It should say the driver package was added. Do not use `SETUP.EXE`; it
   fails on ARM Windows.
4. **Supplier login.** The tool asks for a user name, password and captcha.
   The first login ties that account to this Windows machine, so each
   machine needs its own account from the supplier (Relink). `license
   expired!` means the supplier has to renew the account.

## Per station

1. **Cable.** Station powered on. Peel the dust film off the USB bay on the
   bottom of the station and plug into the **middle** port. That cable goes
   to the small green CH340 board; set its switch to the arrow marked 下载,
   then plug the board's USB into the Mac.
2. **Give the cable to Windows.** When Parallels asks where to connect the
   USB device, pick Windows. If it does not ask: Parallels menu **Devices →
   USB & Bluetooth** → the USB Serial / CH340 device.
3. **Find the port.** Device Manager → **Ports (COM & LPT)** → **USB-SERIAL
   CH340 (COMx)**. Remember COMx.
4. **Open the tool.** Run `C:\cabinet\WriteMQTTSNTool_tng_v3.0_boxed-S06.exe`,
   log in, click **Refresh**, pick COMx, click **Open**. It says
   `open serial port success`.
5. **Back up Relink's settings first.** Click **ReadSN**, both
   **ReadAddress** buttons, **ReadSecurity** and **ReadFile**, then take a
   screenshot of the window. These are what you restore to put the station
   back on Relink. Never write a new SN.
6. **Write CUUB's settings.**
   - **WriteSecurity:** MQTT User = the station ID that ReadSN shows
     (`CUBT…`). MQTT Pass = dashboard → station page → **Broker login**
     card. MQTT SSL Type `2`.
   - **WriteFile:** MQTT CA cert = `C:\cabinet\cuub-mqtt-ca.crt`. Leave the
     device cert and key empty.
   - **WriteAddress** (top row, primary broker): `mqtt.cuub.tech`, port
     `8883`.
7. **Check.** Click each matching **Read** button and compare.
8. **Finish.** Unplug the debug cable and power-cycle the station (off 10 s,
   then on). Then run `setup-kiosk.sh` on the Mac; it checks first that the
   cabinet logged in to the CUUB broker.
