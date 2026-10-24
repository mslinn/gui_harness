<#
  GUI process probe for real-app compatibility testing.

  This script is the Windows-side implementation of the harness contract:
  - launch a GUI executable from WSL via PowerShell
  - retain ownership of the process and its windows
  - inspect the visible UIAutomation tree for real modal dialogs
  - classify the dialog from its user-visible text
  - dismiss the blocking control when possible
  - terminate the process tree cleanly before returning
#>
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Set,
  [string]$Log = '',
  [int]$TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Live {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hWnd);
}
'@

function Stop-ProcessTree([int[]]$ProcessIds) {
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  $stack = New-Object 'System.Collections.Generic.Stack[int]'
  foreach ($processId in $ProcessIds) { if ($processId -gt 0) { $stack.Push($processId) } }

  while ($stack.Count -gt 0) {
    $currentPid = $stack.Pop()
    if (-not $seen.Add($currentPid)) { continue }
    foreach ($child in Get-CimInstance Win32_Process -Filter "ParentProcessId = $currentPid" -ErrorAction SilentlyContinue) {
      $stack.Push([int]$child.ProcessId)
    }
  }

  foreach ($processId in $seen) {
    try { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Close-VisibleWindowsForPids([int[]]$ProcessIds) {
  $owners = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($processId in $ProcessIds) { if ($processId -gt 0) { [void]$owners.Add([int]$processId) } }

  [Live]::EnumWindows({
    param($handle, $lparam)
    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($owners.Contains([int]$owner) -and [Live]::IsWindowVisible($handle)) {
      [void][Live]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      [void][Live]::DestroyWindow($handle)
    }
    return $true
  }, [IntPtr]::Zero) | Out-Null
}

function Cleanup-Notepad() {
  $notepads = @(Get-Process -Name 'notepad' -ErrorAction SilentlyContinue)
  foreach ($notepad in $notepads) {
    try { Stop-Process -Id $notepad.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Read-Log([long]$Start) {
  if (-not $Log -or -not (Test-Path $Log)) { return '' }
  $stream = [System.IO.File]::Open($Log, 'Open', 'Read', 'ReadWrite')
  $stream.Seek($Start, 'Begin') | Out-Null
  $reader = New-Object System.IO.StreamReader($stream)
  $text = $reader.ReadToEnd()
  $reader.Close()
  return $text
}

function Get-Windows([int]$ProcessId) {
  $found = New-Object System.Collections.ArrayList
  [Live]::EnumWindows({
    param($handle, $lparam)
    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($owner -eq $ProcessId -and [Live]::IsWindowVisible($handle)) {
      $class = New-Object System.Text.StringBuilder 256
      [void][Live]::GetClassName($handle, $class, 256)
      $title = New-Object System.Text.StringBuilder 1024
      [void][Live]::GetWindowText($handle, $title, 1024)
      [void]$found.Add([pscustomobject]@{
        Handle = $handle
        Class = $class.ToString()
        Title = $title.ToString()
      })
    }
    return $true
  }, [IntPtr]::Zero) | Out-Null
  return $found
}

function Get-DialogText([IntPtr]$Handle) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
  if ($null -eq $root) { return $null }

  $names = [System.Collections.Generic.List[string]]::new()
  $rootName = $root.Current.Name
  if ($rootName -and $rootName.Trim().Length -gt 0) { [void]$names.Add($rootName.Trim()) }

  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                       [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($element in $all) {
    $name = $element.Current.Name
    if ($name -and $name.Trim().Length -gt 0) {
      $trimmed = $name.Trim()
      if (-not $names.Contains($trimmed)) { [void]$names.Add($trimmed) }
    }
  }

  $text = $names | Where-Object { $_ -and $_.Trim().Length -gt 2 } | Select-Object -Unique
  if (-not $text) { return $null }
  return ($text -join ' | ')
}

function Click-Button([IntPtr]$Handle, [string]$Label) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
  if ($null -eq $root) { return $false }
  $condition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, $Label)))
  $button = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
  if ($null -eq $button) { return $false }
  try {
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    return $true
  } catch { return $false }
}

function Get-DialogInfo([string]$Text) {
  if (-not $Text) { return [pscustomobject]@{ Type = 'none'; Action = $null; ActionType = $null; ActionValue = $null } }

  $normalized = $Text.Trim()
  if ($normalized -match 'A serious program error has occurred\.|fatal error|Live will shut down after this message box is closed\.|program error') {
    return [pscustomobject]@{ Type = 'fatal'; Action = 'OK'; ActionType = 'button'; ActionValue = 'OK' }
  }
  if ($normalized -match 'Would you like to recover your work\?|recover your work|Live unexpectedly quit while you were working on the Live Set') {
    return [pscustomobject]@{ Type = 'recovery'; Action = 'No'; ActionType = 'button'; ActionValue = 'No' }
  }
  if ($normalized -match 'Save changes\?|Do you want to save the changes\?') {
    return [pscustomobject]@{ Type = 'save_changes'; Action = 'No'; ActionType = 'button'; ActionValue = 'No' }
  }

  return [pscustomobject]@{ Type = 'unknown'; Action = $null; ActionType = $null; ActionValue = $null }
}

Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue | Stop-Process -Force
Cleanup-Notepad
Start-Sleep -Milliseconds 250

$logStart = 0
if ($Log -and (Test-Path $Log)) { $logStart = (Get-Item $Log).Length }

$argumentList = @()
if ($Set) { $argumentList = @($Set) }
$process = Start-Process -FilePath $Exe -ArgumentList $argumentList -PassThru

$dialog = $null
$recovered = $false
$crashed = $false
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$cleanupPids = @($process.Id)

try {
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if ($null -eq $running) { break }

    $text = Read-Log $logStart

    if (-not $dialog -and $text -match 'Message Box: (.*)') {
      $message = $Matches[1].Trim()
      if ($message -notmatch 'recover your work') { $dialog = $message }
    }
    if ($text -match 'Exception: Fatal Error') { $crashed = $true }
    if ($text -match 'End ExchangeDocument') { break }

    foreach ($window in Get-Windows $process.Id) {
      $shown = Get-DialogText $window.Handle
      if (-not $shown) { continue }

      $dialogInfo = Get-DialogInfo $shown
      $dialog = $shown

      if ($dialogInfo.Type -eq 'fatal') {
        $crashed = $true
        if (Click-Button $window.Handle $dialogInfo.Action) { }
        break
      }

      if ($dialogInfo.Type -eq 'recovery') {
        if (Click-Button $window.Handle $dialogInfo.Action) { $recovered = $true }
      }

      if ($dialogInfo.Type -eq 'save_changes') {
        if (Click-Button $window.Handle $dialogInfo.Action) { }
      }

      if ($dialogInfo.Type -and $dialogInfo.Type -ne 'unknown') {
        break
      }
    }

    if ($dialog) { break }
  }

  foreach ($window in Get-Windows $process.Id) {
    $shown = Get-DialogText $window.Handle
    if ($shown -and $shown -notmatch 'serious program error|fatal error') {
      if (Click-Button $window.Handle 'OK') { }
      elseif (Click-Button $window.Handle 'No') { }
      elseif (Click-Button $window.Handle 'Yes') { }
    }
  }
}
finally {
  foreach ($child in Get-CimInstance Win32_Process -Filter "ParentProcessId = $process.Id" -ErrorAction SilentlyContinue) {
    if ($child.ProcessId -gt 0) { $cleanupPids += [int]$child.ProcessId }
  }
  Close-VisibleWindowsForPids $cleanupPids
  Start-Sleep -Milliseconds 250
  foreach ($processId in @($cleanupPids | Select-Object -Unique)) {
    if ($processId -gt 0) {
      try { Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue } catch {}
    }
  }

  Cleanup-Notepad
}

if ($dialog) { Write-Output ('DIALOG: ' + $dialog) } else { Write-Output 'DIALOG: none' }
if ($dialog) {
  $dialogInfo = Get-DialogInfo $dialog
  if ($dialogInfo.Type) { Write-Output ('DIALOG_TYPE: ' + $dialogInfo.Type) }
  if ($dialogInfo.Action) { Write-Output ('DISMISS_ACTION: ' + $dialogInfo.ActionType + '=' + $dialogInfo.ActionValue) }
} else {
  Write-Output 'DIALOG_TYPE: none'
  Write-Output 'DISMISS_ACTION: none'
}
if ($crashed) { Write-Output 'CRASHED: yes' } else { Write-Output 'CRASHED: no' }
if ($recovered) { Write-Output 'RECOVERED: yes' } else { Write-Output 'RECOVERED: no' }

Write-Output '--- LOG ---'
Write-Output (Read-Log $logStart)
