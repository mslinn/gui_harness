# gui_harness [![Gem Version](https://badge.fury.io/rb/gui_harness.svg)](https://badge.fury.io/rb/gui_harness)

A Ruby harness for real GUI automation and end-to-end compatibility testing.

## Purpose

`gui_harness` is a small library for driving real desktop applications the way a user does: launch the actual process, inspect the windows it owns, read the visible dialog text, classify the modal state, dismiss the blocking prompt, and return a structured result for tests.

This project is intentionally not a log-only parser. The process-owned window probe is the source of truth for the dialogs of the applications that expose their windows; the dialogs of Live are read from Live's own log, because Live is a Qt application and exposes no names for its windows. The harness treats the UI as the contract, and says so where the UI says nothing.

The harness is designed for the real WSL-to-Windows workflow: Ruby runs in WSL, then the target GUI is launched by PowerShell on Windows. The launcher script is treated as a deployed runtime asset, not as Ruby source code.

## Project layout

- `lib/` contains the Ruby API and domain logic
- `assets/` contains runtime assets that are deployed with the gem, including the Windows PowerShell launcher
- `spec/` contains end-to-end, real-GUI regression tests
- `.vscode/launch.json` contains editor launch entries for the real harness flow

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

The main entry point is `GuiHarness::LiveLauncher`.

```ruby
require 'gui_harness'

result = GuiHarness::LiveLauncher.launch(
  'C:/Program Files/Ableton/Live 12 Suite/Program/Ableton Live 12 Suite.exe',
  'C:/path/to/test.als',
  timeout: 13
)

puts result.exit_code
puts result.dialog
puts result.dialog_type
puts result.dismiss_action
puts result.outcome
```

### `classify_dialog`

The library can also classify a dialog text string directly:

```ruby
GuiHarness::LiveLauncher.classify_dialog('A serious program error has occurred.')
# => { type: :fatal, action: { type: "button", value: "OK" } }

GuiHarness::LiveLauncher.classify_dialog('Save changes?')
# => { type: :save_changes, action: { type: "button", value: "No" } }

GuiHarness::LiveLauncher.classify_dialog("Cannot find the file 'missing.als'. Make sure the path and file name are correct.")
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
- `messages`

It also exposes a derived `outcome` method:

- `:loaded`
- `:crashed`
- `:blocked`
- `:unknown`

This keeps a real GUI run easy to assert in Ruby specs without exposing raw UIAutomation internals.

## When the set is loaded

The harness does not wait for a fixed time and hope. Live writes to its log when it has loaded the
document it was given, and the harness waits for that line: `Loading command-line document: done.`
A set that takes a long time to load is waited for as long as it takes, and a set that loads
quickly is not waited for at all. Live writes that line even when the document could not be
loaded, so the harness also looks for `Failed to load command-line document`, and a set that was
not loaded is never reported as loaded.

## When Live waits for permission

Live's installer asks for permission before it registers the file types of Live, and the prompt
is on the secure desktop, where no program of the session can reach it. Live waits for that
permission, and the set is not loaded until it is given. The harness cannot answer the prompt,
so it reports the run as blocked by the installer rather than as a set that was loaded.

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
bundle exec rspec spec/gui_harness/live_launcher_spec.rb --format documentation
```

## Testing philosophy

This library is not a mock-based parser. It is built to validate real desktop behavior, real dialogs, and real app states. When the harness says a dialog is fatal, recovery, save-related, or an ordinary file error, it is because the real Windows UI exposed that text and the harness classified it as such.

That is what makes it useful for debugging actual compatibility paths and crash-recovery flows.
