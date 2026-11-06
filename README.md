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

The harness is in two layers: a generic capability, and an Ableton Live
specialization.

The generic layer drives any GUI program on Windows. It launches the program,
enumerates the windows the program owns, walks the accessibility tree for a
visible modal, reads the text the dialog exposes, classifies it, dismisses it,
and shuts the program down. It knows nothing of any one program.

The Live layer adds what is particular to Live: Live's own log is where its
dialogs are read, because Live is a Qt application and exposes no names for its
windows; Live's recovery prompt and its installer prompt are handled there; and
Live's way of being closed — answering "Save changes?" and confirming the clean
exit from Live's log — is there too.

The layers are separate directories, so that the two can be read apart:

| Language   | Generic Layer              | Ableton Live Layer      |
|------------|----------------------------|-------------------------|
| Ruby       | `lib/gui_harness/generic/` | `lib/gui_harness/live/` |
| PowerShell | `assets/generic/`          | `assets/live/`          |

Each layer has a library of functions and an entry point that holds the
parameters of the run: `assets/generic/gui_harness_generic.ps1` and
`assets/generic/run.ps1`, and `assets/live/gui_harness_live.ps1` and
`assets/live/run.ps1`. The Live library loads the generic library and redefines
the seams between them.

The design is in [docs/gui_harness_design.md](docs/gui_harness_design.md), and
the implementation plan is in
[docs/relayer_plan.md](docs/relayer_plan.md).


## Generic Layer

The generic layer is responsible for the following:

- launch a GUI executable
- retain the process identity
- enumerate the top-level windows owned by that process
- walk the accessibility tree for a visible modal
- read text exposed by the dialog
- map the text to a known class of dialog
- trigger the correct dismissal action
- return a machine-readable outcome for the test harness

## Live Layer

The Ableton Live layer enhances and modifies the generic layer to support
running Ableton Live in a harness:

- Saves any pre-existing `Options.txt`, then recreates it for each run. The
  saved copy is restored to its previous state after each run. See
  `$live_set/docs/als_work.md` for more information.

TODO document the other high-level responsibilities currently implemented by the Live layer.


## Generic Design Principles

- Classify dialogs by visible text and expected user action
- Prefer actual GUI state over synthetic parser assumptions
- Examine STDOUT and STDERR output to help determine state
- Keep the implementation reusable across desktop apps

## Additional Principles for Ableton Live

- Examine associated files to determine state


## Testing

- No stubs, mocks, or simulations
- Retain a simple result model for tests

## API

The entry point for the generic layer is `GuiHarness::Generic::Launcher`; it
drives simple GUI programs on Windows such as Notepad.  The entry point for
Ableton Live is `GuiHarness::Live::Launcher`.

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

The library can classify a dialog text string directly:

```ruby
GuiHarness::Live::Launcher.classify_dialog('A serious program error has occurred.')
# => { type: :fatal, action: { type: "button", value: "OK" } }

GuiHarness::Live::Launcher.classify_dialog('Save changes?')
# => { type: :save_changes, action: { type: "button", value: "No" } }

GuiHarness::Live::Launcher.classify_dialog("Cannot find the file 'missing.als'. Make sure the path and file name are correct.")
# => { type: :error, action: { type: "button", value: "OK" } }
```

## Result Classes

The generic layer defines the `Result` class in `generic/result.rb`. It holds
the result of executing the harness.  The Ableton Live layer redefines the
`Result` class in `live/launcher.rb` so it is specialized for running Ableton
Live. The two layers operate slightly differently:

- The generic layer reports `:loaded` for a program that ran and that nothing
blocked.
- The Live layer reports `:loaded` only after Live successfully loads the set it
was given. Because Live immediately quits when handed a file name that does not
exist; it logs nothing about the failure, and there is no dialog to examine. The
gui_harness Live layer inspects the Ableton Live log to determin the result
status; if a problem was encountered that could not be handled then the
`:unknown` result is returned.


## Closing GUI Applications

