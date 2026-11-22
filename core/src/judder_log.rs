//! Diagnostic log of the timing of the mouse cursor, from the host pointer to
//! the frames on screen, to find where judder comes from.
//!
//! Enabled by setting SNOW_JUDDER_LOG to the path of a file to write. Each
//! line is CSV: microseconds since the log started, event, then up to three
//! values:
//! - `raw,dx,dy`: the OS delivered a report of the pointing device (raw input,
//!   in device units). Logged when handled, which can be well after the report.
//! - `os,x,y`: the OS delivered a pointer move to the window (physical pixels)
//! - `in,x,y`: the frontend got a host pointer position (absolute mode)
//! - `apply,x,y`: the emulator gave the OS a pointer position
//! - `gframe,seq`: the machine rendered a frame for the frontend
//! - `gskip`: the machine skipped a frame, as the frontend had not taken the last
//! - `fcursor,seq,x,y`: where the cursor was (low memory Mouse) for a rendered frame
//! - `hframe,seq`: the frontend drew with a new frame, or -1 when none came
//! - `wake,cause`: the host event loop woke up (1 timer, 2 event, 3 poll, 4 init)
//! - `redraw,us`: a host redraw (update, paint, swap) ended, after `us` microseconds
//! - `idle`: the host event loop is about to wait for events

use std::fs::File;
use std::io::{LineWriter, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

struct Log {
    start: Instant,
    out: Mutex<LineWriter<File>>,
}

static LOG: OnceLock<Option<Log>> = OnceLock::new();

/// Frames rendered so far
static FRAME_SEQ: AtomicU64 = AtomicU64::new(0);

fn get() -> Option<&'static Log> {
    LOG.get_or_init(|| {
        let path = std::env::var_os("SNOW_JUDDER_LOG")?;
        let f = File::create(&path)
            .inspect_err(|e| log::error!("Cannot create judder log: {}", e))
            .ok()?;
        let mut out = LineWriter::new(f);
        let _ = writeln!(out, "t_us,event,a,b,c");
        log::info!("Writing judder log to {}", path.display());
        Some(Log {
            start: Instant::now(),
            out: Mutex::new(out),
        })
    })
    .as_ref()
}

/// Whether the log is being written
pub fn enabled() -> bool {
    get().is_some()
}

/// Logs an event with its values
pub fn log(event: &str, a: i64, b: i64, c: i64) {
    if let Some(l) = get() {
        let t = l.start.elapsed().as_micros();
        let _ = writeln!(l.out.lock().unwrap(), "{t},{event},{a},{b},{c}");
    }
}

/// Counts a rendered frame, returning its sequence number
pub fn frame_rendered() -> u64 {
    let seq = FRAME_SEQ.fetch_add(1, Ordering::Relaxed) + 1;
    log("gframe", seq as i64, 0, 0);
    seq
}

/// Sequence number of the last rendered frame
pub fn last_frame() -> u64 {
    FRAME_SEQ.load(Ordering::Relaxed)
}
