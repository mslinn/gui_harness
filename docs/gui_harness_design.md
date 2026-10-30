# GUI Harness Design

The generic harness is responsible for real GUI execution, not for the details of one file format.

The harness is in two layers. The generic layer drives any GUI program on Windows. The Ableton
Live layer adds what is particular to Live: Live's own log, Live's invisible dialogs, Live's
installer prompt, and the way Live is shut down. The layers are separate directories in the source
tree, so that the generic capability and the Live specialization can be read apart.

## The layers

| | generic | live |
|---|---|---|
| Ruby | `lib/gui_harness/generic/` | `lib/gui_harness/live/` |
| PowerShell | `assets/generic/` | `assets/live/` |
| dialog rules | fatal program error, file not found, save changes | recovery prompt, updater, Live's wording |
| run state | the modal dialogs of the windows of the process | Live's log: loaded, crashed, updater, pending update |
| shutdown ladder | `close_windows`, `wait_for_exit`, `stop_tree` | `answer_save_prompt`, `confirm_clean_exit` |

The generic layer stands on its own: it launches a program, watches its windows, classifies what it
sees, and shuts the program down. The Live layer is the generic layer with the knowledge of Live
put in.

Live registers the file types of its sets when it starts, and that registration asks for the
permission of an administrator with a prompt on the secure desktop. The prompt is per version of
Live: the first time a version runs it asks, and running it again does not ask, provided the user
accepted the first time. The Live layer does not start Live while a prompt is waiting, and
reports the run as blocked by the installer rather than as a set that was loaded.

Live writes a recovery point when it is killed, and holds the point in its Preferences folder,
next to its log. The point is what drives the recovery prompt of the next launch, and Live holds
the document back until the question is answered. The Live layer clears the point before it
starts Live, by moving it into the folder where Live keeps the ones that have been answered, so
that a run starts without a recovery prompt. The point is also the evidence that the last
session of Live ended badly: a Live that was closed leaves no point behind.

### The files of a layer

Each layer has a library of functions and an entry point that holds the parameters of the run.

```text
assets/generic/gui_harness_generic.ps1   # the generic library: primitives, generic seams, generic rungs
assets/generic/run.ps1                    # the generic entry point: the parameters, and the run
assets/live/gui_harness_live.ps1          # the Live library: loads the generic one, Live seams and rungs
assets/live/run.ps1                       # the Live entry point: the parameters, and the run
```

```text
lib/gui_harness/generic/launcher.rb       # the launch, the parse, and the result
lib/gui_harness/generic/shutdown.rb       # the generic ladder
lib/gui_harness/generic/dialog.rb         # the generic dialog rules
lib/gui_harness/generic/result.rb         # the result model
lib/gui_harness/generic/windows.rb        # the Windows machine, as WSL sees it
lib/gui_harness/live/launcher.rb          # the Live run, and the Live result bits
lib/gui_harness/live/shutdown.rb          # the Live ladder
lib/gui_harness/live/dialog.rb            # the Live dialog rules
```

The launcher writes the assets of its layer down to the Windows temporary directory, keeping the
layout, so that the Live library can find the generic library it loads.

## Core requirement

The harness must do the following:

1. Launch the target GUI process.
2. Retain the process identity.
3. Enumerate the top-level windows that belong to that process.
4. Walk the UIAutomation tree.
5. Read the text exposed to the user.
6. Match the text to a known dialog family.
7. Perform the correct dismissal action.
8. Return a structured outcome.

Log parsing is a secondary check. The process-owned window probe is the primary source of truth.

The exception is Live, which is a Qt application and exposes no names for its windows. The dialogs
of Live are read from Live's own log, because that is the only place where their text is.

## Reading the dialogs of Live

That exception is a measured fact, not an assumption. Live draws its own windows: the window
class is `Ableton Live Window Class` and not `#32770`, so a dialog of Live is not a Windows
dialog, and the window has no children of its own. Nothing that is asked of the window describes
it:

| what is asked of the window | what comes back |
|---|---|
| `GetWindowText` | the empty string |
| `EnumChildWindows` | no children |
| UI Automation, control view | no name, no descendants, not modal |
| UI Automation, raw view | no children |
| MSAA `IAccessible`, `OBJID_WINDOW` and `OBJID_CLIENT` | no name, no children |

The pixels are the one place the text survives. `PrintWindow` with `PW_RENDERFULLCONTENT`
captures the window, and the built-in Windows OCR engine (`Windows.Media.Ocr`) reads the capture.
On Live's main window the OCR reads the title, the menu bar and the mixer labels correctly; on a
dialog it reads most of the text, and it drops the words in the middle of a line. The log is
therefore still the source of truth, and OCR is how a dialog of Live is *seen*.

The Live layer has the capture, in `Get-WindowText`, and it uses it when the log is silent about
a dialog: a dialog that Live draws and does not describe is read from its pixels, and it is
reported when the reading matches a rule the layer knows. A reading that no rule knows is not
reported, because the OCR of a small window is a reading of the text and not a transcription of
it.

The practical notes for a capture are these:

- `PW_RENDERFULLCONTENT` (0x2) is needed. A plain `PrintWindow` often returns a blank or a
  partial image.
- A dialog of Live is small, and the OCR has few pixels to work with. Capturing it larger, or
  upscaling the capture, recovers more of the text.
