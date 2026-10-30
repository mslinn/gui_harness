<#
  The Live library of the GUI harness.

  This file holds what is particular to Ableton Live: Live's log, Live's message boxes, Live's
  recovery prompt, Live's installer, and the way Live is shut down.

  The library has no `param()` block, for the same reason the generic library has none: a
  dot-sourced script assigns its parameters in the caller's scope, and the parameters of the
  run belong to the entry point.

  The generic library is loaded first, and the seams are redefined after it. PowerShell
  resolves a command name when it is called, so a seam that is called by name from generic
  code is the Live definition once this file is loaded.
#>

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'generic/gui_harness_generic.ps1')

# The capture of a window.
#
# The type is added only when it is not there yet, because a library that is dot-sourced
# twice in one session would otherwise fail with "type name already exists".
if (-not ('GuiHarnessCapture' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public class GuiHarnessCapture {
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
}
'@
}

# The window of a dialog of Live.
#
# A dialog of Live is a window of its own, and it has an owner: the window it belongs to. The
# window of the application itself has no owner, so it is not a dialog.
#
# @param Context the run
# @return [object] the window of the dialog, or $null when there is none
function Get-DialogWindow($Context) {
  foreach ($targetPid in $Context.ProcessIds) {
    foreach ($window in Get-TopLevelWindows @($targetPid)) {
      if (-not [GuiHarness]::IsWindowVisible($window.Handle)) { continue }
      if ([IntPtr]::Zero -eq [GuiHarnessCapture]::GetWindow($window.Handle, 4)) { continue }
      return $window
    }
  }
  return $null
}

# The text of a window, read from its pixels.
#
# Live draws its own windows, and nothing in the window tree describes them: the window class
# is Live's own and not #32770, the windows have no children, and UI Automation, the raw view
# and MSAA all come back empty. The pixels are the one place the text survives.
#
# The capture is made with PrintWindow, and the text is recovered from it with the OCR engine
# that Windows has. The OCR reads the text of a large window well, and it drops the words in
# the middle of a line of a small one, so the text of a dialog is a reading of it and not a
# transcription of it.
#
# @param Handle the handle of the window
# @return [string] the text of the window, or an empty string when there is none
function Get-WindowText([IntPtr]$Handle) {
  try {
    $bitmap = Capture-Window $Handle
    if ($null -eq $bitmap) { return '' }
    try {
      return (Read-ImageText $bitmap)
    } finally {
      $bitmap.Dispose()
    }
  } catch {
    Debug-Log "the text of the window could not be read: $_"
    return ''
  }
}

# The image of a window.
#
# The window is captured with PW_RENDERFULLCONTENT, which is what makes the content of a
# window that draws itself appear in the capture. A plain PrintWindow gives a blank or a
# partial image.
#
# @param Handle the handle of the window
# @return [object] the image of the window, or $null when the window has none
function Capture-Window([IntPtr]$Handle) {
  Add-Type -AssemblyName System.Drawing

  $rect = New-Object GuiHarness+RECT
  [void][GuiHarness]::GetWindowRect($Handle, [ref]$rect)
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { return $null }

  $bitmap = New-Object System.Drawing.Bitmap $width, $height
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $hdc = $graphics.GetHdc()
  [void][GuiHarnessCapture]::PrintWindow($Handle, $hdc, 2)
  $graphics.ReleaseHdc($hdc)
  $graphics.Dispose()
  return $bitmap
}

# The text of an image, read with the OCR engine of Windows.
#
# @param Bitmap the image
# @param LanguageTag the language of the text, e.g. 'en-US'
# @return [string] the text of the image, or an empty string when there is none
function Read-ImageText([System.Drawing.Bitmap]$Bitmap, [string]$LanguageTag = 'en-US') {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime

  $stream = New-Object System.IO.MemoryStream
  $null = $Bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
  $stream.Position = 0

  $null = [Windows.Storage.Streams.RandomAccessStreamReference, Windows.Storage, ContentType=WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]
  $null = [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType=WindowsRuntime]

  $random = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
  $writer = [Windows.Storage.Streams.DataWriter]::new($random)
  $null = $writer.WriteBytes($stream.ToArray())
  $null = (Await-WinRt ($writer.StoreAsync()) ([UInt32]))
  $null = $writer.DetachStream()
  $null = $random.Seek(0)

  $decoder = Await-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($random)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $software = Await-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $language = [Windows.Globalization.Language]::new($LanguageTag)
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
  if ($null -eq $engine) { return '' }

  $result = Await-WinRt ($engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])
  return (($result.Lines | ForEach-Object { $_.Text }) -join ' ')
}

