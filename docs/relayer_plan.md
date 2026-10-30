# Plan: Restore the two layers of `gui_harness`, and give the shutdown ladder a generic and a Live implementation

## Context

`gui_harness` was built in two layers — a generic capability (drive any GUI program on Windows) and
an Ableton Live specialization (Live's log, Live's recovery prompt, Live's installer prompt) — but
the code no longer shows that shape. Everything is one flat namespace
(`GuiHarness::LiveLauncher`, `lib/gui_harness/live_launcher.rb`) and one 1423-line PowerShell script
(`assets/gui_harness_live_launcher.ps1`) that mixes generic window/dialog/keyboard/process-tree
code with Live's log parsing, Live's install-helper detection and Live's crash-recovery handling.
The shutdown ladder — close the windows, answer "Save changes?", wait, force-stop — is buried in the
`finally` block of that script, with no generic form and no Live form to point at.

The gem is a dependency of `live_set` (by path), so the two layers have to be visible in the source
tree: separate subdirectories per layer, and a shutdown ladder that has a generic implementation and
a Live-specific specialization.

## Flagged

Two things about this plan are easy to get wrong, and both of them are written down here so that
they are not lost.

**1. The PowerShell libraries must have no `param()` block.** A dot-sourced script assigns its
parameters *in the caller's scope*. If `assets/generic/gui_harness_generic.ps1` declared `$Exe`,
`$Set`, `$Log` or `$Visibility`, then `assets/live/gui_harness_live.ps1` dot-sourcing it would
reset the values of the Live run to their defaults — silently, with no error, and the run would
launch the wrong program or no program at all. The libraries hold the functions and nothing else;
the parameters live in the entry points, `assets/generic/run.ps1` and `assets/live/run.ps1`, which
read them *after* the library is loaded.

**2. `live_set` calls the harness by its old name.** These places in `live_set` use
`GuiHarness::LiveLauncher`:

- `live_set/spec/integration/live_set_round_trip_spec.rb:64` — the launch of Live 11 with the
  converted set.
- `live_set/spec/support/live_harness/live_launcher_spec.rb:6` — the description of the class.
- `live_set/spec/support/live_harness/live_keys.rb:45` and `:70` — `LiveLauncher.windows_path`.

The constant becomes `GuiHarness::Live::Launcher`. `live_set` depends on `gui_harness` by path
(`gem 'gui_harness', path: '../gui_harness'`), so the change is local to the two repositories and
needs no release of the gem first. `live_set` is not part of this repository, so those edits are
listed here and made in that project.

### The layering that is wanted

| | generic | live |
|---|---|---|
| Ruby | `lib/gui_harness/generic/` | `lib/gui_harness/live/` |
| PowerShell | `assets/generic/` | `assets/live/` |
| dialog rules | fatal program error, file not found, save changes | recovery prompt, updater, Live's wording |
| run state | the modal dialogs of the windows | Live's log: loaded, crashed, updater, pending update |
| shutdown ladder | `close_windows`, `wait_for_exit`, `stop_tree` | `answer_save_prompt`, `confirm_clean_exit` |

The ladder is the same idea in both languages: **Ruby owns the order of the rungs, PowerShell owns
the mechanics of each rung.** `GuiHarness::Generic::Shutdown::RUNGS` is the generic ladder,
`GuiHarness::Live::Shutdown::RUNGS` is the Live one, and the launcher hands the rungs to the
sidecar, which climbs them.

## The files

### PowerShell

```text
assets/generic/gui_harness_generic.ps1   # the generic library: primitives, generic seams, generic rungs
assets/generic/run.ps1                    # the generic entry point: the parameters, and the run
assets/live/gui_harness_live.ps1          # the Live library: dot-sources the generic one, Live seams and rungs
assets/live/run.ps1                       # the Live entry point: the parameters, and the run
```

The libraries have **no `param()` block** and no entry point; the entry points have the parameters
and dot-source their library. This asymmetry is required: a dot-sourced script assigns its
parameters *in the caller's scope*, so a generic library that declared `$Exe`/`$Set`/`$Log`/
`$Visibility` would reset the Live run's values to their defaults the moment the Live library
dot-sourced it.

`assets/live/gui_harness_live.ps1` dot-sources the generic library by path
(`Join-Path (Split-Path -Parent $PSScriptRoot) 'generic/gui_harness_generic.ps1'`), then redefines
the seams. PowerShell resolves a bare command name at call time, so a seam that is called **by
name** from generic code is overridden by the Live definition; a seam captured in a variable at
dot-source time would not be.

### Ruby

```text
lib/gui_harness/generic/launcher.rb   # GuiHarness::Generic::Launcher: launch, parse, the result
lib/gui_harness/generic/shutdown.rb   # GuiHarness::Generic::Shutdown: the generic ladder
lib/gui_harness/generic/dialog.rb     # GuiHarness::Generic::Dialog: the generic dialog rules
lib/gui_harness/live/launcher.rb      # GuiHarness::Live::Launcher: the Live run, the Live result
lib/gui_harness/live/shutdown.rb      # GuiHarness::Live::Shutdown: the Live ladder
lib/gui_harness/live/dialog.rb        # GuiHarness::Live::Dialog: the Live dialog rules
```

`GuiHarness::Live::Launcher` is the public entry point. `live_set` is updated to the new name
(it depends on `gui_harness` by path, so the change is local).

## The seams (PowerShell)

The generic library defines each seam twice: `X-Generic…` holds the algorithm, and the seam name is
a one-line delegation. The Live library redefines the seam name and delegates back to the
`X-Generic…` version where the generic behaviour is still wanted.

| seam | generic | live |
|---|---|---|
| `Get-DialogInfo` | fatal / file-not-found / save-changes / recover-work | updater, "Live will shut down…", "Live unexpectedly quit…" |
| `Update-RunState` | the modal dialogs of the windows of the process tree | Live's log: `Message Box:`, `Begin ExchangeDocument`, `Exception: Fatal Error`, `Failed to load command-line document`, `Loading command-line document: done.`, the recovery keys `n` then `esc`, the install helper |
| `Get-PermissionPrompts` | `@()` | `consent.exe` whose title matches `InstallHelper` |
| `Test-WaitsForPermission` | `$false` | the executable is Live and a prompt is waiting |
| `Get-PendingUpdate` | `''` | `auto-update available:` against `Init: Version: 'Live …'` |
| `Invoke-PreRunCleanup` | nothing | `Close-RunningLive` |
| `Get-SaveCandidatePaths` | the path and the path without its extension | the path, the path with `.als`, and `<name> Project/<name>.als` |

## The ladder

**Ruby** holds the order:

```ruby
module GuiHarness
  module Generic
    class Shutdown
      RUNGS = %i[close_windows wait_for_exit stop_tree].freeze
    end
  end
  module Live
    class Shutdown < Generic::Shutdown
      RUNGS = %i[close_windows answer_save_prompt wait_for_exit confirm_clean_exit stop_tree].freeze
    end
  end
end
```

**PowerShell** holds the mechanics. The generic library implements `close_windows` (post `WM_CLOSE`
to the windows of the tree), `wait_for_exit` (poll the tree until it is gone or the deadline
passes) and `stop_tree` (`Stop-ProcessTree`). The Live library implements `answer_save_prompt`
(answer Live's "Save changes?" from its log with `n`, or `y` for `SaveInPlace`) and
`confirm_clean_exit` (Live's log says `GlobalExit(): End`).

The launcher passes the rungs to the sidecar (`-ShutdownRungs close_windows,answer_save_prompt,…`)
and the sidecar climbs them in the `finally` block, stopping when a rung says the application is
gone. `EXITED_CLEANLY` is reported as today: the generic meaning is "the tree went away by itself",
the Live meaning is "Live's log says it quit normally".

## Phases

Each phase leaves the suite green.

**Phase 1 — split the PowerShell sidecar.** Move the functions to their layers per the table below;
introduce the seams; add the two entry points; keep the behaviour identical.
Move to the generic library: the `Add-Type` block (`Live` → `GuiHarness`, guarded by
`if (-not ('GuiHarness' -as [type]))`), `Stop-ProcessTree`, `Get-ProcessTreeIds`,
`Close-VisibleWindowsForPids`, `Set-ProcessWindowVisibility`, `Debug-Log`, `Get-KeyCode`,
`Send-KeyToWindows`, `Send-ShortcutToWindows`, `Focus-Window`, `Send-DismissKey`, `Escape-Keys`,
`Dismiss-MessageDialogs`, `Find-MainWindow`, `Wait-ForMainWindow`, `Find-MessageDialogs`,
`Press-Button`, `Dump-GuiWindows`, `Find-FileDialog`, `Save-Document`, `Wait-ForSet`, `Read-Log`
(takes the path as a parameter now, instead of closing over `$Log`), `Get-Windows`,
`Get-ChildWindows`, `Get-DirectChildren`, `Get-Descendants`, `Get-AncestorClasses`,
`Get-GuiWindows`, `Get-ProcessWindows`, `Test-IsModal`, `Get-DialogElement`, `Get-DialogText`,
`Click-Button`, `Start-Application`, the generic seams, the generic ladder and the generic
`Invoke-Main`.
Move to the Live library: `Get-InstallHelpers`, `Get-PermissionPrompts`, `Test-WaitsForPermission`,
`Get-PendingUpdate`, `Close-RunningLive` (hoisted out of `Invoke-Main`, where it was a nested
function that captured `$logStart`), `Cleanup-Notepad`, the Live seams and the Live rungs.
`Invoke-Main` is rewritten around the seams: it starts the application, loops asking the run state
for the facts, and climbs the ladder in the `finally`.

**Phase 2 — split the Ruby layer.** `GuiHarness::Generic::Launcher` holds the launch, the parse and
the result; `GuiHarness::Generic::Dialog` holds the generic rules; `GuiHarness::Live::Launcher`
holds the Live rules and the Live result bits (the pending-update message); the two `Shutdown`
classes hold the ladders. The launcher writes both layers of the script to
`%TEMP%/gui_harness/{generic,live}/…`, preserving the layout, and points `-File` at the Live entry
point.

**Phase 3 — the rungs come from Ruby.** `Launcher#launch` passes the rungs of its layer to the
sidecar (`-ShutdownRungs`), the sidecar climbs exactly those, and the specs assert the two ladders
(`Generic::Shutdown::RUNGS` vs `Live::Shutdown::RUNGS`) and that a rung the layer does not have is
not climbed.

**Phase 4 — `live_set` and the docs.** `live_set/spec/integration/live_set_round_trip_spec.rb` and
`live_set/spec/support/live_harness/live_launcher_spec.rb` use `GuiHarness::Live::Launcher`. The
docs that describe the harness are updated: `gui_harness/README.md` (the two layers, the ladder,
`exited_cleanly`, the pending-update message), `gui_harness/docs/gui_harness_design.md` (the contract,
now with the layers and the ladder), `live_set/docs/live_control_plan.md` (the harness contract it
refers to) and `live_set/TODO.md` if it names the old constant.

## The pitfalls the split has to avoid

- **Dot-source parameter clobbering.** A dot-sourced script assigns its parameters in the caller's
  scope; the libraries have no `param()` block, and the entry points read their parameters *after*
  the dot-source.
- **`$processId:`** parses as a drive-qualified variable and throws. Keep the `${processId}` form,
  and rename the loop variables to `$targetPid` so they are never confused with the automatic
  `$PID`.
- **`$script:` variables** (`$script:sent` in `Send-KeyToWindows`) resolve to the scope of whoever
  dot-sourced the script. Replace them with the run-state and context objects.
- **`Add-Type` re-definition** throws "type name already exists" when a library is dot-sourced
  twice in one session; guard it.
- **`Start-Process -ArgumentList @()`** throws on an empty array; keep the branch on the count.
- **Captured seams** freeze the generic version; every seam is called by name.

## Files

- `assets/generic/gui_harness_generic.ps1` — new; the generic library
- `assets/generic/run.ps1` — new; the generic entry point
- `assets/live/gui_harness_live.ps1` — new; the Live library
- `assets/live/run.ps1` — new; the Live entry point
- `assets/gui_harness_live_launcher.ps1` — deleted, once the two layers are in place
- `lib/gui_harness/generic/{launcher,shutdown,dialog}.rb` — new
- `lib/gui_harness/live/{launcher,shutdown,dialog}.rb` — new
- `lib/gui_harness/live_launcher.rb` — deleted
- `lib/gui_harness.rb` — requires the two layers
- `spec/gui_harness/generic/*_spec.rb`, `spec/gui_harness/live/*_spec.rb` — the specs follow the layers
- `live_set/spec/integration/live_set_round_trip_spec.rb`,
  `live_set/spec/support/live_harness/live_launcher_spec.rb` — the new constant
- `README.md`, `docs/gui_harness_design.md`, `live_set/docs/live_control_plan.md` — the docs

## Verification

```shell
cd /mnt/f/work/ruby/my_gems/gui_harness
bundle exec rubocop        # no offenses
bundle exec rspec          # the generic specs and the Live specs, 0 failures

cd /mnt/f/work/ruby/my_gems/live_set
bundle exec rspec spec/support/live_harness/live_launcher_spec.rb
bundle exec rubocop
```

The generic specs are the Notepad paths (the real `Cannot find the file …` dialog, the clean
launch), and they now run against the generic layer alone.

Then, by hand: launch Live 12 with a demo set through the sidecar and confirm that the log reaches
`End ExchangeDocument`, that the run reports `exited_cleanly`, that no recovery prompt is left
behind, and that `Get-DialogInfo` and the ladder report the Live versions when the Live layer is
dot-sourced and the generic ones when it is not.