- The process that captures the window has to be at the same integrity level as the application,
  or the capture fails silently.
- `Windows.Media.Ocr` needs the language pack of the language of the dialog.
- Tesseract reads the same capture and is more accurate on some fonts, at the price of another
  dependency.

## Contract

The harness should report:

- `exit_code`
- `output`
- `dialog`
- `dialog_type`
- `dismiss_action`
- `log`
- `loaded`
- `crashed`
- `saved`
- `saved_path`
- `updater`
- `exited_cleanly`
- `messages`

The high-level outcome should be one of:

- `:loaded`
- `:crashed`
- `:blocked`
- `:unknown`

What an outcome means belongs to the layer that defines it. The generic layer reports `:loaded`
for a program that ran and that nothing blocked: a program of any kind can be run, and nothing
about the run says more than that. The Live layer reports `:loaded` only when Live loaded the
document it was given, because Live says so in its log, and a run in which it did not is a run
that loaded nothing. Live quits at once when it is handed a file that does not exist, and it
logs nothing about the failure, so there is no dialog to report either; the outcome is what says
the run came to nothing.

## Dialog families

The recognized families include:

- `:fatal`
- `:recovery`
- `:save_changes`
- `:updater`
- `:error`
- `:unknown`

The harness should also record the associated dismissal action for each family, such as clicking `OK` or `No`.

## The seams

The generic layer holds the algorithms. The Live layer holds the knowledge of Live. The two meet
at a small number of seams, which the generic layer defines and the Live layer overrides.

PowerShell resolves a command name when it is called, so a seam that is called by name from generic
code is the Live definition once the Live layer is loaded. A seam that is captured in a variable
when the layers are loaded stays the generic one, and every seam is therefore called by name.

| seam | generic | live |
|---|---|---|
| `Get-DialogInfo` | fatal / file-not-found / save-changes / recover-work | updater, "Live will shut down…", "Live unexpectedly quit…" |
| `Update-RunState` | the modal dialogs of the windows of the process tree | Live's log, the recovery prompt, the install helper |
| `Get-PermissionPrompts` | none | the prompts of the installer of Ableton |
| `Test-WaitsForPermission` | never | Live waits for the installer of Ableton |
| `Get-PendingUpdate` | none | the update of Live that is waiting to be installed |
| `Invoke-PreRunCleanup` | nothing | close a Live that is still running |
| `Get-SaveCandidatePaths` | the path and the path without its extension | the path, the path with `.als`, and the project folder of Live |
| `Get-BlockedDialog` | the dialog that was found | Live's wording for the dialog of the installer |
| `Get-ExtraProcessIds` | none | the installer helper of Ableton, which is not in the tree of Live |

A seam that is not called by name is not a seam: PowerShell has to resolve the command name when
it is called, and a seam that was captured in a variable when the layers were loaded keeps the
generic behaviour.

## The rules of the layers

Three rules keep the two layers apart, and each of them exists because of the way PowerShell loads
a script.

- **The libraries have no parameters.** A dot-sourced script assigns its parameters *in the caller's
  scope*. A generic library that declared `$Exe`, `$Set`, `$Log` or `$Visibility` would therefore
  reset the values of the run that dot-sourced it, and the run would quietly lose its arguments.
  The entry point of a layer holds the parameters and reads them after its library is loaded.
- **The Live library dot-sources the generic library, and redefines the seams after it.**
- **A seam is called by name.** A seam captured in a variable when the layers are loaded keeps the
  generic behaviour, and the Live layer would never be seen.

## The shutdown ladder

An application is shut down in rungs, and each layer has its own ladder. Ruby holds the order of
the rungs, and PowerShell holds what each rung does.

The launcher hands the rungs of its layer to the sidecar, and the sidecar climbs exactly those. A
rung the layer does not have is not climbed: the order of the rungs belongs to the layer that
asked for the run, and the mechanics of a rung belong to the layer that has it.

The generic ladder:

1. `close_windows` — ask the application to close, the way a person closes it.
2. `wait_for_exit` — wait for the process tree to go away by itself.
3. `stop_tree` — stop what is left, as the last resort.

The Live ladder:

1. `close_windows`
2. `answer_save_prompt` — answer Live's "Save changes?" from Live's log: `No`, or `Yes` when the
   set is to be saved in place.
3. `wait_for_exit`
4. `confirm_clean_exit` — Live's log says `GlobalExit(): End` when Live quit normally.
5. `stop_tree`

An application that is stopped instead of closing leaves a crash report behind and asks to recover
its work on the next start. A clean exit is therefore the difference between a harness run that
leaves nothing behind and one that does, and `exited_cleanly` says which kind of run it was.

## Design principles

- No simulations, stubs, or mocks.
- Real GUI process inspection is required.
- Log files are useful evidence but never the primary truth.
- The harness is reusable across GUI tools, not only a single product.
- The generic layer knows nothing of any one program.

## Typical workflow

1. Launch the app under test.
2. Wait for the UI to settle.
3. Enumerate windows owned by the new process.
4. Inspect visible top-level dialogs.
5. Read text from the UI tree.
6. Classify the dialog family.
7. Dismiss it.
8. Climb the shutdown ladder.
9. Return a structured result for the calling test suite.

## The plan of the work

The two layers are described in [relayer_plan.md](relayer_plan.md), which is the plan of the work
that puts this design in place.
