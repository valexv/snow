# Frame pacing fix: handoff

Notes for picking up the cursor/frame-pacing work in a new session or on
another machine. Read this first.

## Working rules

- Commit only when asked. Short one-line commit messages; long descriptions go
  in the PR. Show the message before committing.
- No `Co-Authored-By` or other AI attribution lines in commits.
- Work for a fix goes on its own branch, never on master.
- Verify a cause with measurements before stating it.

## Goal

In absolute (memory-patching) mouse mode at 100% speed, the guest cursor
should move as fluidly as on the real Mac. In general: each guest frame should
stay on screen for the same number of host refreshes.

## Branches

- `master`: upstream `twvd/snow` master (remote `upstream`), 1fbf26d1.
- `frame-pacing-fix`: the fix, 6 commits on master. Meant for the PR. Commits
  1-5 are pushed to origin; 6 is not pushed yet.
  1. Audio: shorter buffers, so the emulator runs in smaller steps
  2. Absolute mouse: give the OS the newest pointer position as the emulator
     runs (`AbsoluteMouseInput` atomic, polled every 1000 instructions)
  3. egui: pace redraws with a display link on macOS instead of vsync
     (`frontend_egui/src/frame_pacer.rs`, CADisplayLink, macOS 14+)
  4. Audio: pace the emulator by the wall clock, at each machine's own sample
     rate (`core/src/renderer/audio.rs`: `PacedAudioSink`, `AudioPlayer`)
  5. Lock the machine's frames to the display's refresh
     (`core/src/renderer/display_lock.rs`, Options > "Lock to display
     refresh")
  6. egui: lock to the display's refresh on Windows too, from DWM's timing
     (`frontend_egui/src/dwm_timing.rs`: `DwmGetCompositionTimingInfo`, QPC
     times converted to `Instant`s). Vsync still paces the redraws there.
     Also allows a clippy lint on the non-macOS `try_redraw` stub, which broke
     clippy off macOS.
- `frame-pacing-diagnostics`: `frame-pacing-fix` plus the timing log and this
  folder. Never merge it; rebase it onto `frame-pacing-fix` when that changes.
- `macos-swiftui-frontend`: the SwiftUI frontend (`frontend_macos/`), which
  doesn't have the fix yet.

## Diagnostics

Set `SNOW_JUDDER_LOG` to a file path and run snow; it writes a CSV of timing
events (see `core/src/judder_log.rs` for the events). Then:

```
python3 judder/judder_analyze.py <log.csv>
```

Use a release build, and a short run of steady cursor motion: the log grows
quickly (tens of MB in a long session), and pauses dilute the figures.

The key figures:

- "host refreshes each guest frame was shown for": on a 120 Hz display a 60 Hz
  machine should show 2 for (nearly) every frame. 1 or 3 is judder.
- "host pointer input": how evenly the frontend gets pointer moves. On macOS
  a trackpad moves every 8.3 ms. On Windows this line is misleading: the
  frontend reads each position twice per frame, so over half its gaps are
  ~0 ms. Look at the `os` events instead.
- "Pointing device (raw input)": the device's report rate, and how long the
  steps are with 1, 2 or 3 reports between two pointer moves. Raw input is
  logged when handled, not when reported, so its gaps mean nothing on their
  own.
- "uneven" host frames and their causes: where cursor stalls/jumps come from.

On Windows (PowerShell), with the release build already made:

```
$env:SNOW_JUDDER_LOG = "$HOME\snow-judder.csv"; .\target\release\snowemu.exe
```

Python from python.org (winget `Python.Python.3.13`), not the Microsoft Store
alias that stands in for `python` until it's installed.

## Findings so far (macOS, Mac Plus, 120 Hz ProMotion, Magic Trackpad 2)

- Before the fix, glow's vsync buffer swap blocked the main thread ~98% of the
  time, so winit delivered pointer moves in lumps (gaps 3-25 ms instead of
  8.3 ms). Turning off macOS mouse coalescing did nothing; Bluetooth vs USB
  made no difference. Fixed by commit 3.
- Emulation was paced by the host audio callback, so guest frames landed on a
  ~5.8 ms grid. Fixed by commit 4, which also fixed the machine running ~0.9%
  slow (the compact Macs' 22254.5 Hz audio was played at 22050 Hz).
- CVDisplayLink fires at ~121-122 Hz on a ProMotion display whose mode says
  120.04 Hz; CADisplayLink keeps to the real refreshes.
- With everything on: 99-100% of guest frames shown exactly 2 refreshes, guest
  60.02 Hz, host 120.04 Hz; 86-95% with the display lock off. CPU and GPU
  normal (~545 event loop wakes/s).
- egui asks for an immediate repaint every frame (cause unknown); the pacer
  (or vsync) hides it.

## Findings on Windows (2026-11-22; Windows 11, Mac Plus, basic USB optical mouse)

- The diagnostic log works on Windows as is.
- Vsync still blocks the main thread 96-98% of the time, and Windows coalesces
  pointer moves, so the window gets exactly one pointer move per refresh. They
  come evenly, not in lumps as on macOS before commit 3. Left as is.
- 100 Hz display: frames shown 2, 2, 1 refreshes (66/34%), as 100/60 forces.
  No lock can fix that without running the machine far off real speed.
- 60 Hz display, no lock: guest 60.13 Hz against the display's 59.95 Hz, so
  it gains a frame every ~5.6 s, and each time a burst of ~10 skipped and
  doubled frames over 0.5-1 s, as the jitter flips frames across the refresh.
- 60 Hz display, with commit 6: guest 59.99 Hz, 99.5-99.7% of frames shown
  exactly 1 refresh, no bursts. DWM reported 59.973 Hz.
- Remaining unevenness (~24% of host frames "uneven" by the analyzer) comes
  from the mouse, measured with raw input: it reports at ~124 Hz, so 2.07
  reports per 60 Hz frame. Steps with 1, 2, 3 reports are 0.48x, 0.97x and
  1.48x their neighbours; ~8% of frames get 3. The guest cursor follows the
  positions it's given exactly. The Windows desktop cursor has the same
  cadence with this mouse; the Mac's trackpad (8.3 ms) gives exactly 2 per
  frame, which is why it looked smoother there.
- Decided against the fix for that (a raw-input thread with timestamped
  positions, and the guest given the position one report ago, interpolated):
  too much for a small difference, which a 500-1000 Hz mouse removes anyway.

## Windows: still to test

- Audio: the startup chime and a game or sound sample, with the cpal and the
  SDL2 (`--features audio_sdl2`) backends. Not checked yet.
- Several displays at different refresh rates: DWM's timing is the main
  display's, so the lock follows that one even with the window elsewhere.

## Open items

- Port the fix to the SwiftUI frontend: its FFI (`snow_ffi` on
  `macos-swiftui-frontend`) doesn't build against the new audio API
  (`ChannelAudioSink::new(freq, channels)`, `AudioPlayer`). It should use
  `AudioPlayer` for playback, `AbsoluteMouseInput` for the mouse, and feed its
  CADisplayLink into `DisplayLock`.
- Upstream's `CpalAudioStreamSink::send` sleeps for a dead stream; that's now
  redundant with `PacedAudioSink`. Harmless.
- PR description drafted in the session; not yet opened. Add commit 6 and the
  Windows findings to it.
- Push `frame-pacing-fix` (commit 6) and force-push the rebased
  `frame-pacing-diagnostics`.
- `cargo fmt --check` fails on `core/src/renderer/display_lock.rs` (a long
  `assert!` in the tests, from commit 5). Fix before opening the PR.
