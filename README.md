# gui_harness [![Gem Version](https://badge.fury.io/rb/gui_harness.svg)](https://badge.fury.io/rb/gui_harness)

A Ruby harness for real GUI automation and end-to-end compatibility testing.

## Purpose

`gui_harness` is a small library for driving real desktop applications the way a user does: launch the actual process, inspect the windows it owns, read the visible dialog text, classify the modal state, dismiss the blocking prompt, and return a structured result for tests.

This project is intentionally not a log-only parser. The process-owned window probe is the source of truth. The harness treats the UI as the contract.

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
  timeout: 120
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
GuiHarness::LiveLauncher.classify_dialog("A serious program error has occurred.")
# => { type: :fatal, action: { type: "button", value: "OK" } }

GuiHarness::LiveLauncher.classify_dialog("Save changes?")
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

It also exposes a derived `outcome` method:

- `:loaded`
- `:crashed`
- `:blocked`
- `:unknown`

This keeps a real GUI run easy to assert in Ruby specs without exposing raw UIAutomation internals.

## Real-world usage

The harness is intended for round-trip and compatibility testing against real apps. A typical scenario is to launch a real desktop app with a real `.als` file, let it show a modal, classify the dialog, dismiss it, and then assert on the final state.

The same pattern has been exercised with a common Windows app demo: a missing file in Notepad generates a standard `Cannot find the file ...` error dialog. That is exactly the kind of real-world modal the harness is meant to observe and report.

## PowerShell/Windows integration

The Ruby class delegates actual window inspection to a PowerShell script. The script enumerates the real Windows UI, walks the automation tree, reads dialog text, and returns the observed information in a format that Ruby can parse.

This separation keeps Ruby as the test-facing layer while leaving the actual OS-specific automation in the Windows script.

## Development

Install dependencies:

```bash
bundle install
```

Run the test suite:

```bash
bundle exec rspec
```

## Testing philosophy

This library is not a mock-based parser. It is built to validate real desktop behavior, real dialogs, and real app states. When the harness says a dialog is fatal, recovery, save-related, or an ordinary file error, it is because the real Windows UI exposed that text and the harness classified it as such.

That is what makes it useful for debugging actual compatibility paths and crash-recovery flows.
