param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$Label
)

# Diagnostic snapshot of everything Live touches, so that a version switch can be diffed.
# Read-only: this script never writes to the registry or to Live's directories.

$ErrorActionPreference = 'SilentlyContinue'
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string]$Text) $lines.Add($Text) }

function Dump-RegistryKey {
    param([string]$Path, [string]$Display, [int]$Depth = 0)

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Line "MISSING-REG|${Display}"
        return
    }
    $key = Get-Item -LiteralPath $Path
    if (-not $key) {
        Add-Line "MISSING-REG|${Display}"
        return
    }
    Add-Line ("KEY|{0}|lw={1}" -f $Display, $key.LastWriteTime.ToString('o'))
    foreach ($name in $key.GetValueNames()) {
        $value = $key.GetValue($name)
        Add-Line ("VAL|{0}\{1}|{2}" -f $Display, $name, (($value | Out-String) -replace '\s+', ' ').Trim())
    }
    if ($Depth -lt 6) {
        foreach ($sub in $key.GetSubKeyNames()) {
            Dump-RegistryKey -Path (Join-Path $Path $sub) -Display "${Display}\${sub}" -Depth ($Depth + 1)
        }
    }
}

function Dump-Tree {
    param([string]$Root, [string]$Display, [int]$Depth = 6)

    Add-Line "=== TREE ${Display} (${Root}) ==="
    if (-not (Test-Path -LiteralPath $Root)) {
        Add-Line "MISSING-TREE|${Display}"
        return
    }
    $files = Get-ChildItem -LiteralPath $Root -Recurse -Depth $Depth -File |
        Where-Object { $_.FullName -notmatch '\\Cache\\' } |
        Sort-Object FullName
    foreach ($file in $files) {
        Add-Line ("FILE|{0}|len={1}|lw={2}" -f $file.FullName, $file.Length, $file.LastWriteTime.ToString('o'))
    }
    Add-Line ("TREE-COUNT|{0}|{1}" -f $Display, $files.Count)
}

Add-Line ("LABEL|{0}" -f $Label)
Add-Line ("WHEN|{0}" -f (Get-Date).ToString('o'))
Add-Line ("WHO|{0}" -f (whoami))
Add-Line ("INTEGRITY|{0}" -f ((whoami /groups | Select-String 'Mandatory Label').ToString().Trim()))

# --- registry: Ableton's own hives -------------------------------------------
Dump-RegistryKey -Path 'HKLM:\SOFTWARE\Ableton' -Display 'HKLM\SOFTWARE\Ableton'
Dump-RegistryKey -Path 'HKCU:\Software\Ableton' -Display 'HKCU\Software\Ableton'

# --- registry: the shell's association machinery, machine wide ---------------
$classRoot = 'HKLM:\SOFTWARE\Classes'
foreach ($name in (Get-ChildItem -LiteralPath $classRoot | Where-Object { $_.PSChildName -match 'bleton' })) {
    Dump-RegistryKey -Path $name.PSPath -Display "HKLM\SOFTWARE\Classes\$($name.PSChildName)"
}

# --- registry: the shell's per-user state ------------------------------------
$fileExts = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts'
foreach ($ext in @('.als', '.alp', '.alc', '.abl', '.ablbundle')) {
    Dump-RegistryKey -Path (Join-Path $fileExts $ext) -Display "HKCU\FileExts\$ext"
}

# --- files -------------------------------------------------------------------
Dump-Tree -Root 'C:\ProgramData\Ableton' -Display 'ProgramData\Ableton' -Depth 4
Dump-Tree -Root (Join-Path $env:APPDATA 'Ableton') -Display 'AppData\Ableton' -Depth 6

# --- what is running now -----------------------------------------------------
Add-Line '=== PROCESSES ==='
foreach ($process in (Get-Process | Where-Object { $_.ProcessName -match 'bleton|consent|InstallHelper' } | Sort-Object ProcessName)) {
    Add-Line ("PROC|{0}|pid={1}|started={2}" -f $process.ProcessName, $process.Id, $process.StartTime.ToString('o'))
}

# --- scheduled tasks and services --------------------------------------------
Add-Line '=== SCHEDULED-TASKS ==='
foreach ($task in (Get-ScheduledTask | Where-Object { $_.TaskName -match 'bleton' -or $_.TaskPath -match 'bleton' })) {
    Add-Line ("TASK|{0}{1}|state={2}|user={3}|runlevel={4}" -f $task.TaskPath, $task.TaskName, $task.State, $task.Principal.UserId, $task.Principal.RunLevel)
}

Add-Line '=== SERVICES ==='
foreach ($service in (Get-Service | Where-Object { $_.Name -match 'bleton' -or $_.DisplayName -match 'bleton' })) {
    Add-Line ("SERVICE|{0}|{1}|{2}" -f $service.Name, $service.DisplayName, $service.Status)
}

# --- event log ---------------------------------------------------------------
Add-Line '=== EVENTS ==='
foreach ($logName in @('Application', 'System')) {
    foreach ($event in (Get-WinEvent -FilterHashtable @{LogName = $logName} -MaxEvents 2000 |
            Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-12) -and
                           $_.Message -match 'bleton|InstallHelper|consent|UAC|AppInfo' } |
            Sort-Object TimeCreated)) {
        $message = (($event.Message | Out-String) -replace '\s+', ' ').Trim()
        Add-Line ("EVENT|{0}|{1}|id={2}|provider={3}|{4}" -f $logName, $event.TimeCreated.ToString('o'), $event.Id, $event.ProviderName, $message)
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$outFile = Join-Path $OutDir "${Label}.txt"
$lines | Set-Content -LiteralPath $outFile -Encoding UTF8
Write-Output ("WROTE|{0}|lines={1}" -f $outFile, $lines.Count)