# The result of a call of Windows that is asynchronous.
#
# The OCR engine of Windows is a WinRT API, and its calls return a task that has to be waited
# for before the result can be read.
#
# @param Task the task the call returned
# @param ResultType the type of the result
# @return [object] the result of the call
function Await-WinRt($Task, $ResultType) {
  $method = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
              Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
              })[0]
  $netTask = $method.MakeGenericMethod($ResultType).Invoke($null, @($Task))
  $netTask.Wait(-1) | Out-Null
  return $netTask.Result
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

# The update that is waiting to be installed.
#
# Live fetches the update of its own version while it runs, and installs it when it exits.
# Only the current version of Live has updates: the updater of an old version has nothing to
# offer. The version of the update is announced in the log, and the version that is running is
# in the log as well, so an update that is still waiting is told apart from an update that has
# been installed.
#
# @param LogText the text of the log
# @return [string] the version of the update that is waiting, or an empty string when there is
#   no update waiting
function Get-PendingUpdate([string]$LogText) {
  $announcements = [regex]::Matches($LogText, 'auto-update available: ([0-9.]+)')
  if ($announcements.Count -eq 0) { return '' }

  $update = $announcements[$announcements.Count - 1].Groups[1].Value

  $running = [regex]::Match($LogText, 'Init: Version: ''Live ([0-9.]+)')
  if (-not $running.Success) { $running = [regex]::Match($LogText, 'Started: Live ([0-9.]+)') }
  if ($running.Success -and $running.Groups[1].Value -eq $update) { return '' }

  return $update
}

# The programs to stop besides the tree of Live.
#
# The installer helper of Ableton is not a child of Live, so it is not in the tree of Live,
# and the tree cannot be used to find it. It takes the machine over while it runs, so it is
# closed and stopped with the tree.
#
# @return [array] the ids of the programs
function Get-ExtraProcessIds {
  return @(Get-InstallHelpers | ForEach-Object { $_.Id })
}

# The paths the set that was saved may have been written to.
#
# Live writes a set as a project folder, so the set is looked for in the folder as well.
#
# @param Path the path of the set to write
# @return [Array] the paths the set may have been written to
function Get-SaveCandidatePaths([string]$Path) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $directory = [System.IO.Path]::GetDirectoryName($Path)
  $typed = [System.IO.Path]::Combine($directory, $name)
  return @(
    $Path,
    ($typed + '.als'),
    [System.IO.Path]::Combine($directory, ($name + ' Project'), ($name + '.als'))
  )
}

# The dialogs of Live, and the action that answers them.
#
# @param Text the text of the dialog
# @return [object] the family of the dialog, the action, and the way the action is done
function Get-DialogInfo([string]$Text) {
  if (-not $Text) { return (Get-DialogInfo-Generic $Text) }

  $normalized = $Text.Trim()
  if ($normalized -match 'InstallHelper|installing packages') {
    return [pscustomobject]@{ Type = 'updater'; Action = $null; ActionType = $null; ActionValue = $null }
  }
  if ($normalized -match 'Live will shut down after this message box is closed\.') {
    return [pscustomobject]@{ Type = 'fatal'; Action = 'OK'; ActionType = 'button'; ActionValue = 'OK' }
  }
  if ($normalized -match 'Live unexpectedly quit while you were working on the Live Set') {
    return [pscustomobject]@{ Type = 'recovery'; Action = 'No'; ActionType = 'button'; ActionValue = 'No' }
  }

  return (Get-DialogInfo-Generic $Text)
}

