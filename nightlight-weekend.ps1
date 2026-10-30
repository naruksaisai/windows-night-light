<#
.SYNOPSIS
    Skip the Windows Night light schedule on Friday and Saturday nights.

.DESCRIPTION
    Windows Night light has one daily schedule with no day-of-week option.
    This script turns the schedule off/on by editing the Night light settings
    in the registry, and can register two scheduled tasks to do it weekly:
      - Friday 12:00   -> schedule OFF (skips Fri night and Sat night)
      - Sunday 12:00   -> schedule ON  (back to normal from Sun night)
    Your start/end times are left untouched.

.EXAMPLE
    .\nightlight-weekend.ps1 Status
    .\nightlight-weekend.ps1 Install
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('Status', 'Enable', 'Disable', 'Install', 'Uninstall')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'

$StoreRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current'
$TaskOff = 'NightLight - Weekend Off (Friday)'
$TaskOn = 'NightLight - Weekend On (Sunday)'

# Both the account-wide and the per-device copies of the setting.
function Get-SettingsKeys {
    Get-ChildItem $StoreRoot |
        Where-Object { $_.PSChildName -match 'windows\.data\.bluelightreduction\.settings(perdevice)?$' } |
        ForEach-Object { Get-ChildItem $_.PSPath }
}

# Blob layout: 43 42 01 00 | 0A 02 01 00 | 2A 06 <5-byte timestamp> | 2A 2B 0E <len> | 43 42 01 00 [02 01] CA 14 ...
# The optional "02 01" right after the inner header is the "schedule on" flag.
function Get-InnerOffset([byte[]]$Data) {
    for ($i = 10; $i -lt $Data.Length - 4; $i++) {
        if ($Data[$i] -eq 0x2A -and $Data[$i + 1] -eq 0x2B -and $Data[$i + 2] -eq 0x0E) { return $i + 3 }
    }
    throw 'Unrecognised Night light settings format.'
}

function Test-ScheduleOn([byte[]]$Data) {
    $p = (Get-InnerOffset $Data) + 5
    return ($Data[$p] -eq 0x02 -and $Data[$p + 1] -eq 0x01)
}

function Get-ScheduleTimes([byte[]]$Data) {
    $hex = ($Data | ForEach-Object { $_.ToString('X2') }) -join ' '
    $fmt = {
        param($tag)
        if ($hex -match "$tag((?: (?:0E|2E) [0-9A-F]{2})*) 00") {
            $h = 0; $m = 0
            if ($Matches[1] -match '0E ([0-9A-F]{2})') { $h = [Convert]::ToInt32($Matches[1], 16) }
            if ($Matches[1] -match '2E ([0-9A-F]{2})') { $m = [Convert]::ToInt32($Matches[1], 16) }
            '{0:D2}:{1:D2}' -f $h, $m
        } else { '?' }
    }
    "{0} - {1}" -f (& $fmt 'CA 14'), (& $fmt 'CA 1E')
}

function Set-Schedule([bool]$On) {
    foreach ($key in Get-SettingsKeys) {
        $data = [byte[]](Get-ItemProperty $key.PSPath).Data
        if ((Test-ScheduleOn $data) -eq $On) { continue }

        $lenPos = Get-InnerOffset $data
        $flagPos = $lenPos + 5
        $list = [System.Collections.Generic.List[byte]]::new($data)
        if ($On) {
            $list.InsertRange($flagPos, [byte[]](0x02, 0x01))
            $list[$lenPos] += 2
        } else {
            $list.RemoveRange($flagPos, 2)
            $list[$lenPos] -= 2
        }

        # Refresh the 5-byte LEB128 timestamp so Windows notices the change.
        $ts = [uint64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        for ($i = 0; $i -lt 5; $i++) {
            $b = [byte]($ts -band 0x7F); $ts = $ts -shr 7
            if ($i -lt 4) { $b = $b -bor 0x80 }
            $list[10 + $i] = $b
        }

        Set-ItemProperty $key.PSPath -Name Data -Value ([byte[]]$list.ToArray()) -Type Binary
    }
    Write-Host ("Night light schedule turned {0}." -f ($(if ($On) { 'ON' } else { 'OFF' })))
}

function Show-Status {
    foreach ($key in Get-SettingsKeys) {
        $data = [byte[]](Get-ItemProperty $key.PSPath).Data
        $name = if ($key.PSChildName -match 'perdevice$') { 'per-device' } else { 'account' }
        Write-Host ("Schedule ({0}): {1}  [{2}]" -f $name, $(if (Test-ScheduleOn $data) { 'ON' } else { 'OFF' }), (Get-ScheduleTimes $data))
    }
    foreach ($t in $TaskOff, $TaskOn) {
        $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        if ($task) {
            $next = (Get-ScheduledTaskInfo -TaskName $t).NextRunTime
            Write-Host ("Task '{0}': {1}, next run {2}" -f $t, $task.State, $next)
        } else {
            Write-Host ("Task '{0}': not installed" -f $t)
        }
    }
}

function Install-Tasks {
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    $jobs = @(
        @{ Name = $TaskOff; Day = 'Friday'; Arg = 'Disable' },
        @{ Name = $TaskOn;  Day = 'Sunday'; Arg = 'Enable' }
    )
    foreach ($j in $jobs) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($j.Arg)"
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $j.Day -At '12:00'
        Register-ScheduledTask -TaskName $j.Name -Action $action -Trigger $trigger -Settings $settings `
            -Principal $principal -Force | Out-Null
        Write-Host "Installed task '$($j.Name)' ($($j.Day) 12:00 -> $($j.Arg))."
    }

    # Put the schedule in the right state for today.
    $day = (Get-Date).DayOfWeek
    $hour = (Get-Date).Hour
    $weekend = ($day -eq 'Friday' -and $hour -ge 12) -or $day -eq 'Saturday' -or ($day -eq 'Sunday' -and $hour -lt 12)
    Set-Schedule (-not $weekend)
}

function Uninstall-Tasks {
    foreach ($t in $TaskOff, $TaskOn) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed task '$t'."
    }
    Set-Schedule $true
}

switch ($Action) {
    'Status'    { Show-Status }
    'Enable'    { Set-Schedule $true }
    'Disable'   { Set-Schedule $false }
    'Install'   { Install-Tasks }
    'Uninstall' { Uninstall-Tasks }
}
