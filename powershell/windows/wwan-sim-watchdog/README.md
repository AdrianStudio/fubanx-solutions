# WWAN SIM Watchdog

PowerShell script that detects a missing SIM or mobile broadband adapter on a Windows laptop, logs the state, and optionally restarts the WWAN stack.

## Problem

Rugged laptops such as the Getac S410 intermittently report "No SIM Detected" in the field. Users reseat the SIM by hand, and reinstalling drivers helps for a day or two. Support has no history of how often or on which devices it happens.

## Prerequisites

- PowerShell 7.0 or later on Windows 10 or 11.
- Built-in NetAdapter module and the `netsh` and `pnputil` tools.
- Environment variable `COMPUTERNAME`: set by Windows, holds the host name written to the report and to console messages. Nothing to configure.
- Report-only runs need no special rights beyond writing to `ReportPath`.
- `-Apply` needs an elevated session (local Administrator or SYSTEM) to restart `WwanSvc`, restart the adapter and rescan devices.
- Deploy through Intune remediations, a scheduled task or an RMM and collect the report file centrally.
- Exit code 1 means the fault is present (report-only) or persists after remediation. Use it to raise an alert.

## Usage

```powershell
./wwan-sim-watchdog.ps1 -ReportPath C:\ProgramData\WwanWatchdog\report.jsonl -RecheckSeconds 30

./wwan-sim-watchdog.ps1 -ReportPath C:\ProgramData\WwanWatchdog\report.jsonl -RecheckSeconds 30 -Apply
```

- Each run appends one JSON line with timestamp, computer name, states before and after, actions taken, driver version and raw `netsh mbn` output.
- A reader contact that is physically failing cannot be repaired by software. The report shows which devices need hardware service.

## Unverified

- The `$noSimPattern` text match against `netsh mbn show interfaces` and `netsh mbn show readyinfo` output. The wording may differ by Windows build, driver and language. Check a failing device and adjust the pattern.
- The `*` argument to `netsh mbn show readyinfo` for all interfaces.
- That the Getac adapter reports `PhysicalMediaType` as `Wireless WAN`.
