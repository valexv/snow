#!/usr/bin/env python3
"""Summarizes a Snow judder log (SNOW_JUDDER_LOG) into where cursor judder comes from."""
import csv
import statistics as st
import sys
from bisect import bisect_left, bisect_right


def stats(name, xs, unit="ms"):
    if len(xs) < 2:
        print(f"  {name}: too few samples ({len(xs)})")
        return
    xs = sorted(xs)
    q = lambda p: xs[min(len(xs) - 1, int(p * len(xs)))]
    print(
        f"  {name}: n={len(xs)} mean={st.mean(xs):.2f}{unit} sd={st.pstdev(xs):.2f} "
        f"p1={q(0.01):.2f} p50={q(0.5):.2f} p99={q(0.99):.2f} max={xs[-1]:.2f}"
    )


def main(path):
    ev = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            ev.setdefault(row["event"], []).append(
                (int(row["t_us"]) / 1000.0, int(row["a"]), int(row["b"]), int(row["c"]))
            )
    get = lambda k: ev.get(k, [])
    inputs, applies = get("in"), get("apply")
    gframes, gskips, hframes = get("gframe"), get("gskip"), get("hframe")
    fcursor = {s: (x, y) for _, s, x, y in get("fcursor")}
    gframe_t = {s: t for t, s, _, _ in gframes}
    skip_t = [t for t, *_ in gskips]
    apply_t = [t for t, *_ in applies]

    print(f"Log: {path}")
    print("\nTiming (real time between events):")
    stats("host pointer input", [b[0] - a[0] for a, b in zip(inputs, inputs[1:])])
    stats("applied to guest", [b[0] - a[0] for a, b in zip(applies, applies[1:])])
    guest = sorted([t for t, *_ in gframes] + skip_t)
    stats("guest frames (rendered+skipped)", [b - a for a, b in zip(guest, guest[1:])])
    stats("host frames", [b[0] - a[0] for a, b in zip(hframes, hframes[1:])])
    if guest:
        print(f"  guest frames skipped (frontend had not taken previous): {len(skip_t)} of {len(guest)}")
    new_h = sum(1 for h in hframes if h[1] >= 0)
    print(f"  host frames with a new guest frame: {new_h} of {len(hframes)}")

    # Host refreshes each guest frame stayed on screen, from the time to the
    # next new one in units of the typical time between host frames (the
    # refresh period, as host frames come once per refresh while drawing).
    # With a 60 Hz machine on a 120 Hz display, all should be 2; 1 or 3 shows
    # as judder. Gaps over 100 ms (pauses, idle) are left out.
    new_t = [t for t, s, _, _ in hframes if s >= 0]
    host_dt = sorted(b[0] - a[0] for a, b in zip(hframes, hframes[1:]))
    if len(new_t) > 1 and host_dt:
        refresh = host_dt[len(host_dt) // 2]
        shown_for = [round((b - a) / refresh) for a, b in zip(new_t, new_t[1:]) if b - a < 100]
        print(f"  host refreshes each guest frame was shown for (refresh {refresh:.2f}ms):")
        for n in sorted(set(shown_for)):
            k = shown_for.count(n)
            print(f"    {n:3d}: {k:6d} ({100 * k / len(shown_for):.1f}%)")

    # Visible cursor movement per host frame
    shown = []  # (t, seq or None, cursor pos)
    cur_seq = None
    for t, s, _, _ in hframes:
        if s >= 0:
            cur_seq = s
        if cur_seq is not None and cur_seq in fcursor:
            shown.append((t, s if s >= 0 else None, cur_seq))
    disp = []
    for (t0, _, s0), (t1, new, s1) in zip(shown, shown[1:]):
        (x0, y0), (x1, y1) = fcursor[s0], fcursor[s1]
        disp.append((t1, new, s0, s1, ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5))

    causes = {}
    moving = 0
    W = 10
    for i, (t, new, s0, s1, d) in enumerate(disp):
        win = [x[4] for x in disp[max(0, i - W) : i + W + 1] if x[4] > 0]
        if len(win) < W:
            continue
        m = st.median(win)
        if m < 2:
            continue
        moving += 1
        if 0.5 * m <= d <= 1.6 * m:
            continue
        kind = "stall" if d < 0.5 * m else "jump"
        if new is None:
            cause = "no new guest frame for this host refresh"
        else:
            t0, t1 = gframe_t.get(s0), gframe_t.get(s1)
            nskip = bisect_left(skip_t, t1) - bisect_right(skip_t, t0) if t0 and t1 else 0
            napply = bisect_left(apply_t, t1) - bisect_right(apply_t, t0) if t0 and t1 else -1
            if nskip > 0:
                cause = "guest frame(s) skipped before this one"
            elif napply == 0:
                cause = "guest cursor: no new position reached the guest that frame"
            elif napply >= 2:
                cause = "guest cursor: several positions reached the guest that frame"
            else:
                cause = "guest cursor: other"
        causes[(kind, cause)] = causes.get((kind, cause), 0) + 1

    print(f"\nHost frames while the cursor moves steadily: {moving}")
    bad = sum(causes.values())
    if moving:
        print(f"  uneven (stall <0.5x or jump >1.6x the local median step): {bad} ({100 * bad / moving:.1f}%)")
    for (kind, cause), n in sorted(causes.items(), key=lambda kv: -kv[1]):
        print(f"    {n:5d}  {kind:5s}  {cause}")


if __name__ == "__main__":
    main(sys.argv[1])
