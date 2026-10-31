# Elevation: the `ableton:` handler and the UAC prompt

How the Live layer avoids the UAC prompt that Live raises when it is not the version that ran
last — without needing any privilege.

Written: 2026-10-30.

## Why this is a problem

> UAC causes a real problem for this workflow because a human must sit and wait to say Yes to UAC
> hundreds of times.

The A/B workflow needs a great many runs: author a set in one version, save it, load that set in
the other version, save it there, and compare the XML of the two. The prompt is on the secure
desktop, where no automation can reach it, so every version switch put a person in the loop. A
harness that stops for a human is not a harness.

The rule that governs the prompt, as it was observed:

> it only invokes UAC the first time that a different version of live runs. so you can use live 12
> many times, and only be prompted the first time. then when you run live 11, uac runs, and you
> can launch live 11 as much as you want. the next time you run live 12, uac runs, etc.

So the trigger is a **version switch**, not a launch. The prompt is per version, not per machine.

The symptom was worse than a delay: Live 11 hangs at startup on the invisible prompt, and does
not proceed until somebody answers it.

Two ways out were considered. One was to disable UAC on the machine, which would have solved it
but "is not optimal". The other was to watch what Live writes while it runs —

> we could monitor `%programdata%\ableton` and `%appdata%\ableton` for writes from the time Live
> 11 or 12 starts to when it ends. Once we identify what changes, gui_harness can recreate the
> happy path for Live 12 so UAC is not triggered.

— which is what was done, and which is what the finding below is. The premise that motivated it:

> Ableton Live must leave a persistent reminder of the version of Live that last ran. Either this
> will be a file, a marker directory, or a Windows registry entry.

The reminder turned out to be a registry entry after all, and the machine-wide one at that.

## The finding

One registry value names the version of Live that last ran:

```
HKLM\SOFTWARE\Classes\ableton\Shell\open\command
    (Default)  C:\ProgramData\Ableton\Live 11 Suite\Program\Ableton Live 11 Suite.exe "%1"
```

Live rewrites that value when it starts and finds that the value names a different version. The
key is machine-wide, so the rewrite is elevated, and **the elevation is the prompt**.

The measurements that established this:

- Launching Live 11 when the value named Live 11: no prompt, and **no change anywhere** — not in
  the registry, not in `%ProgramData%\Ableton`.
- Launching Live 12 when the value named Live 11: the prompt appeared, and afterwards **exactly
  one value in the whole machine had changed** — that value, now naming Live 12. Nothing in
  `%ProgramData%\Ableton` changed. Nothing else in the registry changed.
- Closing Live 12 changed nothing further.

So the entire elevated operation is one string in one key. Nothing is written to disk, no service
is registered, no task is created. The snapshot that established this is
`assets/live/uac_snapshot.ps1`, which dumps the Ableton hives, the machine-wide and per-user
class registrations, the two Ableton directory trees, the running processes and the event log.

This also explains the rule. The key holds exactly one version. A version that finds its own name
there does nothing and prompts not at all. A version that finds someone else's name rewrites it
and prompts once. The next run of that same version finds its own name and is silent, until
some other version runs.

## Why no privilege is needed

Windows resolves a class registration from the per-user hive first and falls back to the
machine-wide hive. `HKEY_CLASSES_ROOT` is the merged view of the two, and it is what a program
that asks the shell "what handles this?" sees.

Live consults that merged view. So a per-user registration shadows the machine-wide one, and
Live finds its own name there without anything being promoted.

The experiment that established it:

1. The machine-wide value named Live 12.
2. A per-user key was created:
   `HKCU\Software\Classes\ableton\Shell\open\command` → the Live 11 executable.
3. The merged view was read back and resolved to Live 11.
4. Live 11 was launched: **no UAC prompt.**

Nothing was elevated, and the machine-wide value was not touched. The per-user key needs no
privilege to write.

## What the Live layer does

Before launching Live, the Live layer makes the registration that the machine would use name the
version it is about to launch:

```text
HKCU\Software\Classes\ableton\Shell\open\command
    (Default)  <path of the Live executable being launched> "%1"
```

**Nothing is written when the default already names the version that is wanted.** When Live 12 is
the default and the harness runs Live 12, there is nothing to do: the registration is left
alone, and the run is not disturbed at all. The registration is written only when the default
names another version, which is the one time in which Live would ask to be promoted.

A registration names a version when it names that executable, or when it names another
executable of the same version. The version is the version of the file itself — the folder that
holds a copy of Live holds the edition and not the version, so the folder cannot be read for it.

The write is per-user, so it needs no elevation, and it leaves the machine-wide registration
intact. The machine's own `ableton:` association still says what the user's installation says.

## What the run leaves behind

A run that is only a test should not change what the machine does for the people who use it.
When the run is over, the per-user registration of the run is **taken away**, and the
registration of the machine applies again — which is what a user expects of a machine that was
only used for a test.

Only the registration that the run wrote is taken away. A per-user registration that the user
made for themselves is left alone, and a run that never wrote one takes nothing away.

The machine's own registration names the version of Live that last ran with the permission of an
administrator, which is the version a user gets when they use their machine.

## What it costs

Nothing, in the end. The per-user registration is written for the run and taken away when the
run is over, so the machine is as it was before: the `ableton:` URL opens whichever version the
machine's own registration names.

The cost is during the run. While Live runs, the `ableton:` URL opens the version the harness
launched rather than the one the machine names.

## Where the code goes

- `Set-ApplicationRegistration` is the seam that is called before `Start-Application`, and
  `Restore-ApplicationRegistration` is the seam that is called when the run is over. The generic
  layer defines both and does nothing in them; the Live layer overrides them. Both take the
  context of the run, which holds the path of the executable and the flag that says whether the
  run wrote a registration.
- The helpers of the Live layer are `Get-ProtocolHandlerKey`, `Get-EffectiveProtocolHandler`,
  `Get-HandlerExecutable`, `Get-ExecutableVersion` and `Test-HandlerMatches`. They are in
  `assets/live/gui_harness_live.ps1`.
- The Ruby side needs nothing: the launcher already knows the path of the executable, and the
  sidecar already has it.
- The key the Live layer writes is `Get-ProtocolHandlerKey`, and not a path written into the
  body of the function, so that a test can point it at a key of its own and leave the
  registration of the machine alone.

## How it is verified

- `spec/gui_harness/live/protocol_handler_spec.rb` asserts that the registration names the
  version that is about to be run, that nothing is written when it already names it, that
  nothing is written when the default names the version that is wanted, that the per-user
  registration shadows the one of the machine, that the registration of the run is taken away
  when the run is over, and that a registration the run did not write is left alone.
- By hand: the same sequence as the experiment above — point the effective handler at Live 11,
  launch Live 12, and confirm that no prompt appears, and that the per-user registration is gone
  when the run is over.

## If this stops working

If a future version of Live starts consulting the machine-wide key directly, the per-user shadow
ceases to be consulted and the prompt returns. In that case the fallback is to write that one
value with elevation — a scheduled task registered to run with the highest privileges, so that
one human approval at registration time replaces a prompt per launch. The contract of such a
broker, and the privilege boundary it opens, would need to be written down before it was built.
