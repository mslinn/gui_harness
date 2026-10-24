# gui_harness

GUI automation harness for launching and observing real desktop apps during integration tests.

## Purpose

This project provides a reusable Ruby layer for working with GUI applications in end-to-end tests, especially desktop apps that need real window inspection and dismissal logic rather than mock-only behavior.

## Typical use

- Launch a desktop application under test
- Enumerate process-owned windows
- Read visible dialog text and classify modal states
- Trigger the appropriate dismissal action
- Record the final result for real integration and round-trip testing

## Development

- `bundle install`
- `bundle exec rspec`
