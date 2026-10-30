<#
  GUI process probe for real-app compatibility testing.

  This script is the Windows-side implementation of the harness contract:
  - launch a GUI executable from WSL via PowerShell
  - retain ownership of the process and its windows
  - inspect the visible UIAutomation tree for real modal dialogs
  - classify the dialog from its user-visible text
  - dismiss the blocking control when possible
  - save the set that was opened, when a path is given
  - terminate the process tree cleanly before returning
#>
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Set,
  [string]$Log = '',
  [string]$SavePath = '',
  [switch]$SaveInPlace,
  [string]$PidFile = '',
  [int]$TimeoutSeconds = 5,
  [ValidateSet('normal','minimized','hidden')][string]$Visibility = 'normal',
  [switch]$HarnessDebug
)

if ($HarnessDebug) { $env:GUI_HARNESS_DEBUG = '1' }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Live {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr l);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
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

# Finds the installer helper of Ableton.
#
# Live checks for updates through a helper program of its own. The helper is not a child of
# Live, so it is not in the tree of Live, and the tree cannot be used to find it. It is not a
# Qt window either, so UI Automation does not see it. It blocks the machine while it runs: it
# takes the screen, and Live waits for it. A run that meets the helper is a run that is blocked.
#
# @param Names the names of the helper processes
# @return [array] the helper processes
function Get-InstallHelpers([string[]]$Names = @('InstallHelper')) {
  return @(Get-Process -Name $Names -ErrorAction SilentlyContinue)
}

# The prompts that ask for permission.
#
# The installer helper of Ableton asks for permission before it registers the file types of
# Live, and Live waits for the helper. The prompt is on the secure desktop, where no program
# of the session can reach it, so it is not answered by the harness and it is not answered by
# the run either.
#
# Only the prompts of the installer of Ableton are of interest here: a prompt of any other
# program is not the business of the harness.
#
# @return [array] the prompts of the installer that are waiting for an answer
function Get-PermissionPrompts {
  $prompts = @(Get-Process -Name 'consent' -ErrorAction SilentlyContinue)
  return @($prompts | Where-Object { $_.MainWindowTitle -match 'InstallHelper' })
}