# A Live that is still running from an earlier run is closed before this run starts.
#
# It is closed, and not killed: a Live that is killed while it checks for package installation
# checks again on the next start, and puts up the installer of Ableton. The installer takes the
# machine over while it runs, so a Live that is left half way through its start is a problem
# that comes back on every run.
#
# @param Context the run that is starting
# @return [void]
function Close-RunningLive($Context) {
  $running = @(Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue)
  if ($running.Count -eq 0) { return }

  $pids = @($running | ForEach-Object { $_.Id })
  Debug-Log "closing Live that is still running (pids: $($pids -join ','))"
  Close-VisibleWindowsForPids $pids

  $deadline = (Get-Date).AddSeconds(5)
  while ((Get-Date) -lt $deadline) {
    $messages = [regex]::Matches((Read-Log $Context.Log $Context.LogStart), 'Message Box: (.*)')
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].Groups[1].Value -match 'Save changes') {
      [void](Send-KeyToWindows $pids 'n')
    }
    $remaining = @(Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { return }
    Start-Sleep -Milliseconds 200
  }

  Get-Process -Name 'Ableton Live*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# What the run does before Live is started.
#
# @param Context the run that is starting
# @return [void]
function Invoke-PreRunCleanup($Context) {
  Close-RunningLive $Context
  Clear-RecoveryPoint $Context
  Cleanup-Notepad
}

# Live's pending recovery point.
#
# Live writes a recovery point when it is killed, and it holds the point in its Preferences
# folder, next to its log. The point is what drives the recovery prompt of the next launch:
# Live finds it, asks whether to recover the work, and holds the document back until the
# question is answered.
#
# The point is the evidence that the last session of Live ended badly. A Live that was closed
# leaves no point behind.
#
# @param Context the run
# @return [string] the path of the file of the recovery point, or an empty string when there
#   is no recovery point
function Get-RecoveryPoint($Context) {
  if (-not $Context.Log) { return '' }

  $folder = Split-Path -Parent $Context.Log
  if (-not $folder) { return '' }

  $path = Join-Path $folder 'CrashRecoveryInfo.cfg'
  if (-not (Test-Path $path)) { return '' }
  return $path
}

# Clears Live's pending recovery point.
#
# The point is moved into the folder where Live keeps the ones that have been answered, and
# it is named the way Live names them, so that the next launch of Live does not ask to
# recover the work of a session that was killed. The evidence of what crashed is kept, where
# Live keeps it.
#
# @param Context the run
# @return [void]
function Clear-RecoveryPoint($Context) {
  $path = Get-RecoveryPoint $Context
  if (-not $path) { return }

  $folder = Split-Path -Parent $path
  $archive = Join-Path $folder 'Crash'
  if (-not (Test-Path $archive)) { $null = New-Item -ItemType Directory -Path $archive }

  $stamp = (Get-Item $path).LastWriteTime.ToString('yyyy_MM_dd__HH_mm_ss')
  foreach ($name in @('CrashRecoveryInfo.cfg', 'BaseFiles', 'Undo')) {
    $from = Join-Path $folder $name
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $archive ($stamp + '_' + $name)
    Move-Item -Path $from -Destination $to -Force -ErrorAction SilentlyContinue
  }
  Debug-Log "the recovery point of the session that was killed was moved to $archive"
}

