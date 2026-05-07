# Trim-MonitorEdid

PowerShell script to fix a Windows bug that causes system-wide stutter on certain monitors by trimming their EDID mode lists.

## The bug

Some monitors (notably LG ultrawides/OLEDs, plus various Samsung, ASUS, Dell, and Lenovo models) report enormous mode lists in their EDID. Windows enumerates the full list on every call to `NtGdiDdDDIGetDisplayModeList`, which is invoked continuously by DWM, application startup, focus changes, and various background services. On affected hardware this causes pervasive system-wide stutter — worst with a single high-refresh OLED as the only active display.

NVIDIA [confirmed this is a Windows-side bug](https://learn.microsoft.com/en-us/answers/questions/3918257/monitors-causing-stuttering-in-windows), not a driver issue. See that thread for the affected-monitor list.

The script writes overrides via Microsoft's documented [`EDID_OVERRIDE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/overriding-monitor-edids) registry mechanism, preserving Detailed Timing Descriptors (including high-refresh modes in DisplayID 2.0 extension blocks) while zeroing out the legacy timing bloat.

## Usage

Run PowerShell as **Administrator**:

```powershell
# Conservative trim (default - overrides base block only)
powershell -ExecutionPolicy Bypass -File .\Trim-MonitorEdid.ps1

# Aggressive (also trims CTA-861 Video Data Blocks)
powershell -ExecutionPolicy Bypass -File .\Trim-MonitorEdid.ps1 -Aggressive

# Different vendor (SAM=Samsung, ACR=Acer, AUS=ASUS, DEL=Dell, etc.)
powershell -ExecutionPolicy Bypass -File .\Trim-MonitorEdid.ps1 -ManufacturerCode SAM

# Dry run - show what would change without writing
powershell -ExecutionPolicy Bypass -File .\Trim-MonitorEdid.ps1 -WhatIf

# Restore original EDID from automatic backup
powershell -ExecutionPolicy Bypass -File .\Trim-MonitorEdid.ps1 -Restore
```

**Reboot after running.** `EDID_OVERRIDE` is read by the monitor driver during device initialization, not on driver restart (Ctrl+Shift+Win+B is not enough). Backups are written automatically to `./edid-backups/` on first run.

## Notes

- After the fix, NVCP's "Change Resolution" list will still show driver-synthesized scaled modes (1920×1080, 1280×720, etc.). That's expected and doesn't affect the fix — the actual change is at the WDDM kernel API layer below NVCP. The bug is resolved if system-wide stutter is gone.
- If the display goes black after reboot (very unlikely with conservative mode): Safe Mode (Shift+Restart → Troubleshoot → Advanced → Startup Settings → F4), run with `-Restore`, reboot.

## Credit

Original bug discovery and CRU/SRE-based workaround documented on [r/nvidia](https://www.reddit.com/r/nvidia/comments/198is3r/update_lg_monitors_causing_stuttering_fix/) — credit to u/Adrianos30, u/diceman2037, and "Guzz" on the guru3D forums for identifying `NtGdiDdDDIGetDisplayModeList` as the culprit.

## License

MIT. Modifies the Windows registry — use at your own risk.