# Whether the application waits for a permission that cannot be given.
#
# Only Live waits for the installer of Ableton, and only a prompt of that installer holds Live
# up. A prompt of any other program is of no account, and an application that is not Live does
# not wait for it at all.
#
# @param Exe the path of the application
# @param Prompts the prompts that are waiting for an answer
# @return [bool] whether the application waits
function Test-WaitsForPermission([string]$Exe, $Prompts) {
  if ($Exe -notmatch 'Ableton Live') { return $false }
  return (@($Prompts).Count -gt 0)
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
    'S' { return 0x53 }
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

# Sends a shortcut to the windows of an application.
#
# The shortcut is posted as key messages, with the modifiers posted before the key. The state
# of a key is held per thread, and the state of the target thread is what its window
# procedure reads, so a shortcut that is posted this way is seen as a shortcut.
#
# @param ProcessIds the processes the shortcut goes to
# @param Modifiers the modifiers of the shortcut, e.g. 'CTRL' and 'SHIFT'
# @param Key the key of the shortcut
# @return [int] the number of windows the shortcut was sent to
function Send-ShortcutToWindows([int[]]$ProcessIds, [string[]]$Modifiers, [string]$Key) {
  $code = Get-KeyCode $Key
  if ($code -eq 0) { return 0 }

  $modifierCodes = @()
  foreach ($modifier in $Modifiers) {
    switch ($modifier.ToUpper()) {
      'CTRL' { $modifierCodes += 0x11 }
      'SHIFT' { $modifierCodes += 0x10 }
      'ALT' { $modifierCodes += 0x12 }
    }
  }

  $script:sent = 0
  [Live]::EnumWindows({
    param($handle, $lparam)
    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    if ($ProcessIds -contains [int]$owner) {
      foreach ($modifier in $modifierCodes) {
        [void][Live]::PostMessage($handle, 0x0100, [IntPtr]$modifier, [IntPtr]::Zero)
      }
      [void][Live]::PostMessage($handle, 0x0100, [IntPtr]$code, [IntPtr]::Zero)
      [void][Live]::PostMessage($handle, 0x0101, [IntPtr]$code, [IntPtr]::Zero)
      foreach ($modifier in $modifierCodes) {
        [void][Live]::PostMessage($handle, 0x0101, [IntPtr]$modifier, [IntPtr]::Zero)
      }
      $script:sent++
    }
    return $true
  }, [IntPtr]::Zero) | Out-Null

  Debug-Log "sent the shortcut $Key to $script:sent windows"
  return $script:sent
}

# Brings a window to the foreground.
#
# A process that runs in the background may not take the foreground: Windows gives the
# foreground to the process that presses a key, so the ALT key is pressed when the window does
# not come to the front. Whether the window is in the foreground is what is returned, because
# the keys that are typed go to the window in the foreground and to no other.
#
# @param Handle the handle of the window
# @return [boolean] whether the window is in the foreground
function Focus-Window([IntPtr]$Handle) {
  [void][Live]::ShowWindow($Handle, 9)
  Start-Sleep -Milliseconds 100
  [void][Live]::BringWindowToTop($Handle)
  [void][Live]::SetForegroundWindow($Handle)
  Start-Sleep -Milliseconds 100

  if ([Live]::GetForegroundWindow() -ne $Handle) {
    [Live]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
    [Live]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    [void][Live]::SetForegroundWindow($Handle)
    Start-Sleep -Milliseconds 100
  }

  return ([Live]::GetForegroundWindow() -eq $Handle)
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

# Escapes the characters that WScript.Shell.SendKeys treats as commands.
#
# @param Text the text to escape
# @return [string] the text, with the commands escaped
function Escape-Keys([string]$Text) {
  return [regex]::Replace($Text, '([+\^%~(){}\[\]])', '{$1}')
}

# Finds the dialogs that say something.
#
# A dialog that says something is a window of the standard class, and it holds the text of
# its message in the controls that hold static text. The text is what says what the dialog
# is asking for, and which of its buttons is the right one to press.
#
# @return [Array] the dialogs, with their text and their buttons
# Dismisses the dialogs that say something.
#
# A dialog that says something holds the program up: the program does not answer the keys that
# are sent to it while the dialog is there. The dialog is dismissed by pressing the button that
# answers it, so that the program answers the keys again.
#
# A dialog that says the program failed is not dismissed: it is reported, and the run is over.
#
# @param ProcessIds the processes whose windows are looked at
# @return [Array] the texts of the dialogs that were dismissed
function Dismiss-MessageDialogs([int[]]$ProcessIds) {
  $dismissed = @()
  foreach ($messageDialog in Find-MessageDialogs $ProcessIds) {
    $text = $messageDialog.Text
    if ($text -match 'serious program error|fatal error|shut down after this message box') { continue }

    $button = $messageDialog.Buttons | Where-Object { $_.Title -match '^(OK|&OK)$' } | Select-Object -First 1
    if ($null -eq $button) {
      $button = $messageDialog.Buttons | Where-Object { $_.Title -match '^(No|&No)$' } | Select-Object -First 1
    }
    if ($null -eq $button) {
      Debug-Log "the dialog says: $text"
      Debug-Log 'the dialog has no known button, sending the escape to the foreground'
      continue
    }

    Debug-Log "the dialog says: $text"
    Debug-Log "pressing the '$($button.Title)' button of the dialog"
    [void](Press-Button $button)
    $dismissed += $text
  }
  return $dismissed
}

# Finds the window of the application itself.
#
# The window of the application is the largest window of the process, and it is the one that
# has the title of the set that is open. The windows that are smaller are the splash screen
# and the windows of the plugins, and the keys that go to them are lost.
#
# @param ProcessId the process of the application
# @return the window, or $null when the application has no window yet
function Find-MainWindow([int]$ProcessId) {
  $best = $null
  $bestArea = 0
  $untitled = $null
  $untitledArea = 0
  foreach ($window in Get-Windows $ProcessId) {
    if ($window.Class -eq '#32770') { continue }

    $rect = New-Object Live+RECT
    [void][Live]::GetWindowRect($window.Handle, [ref]$rect)
    $area = ($rect.Right - $rect.Left) * ($rect.Bottom - $rect.Top)

    # A window without a title is the window of the application while the set is still loading,
    # and it is the splash screen later on. It is only used when the application has no window
    # with a title at all.
    if (-not $window.Title -or $window.Title.Trim().Length -eq 0) {
      if ($area -gt $untitledArea) {
        $untitledArea = $area
        $untitled = $window
      }
      continue
    }

    if ($area -le $bestArea) { continue }

    $bestArea = $area
    $best = $window
  }
  if ($null -ne $best) { return $best }
  return $untitled
}

# Waits for the window of the application to be there and to have its title.
#
# The set is loaded before the window of the application has its title, so the keys that are
# sent to it too early are lost.
#
# @param ProcessId the process of the application
# @param Seconds how long to wait
# @return the window, or $null when the application has no titled window in that time
function Wait-ForMainWindow([int]$ProcessId, [int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    $window = Find-MainWindow $ProcessId
    if ($null -ne $window) { return $window }
    Start-Sleep -Milliseconds 200
  }
  return $null
}

function Find-MessageDialogs([int[]]$ProcessIds) {
  $found = New-Object System.Collections.ArrayList
  foreach ($window in Get-ProcessWindows $ProcessIds) {
    if ($window.Class -ne '#32770') { continue }

    $children = @(Get-DirectChildren $window.Handle @(Get-ChildWindows $window.Handle))

    # A dialog that asks for the name of a file is not a dialog that says something: it holds
    # a field for the name and a button that confirms the save, and its text belongs to the
    # places in the file system.
    $isFileDialog = $false
    foreach ($child in $children) {
      if ($child.Class -eq 'Edit') { $isFileDialog = $true }
      if ($child.Class -eq 'Button' -and $child.Title -match '^(Save|&Save|Save As|&Save As)$') { $isFileDialog = $true }
    }
    if ($isFileDialog) { continue }

    $texts = @($children | Where-Object { $_.Class -eq 'Static' -and $_.Title -and $_.Title.Trim().Length -gt 0 } |
                 ForEach-Object { $_.Title.Trim() })
    if ($texts.Count -eq 0) { continue }

    $buttons = @($children | Where-Object { $_.Class -eq 'Button' })
    [void]$found.Add([pscustomobject]@{
      Window = $window
      Text = ($texts -join ' ')
      Buttons = $buttons
    })
  }
  return $found
}

# Presses a button of a dialog.
#
# The button is pressed by the message that a button expects, so that the program that owns
# the dialog sees the click the way it sees a click from a person.
#
# @param Button the button to press
# @return [boolean] whether the button was pressed
function Press-Button($Button) {
  if ($null -eq $Button) { return $false }
  [void][Live]::SendMessage($Button.Handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
  return $true
}

# Finds the dialog that asks for the name of a file.
#
# A file dialog is told apart by the controls it holds: a field for the name of the file, and
# a button that confirms the save. A window without those controls is not a file dialog, so
# the window of the application itself is never mistaken for one.
#
# The windows of every program that has a user interface are looked at, because the dialog is
# not always a window of the program that was launched: a program can ask another program to
# put up its dialog.
#
# @return the dialog, with the field and the button, or $null when there is none
# Writes down the windows of the programs that have a user interface, and the controls they
# hold, so that a dialog that was not recognized can be looked at.
function Dump-GuiWindows([int[]]$ProcessIds) {
  foreach ($window in Get-ProcessWindows $ProcessIds) {
    Debug-Log "gui window: class=$($window.Class) title=$($window.Title)"
    $tree = @(Get-ChildWindows $window.Handle)
    foreach ($child in $tree) {
      Debug-Log "  child: class=$($child.Class) title=$($child.Title) parent=$($child.Parent)"
    }
  }
}

function Find-FileDialog([int[]]$ProcessIds) {
  foreach ($window in Get-ProcessWindows $ProcessIds) {
    # The windows inside the window are read in one go, because reading them again for every
    # one of them costs a walk of the whole tree for each of them, and the walk is slow.
    $tree = @(Get-ChildWindows $window.Handle)

    # The dialog of the program is a window of its own inside the window of the program, so
    # the windows inside the windows are looked at as well.
    $candidates = @($window) + $tree
    foreach ($candidate in $candidates) {
      $children = @(Get-DirectChildren $candidate.Handle $tree)
      if ($children.Count -eq 0) { continue }

      # The button that confirms the save is a control of the dialog itself, but the field
      # that holds the name of the file is not always: a dialog of the newer style holds it
      # inside a box that holds a list of the recent names, and the field is inside that.
      $save = $null
      foreach ($child in $children) {
        if ($child.Class -eq 'Button' -and $child.Title -match '^(Save|&Save|Save As|&Save As)$') {
          $save = $child
          break
        }
      }

      # A dialog holds more than one field for typing: the field for the name of the file, and
      # the field for the place to look for it. The field for the name of the file is the one
      # that is under the box that holds the list of the recent names, so the fields are told
      # apart by what holds them.
      $below = @(Get-Descendants $candidate.Handle $tree)
      $edit = $null
      foreach ($child in $below) {
        if ($child.Class -ne 'Edit') { continue }
        $chain = (Get-AncestorClasses $child $tree) -join ' > '
        Debug-Log "  edit under: $chain"
        if ($chain -match 'FloatNotifySink') { $edit = $child; break }
        if ($null -eq $edit) { $edit = $child }
      }

      if ($null -eq $edit -and $null -eq $save) { continue }

      Debug-Log "file dialog: class=$($candidate.Class) title=$($candidate.Title)"
      foreach ($child in $children) {
        Debug-Log "  child: class=$($child.Class) title=$($child.Title)"
      }
      return [pscustomobject]@{
        Window = $candidate
        Edit = $edit
        Save = $save
      }
    }
  }
  return $null
}

# Saves the set that the application has open.
#
# The save is done with the keyboard: the application is brought to the foreground, its Save As
# command is sent, the path of the set is typed, and the save is confirmed. The file that
# appears is what says whether the save worked.
#
# The path that is typed has no extension, because the application gives the set its own name
# and puts it in a project folder: a set that is saved as "C:/sets/Foo" is written as
# "C:/sets/Foo Project/Foo.als". Both are looked for, so that the file that appears is found
# wherever the application puts it.
#
# A file that is already there is not a save: the file has to be written after the save was
# asked for, so that a set that was left over from an earlier run is not taken for the result.
#
# @param ProcessId the process the keys go to
# @param ProcessIds the processes whose windows are looked at
# @param Path the path of the set to write
# @return [string] the path the set was written to, or an empty string when it was not written
function Save-Document([int]$ProcessId, [int[]]$ProcessIds, [string]$Path) {
  $shell = New-Object -ComObject WScript.Shell
  $asked = Get-Date

  # A dialog that is up holds the application up, and the keys that go to the application are
  # lost while it is there. The dialogs are dismissed before the keys are sent.
  [void](Dismiss-MessageDialogs $ProcessIds)

  # The window of the application itself is the one that takes the keys. A window that is a
  # dialog is not that window, even when it has a title: the Kontakt error box of Live has a
  # title, and the keys that go to it are lost.
  $main = Wait-ForMainWindow $ProcessId 10
  if ($null -ne $main) {
    Debug-Log "the window of the application is '$($main.Title)'"
    Debug-Log "the window of the application is in the foreground: $(Focus-Window $main.Handle)"
  } else {
    Debug-Log "the application was brought to the foreground: $($shell.AppActivate($ProcessId))"
  }
  Start-Sleep -Milliseconds 500

  Debug-Log "sending Save As"
  $shell.SendKeys('^+s')

  # The save dialog is a window of its own, and the path has to be typed into it, so the
  # dialog is waited for and brought to the foreground.
  #
  # The key is sent again while the dialog is waited for, because the key is lost when the
  # application is busy or when another window has the focus. The dialog comes up in a second
  # or two when the key gets through.
  $dialog = $null
  $dumped = $false
  $askedAgain = Get-Date
  $dialogDeadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $dialogDeadline) {
    Start-Sleep -Milliseconds 200
    $dialog = Find-FileDialog $ProcessIds
    if ($null -ne $dialog) { break }

    # A dialog that comes up while the save dialog is waited for holds the application up, and
    # the save dialog never comes up while it is there.
    [void](Dismiss-MessageDialogs $ProcessIds)

    if (((Get-Date) - $askedAgain).TotalSeconds -ge 1) {
      $askedAgain = Get-Date
      Debug-Log 'sending Save As again'
      if ($null -ne $main) { [void](Focus-Window $main.Handle) }
      $shell.SendKeys('^+s')
    }

    if (-not $dumped) {
      $dumped = $true
      Debug-Log 'no save dialog yet'
      Dump-GuiWindows $ProcessIds
    }
  }
  if ($null -eq $dialog) {
    Debug-Log 'no save dialog came up'
    Dump-GuiWindows $ProcessIds
    return ''
  }
  Debug-Log "the save dialog is up: class=$($dialog.Window.Class) title=$($dialog.Window.Title)"
  Debug-Log "the save dialog is in the foreground: $(Focus-Window $dialog.Window.Handle)"
  Start-Sleep -Milliseconds 300

  $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $directory = [System.IO.Path]::GetDirectoryName($Path)
  $typed = [System.IO.Path]::Combine($directory, $name)

  if ($null -ne $dialog.Edit) {
    # The field that holds the name of the file is a control of the dialog, so the name is put
    # into it directly, and the button that confirms the save is pressed.
    Debug-Log "putting the path $typed into the field of the dialog"
    $text = New-Object System.Text.StringBuilder $typed
    [void][Live]::SendMessage($dialog.Edit.Handle, 0x000C, [IntPtr]::Zero, $text)
    Start-Sleep -Milliseconds 200
    if ($null -ne $dialog.Save) {
      Debug-Log "pressing the '$($dialog.Save.Title)' button"
      [void][Live]::SendMessage($dialog.Save.Handle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    } else {
      $shell.SendKeys('{ENTER}')
    }
  } else {
    Debug-Log "typing the path $typed"
    $shell.SendKeys((Escape-Keys $typed))
    Start-Sleep -Milliseconds 500
    $shell.SendKeys('{ENTER}')
  }

  # Live writes a set as a project folder, so the set is looked for in the folder as well.
  $candidates = @(
    $Path,
    ($typed + '.als'),
    [System.IO.Path]::Combine($directory, ($name + ' Project'), ($name + '.als'))
  )

  $deadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $deadline) {
    foreach ($candidate in $candidates) {
      if (Test-Path $candidate) {
        if ((Get-Item $candidate).LastWriteTime -gt $asked) { return $candidate }
        Debug-Log "the file $candidate is there, but it was not written by this save"
      }
    }
    Start-Sleep -Milliseconds 200
  }
  return ''
}

# Waits for the set to be written.
#
# The file that the application writes is what says whether the save worked: the file has to
# change, and it has to change after the question was answered.
#
# @param Path the path of the set
# @param Before when the set was written last
# @return [string] the path of the set, or an empty string when the set was not written
function Wait-ForSet([string]$Path, [datetime]$Before) {
  if (-not (Test-Path $Path)) { return '' }

  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline) {
    if ((Get-Item $Path).LastWriteTime -gt $Before) { return $Path }
    Start-Sleep -Milliseconds 200
  }
  return ''
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

# The windows that belong to a window.
#
# A window holds the controls of a dialog, and the controls are what say what the dialog is
# and what it is asking for: the field that holds the name of the file, and the button that
# confirms it. A window that has no children of its own says nothing about that.
#
# The enumeration walks the whole tree of the window in one go, and the parent of each window
# is written down with it, so that the children of a window can be told apart from the
# children of its children.
#
# @param Parent the handle of the window
# @return [Array] the windows in the tree, with their class, their title and their parent
function Get-ChildWindows([IntPtr]$Parent) {
  $found = New-Object System.Collections.ArrayList
  [Live]::EnumChildWindows($Parent, {
    param($handle, $lparam)
    $class = New-Object System.Text.StringBuilder 256
    [void][Live]::GetClassName($handle, $class, 256)
    $title = New-Object System.Text.StringBuilder 1024
    [void][Live]::GetWindowText($handle, $title, 1024)
    [void]$found.Add([pscustomobject]@{
      Handle = $handle
      Class = $class.ToString()
      Title = $title.ToString()
      Parent = [Live]::GetParent($handle)
    })
    return $true
  }, [IntPtr]::Zero) | Out-Null
  return $found
}

# The windows that are the direct children of a window.
#
# @param Parent the handle of the window
# @param Tree the windows in the tree of the window
# @return [Array] the children of the window
function Get-DirectChildren([IntPtr]$Parent, $Tree) {
  return @($Tree | Where-Object { $_.Parent -eq $Parent })
}

# The windows that are below a window.
#
# A window is below another window when the other one is on its way up to the top: the parent
# of the window, or the parent of that one, and so on.
#
# @param Ancestor the handle of the window
# @param Tree the windows in the tree of the window
# @return [Array] the windows below the window
function Get-Descendants([IntPtr]$Ancestor, $Tree) {
  $parents = @{}
  foreach ($window in $Tree) { $parents[$window.Handle] = $window.Parent }

  $below = New-Object System.Collections.ArrayList
  foreach ($window in $Tree) {
    $parent = $window.Parent
    while ($null -ne $parent -and $parent -ne [IntPtr]::Zero) {
      if ($parent -eq $Ancestor) {
        [void]$below.Add($window)
        break
      }
      $parent = $parents[$parent]
    }
  }
  return $below
}

# The classes of the windows that hold a window.
#
# The chain is the way up from the window to the top of the tree, and it says what a window is
# a part of. Two windows of the same class can be told apart by the chain: a dialog of the
# newer style holds a field for the name of the file under a box that holds the list of the
# recent names, and a field for the place to look for it under a different box.
#
# @param Window the window
# @param Tree the windows in the tree of the window
# @return [Array] the classes of the windows that hold the window, from the top down
function Get-AncestorClasses($Window, $Tree) {
  $parents = @{}
  $classes = @{}
  foreach ($item in $Tree) {
    $parents[$item.Handle] = $item.Parent
    $classes[$item.Handle] = $item.Class
  }

  $chain = New-Object System.Collections.ArrayList
  $parent = $parents[$Window.Handle]
  while ($null -ne $parent -and $parent -ne [IntPtr]::Zero) {
    if ($classes.ContainsKey($parent)) { [void]$chain.Add($classes[$parent]) }
    $parent = $parents[$parent]
  }

  if ($chain.Count -eq 0) { return @() }
  return @($chain.ToArray())[($chain.Count - 1)..0]
}

# The windows of the programs that have a user interface.
#
# A window that is visible is a window of a program that has a user interface, so the
# background programs, which have no windows at all, are left out by looking at the visible
# windows only.
#
# @return [Array] the visible windows, with the program they belong to
function Get-GuiWindows {
  $found = New-Object System.Collections.ArrayList
  [Live]::EnumWindows({
    param($handle, $lparam)
    if (-not [Live]::IsWindowVisible($handle)) { return $true }

    $owner = 0
    [void][Live]::GetWindowThreadProcessId($handle, [ref]$owner)
    $class = New-Object System.Text.StringBuilder 256
    [void][Live]::GetClassName($handle, $class, 256)
    $title = New-Object System.Text.StringBuilder 1024
    [void][Live]::GetWindowText($handle, $title, 1024)

    $program = ''
    try { $program = (Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { }
    [void]$found.Add([pscustomobject]@{
      Handle = $handle
      Class = $class.ToString()
      Title = $title.ToString()
      ProcessId = $owner
      Program = $program
    })
    return $true
  }, [IntPtr]::Zero) | Out-Null
  return $found
}

# The windows of a set of programs.
#
# A dialog belongs to the program that puts it up, so the windows of the programs that are
# asked about are the ones that are looked at.
#
# @param ProcessIds the processes whose windows are wanted
# @return [Array] the visible windows, with the program they belong to
function Get-ProcessWindows([int[]]$ProcessIds) {
  $found = New-Object System.Collections.ArrayList
  foreach ($processId in $ProcessIds) {
    foreach ($window in Get-Windows $processId) {
      [void]$found.Add([pscustomobject]@{
        Handle = $window.Handle
        Class = $window.Class
        Title = $window.Title
        ProcessId = $processId
      })
    }
  }
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
  if ($normalized -match 'InstallHelper|installing packages') {
    return [pscustomobject]@{ Type = 'updater'; Action = $null; ActionType = $null; ActionValue = $null }
  }
  if ($normalized -match 'A serious program error has occurred\.|fatal error|Live will shut down after this message box is closed\.|program error') {
    return [pscustomobject]@{ Type = 'fatal'; Action = 'OK'; ActionType = 'button'; ActionValue = 'OK' }
  }
  if ($normalized -match 'Would you like to recover your work\?|recover your work|Live unexpectedly quit while you were working on the Live Set') {
    return [pscustomobject]@{ Type = 'recovery'; Action = 'No'; ActionType = 'button'; ActionValue = 'No' }
  }
  if ($normalized -match 'Save changes\?|Do you want to save the changes\?') {
    return [pscustomobject]@{ Type = 'save_changes'; Action = 'No'; ActionType = 'button'; ActionValue = 'No' }
  }
  if ($normalized -match 'cannot find the path specified|cannot find the file|cannot find the .* file|make sure the path and file name are correct|the file does not exist') {
    return [pscustomobject]@{ Type = 'error'; Action = 'OK'; ActionType = 'button'; ActionValue = 'OK' }
  }

  return [pscustomobject]@{ Type = 'unknown'; Action = $null; ActionType = $null; ActionValue = $null }
}

# The body of the script.
#
# The functions above are the parts of the harness that can be tested on their own: a test
# dot-sources this script and calls them. The body launches the application, so it runs only
# when the script is run, and not when it is dot-sourced.
function Invoke-Main {

# A Live that is still running from an earlier run is closed before this run starts.
#
# It is closed, and not killed: a Live that is killed while it checks for package installation
# checks again on the next start, and puts up the installer of Ableton. The installer takes the
# machine over while it runs, so a Live that is left half way through its start is a problem
# that comes back on every run.
function Close-RunningLive() {
  $running = @(Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue)
  if ($running.Count -eq 0) { return }

  $pids = @($running | ForEach-Object { $_.Id })
  Debug-Log "closing Live that is still running (pids: $($pids -join ','))"
  Close-VisibleWindowsForPids $pids

  $deadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $deadline) {
    $messages = [regex]::Matches((Read-Log $logStart), 'Message Box: (.*)')
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].Groups[1].Value -match 'Save changes') {
      [void](Send-KeyToWindows $pids 'n')
    }
    $remaining = @(Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  }

  Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$logStart = 0
if ($Log -and (Test-Path $Log)) { $logStart = (Get-Item $Log).Length }

Close-RunningLive
Cleanup-Notepad
Start-Sleep -Milliseconds 250

$dialog = $null
$recovered = $false
$crashed = $false
$saved = ''
$updater = $false
$lastMessage = $null
$dismissed = @()

$argumentList = @()
if ($Set) { $argumentList = @($Set) }
$windowStyle = switch ($Visibility) {
  'hidden' { 'Normal' }
  'minimized' { 'Normal' }
  default { 'Normal' }
}

# A permission prompt of the installer of Ableton is on the secure desktop, where nothing of
# the session can answer it. Live waits for that permission, and every Live that is started
# while a prompt is waiting leaves another prompt behind. So Live is not started at all while
# a prompt is waiting, and the run is reported as blocked by the installer.
$pendingPrompts = @(Get-PermissionPrompts)
$process = $null
if (Test-WaitsForPermission $Exe $pendingPrompts) {
  $updater = $true
  Debug-Log "a prompt is asking for permission ($($pendingPrompts.Count) of them); Live is not started"
} else {
  $process = Start-Process -FilePath $Exe -ArgumentList $argumentList -PassThru -WindowStyle $windowStyle
  if ($Visibility -ne 'normal') { Set-ProcessWindowVisibility $process.Id $Visibility }

  # The pid of the application is written down, so that a run that is cut short from the outside
  # still knows what to stop. A Live that is left running goes on by itself, and it takes the
  # machine over when it checks for package installation.
  if ($PidFile) { Set-Content -Path $PidFile -Value $process.Id -Encoding ascii }
}

# When the set was written last, so that the write of the application can be told apart from
# the set that was there before.
$setWriteTime = [datetime]::MinValue
if ($Set -and (Test-Path $Set)) { $setWriteTime = (Get-Item $Set).LastWriteTime }

# The installer helper of Ableton is given this many seconds to do its work before it is
# dismissed.
$helperWaitSeconds = 10
$helperSeenAt = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$cleanupPids = @()
if ($process) { $cleanupPids = @($process.Id) }

# The keys that dismiss the recovery prompt of Live, in the order they are tried.
$recoveryKeys = @('n', 'esc')
$recoveryAttempt = 0
$recoveryKeySentAt = $null

try {
  while ((Get-Date) -lt $deadline) {
    # The application was not started, because a permission prompt is waiting. There is
    # nothing to watch for.
    if ($null -eq $process) { break }

    Start-Sleep -Milliseconds 200
    $cleanupPids = @(Get-ProcessTreeIds @($process.Id))
    Debug-Log "process tree: $($cleanupPids -join ',')"
    $running = @($cleanupPids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) { break }

    # The installer helper of Ableton blocks the machine while it runs, and Live waits for it,
    # so the set is never loaded while the helper is up. The helper is given ten seconds to do
    # its work, and is dismissed after that, so that the screen of the machine is free again.
    $helpers = @(Get-InstallHelpers)
    $prompts = @(Get-PermissionPrompts)
    if (Test-WaitsForPermission $Exe $prompts) {
      # A prompt is asking for permission, and the prompt is where nothing can reach it, so it
      # cannot be answered here. Live waits for the permission, and the set is not loaded
      # until it is given. The run is reported as blocked, so that the wait is not mistaken
      # for a set that was loaded.
      $updater = $true
      Debug-Log "a prompt is asking for permission ($($prompts.Count) of them); Live waits for it"
      break
    }
    if ($helpers.Count -gt 0) {
      $updater = $true
      if ($null -eq $helperSeenAt) { $helperSeenAt = Get-Date }
      $helperPids = @($helpers | ForEach-Object { $_.Id })
      $waiting = ((Get-Date) - $helperSeenAt).TotalSeconds
      Debug-Log "InstallHelper is running (pids: $($helperPids -join ',')); waiting ${waiting}s"
      if ($waiting -ge $helperWaitSeconds) {
        Debug-Log "dismissing InstallHelper"
        foreach ($helper in $helpers) {
          # The helper is not a Qt window, so a posted key does not reach it: the escape is
          # typed to the window that has the focus.
          [void](Send-DismissKey $helper.Id '{ESC}')
          foreach ($window in Get-Windows $helper.Id) {
            [void][Live]::PostMessage($window.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
          }
        }
        # Live gets the time it needs to load the set, now that the machine is free again.
        $deadline = $deadline.AddSeconds($waiting)
        $helperSeenAt = $null
      }
    } else {
      $helperSeenAt = $null
    }

    $text = Read-Log $logStart

    # Live says in its log when it checks for packages, which it does on every start. The
    # check itself is not the updater: the updater is the helper that does the installing, and
    # the helper is a process of its own.
    if ($text -match 'Check for package installation') {
      Debug-Log 'Live is checking for package installation'
    }

    # A dialog of the standard class holds the text of its message in the controls that hold
    # static text, and it holds the buttons that answer it. The button that answers it is
    # pressed, so that the dialog goes away the way a person would make it go away.
    foreach ($messageDialog in Find-MessageDialogs $cleanupPids) {
      $messageText = $messageDialog.Text
      if ($messageText -eq $lastMessage) { continue }

      if ($messageText -match 'serious program error|fatal error|shut down after this message box') {
        $dialog = $messageText
        $crashed = $true
        $lastMessage = $messageText
        continue
      }

      $lastMessage = $messageText
      $dismissed += $messageText
      Debug-Log "the dialog says: $messageText"

      $button = $messageDialog.Buttons | Where-Object { $_.Title -match '^(OK|&OK)$' } | Select-Object -First 1
      if ($null -eq $button) {
        $button = $messageDialog.Buttons | Where-Object { $_.Title -match '^(No|&No)$' } | Select-Object -First 1
      }
      if ($null -ne $button) {
        Debug-Log "pressing the '$($button.Title)' button of the dialog"
        [void](Press-Button $button)
      } else {
        # The dialog has no button that is known, so the key that closes it is sent to the
        # window that has the focus.
        Debug-Log 'the dialog has no known button, sending the escape to the foreground'
        [void](Send-DismissKey $process.Id '{ESC}')
      }
    }

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
        } else {
          if ($null -ne $recoveryKeySentAt -and
              ((Get-Date) - $recoveryKeySentAt).TotalSeconds -ge 1) {
            # The prompt did not go away. It is the window that has the focus that is dismissed,
            # so the app is brought to the foreground and the key is sent to it.
            $recoveryKeySentAt = Get-Date
            Debug-Log "dismissing the recovery prompt with the foreground"
            [void](Send-DismissKey $process.Id 'n')
          }
        }
      } else {
        if ($message -ne $lastMessage) {
          $lastMessage = $message
          if ($message -match 'serious program error|fatal error|shut down after this message box') {
            $dialog = $message
            $crashed = $true
          } else {
            # A message box that is not fatal is dismissed, so that the set can still be loaded.
            # Live puts up a box of its own when a plugin cannot be loaded, and that box holds
            # the set back as long as it is there.
            $dismissed += $message
            Debug-Log "dismissing the message box: $message"
            [void](Send-KeyToWindows $cleanupPids 'esc')
          }
        }
      }
    }
    if ($text -match 'Begin ExchangeDocument') { $recovered = $true }
    if ($text -match 'Exception: Fatal Error') { $crashed = $true }

    # Live says that it has loaded the document it was given even when the document could not
    # be loaded, so the failure is looked for first. A set that is not loaded is not saved.
    $failure = [regex]::Match($text, 'Failed to load command-line document: (.*)')
    if ($failure.Success) {
      $dialog = $failure.Groups[1].Value.Trim()
      Debug-Log "the document was not loaded: $dialog"
      break
    }

    # The set is loaded when Live says that it has loaded the document it was given. Live says
    # it twice over: once for the document of the start, and once for the document of the
    # command line. The last one is the set that was asked for.
    #
    # The log is what says when the set is loaded, so a set that takes a long time to load is
    # waited for as long as it takes, and a set that loads quickly is not waited for at all.
    if ($text -match 'Loading command-line document: done\.') {
      # The set is loaded. It is saved here, because the save is what the caller asked for, and
      # the set is the thing Live has open.
      if ($SaveInPlace) {
        Debug-Log "the set will be saved when Live is closed: $Set"
      } else {
        if ($SavePath -and -not $saved) {
          Debug-Log "saving the set to $SavePath"
          $saved = Save-Document $process.Id $cleanupPids $SavePath
          Debug-Log "saved: $saved"
        }
      }
      break
    }

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
  $cleanupPids += @(Get-InstallHelpers | ForEach-Object { $_.Id })
  Close-VisibleWindowsForPids $cleanupPids

  # Live asks whether to save the set when it is closed. The set is a test, so the answer is
  # no, unless the caller asked for the set to be saved. Live that is closed this way leaves no
  # crash recovery state behind, and the next run starts without a recovery prompt.
  $closeDeadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $closeDeadline) {
    $messages = [regex]::Matches((Read-Log $logStart), 'Message Box: (.*)')
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].Groups[1].Value -match 'Save changes') {
      if ($SaveInPlace) {
        Debug-Log 'answering the save prompt with yes'
        [void](Send-KeyToWindows @(Get-ProcessTreeIds @($process.Id)) 'y')
      } else {
        [void](Send-KeyToWindows @(Get-ProcessTreeIds @($process.Id)) 'n')
      }
    }
    $running = @(Get-ProcessTreeIds @($process.Id) | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($running.Count -eq 0) { break }
    Start-Sleep -Milliseconds 200
  }

  # The set is written while Live is closing, so Live is not killed before it is written.
  if ($SaveInPlace -and -not $saved) {
    $saved = Wait-ForSet $Set $setWriteTime
    Debug-Log "saved: $saved"
  }

  Stop-ProcessTree $cleanupPids
  Cleanup-Notepad
  if ($PidFile -and (Test-Path $PidFile)) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
}

if ($updater -and -not $dialog) {
  $dialog = 'Live is installing packages: the installer takes over the machine and Live waits for it'
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
if ($updater) { Write-Output 'UPDATER: yes' } else { Write-Output 'UPDATER: no' }
foreach ($message in $dismissed) { Write-Output ('MESSAGE: ' + $message) }
if ($recovered) { Write-Output 'RECOVERED: yes' } else { Write-Output 'RECOVERED: no' }
if ($SavePath) {
  if ($saved) { Write-Output 'SAVED: yes' } else { Write-Output 'SAVED: no' }
  if ($saved) { Write-Output ('SAVED_PATH: ' + $saved) } else { Write-Output ('SAVED_PATH: ' + $SavePath) }
}

Write-Output '--- LOG ---'
Write-Output (Read-Log $logStart)

}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