# What the run knows about Live, from Live's log.
#
# Live is a Qt application and exposes no names for its windows, so its log is where its
# dialogs are read from.
#
# @param State the state of the run
# @param Context the run
# @return [void]
function Update-RunState-Live($State, $Context) {
  # The installer helper of Ableton blocks the machine while it runs, and Live waits for it,
  # so the set is never loaded while the helper is up. The helper is given ten seconds to do
  # its work, and is dismissed after that, so that the screen of the machine is free again.
  $helpers = @(Get-InstallHelpers)
  if ($helpers.Count -gt 0) {
    $state.Updater = $true
    foreach ($helper in $helpers) { $Context.ExtraPids += $helper.Id }
    if ($null -eq $State.HelperSeenAt) { $State.HelperSeenAt = Get-Date }
    $helperPids = @($helpers | ForEach-Object { $_.Id })
    $waiting = ((Get-Date) - $State.HelperSeenAt).TotalSeconds
    Debug-Log "InstallHelper is running (pids: $($helperPids -join ',')); waiting ${waiting}s"
    if ($waiting -ge 10) {
      Debug-Log 'dismissing InstallHelper'
      foreach ($helper in $helpers) {
        # The helper is not a Qt window, so a posted key does not reach it: the escape is
        # typed to the window that has the focus.
        [void](Send-DismissKey $helper.Id '{ESC}')
        foreach ($window in Get-Windows $helper.Id) {
          [void][GuiHarness]::PostMessage($window.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
      }
      # Live gets the time it needs to load the set, now that the machine is free again.
      $Context.Deadline = $Context.Deadline.AddSeconds($waiting)
      $State.HelperSeenAt = $null
    }
  } else {
    $State.HelperSeenAt = $null
  }

  $text = Read-Log $Context.Log $Context.LogStart

  # Live says in its log when it checks for packages, which it does on every start. The
  # check itself is not the updater: the updater is the helper that does the installing, and
  # the helper is a process of its own.
  if ($text -match 'Check for package installation') {
    Debug-Log 'Live is checking for package installation'
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
      if ($State.RecoveryAttempt -lt $State.RecoveryKeys.Count) {
        $key = $State.RecoveryKeys[$State.RecoveryAttempt]
        $State.RecoveryAttempt++
        $State.RecoveryKeySentAt = Get-Date
        Debug-Log "dismissing the recovery prompt with $key"
        [void](Send-KeyToWindows $Context.ProcessIds $key)
      } elseif ($null -ne $State.RecoveryKeySentAt -and
              ((Get-Date) - $State.RecoveryKeySentAt).TotalSeconds -ge 1) {
        # The prompt did not go away. It is the window that has the focus that is dismissed,
        # so the app is brought to the foreground and the key is sent to it.
        $State.RecoveryKeySentAt = Get-Date
        Debug-Log 'dismissing the recovery prompt with the foreground'
        [void](Send-DismissKey $Context.Process.Id 'n')
      }
    } elseif ($message -ne $State.LastMessage) {
      $State.LastMessage = $message
      if ($message -match 'serious program error|fatal error|shut down after this message box') {
        $State.Dialog = $message
        $State.Crashed = $true
      } else {
        # A message box that is not fatal is dismissed, so that the set can still be loaded.
        # Live puts up a box of its own when a plugin cannot be loaded, and that box holds
        # the set back as long as it is there.
        $State.Dismissed += $message
        Debug-Log "dismissing the message box: $message"
        [void](Send-KeyToWindows $Context.ProcessIds 'esc')
      }
    }
  }
  if ($text -match 'Begin ExchangeDocument') { $State.Recovered = $true }
  if ($text -match 'Exception: Fatal Error') { $State.Crashed = $true }

  # Live draws its own windows, so the tree does not say what a dialog says. When the log is
  # silent about a dialog, the pixels are the only place its text is, so the text is read from
  # them. The OCR reads a dialog well enough to tell it from another dialog and not well
  # enough to be a transcription of it, so a reading that no rule knows is not reported.
  if (-not $State.Dialog) {
    $popup = Get-DialogWindow $Context
    if ($null -ne $popup -and -not $State.ReadWindows.ContainsKey($popup.Handle)) {
      $State.ReadWindows[$popup.Handle] = $true
      $shown = Get-WindowText $popup.Handle
      if ($shown) {
        $dialogInfo = Get-DialogInfo $shown
        if ($dialogInfo.Type -ne 'unknown') {
          Debug-Log "the dialog says: $shown"
          $State.Dialog = $shown
          if ($dialogInfo.Type -eq 'fatal') { $State.Crashed = $true }
        }
      }
    }
  }

  # Live says that it has loaded the document it was given even when the document could not
  # be loaded, so the failure is looked for first. A set that is not loaded is not saved.
  $failure = [regex]::Match($text, 'Failed to load command-line document: (.*)')
  if ($failure.Success) {
    $State.Dialog = $failure.Groups[1].Value.Trim()
    Debug-Log "the document was not loaded: $State.Dialog"
    $State.Done = $true
    return
  }

  # The set is loaded when Live says that it has loaded the document it was given. Live says
  # it twice over: once for the document of the start, and once for the document of the
  # command line. The last one is the set that was asked for.
  #
  # The log is what says when the set is loaded, so a set that takes a long time to load is
  # waited for as long as it takes, and a set that loads quickly is not waited for at all.
  if ($text -match 'Loading command-line document: done\.') {
    $State.Loaded = $true
    if ($Context.SaveInPlace) {
      Debug-Log "the set will be saved when Live is closed: $Context.Set"
    } elseif ($Context.SavePath -and -not $Context.Saved) {
      Debug-Log "saving the set to $Context.SavePath"
      $Context.Saved = Save-Document $Context $Context.SavePath
      Debug-Log "saved: $Context.Saved"
    }
    $State.Done = $true
  }
}

# What the run knows about Live.
#
# @param State the state of the run
# @param Context the run
# @return [void]
function Update-RunState($State, $Context) {
  Update-RunState-MessageDialogs $State $Context
  Update-RunState-Live $State $Context
  if ($State.Done) { return }
  Update-RunState-Windows $State $Context
}

# The dialog that is reported when nothing else holds Live up.
#
# @param State the state of the run
# @return [string] the text of the dialog, or $null when there is none
function Get-BlockedDialog($State) {
  if ($State.Updater -and -not $State.Dialog) {
    return 'Live is installing packages: the installer takes over the machine and Live waits for it'
  }
  return (Get-BlockedDialog-Generic $State)
}

# Whether the ladder has nothing left to climb.
#
# Live's clean exit is settled from Live's log, so the ladder does not stop until the rung
# that reads the log has been climbed.
#
# @param Context the run
# @return [bool] whether the ladder is done
function Test-LadderComplete($Context) {
  return ((Test-LadderComplete-Generic $Context) -and $Context.CleanExitConfirmed)
}

# The rung that answers Live's "Save changes?".
#
# Live asks whether to save the set when it is closed. The set is a test, so the answer is
# no, unless the caller asked for the set to be saved. Live that is closed this way leaves no
# crash recovery state behind, and the next run starts without a recovery prompt.
#
# @param Context the run
# @return [bool] whether the ladder may stop
function answer_save_prompt($Context) {
  $deadline = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $deadline) {
    if (Test-ApplicationGone $Context) { return $false }

    $messages = [regex]::Matches((Read-Log $Context.Log $Context.LogStart), 'Message Box: (.*)')
    if ($messages.Count -gt 0 -and $messages[$messages.Count - 1].Groups[1].Value -match 'Save changes') {
      $key = if ($Context.SaveInPlace) { 'y' } else { 'n' }
      Debug-Log "answering the save prompt with $key"
      [void](Send-KeyToWindows @(Get-ProcessTreeIds @($Context.Process.Id)) $key)
    }
    Start-Sleep -Milliseconds 200
  }
  return $false
}

# The rung that confirms that Live quit normally.
#
# Live says in its log that it quit normally, and its log is the only place where that is
# said.
#
# @param Context the run
# @return [bool] whether the ladder may stop
function confirm_clean_exit($Context) {
  $text = Read-Log $Context.Log $Context.LogStart
  if ($text -match 'GlobalExit\(\): End') {
    Debug-Log 'Live says that it quit normally'
    $Context.ExitedCleanly = $true
  }
  $Context.CleanExitConfirmed = $true
  return $true
}
