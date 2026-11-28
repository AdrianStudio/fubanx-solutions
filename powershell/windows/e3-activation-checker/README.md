# E3 Activation Checker

A PowerShell script that diagnoses why Windows Pro devices do not step up to Enterprise with an E3 licence, and optionally restarts the subscription license tasks.

## Problem
About 150 Windows 11 Pro laptops keep running Pro although their users have E3 licences. Subscription activation works for some users and not for others, and the cause is found by reading the Store event log and checking each device by hand. Standard steps such as VPN, GPUpdate and new profiles do not change the result.

## Prerequisites
- No environment variables are read.
- PowerShell 7 on the admin machine.
- WinRM enabled on the target devices.
- Local administrator rights on each target device.
- No extra modules. The targets use built-in ScheduledTasks, CIM and event log cmdlets and `dsregcmd.exe` from the system path.

## Usage
```powershell
./e3-activation-checker.ps1 -ComputerName <device1>, <device2>
./e3-activation-checker.ps1 -ComputerName <device1>, <device2> -EventLogDays 30
./e3-activation-checker.ps1 -ComputerName <device1>, <device2> -Apply
```
- The default run is report-only. It returns one object per device with edition, join state, license status, firmware key, Store errors, task state and findings.
- `-Apply` enables disabled subscription license tasks and starts them on devices that are not Enterprise.
- Joining a device to Entra ID, assigning licences or replacing a wrong firmware key is not done by the script. It reports these as findings.

## Unverified
- Scheduled task folder `\Microsoft\Windows\Subscription\` and the tasks inside it are assumed from Windows behaviour and not from a published reference.
- The wording of `OA3xOriginalProductKeyDescription` varies by OEM. The Windows 10/11 and Home/Core pattern match may need adjusting.
- Last task result `267011` (task never run) is treated as not an error.
