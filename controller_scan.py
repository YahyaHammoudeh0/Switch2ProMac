#!/usr/bin/env python3
"""
controller_scan.py - live HID scanner for reverse-engineering a controller's report layout.

Part of scoping the "dynamic virtual controller" idea: before we can re-present a
controller as something else, we have to *understand* its raw HID reports. This tool:

  list     - enumerate connected HID devices (flags Nintendo VID 0x057E)
  monitor  - open a device and show which report bytes change as you move things,
             so we can locate the analog sticks and measure their REAL range.

Workflow:
  1. bash pro2steam.sh                 # put the controller into HID mode first
  2. .venv/bin/python controller_scan.py list
  3. .venv/bin/python controller_scan.py monitor      # auto-picks the Nintendo device
     ...then wiggle the LEFT stick in full circles, then the RIGHT, then triggers.
     Watch which byte rows light up + how wide their [min..max] gets. Ctrl-C for a summary.
"""
import argparse
import sys
import time

try:
    import hid
except ImportError:
    sys.exit("Missing hidapi. Activate the venv first: source .venv/bin/activate")

NINTENDO_VID = 0x057E
REPORT_LEN = 64
HOT_WINDOW = 0.6          # seconds a byte stays highlighted after it last changed
QUIET_SPREAD = 4          # bytes that never move more than this are dimmed


def _tty():
    return sys.stdout.isatty()


RESET, BOLD, DIM, HOT = "\033[0m", "\033[1m", "\033[2m", "\033[1;33m"


def c(s, code):
    return f"{code}{s}{RESET}" if _tty() else str(s)


def cmd_list(_args):
    devs = hid.enumerate()
    if not devs:
        print("No HID devices found. Is the controller plugged in and initialized?")
        return
    print(f"{'VID:PID':<15}{'Usage pg/id':<14}Product / Manufacturer")
    print("-" * 64)
    for d in devs:
        vid, pid = d.get("vendor_id", 0), d.get("product_id", 0)
        usage = f"{d.get('usage_page', 0):#06x}/{d.get('usage', 0):#04x}"
        name = (d.get("product_string") or "?").strip()
        manu = (d.get("manufacturer_string") or "").strip()
        tag = c("  <- Nintendo", HOT) if vid == NINTENDO_VID else ""
        print(f"{vid:#06x}:{pid:#06x}   {usage:<14}{name} / {manu}{tag}")


def _open_gamepad(args):
    """Open the Game Pad HID collection for the requested (or Nintendo) device."""
    vid = args.vid if args.vid is not None else NINTENDO_VID
    devs = hid.enumerate(vid, args.pid or 0)
    if not devs:
        sys.exit(f"No HID device for VID={vid:#06x} PID={args.pid or 0:#06x}. "
                 f"Run `list` first (and make sure Steam isn't holding the device).")
    # Prefer the Game Pad collection (Generic Desktop page 0x01, usage 0x05) -
    # that's the one carrying stick/button reports; other collections are noise.
    target = next(
        (d for d in devs if d.get("usage_page") == 0x01 and d.get("usage") == 0x05),
        devs[0],
    )
    h = hid.device()
    h.open_path(target["path"])
    h.set_nonblocking(True)
    return h, target, vid


def cmd_capture(args):
    h, target, vid = _open_gamepad(args)
    name = (target.get("product_string") or "?").strip()
    print(f"Capturing {args.seconds:.0f}s from {name} ({vid:#06x}:{target['product_id']:#06x}).")
    print(">>> NOW: roll the LEFT stick in full circles a few times, then the RIGHT stick,")
    print("    then squeeze both triggers and mash some buttons. <<<\n")

    mins = [None] * REPORT_LEN
    maxs = [None] * REPORT_LEN
    length = REPORT_LEN
    start = time.time()
    last_note = -1
    try:
        while (time.time() - start) < args.seconds:
            r = h.read(REPORT_LEN)
            if r:
                length = len(r)
                for i, b in enumerate(r):
                    if mins[i] is None:
                        mins[i] = maxs[i] = b
                    else:
                        mins[i] = min(mins[i], b)
                        maxs[i] = max(maxs[i], b)
            remaining = int(args.seconds - (time.time() - start))
            if remaining != last_note:
                sys.stdout.write(f"\r  {remaining:>2}s left... ")
                sys.stdout.flush()
                last_note = remaining
            time.sleep(0.002)
    except KeyboardInterrupt:
        pass
    finally:
        h.close()
    print("\n")
    _summary(mins, maxs, length)


