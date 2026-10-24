# gui_harness [![Gem Version](https://badge.fury.io/rb/gui_harness.svg)](https://badge.fury.io/rb/gui_harness)

A Ruby harness for real GUI app automation and round-trip testing.

## Purpose

`gui_harness` exists to test desktop applications the way users actually run them: launch the real process, inspect the real windows it owns, read the visible dialog text, classify the modal state, dismiss the blocking prompt, and record the final outcome.

This project is designed for integration scenarios where logs are useful but not authoritative. The process-owned window probe is the primary source of truth.

## Core requirement

The harness must do the following:

- launch the target GUI application
- retain the process identity
- enumerate the top-level windows that belong to that process
- walk the UIAutomation tree for each visible window
- read whatever user-facing text is exposed by the active dialog
- classify the dialog family
- dismiss the dialog using the correct action
- report whether the run loaded, crashed, blocked, or ended in an unknown state

Log parsing remains a secondary source of evidence. The actual GUI state wins.

## Why this project exists

This is meant for reverse-engineering and compatibility testing where the behavior of the real application matters more than parser-only assertions.

The intended use is to support workloads like:

- round-trip testing of `.als` files across Ableton Live versions
- observing application startup and crash-recovery prompts
- detecting fatal errors and dismissal paths without mocking the UI
- validating real end-to-end behavior against actual app output

## Design principles

- No simulations, stubs, or mocks
- Prefer real process and real window inspection over synthetic log-only checks
- Treat UI text and dialog family as the contract
- Return structured results that downstream tests can assert on
- Keep the harness readable, deterministic, and reusable across apps

## Expected workflow

1. Launch the target process.
2. Wait briefly for the UI to settle.
3. Enumerate windows owned by that process.
4. Find the top-level dialog or modal that is actually visible.
5. Read the text and classify it as one of the expected families.
6. Trigger the matching dismissal action.
7. Capture the final outcome and any relevant logs.
8. Return a machine-readable result for the test harness.

## Typical result model

The harness should produce structured results including at least:

- `exit_code`
- `output`
- `dialog`
- `dialog_type`
- `dismiss_action`
- `log`
- `loaded`
- `crashed`

This is intentionally simple: the result object should be easy for specs to assert against without needing to inspect raw UI automation output directly.

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

This project is not a synthetic mock-based test harness. It is meant to be used against real GUI behavior and real files. The test contract is defined by what the process shows users, not by what a parser happens to infer from a log file.

That keeps the harness honest and makes it useful for debugging actual compatibility and crash paths.

## Project status

This repository is in the initial harness stage: the project scaffold is established and the contract is being formalized around the process-owned window probe and dialog classification workflow.
