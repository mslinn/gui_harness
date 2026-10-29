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
  [int]$TimeoutSeconds = 5,
  [ValidateSet('normal','minimized','hidden')][string]$Visibility = 'normal'
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
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
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

function Get-ProcessTreeIds([int[]]$ProcessIds) {
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

  return @($seen)
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

function Set-ProcessWindowVisibility([int]$ProcessId, [string]$Visibility) {
  $mode = switch ($Visibility) {
    'hidden' { 0 }
    'minimized' { 2 }
    default { 1 }
  }

  [Live]::EnumWindows({
    param($handle, $lparam)
    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($owner -eq $ProcessId) {
      [void][Live]::ShowWindow($handle, $mode)
    }
    return $true
  }, [IntPtr]::Zero) | Out-Null
}

function Debug-Log([string]$Message) {
  if ($env:GUI_HARNESS_DEBUG -eq '1' -or $env:DEBUG -eq '1') {
    [Console]::Error.WriteLine("[gui_harness] $Message")
  }
}

# The virtual key code of a key the harness sends.
#
# @param Key the name of the key, e.g. 'n' or 'esc'
# @return [int] the virtual key code, or 0 when the key is not one of them
function Get-KeyCode([string]$Key) {
  switch ($Key.ToUpper()) {
    'N' { return 0x4E }
    'Y' { return 0x59 }
    'ESC' { return 0x1B }
    '{ESC}' { return 0x1B }
    'ENTER' { return 0x0D }
    default { return 0 }
  }
}

# Sends a key to the windows of an application.
#
# The dialogs of Live are Qt windows, and UI Automation sees nothing in them, so a dialog of Live
# is read from its log and dismissed with the keyboard. The key is posted to the windows of the
# application, and not to the foreground window: a modal dialog of Live is a window of Live, but
# the window that has the focus is not necessarily the dialog.
#
# @param ProcessIds the processes the key goes to
# @param Key the name of the key
# @return [int] the number of windows the key was sent to
function Send-KeyToWindows([int[]]$ProcessIds, [string]$Key) {
  $code = Get-KeyCode $Key
  if ($code -eq 0) { return 0 }

  $script:sent = 0
  [Live]::EnumWindows({
    param($handle, $lparam)
    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($ProcessIds -contains [int]$owner) {
      [void][Live]::PostMessage($handle, 0x0100, [IntPtr]$code, [IntPtr]::Zero)
      [void][Live]::PostMessage($handle, 0x0101, [IntPtr]$code, [IntPtr]::Zero)
      $script:sent++
    }
    return $true
  }, [IntPtr]::Zero) | Out-Null

  Debug-Log "sent $Key to $script:sent windows"
  return $script:sent
}

# Brings the app to the foreground and sends it a key.
#
# @param ProcessId the process the key goes to
# @param Key the key, in the notation of WScript.Shell.SendKeys
# @return $true if the app was brought to the foreground
function Send-DismissKey([int]$ProcessId, [string]$Key) {
  $shell = New-Object -ComObject WScript.Shell
  $activated = $shell.AppActivate($ProcessId)
  Debug-Log "AppActivate($ProcessId) returned $activated, sending $Key"
  if (-not $activated) { return $false }
  Start-Sleep -Milliseconds 200
  $shell.SendKeys($Key)
  return $true
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

function Test-IsModal($Element) {
  if ($null -eq $Element) { return $false }
  try {
    $pattern = $Element.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
    return $pattern.Current.IsModal
  } catch { return $false }
}

# Finds the modal dialog of a window.
#
# An application is not a dialog. The windows of an application hold the whole of its
# interface, so the text of a window says nothing about whether the application is blocked.
# A dialog is a window inside it that is modal, and its own text is the text of the dialog.
#
# The dialogs of Live are Qt windows, and UI Automation sees nothing in them, so a dialog of
# Live is read from its log instead.
#
# @param Handle the handle of a window of the application
# @return the modal dialog, or $null when there is none
function Get-DialogElement([IntPtr]$Handle) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
  if ($null -eq $root) { return $null }
  if (Test-IsModal $root) { return $root }

  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window)
  $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
  foreach ($element in $windows) {
    if (Test-IsModal $element) { return $element }
  }
  return $null
}