def cmd_monitor(args):
    h, target, vid = _open_gamepad(args)
    name = (target.get("product_string") or "?").strip()
    print(f"Opened {name} ({vid:#06x}:{target['product_id']:#06x}). "
          f"Move sticks/triggers. Ctrl-C to stop.\n")

    mins = [None] * REPORT_LEN
    maxs = [None] * REPORT_LEN
    last_change = [0.0] * REPORT_LEN
    cur = [0] * REPORT_LEN
    prev = None
    length = REPORT_LEN
    next_frame = 0.0

    try:
        while True:
            r = h.read(REPORT_LEN)
            now = time.time()
            if r:
                length = len(r)
                for i, b in enumerate(r):
                    if mins[i] is None:
                        mins[i] = maxs[i] = b
                    else:
                        mins[i] = min(mins[i], b)
                        maxs[i] = max(maxs[i], b)
                    if prev is not None and i < len(prev) and prev[i] != b:
                        last_change[i] = now
                    cur[i] = b
                prev = r
            if now >= next_frame:
                _render(cur, mins, maxs, last_change, now, length)
                next_frame = now + 1 / 30
            time.sleep(0.002)
    except KeyboardInterrupt:
        pass
    finally:
        h.close()
        _summary(mins, maxs, length)


def _render(cur, mins, maxs, last_change, now, length):
    rows = [c("byte  hex dec  [ min.. max]  spread  activity", BOLD)]
    for i in range(length):
        if mins[i] is None:
            continue
        spread = maxs[i] - mins[i]
        bar = "#" * int((spread / 255) * 24)
        row = (f"{i:>3}   {cur[i]:02x} {cur[i]:>3}  "
               f"[{mins[i]:>4}..{maxs[i]:>4}]  {spread:>4}   {bar}")
        if (now - last_change[i]) < HOT_WINDOW:
            row = c(row, HOT)
        elif spread <= QUIET_SPREAD:
            row = c(row, DIM)
        rows.append(row)
    sys.stdout.write(("\033[H\033[J" if _tty() else "\n\n") + "\n".join(rows) + "\n")
    sys.stdout.flush()


def _summary(mins, maxs, length):
    print("\n\n=== Byte activity (widest spread = most likely an analog axis) ===")
    spreads = sorted(
        ((maxs[i] - mins[i], i) for i in range(length) if mins[i] is not None),
        reverse=True,
    )
    for spread, i in spreads[:12]:
        print(f"  byte {i:>2}: {mins[i]:>4}..{maxs[i]:>4}   (spread {spread})")
    print("\nNintendo sticks pack 2 axes into 3 bytes (12 bits each):")
    print("  X = b0 | ((b1 & 0x0F) << 8)      Y = (b1 >> 4) | (b2 << 4)")
    print("So look for a run of 3 adjacent high-spread bytes = one stick.")
    print("The spread also tells us the real range: if a 12-bit axis only spans")
    print("~1024..3072 instead of 0..4095, that's the ~50% problem, quantified.")


def _record(h, seconds, label):
    """Read reports for `seconds`; return (frames, length) where frames is a list of int-lists."""
    frames, length, start, last = [], 0, time.time(), -1
    while (time.time() - start) < seconds:
        r = h.read(REPORT_LEN)
        if r:
            length = max(length, len(r))
            frames.append(list(r))
        rem = int(seconds - (time.time() - start))
        if rem != last:
            sys.stdout.write(f"\r  [{label}] recording... {rem:>2}s ")
            sys.stdout.flush()
            last = rem
        time.sleep(0.001)
    sys.stdout.write("\r" + " " * 44 + "\r")
    sys.stdout.flush()
    return frames, length


def _envelope(frames, length):
    lo, hi = [255] * length, [0] * length
    for f in frames:
        for i in range(min(len(f), length)):
            lo[i], hi[i] = min(lo[i], f[i]), max(hi[i], f[i])
    return lo, hi


