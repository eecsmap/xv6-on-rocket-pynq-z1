#!/usr/bin/env python3
"""Capture the board's console across a power cycle. Read-only.

    ./tools/serial-listen.py 600        # watch for ten minutes, then stop

Start it *before* powering the board on. Boot output begins within about two
seconds of power and there is no way to ask for it again, so a listener attached
afterwards has already missed the FSBL and most of u-boot.

Nothing is ever written to a port. That is deliberate: any byte arriving during
u-boot's autoboot countdown stops it at `zynq-uboot>`, so a listener that echoes
or probes would change the boot it was started to observe. Ports are opened
O_RDONLY with CLOCAL set, and the modem control lines are left alone.

The part that is easy to get wrong -- and the reason this exists rather than a
`screen` invocation -- is that **the device node does not survive a power
cycle**. Powering the board cycles its FTDI bridge, so the node is destroyed and
recreated, usually under a different number (ttyUSB1 -> ttyUSB3 -> ...). Two
consequences:

  * A listener that opens once and blocks on read sees nothing, ever. It is not
    watching a port any more, it is holding a dead descriptor. Worse, it does
    not notice: with the node gone, select() simply never reports readable, so
    read() is never called and never returns the error that would have revealed
    it. Reconnect-on-error logic never fires.
  * Watching a fixed path -- even a stable /dev/serial/by-id/ one -- is not
    enough either, for the same reason: the name is stable, the inode is not.

So this rescans instead. Every 300 ms it looks for ttyUSB*/ttyACM* nodes it is
not already reading and attaches to whatever it finds, which means it picks the
board back up a fraction of a second after it re-enumerates, whatever number it
came back as. Everything is logged per node under /tmp/serial/.

docs/JTAG-DEBUGGING.md has the same warning in prose.
"""

import glob
import os
import select
import sys
import termios
import threading
import time

BAUD = termios.B115200
LOGDIR = "/tmp/serial"
RESCAN = 0.3


def open_ro(path):
    """Open read-only, no controlling tty, modem lines ignored."""
    fd = os.open(path, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        cc = list(termios.tcgetattr(fd)[6])
        cc[termios.VMIN] = 0
        cc[termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, [
            0, 0,
            BAUD | termios.CS8 | termios.CREAD | termios.CLOCAL,
            0, BAUD, BAUD, cc])
    except Exception:
        os.close(fd)
        raise
    return fd


def stamp():
    return time.strftime("%H:%M:%S")


def watch(path, deadline, watched, lock):
    """Read one node until it disappears, then let the scanner re-adopt it."""
    name = os.path.basename(path)
    log = os.path.join(LOGDIR, name + ".log")
    total = 0
    try:
        fd = open_ro(path)
    except OSError:
        with lock:
            watched.discard(path)
        return
    print("[%s] + %s -> %s" % (stamp(), name, log), flush=True)
    try:
        with open(log, "ab", buffering=0) as f:
            while time.time() < deadline:
                if not select.select([fd], [], [], 0.5)[0]:
                    continue
                data = os.read(fd, 4096)      # raises once the node is gone
                if data:
                    if total == 0:
                        print("[%s] *** %s: first bytes ***" % (stamp(), name),
                              flush=True)
                    total += len(data)
                    f.write(data)
    except OSError:
        print("[%s] - %s went away after %d bytes (re-enumerating?)"
              % (stamp(), name, total), flush=True)
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        with lock:
            watched.discard(path)
    if total:
        print("[%s] %s: %d bytes" % (stamp(), name, total), flush=True)


def main():
    duration = int(sys.argv[1]) if len(sys.argv) > 1 else 900
    deadline = time.time() + duration
    os.makedirs(LOGDIR, exist_ok=True)
    watched, lock, threads = set(), threading.Lock(), []
    print("[%s] scanning for serial ports, read-only, %ds" % (stamp(), duration),
          flush=True)
    while time.time() < deadline:
        for path in sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*")):
            with lock:
                if path in watched:
                    continue
                watched.add(path)
            t = threading.Thread(target=watch,
                                 args=(path, deadline, watched, lock))
            t.start()
            threads.append(t)
        time.sleep(RESCAN)
    for t in threads:
        t.join()
    print("[%s] done, logs in %s/" % (stamp(), LOGDIR), flush=True)


if __name__ == "__main__":
    main()