An application running under the harness is shut down in stages ("rungs of a
ladder"), and each layer has its own shutdown ladder. The Ruby code defines the
order of the rungs, and the PowerShell code defines what each rung does. The
launcher hands the rungs of its layer to the sidecar, and the sidecar climbs them.

The generic ladder:

1. `close_windows` — ask the application to close, the way a person closes it.
2. `wait_for_exit` — wait for the process tree to go away by itself.
3. `stop_tree` — stop what is left, as the last resort.

The Live ladder:

1. `close_windows`
2. `answer_save_prompt` — answer Live's "Save changes?" from Live's log: `No`,
   or `Yes` when the set is to be saved in place.
3. `wait_for_exit`
4. `confirm_clean_exit` — Live's log says it quit normally.
5. `stop_tree`

The generic layer waits five seconds for the application to close. An
application that closes by itself has exited cleanly, and `exited_cleanly` is
`true`.

An application that does not close is forcefully stopped, and `exited_cleanly`
is `false`. Stop are abrupt: the application does not get to save the document
it was working on. Live leaves a crash report behind and will ask to recover its
work on the next start. A clean exit is therefore the difference between a
harness run that leaves nothing behind and one that does.


## Ableton Live Layer

### Pending Updates

Live fetches updates when available, and a background process installs
that update when Live exits. During an update, Live must not be launched
until the update starts.

The harness reads the log of the application and reports the pending update, so
that the change to the machine is not a surprise:

```ruby
result.messages
# => ['Live 12.4.6 will install update 12.4.7 automatically when it exits.']
```

The message is empty when there is no update, and when the version that is
running is the version that has already been installed.

### Loading Live Sets

Live writes to its log when it has loaded the live set it was given. The
harness watches the Live log, looking for the line: `Loading command-line
document: done.`.

Live writes a different message when the document could not be loaded, so the
harness also looks for `Failed to load command-line document`. Sets that
were not loaded succesfully are reported as such.

### Reading Live Dialogs

Live draws its own windows, and nothing in the window tree describes them. The window class is Live's own rather than
the standard `#32770`, the windows have no children, and UI Automation (the control view and the raw view), MSAA and
`GetWindowText` all come back empty.

The text of a some Live dialogs are written to Live's log. The harness reads the log when possible, because the log
contents are reliable.

As a fallback, the contents of a window can be captured as a 2D array of pixels which can be read with OCR. This process
is used on Live's main window for reading the title, the menu bar and the mixer labels correctly; however, for a dialog
See `docs/gui_harness_design.md` for more information.

### Killing Live

Live writes a recovery point when it is killed, and holds it in its Preferences folder, next to its log. The point is
what makes the next launch of Live ask whether to recover the work, and Live holds the document back until the question
is answered.

Before it starts Live, the Live layer clears the point: it moves it into the folder where Live keeps the ones that have
been answered, named the way Live names them. A run therefore starts without a recovery prompt, and the evidence of what
crashed is kept where Live keeps it.

### When Live waits for permission

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

### When Live asks to be promoted

There is a second prompt, and it is the one that the `ableton:` protocol raises. Live rewrites
the machine-wide registration of that protocol when it starts and finds that another version of
Live ran last, and that rewrite is elevated, so the elevation is the prompt.

The harness keeps the prompt away without any privilege. Windows resolves a registration from
the per-user hive first, so the Live layer writes a per-user registration of the protocol that
names the version it is about to run, and Live finds its own name there. Nothing is promoted,
and the machine-wide registration is left alone.

Nothing is written when the default already names the version that is wanted: when Live 12 is
the default and the harness runs Live 12, the registration is left alone and the run is not
disturbed at all.

A run leaves the machine as it was: the per-user registration of the run is taken away when the
run is over, and the registration of the machine applies again.

The finding, the measurements it rests on, and the fallback if a future version of Live stops
consulting the merged view are in [docs/elevation.md](docs/elevation.md).

The command line that the harness gives to Live is the path of the program and the path of the
set. There are no other arguments.

### Real-world usage

The harness is intended for round-trip and compatibility testing against real apps. A typical scenario is to launch a
real desktop app with a real `.als` file, let it show a modal, classify the dialog, dismiss it, and then assert on the
final state.

The project includes two live Notepad regression paths:

- error path: launch Notepad with a missing file and assert that the real `Cannot find the file ...` dialog is detected
  and dismissed
- success path: launch Notepad with a valid file and assert that there is no dialog, the run reports success, and the
  app exits cleanly without leaving a process behind

This is exactly the kind of real-world modal handling the harness is meant to observe and report.

## PowerShell/Windows integration

The Ruby class delegates actual window inspection to a PowerShell script in `assets/`. The script enumerates the real
Windows UI, walks the automation tree, reads dialog text, and returns the observed information in a format that Ruby can
parse.

This separation keeps Ruby as the test-facing layer while leaving the actual OS-specific automation in the deployment
asset that ships with the gem.

## VS Code workflow

This project includes a small VS Code launch setup for running the real-GUI specs directly from the editor.

### Launch configurations

From the Run and Debug panel, use one of these entries:

- `RSpec: all specs` — runs the whole suite
- `RSpec: current file` — runs the active spec file
- `Ruby: quick Notepad probe` — runs the direct WSL-to-Windows dialog probe used during harness debugging

The harness is meant to run from WSL while the app itself is launched on Windows via PowerShell. That is the supported environment for the real GUI tests.

## Development

The project is meant to be developed and debugged from WSL, while the GUI itself is launched on Windows. This is
intentional and is part of the contract: the harness is a real native-GUI automation layer, not a mocked or local-only
emulator.

Install dependencies:

```bash
bundle install
```

Run the test suite:

```bash
bundle exec rspec
```

Run the GUI harness specs:

```bash
bundle exec rspec \
  spec/gui_harness/generic/launcher_spec.rb \
  spec/gui_harness/live/launcher_spec.rb \
    --format documentation
```

## Testing philosophy

This library is not a mock-based parser. It is built to validate real desktop behavior, real dialogs, and real app
states. When the harness says a dialog is fatal, recovery, save-related, or an ordinary file error, it is because the
real Windows UI exposed that text and the harness classified it as such.

That is what makes it useful for debugging actual compatibility paths and crash-recovery flows.
