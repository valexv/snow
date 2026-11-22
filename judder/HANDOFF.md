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
- `frame-pacing-fix`: the fix, 5 commits on master, pushed to origin. Meant
  for the PR.
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
  a trackpad moves every 8.3 ms.
- "uneven" host frames and their causes: where cursor stalls/jumps come from.

On Windows (PowerShell):

```
$env:SNOW_JUDDER_LOG = "$HOME\snow-judder.csv"; cargo run --release -p snow_frontend_egui
```

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

## Windows: what to test

- Commit 3 is macOS-only. On Windows, eframe still uses vsync, so the
  input-lumping problem may happen there too. Check "host pointer input" in a
  log while moving the mouse steadily.
- `frame_pacer::refresh_grid()` returns None off macOS, so the display lock
  never engages on Windows: expect a frame shown for 1 or 3 refreshes every
  few seconds (60.15 Hz machine vs 60 Hz display). A Windows fix would need
  the refresh timing from somewhere, e.g. DXGI `GetFrameStatistics` or
  `DwmGetCompositionTimingInfo`.
- Commits 1, 2 and 4 are in the core and apply as-is. Check that audio sounds
  right (startup chime, then a game or sound sample), with both the cpal and
  the SDL2 backends.
- The diagnostic log itself hasn't been tried on Windows.

## Open items

- Port the fix to the SwiftUI frontend: its FFI (`snow_ffi` on
  `macos-swiftui-frontend`) doesn't build against the new audio API
  (`ChannelAudioSink::new(freq, channels)`, `AudioPlayer`). It should use
  `AudioPlayer` for playback, `AbsoluteMouseInput` for the mouse, and feed its
  CADisplayLink into `DisplayLock`.
- Upstream's `CpalAudioStreamSink::send` sleeps for a dead stream; that's now
  redundant with `PacedAudioSink`. Harmless.
- PR description drafted in the session; not yet opened.