def _decode12(b0, b1, b2):
    """Standard Nintendo 3-byte -> two 12-bit axes packing."""
    return b0 | ((b1 & 0x0F) << 8), (b1 >> 4) | (b2 << 4)


def cmd_find(args):
    h, target, vid = _open_gamepad(args)
    name = (target.get("product_string") or "?").strip()
    print(f"Finding sticks on {name} ({vid:#06x}:{target['product_id']:#06x}).")
    print("Key idea: the motion sensor + counter bytes move no matter what, so we compare")
    print("REST vs MOVE and keep only the bytes that light up when a specific stick moves.\n")

    input("[1/3] Hold the controller STILL, hands OFF the sticks/buttons. Press Enter, then don't move it...")
    base, length = _record(h, 3.0, "rest")
    blo, bhi = _envelope(base, length)

    input("\n[2/3] Roll ONLY the LEFT stick in full circles, pushing hard to the edges.\n"
          "      Keep the controller body still. Press Enter to start...")
    left, _ = _record(h, 5.0, "left")

    input("\n[3/3] Now roll ONLY the RIGHT stick, hard to the edges.\n"
          "      Keep the controller body still. Press Enter to start...")
    right, _ = _record(h, 5.0, "right")
    h.close()

    MARGIN = 8  # ignore small rest jitter from the motion sensor

    def analyze(stick_name, frames):
        lo, hi = _envelope(frames, length)
        flagged = [i for i in range(length)
                   if lo[i] < blo[i] - MARGIN or hi[i] > bhi[i] + MARGIN]
        print(f"\n=== {stick_name} STICK ===")
        if not flagged:
            print("  (nothing moved beyond rest - try again, pushing the stick harder)")
            return
        for i in flagged:
            rest_mid = (blo[i] + bhi[i]) // 2
            print(f"  byte {i:>2}: rest~{rest_mid:>3}   moved {lo[i]:>3}..{hi[i]:>3}")
        # Look for 3 adjacent flagged bytes = a classic Nintendo stick triplet, and decode it.
        triplets = [(i, i + 1, i + 2) for i in flagged
                    if (i + 1 in flagged and i + 2 in flagged)]
        for a, b, c in triplets:
            mv = [_decode12(f[a], f[b], f[c]) for f in frames if c < len(f)]
            rest = [_decode12(f[a], f[b], f[c]) for f in base if c < len(f)]
            if not mv:
                continue
            xs, ys = [p[0] for p in mv], [p[1] for p in mv]
            cx = sum(p[0] for p in rest) // len(rest) if rest else 0
            cy = sum(p[1] for p in rest) // len(rest) if rest else 0
            xr, yr = max(xs) - min(xs), max(ys) - min(ys)
            print(f"  -> triplet [{a},{b},{c}] as 12-bit (center should read ~2048):")
            print(f"       rest center: X={cx}  Y={cy}")
            print(f"       X {min(xs):>4}..{max(xs):<4} span {xr:>4}  = {xr / 4095 * 100:3.0f}% of full range")
            print(f"       Y {min(ys):>4}..{max(ys):<4} span {yr:>4}  = {yr / 4095 * 100:3.0f}% of full range")

    analyze("LEFT", left)
    analyze("RIGHT", right)
    print("\nPaste all of this back. If a triplet's rest center reads ~2048 and the span is")
    print("well under 4095, that's the sticks found + the 50% problem quantified.")


LEFT_STICK, RIGHT_STICK = (6, 7, 8), (9, 10, 11)  # discovered via `find`


def _norm(v, lo, ctr, hi):
    """Map raw 12-bit value to -1..+1, stretching each half around center independently."""
    if v >= ctr:
        return min(1.0, (v - ctr) / (hi - ctr)) if hi > ctr else 0.0
    return max(-1.0, (v - ctr) / (ctr - lo)) if ctr > lo else 0.0


def _bar(val, half=10):
    pos = int(round(val * half))
    cells = []
    for k in range(-half, half + 1):
        cells.append("|" if k == 0 else
                     ("=" if (0 < k <= pos or pos <= k < 0) else " "))
    return "".join(cells)


