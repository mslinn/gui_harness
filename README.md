# gui_harness [![Gem Version](https://badge.fury.io/rb/gui_harness.svg)](https://badge.fury.io/rb/gui_harness)

A Ruby harness for real GUI automation and end-to-end compatibility testing.

## Purpose

`gui_harness` is a small library for driving real desktop applications the way a user does: launch the actual process, inspect the windows it owns, read the visible dialog text, classify the modal state, dismiss the blocking prompt, and return a structured result for tests.

This project is intentionally not a log-only parser. The process-owned window probe is the source of truth for the dialogs of the applications that expose their windows; the dialogs of Live are read from Live's own log, because Live is a Qt application and exposes no names for its windows. The harness treats the UI as the contract, and says so where the UI says nothing.

The harness is designed for the real WSL-to-Windows workflow: Ruby runs in WSL, then the target GUI is launched by PowerShell on Windows. The launcher script is treated as a deployed runtime asset, not as Ruby source code.

## Project layout

- `lib/` contains the Ruby API and domain logic, in a directory per layer
- `assets/` contains runtime assets that are deployed with the gem, including the Windows
  PowerShell sidecar, in a directory per layer
- `spec/` contains end-to-end, real-GUI regression tests, in a directory per layer
- `docs/` contains the design of the harness and the plan of the work
- `.vscode/launch.json` contains editor launch entries for the real harness flow

## The two layers

The harness is in two layers: a generic capability, and an Ableton Live specialization.

The generic layer drives any GUI program on Windows. It launches the program, enumerates the
windows the program owns, walks the accessibility tree for a visible modal, reads the text the
dialog exposes, classifies it, dismisses it, and shuts the program down. It knows nothing of any
one program.

The Live layer adds what is particular to Live: Live's own log is where its dialogs are read,
because Live is a Qt application and exposes no names for its windows; Live's recovery prompt and
its installer prompt are handled there; and Live's way of being closed — answering "Save changes?"
and confirming the clean exit from Live's log — is there too.

The layers are separate directories, so that the two can be read apart:

| | generic | live |
|---|---|---|
| Ruby | `lib/gui_harness/generic/` | `lib/gui_harness/live/` |
| PowerShell | `assets/generic/` | `assets/live/` |

Each layer has a library of functions and an entry point that holds the parameters of the run:
`assets/generic/gui_harness_generic.ps1` and `assets/generic/run.ps1`, and
`assets/live/gui_harness_live.ps1` and `assets/live/run.ps1`. The Live library loads the generic
library and redefines the seams between them.

The design is in [docs/gui_harness_design.md](docs/gui_harness_design.md), and the plan of the work
that puts it in place is in [docs/relayer_plan.md](docs/relayer_plan.md).

## Core behavior

The harness is designed to do the following:

- launch a GUI executable
- retain the process identity
- enumerate the top-level windows owned by that process
- walk the accessibility tree for a visible modal
- read text exposed by the dialog
- map the text to a known class of dialog
- trigger the correct dismissal action
- return a machine-readable outcome for the test harness

## Design principles

- no stubs, mocks, or simulations
- prefer actual GUI state over synthetic parser assumptions
- retain a simple result model for tests
- classify dialogs by visible text and expected user action
- keep the implementation reusable across desktop apps

## API

The main entry point is `GuiHarness::Live::Launcher`. The generic layer is
`GuiHarness::Generic::Launcher`, and it drives any GUI program on Windows.

```ruby
require 'gui_harness'

result = GuiHarness::Live::Launcher.launch(
  'C:/Program Files/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe',
  'C:/path/to/test.als',
  timeout: 13
)

puts result.exit_code
puts result.dialog
puts result.dialog_type
puts result.dismiss_action
puts result.outcome
puts result.exited_cleanly
puts result.messages
```

### `classify_dialog`

The library can also classify a dialog text string directly:

```ruby
GuiHarness::Live::Launcher.classify_dialog('A serious program error has occurred.')
# => { type: :fatal, action: { type: "button", value: "OK" } }

GuiHarness::Live::Launcher.classify_dialog('Save changes?')
# => { type: :save_changes, action: { type: "button", value: "No" } }

GuiHarness::Live::Launcher.classify_dialog("Cannot find the file 'missing.als'. Make sure the path and file name are correct.")
# => { type: :error, action: { type: "button", value: "OK" } }
```

## Result model

The launch result is a Ruby `Struct` with the following fields:

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

It also exposes a derived `outcome` method:

- `:loaded`
- `:crashed`
- `:blocked`
- `:unknown`

What an outcome means belongs to the layer that defines it. The generic layer reports `:loaded`
for a program that ran and that nothing blocked. The Live layer reports `:loaded` only when Live
loaded the document it was given, because Live says so in its log; a run in which it did not is
reported as `:unknown`. Live quits at once when it is handed a file that does not exist, and it
logs nothing about the failure, so there is no dialog to report either.

This keeps a real GUI run easy to assert in Ruby specs without exposing raw UIAutomation internals.

## How the application is closed

An application is shut down in rungs, and each layer has its own ladder. Ruby holds the order of
the rungs, and PowerShell holds what each rung does: the launcher hands the rungs of its layer to
the sidecar, and the sidecar climbs exactly those.

The generic ladder:

1. `close_windows` — ask the application to close, the way a person closes it.
2. `wait_for_exit` — wait for the process tree to go away by itself.
3. `stop_tree` — stop what is left, as the last resort.

The Live ladder:

1. `close_windows`
2. `answer_save_prompt` — answer Live's "Save changes?" from Live's log: `No`, or `Yes` when the
   set is to be saved in place.
3. `wait_for_exit`
4. `confirm_clean_exit` — Live's log says it quit normally.
5. `stop_tree`

