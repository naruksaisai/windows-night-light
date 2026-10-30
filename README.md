# windows-night-light

Skip the Windows Night light schedule on **Friday and Saturday nights**.

Windows only has one daily Night light schedule. `nightlight-weekend.ps1` turns that schedule off and on by editing the registry, and uses two Task Scheduler jobs to do it every week:

| Task | When | Does |
|---|---|---|
| NightLight - Weekend Off (Friday) | Friday 12:00 | Schedule **off** (skips Fri + Sat night) |
| NightLight - Weekend On (Sunday) | Sunday 12:00 | Schedule **on** (normal from Sun night) |

The script doesn't change your start and end times. If the PC is off at 12:00, the task runs as soon as you next log in.

## Usage

Open PowerShell in this folder. You don't need admin rights.

```powershell
# One-time setup: create the weekly tasks and set the schedule for today
powershell -ExecutionPolicy Bypass -File .\nightlight-weekend.ps1 Install

# Check the schedule state, times and next task runs
powershell -ExecutionPolicy Bypass -File .\nightlight-weekend.ps1 Status

# Turn the schedule on or off by hand
powershell -ExecutionPolicy Bypass -File .\nightlight-weekend.ps1 Disable
powershell -ExecutionPolicy Bypass -File .\nightlight-weekend.ps1 Enable

# Remove the tasks and turn the schedule back on
powershell -ExecutionPolicy Bypass -File .\nightlight-weekend.ps1 Uninstall
```

The tasks point to the script at its current path. Don't move or delete this folder after running `Install`, or run `Install` again from the new location.

## Notes

- Microsoft doesn't document this registry format (`CloudStore\...\windows.data.bluelightreduction.settings`), so a future Windows update could break the script. If that happens, `Status` will show an error or wrong values.
- If **Settings > System > Display > Night light** still shows the old state, close and reopen Settings.