function Get-DialogText($Element) {
  if ($null -eq $Element) { return $null }

  $names = [System.Collections.Generic.List[string]]::new()
  $rootName = $Element.Current.Name
  if ($rootName -and $rootName.Trim().Length -gt 0) { [void]$names.Add($rootName.Trim()) }

  $all = $Element.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                           [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($element in $all) {
    $name = $element.Current.Name
    Debug-Log "  element type=$($element.Current.ControlType.ProgrammaticName) class=$($element.Current.ClassName) name='$name'"
    if ($name -and $name.Trim().Length -gt 0) {
      $trimmed = $name.Trim()
      if (-not $names.Contains($trimmed)) { [void]$names.Add($trimmed) }
    }
  }

  $text = $names | Where-Object { $_ -and $_.Trim().Length -gt 2 } | Select-Object -Unique
  if (-not $text) { return $null }
  return ($text -join ' | ')
}

function Click-Button($Element, [string]$Label) {
  if ($null -eq $Element) { return $false }
  $condition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button)),
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::NameProperty, $Label)))
  $button = $Element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
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
  if ($normalized -match 'cannot find the path specified|cannot find the file|make sure the path and file name are correct|the file does not exist') {
    return [pscustomobject]@{ Type = 'error'; Action = 'OK'; ActionType = 'button'; ActionValue = 'OK' }
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
$windowStyle = switch ($Visibility) {
  'hidden' { 'Normal' }
  'minimized' { 'Normal' }
  default { 'Normal' }
}
$process = Start-Process -FilePath $Exe -ArgumentList $argumentList -PassThru -WindowStyle $windowStyle
if ($Visibility -ne 'normal') { Set-ProcessWindowVisibility $process.Id $Visibility }

$dialog = $null
$recovered = $false
$crashed = $false
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$cleanupPids = @($process.Id)

# The keys that dismiss the recovery prompt of Live, in the order they are tried.
$recoveryKeys = @('n', 'esc')
$recoveryAttempt = 0
$recoveryKeySentAt = $null

try {
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $cleanupPids = @(Get-ProcessTreeIds @($process.Id))
    Debug-Log "process tree: $($cleanupPids -join ',')"
    $running = @($cleanupPids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) { break }

    $text = Read-Log $logStart

    # Live writes the text of its message boxes to its log, and its dialogs are Qt windows that
    # UI Automation sees nothing in, so the log is where a dialog of Live is read from.
    $messages = [regex]::Matches($text, 'Message Box: (.*)')
    if ($messages.Count -gt 0) {
      $message = $messages[$messages.Count - 1].Groups[1].Value.Trim()
      if ($message -match 'recover your work') {
        # The recovery prompt holds the set back: the document is not loaded until it is gone.
        # The key goes to the windows of Live as soon as the prompt is seen, and again with the
        # next key when the prompt is still there.
        if ($recoveryAttempt -lt $recoveryKeys.Count) {
          $key = $recoveryKeys[$recoveryAttempt]
          $recoveryAttempt++
          $recoveryKeySentAt = Get-Date
          Debug-Log "dismissing the recovery prompt with $key"
          [void](Send-KeyToWindows $cleanupPids $key)
        } elseif ($null -ne $recoveryKeySentAt -and
                  ((Get-Date) - $recoveryKeySentAt).TotalSeconds -ge 1) {
          # The prompt did not go away. It is the window that has the focus that is dismissed,
          # so the app is brought to the foreground and the key is sent to it.
          $recoveryKeySentAt = Get-Date
          Debug-Log "dismissing the recovery prompt with the foreground"
          [void](Send-DismissKey $process.Id 'n')
        }
      } elseif (-not $dialog) {
        $dialog = $message
      }
    }
    if ($text -match 'Begin ExchangeDocument') { $recovered = $true }
    if ($text -match 'Exception: Fatal Error') { $crashed = $true }
    if ($text -match 'End ExchangeDocument') { break }

    foreach ($processId in $cleanupPids) {
      $windows = @(Get-Windows $processId)
      Debug-Log "visible windows for PID ${processId}: $($windows.Count)"
      foreach ($window in $windows) {
        $dialogElement = Get-DialogElement $window.Handle
        $shown = Get-DialogText $dialogElement
        Debug-Log "window PID=$processId class=$($window.Class) title=$($window.Title) text=$shown"
        if (-not $shown) { continue }

        $dialogInfo = Get-DialogInfo $shown
        $dialog = $shown

        if ($dialogInfo.Type -eq 'fatal') {
          $crashed = $true
          if (Click-Button $dialogElement $dialogInfo.Action) { }
          break
        }

        if ($dialogInfo.Type -eq 'recovery') {
          if (Click-Button $dialogElement $dialogInfo.Action) {
            $recovered = $true
            $dialog = $null
            break
          }
        }

        if ($dialogInfo.Type -eq 'save_changes') {
          if (Click-Button $dialogElement $dialogInfo.Action) { }
        }

        if ($dialogInfo.Type -and $dialogInfo.Type -ne 'unknown') { break }
      }
      if ($dialog) { break }
    }

    if ($dialog) { break }
    if ($recovered) { continue }
  }

  $cleanupPids = @(Get-ProcessTreeIds @($process.Id))
  foreach ($processId in $cleanupPids) {
    foreach ($window in Get-Windows $processId) {
      $dialogElement = Get-DialogElement $window.Handle
      $shown = Get-DialogText $dialogElement
      if ($shown -and $shown -notmatch 'serious program error|fatal error') {
        if (Click-Button $dialogElement 'OK') { }
        elseif (Click-Button $dialogElement 'No') { }
        elseif (Click-Button $dialogElement 'Yes') { }
      }
    }
  }
}
finally {
  $cleanupPids = @(Get-ProcessTreeIds @($process.Id))
  Close-VisibleWindowsForPids $cleanupPids

  # Live asks whether to save the set when it is closed. The set is a test, so the answer is no.
  # Live that is closed this way leaves no crash recovery state behind, and the next run starts
  # without a recovery prompt.
  $closeDeadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $closeDeadline) {
    $messages = [regex]::Matches((Read-Log $logStart), 'Message Box: (.*)')
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].Groups[1].Value -match 'Save changes') {
      [void](Send-KeyToWindows @(Get-ProcessTreeIds @($process.Id)) 'n')
    }
    $running = @(Get-ProcessTreeIds @($process.Id) | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) { break }
    Start-Sleep -Milliseconds 200
  }

  Stop-ProcessTree @($process.Id)
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