The generic layer waits five seconds for the application to go away. An application that is gone
by itself has exited cleanly, and `exited_cleanly` is true.

An application that has not gone away is stopped, and `exited_cleanly` is false. A stop is abrupt:
the application does not get to write its state down, so it may leave a crash report behind and
ask to recover its work on the next start. A clean exit is therefore the difference between a
harness run that leaves nothing behind and one that does.

## When an update is waiting

An application that fetches an update of its own version while it runs installs that update when
it exits. Only the current version of Live has updates: the updater of an older version has
nothing to offer.

The harness reads the log of the application and reports the update that is waiting, so that the
change to the machine is not a surprise:

```ruby
result.messages
# => ['Live 12.4.6 will install update 12.4.7 automatically when it exits.']
```

The message is empty when there is no update, and when the version that is running is the version
that has already been installed.

## When the set is loaded

The harness does not wait for a fixed time and hope. Live writes to its log when it has loaded the
document it was given, and the harness waits for that line: `Loading command-line document: done.`
A set that takes a long time to load is waited for as long as it takes, and a set that loads
quickly is not waited for at all. Live writes that line even when the document could not be
loaded, so the harness also looks for `Failed to load command-line document`, and a set that was
not loaded is never reported as loaded.

## Reading the dialogs of Live

Live draws its own windows, and nothing in the window tree describes them: the window class is
Live's own rather than the standard `#32770`, the windows have no children, and UI Automation
(the control view and the raw view), MSAA and `GetWindowText` all come back empty.

The text of a dialog of Live is therefore in two places, and only two: Live's own log, and the
pixels. The harness reads the log, because the log is exact. The pixels are how a dialog of Live
is *seen*: `PrintWindow` with `PW_RENDERFULLCONTENT` captures the window, and the built-in
Windows OCR engine reads the capture. On Live's main window that reads the title, the menu bar
and the mixer labels correctly; on a dialog it reads most of the text and drops the words in the
middle of a line.

The Live layer reads the pixels when the log is silent about a dialog, so a dialog that Live
draws and does not describe is still seen.

## When Live was killed

Live writes a recovery point when it is killed, and holds it in its Preferences folder, next to
its log. The point is what makes the next launch of Live ask whether to recover the work, and
Live holds the document back until the question is answered.

Before it starts Live, the Live layer clears the point: it moves it into the folder where Live
keeps the ones that have been answered, named the way Live names them. A run therefore starts
without a recovery prompt, and the evidence of what crashed is kept where Live keeps it.

## When Live waits for permission

Live's installer asks for permission before it registers the file types of Live, and the prompt
is on the secure desktop, where no program of the session can reach it. Live waits for that
permission, and the set is not loaded until it is given. The harness cannot answer the prompt,
so it reports the run as blocked by the installer rather than as a set that was loaded.

The prompts are not allowed to pile up. Live is not started at all while a prompt of the
installer is waiting, so a run never leaves another prompt behind. When the prompt appears
while Live is running, the run waits for the answer for a while, and the user who answers it
finishes the registration of the file types, after which Live does not ask for permission again.

The prompt is per version of Live, not per machine. The first time a version runs it asks, and
switching to another version asks again for that version. Running a version again does not ask,
provided the user accepted the first time. A version that has been authorized starts straight
away, so a run against it is not held up at the start.

The command line that the harness gives to Live is the path of the program and the path of the
set. There are no other arguments.

## Real-world usage

The harness is intended for round-trip and compatibility testing against real apps. A typical scenario is to launch a real desktop app with a real `.als` file, let it show a modal, classify the dialog, dismiss it, and then assert on the final state.

The project includes two live Notepad regression paths:

- error path: launch Notepad with a missing file and assert that the real `Cannot find the file ...` dialog is detected and dismissed
- success path: launch Notepad with a valid file and assert that there is no dialog, the run reports success, and the app exits cleanly without leaving a process behind

This is exactly the kind of real-world modal handling the harness is meant to observe and report.

## PowerShell/Windows integration

The Ruby class delegates actual window inspection to a PowerShell script in `assets/`. The script enumerates the real Windows UI, walks the automation tree, reads dialog text, and returns the observed information in a format that Ruby can parse.

This separation keeps Ruby as the test-facing layer while leaving the actual OS-specific automation in the deployment asset that ships with the gem.

## VS Code workflow

This project includes a small VS Code launch setup for running the real-GUI specs directly from the editor.

### Launch configurations

From the Run and Debug panel, use one of these entries:

- `RSpec: all specs` — runs the whole suite
- `RSpec: current file` — runs the active spec file
- `Ruby: quick Notepad probe` — runs the direct WSL-to-Windows dialog probe used during harness debugging

The harness is meant to run from WSL while the app itself is launched on Windows via PowerShell. That is the supported environment for the real GUI tests.

## Development

The project is meant to be developed and debugged from WSL, while the GUI itself is launched on Windows. This is intentional and is part of the contract: the harness is a real native-GUI automation layer, not a mocked or local-only emulator.

Install dependencies:

```bash
bundle install
```

Run the test suite:

```bash
bundle exec rspec
```

Run the focused GUI harness spec:

```bash
bundle exec rspec spec/gui_harness/generic/launcher_spec.rb spec/gui_harness/live/launcher_spec.rb --format documentation
```

## Testing philosophy

This library is not a mock-based parser. It is built to validate real desktop behavior, real dialogs, and real app states. When the harness says a dialog is fatal, recovery, save-related, or an ordinary file error, it is because the real Windows UI exposed that text and the harness classified it as such.

That is what makes it useful for debugging actual compatibility paths and crash-recovery flows.
