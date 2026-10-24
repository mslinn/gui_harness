# GUI Harness Plan

The generic harness is responsible for real GUI execution, not for the details of one file format.

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

The high-level outcome should be one of:

- `:loaded`
- `:crashed`
- `:blocked`
- `:unknown`

## Dialog families

The recognized families include:

- `:fatal`
- `:recovery`
- `:save_changes`
- `:unknown`

The harness should also record the associated dismissal action for each family, such as clicking `OK` or `No`.

## Design principles

- No simulations, stubs, or mocks.
- Real GUI process inspection is required.
- Log files are useful evidence but never the primary truth.
- The harness is reusable across GUI tools, not only a single product.

## Typical workflow

1. Launch the app under test.
2. Wait for the UI to settle.
3. Enumerate windows owned by the new process.
4. Inspect visible top-level dialogs.
5. Read text from the UI tree.
6. Classify the dialog family.
7. Dismiss it.
8. Return a structured result for the calling test suite.