def cmd_cal(args):
    h, target, vid = _open_gamepad(args)
    name = (target.get("product_string") or "?").strip()
    print(f"Live calibration preview for {name} ({vid:#06x}:{target['product_id']:#06x}).")
    print("Sweep BOTH sticks to their edges once so it learns your range, then compare")
    print("these calibrated %s against Steam's test screen at the same stick position.")
    print("Ctrl-C to stop.\n")

    sticks = (LEFT_STICK, RIGHT_STICK)
    # Brief rest sample -> per-axis centers.
    acc = {s: ([], []) for s in sticks}
    t0 = time.time()
    while time.time() - t0 < 0.5:
        r = h.read(REPORT_LEN)
        if r and len(r) > 11:
            for s in sticks:
                x, y = _decode12(r[s[0]], r[s[1]], r[s[2]])
                acc[s][0].append(x)
                acc[s][1].append(y)
        time.sleep(0.002)
    ctr = {s: (sum(acc[s][0]) // max(1, len(acc[s][0])) or 2048,
               sum(acc[s][1]) // max(1, len(acc[s][1])) or 2048) for s in sticks}
    lo = {s: [ctr[s][0], ctr[s][1]] for s in sticks}
    hi = {s: [ctr[s][0], ctr[s][1]] for s in sticks}
    cur = {s: [ctr[s][0], ctr[s][1]] for s in sticks}

    next_frame = 0.0
    try:
        while True:
            r = h.read(REPORT_LEN)
            now = time.time()
            if r and len(r) > 11:
                for s in sticks:
                    for ax, val in enumerate(_decode12(r[s[0]], r[s[1]], r[s[2]])):
                        cur[s][ax] = val
                        lo[s][ax] = min(lo[s][ax], val)
                        hi[s][ax] = max(hi[s][ax], val)
            if now >= next_frame:
                out = ["\033[H\033[J" if _tty() else "\n"]
                out.append("  stick  raw   calibrated")
                for label, s in (("LEFT ", LEFT_STICK), ("RIGHT", RIGHT_STICK)):
                    for ax, axn in ((0, "X"), (1, "Y")):
                        n = _norm(cur[s][ax], lo[s][ax], ctr[s][ax], hi[s][ax])
                        out.append(f"  {label}{axn}  {cur[s][ax]:>4}   {n * 100:+4.0f}%  [{_bar(n)}]")
                out.append(f"\n  learned range so far: L=[{lo[LEFT_STICK]}..{hi[LEFT_STICK]}] "
                           f"R=[{lo[RIGHT_STICK]}..{hi[RIGHT_STICK]}]")
                out.append("  push a stick fully and hold: calibrated should read ~+100% / -100%.")
                sys.stdout.write("\n".join(out) + "\n")
                sys.stdout.flush()
                next_frame = now + 1 / 30
            time.sleep(0.002)
    except KeyboardInterrupt:
        pass
    finally:
        h.close()


def _add_dev_args(parser):
    parser.add_argument("--vid", type=lambda x: int(x, 0), default=None, help="e.g. 0x057e")
    parser.add_argument("--pid", type=lambda x: int(x, 0), default=None, help="e.g. 0x2069")


def main():
    p = argparse.ArgumentParser(description="Live HID scanner for controller reports.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="enumerate connected HID devices")
    _add_dev_args(sub.add_parser("monitor", help="watch report bytes change live (Ctrl-C for summary)"))
    cap = sub.add_parser("capture", help="record min/max over N seconds, then print a paste-friendly summary")
    _add_dev_args(cap)
    cap.add_argument("--seconds", type=float, default=8.0, help="capture duration (default 8)")
    _add_dev_args(sub.add_parser("find", help="guided rest-vs-move capture to locate the stick bytes + measure range"))
    _add_dev_args(sub.add_parser("cal", help="live calibrated stick readout (compare against Steam's test screen)"))
    args = p.parse_args()
    {"list": cmd_list, "monitor": cmd_monitor, "capture": cmd_capture,
     "find": cmd_find, "cal": cmd_cal}[args.cmd](args)


if __name__ == "__main__":
    main()
