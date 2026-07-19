# Unlocking & Installing UEFI BIOS on Acer Chromebook Plus 516 (JUBILEUM)
### A SuzyQable-Free Guide for Ti50 (Gen2) Google Security Chips

This manual outlines the exact, tested procedure to permanently remove hardware write-protection, disable the firmware lock, and flash a custom MrChromebox UEFI BIOS on the **Acer Chromebook Plus 516 Plus** (and identical `JUBILEUM` or `JUBILANT` board architectures) without using a specialized debug cable or taking the laptop apart.

---

## Phase 1: Enter Developer Mode
1. Power off the Chromebook completely.
2. Press and hold **`Esc` + `Refresh` (F3/circular arrow)**, then press the **`Power`** button. Release all keys.
3. When the white Recovery screen appears, press **`Ctrl` + `D`**.
4. Confirm by pressing **`Enter`**. 
5. The device will transition to Developer Mode and wipe all internal user data. This takes a few minutes.
6. When the "OS Verification is Off" warning screen appears, press **`Ctrl` + `D`** to skip it and reach the ChromeOS Setup/Welcome screen.

---

## Phase 2: Connect to Wi-Fi (No Login)
*Do not log into a Google Account during this setup.*
1. On the graphical Welcome screen, click the **Quick Settings panel** (bottom right corner near the clock).
2. Click the Wi-Fi icon, select your network, and enter the password.
3. Verify you are connected, then stop. Do not advance past this screen.

---

## Phase 3: Unlocking the Ti50 Security Chip via Terminal
Because this laptop features a modern **Ti50** security chip (`RW 0.23.x`), the classic `start device` commands will not trigger physical prompts. Use the following exact sequence:

1. Open the Developer Terminal by pressing **`Ctrl` + `Alt` + `F2`** (the forward arrow key next to Escape).
2. At the login prompt, type `chronos` and press **`Enter`**.
3. Trigger the Case Closed Debugging (CCD) open loop by typing:
   ```bash
   sudo gsctool -a -o
   ```
4. **The Power Button Challenge**: The system will instantly reboot or start scrolling lines in the terminal, stating `Press PP button now!`. 
   * **Action Required:** Tap the physical power button repeatedly whenever prompted. 
   * The security chip will require you to complete this physical presence challenge multiple times over a **3-to-5 minute window** to verify a human is standing at the machine.

---

## Phase 4: Re-enabling Terminal Access & Software Drops
Once the physical challenge loops finish, the Google Security Chip will automatically force the laptop out of Developer Mode and back into **Verified Mode (Normal Mode)** as a safety precaution. 

1. Repeat **Phase 1** to place the laptop back into **Developer Mode** (`Esc` + `Refresh` + `Power` $\rightarrow$ `Ctrl` + `D`).
2. Pass the warning screen with `Ctrl` + `D`. 
3. Re-open the terminal with **`Ctrl` + `Alt` + `F2`** and log back in as `chronos`.
4. Run the two critical commands to permanently disable the Ti50 hardware-level Read-Only Firmware Verification:
   ```bash
   sudo gsctool -a -I AllowUnverifiedRo:always
   ```
   *(Press the power button one or two quick times if prompted to confirm).*
   ```bash
   sudo gsctool -a -w disable
   ```
5. Drop the software write-protection flag:
   ```bash
   sudo flashrom -p internal --wp-disable
   ```
   *(Ensure you type `--wp-disable` with a double-hyphen and no spaces inside the flag).*

---

## Phase 5: The Critical Hard Reboot
The internal flash architecture requires a full power cycle to register that the security chip has dropped the hardware protection line. **Do not run the firmware script yet.**

1. From the terminal, safely restart the machine:
   ```bash
   sudo reboot
   ```
2. Boot past the warning screen (`Ctrl` + `D`), open the terminal (`Ctrl` + `Alt` + `F2`), and log back in as `chronos`.

---

## Phase 6: Flashing the MrChromebox UEFI BIOS
1. Ensure your network connection is active by running a quick test:
   ```bash
   ping -c 3 google.com
   ```
2. If data returns with 0% packet loss, execute the official utility script (use a lowercase `O` in the `-LO` flag):
   ```bash
   cd; curl -LO mrchromebox.tech/firmware-util.sh && sudo bash firmware-util.sh
   ```
3. When the blue utility menu launches, verify that the top lines accurately display your board architecture. 
4. Select **Option 2: Install UEFI (full ROM)**.
5. **Firmware Backup**: When prompted to back up your stock firmware, select **`y` (Yes)**. Insert a formatted USB flash drive or SD card when requested. The script will save your original layout to the device as `bios.bin`. *Keep this file safe in case you ever want to revert the device back into a Chromebook.*
6. Select **`y`** to make USB devices the default boot priority.
7. Wait roughly 60 to 90 seconds for the flash process to finish. **Do not click keys, close the lid, or unplug the power adapter while blocks are writing.**

---

## Phase 7: Installation of New OS
1. When the script prints `SUCCESS` in green text, press **`Q`** to exit back to the command line.
2. Issue a final restart command:
   ```bash
   sudo reboot
   ```
3. The old ChromeOS white warning screens are now permanently gone. The laptop will boot to the custom **MrChromebox / Coreboot** splash screen.
4. Insert your bootable Windows or Linux installation USB drive (built via Rufus using **GPT partition scheme / UEFI target system** settings).
5. The device will automatically boot the installer. If it does not, tap the **`Esc`** key at startup to bring up the UEFI boot manager and manually select your USB drive.
