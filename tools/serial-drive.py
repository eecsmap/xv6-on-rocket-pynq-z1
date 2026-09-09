#!/usr/bin/env python3
"""Drive the board's console: send commands, capture output.

Unlike serial-listen.py this one writes, so it is only safe once the board is
past u-boot -- a byte during the autoboot countdown stops it at zynq-uboot>.
"""
import glob, os, sys, time, serial

BY_ID = "/dev/serial/by-id/usb-Digilent*Adept*-if01-port0"

def port():
    m = sorted(glob.glob(BY_ID))
    if not m:
        sys.exit("no Digilent if01 console found")
    return os.path.realpath(m[0])

def drain(s, seconds, log=None, echo=True):
    """Read for `seconds`, returning everything seen."""
    buf, end = b"", time.time() + seconds
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            if log: log.write(d); log.flush()
            if echo: sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
            end = max(end, time.time() + 1.0)   # extend while data keeps coming
        else:
            time.sleep(0.05)
    return buf

def main():
    p = port()
    s = serial.Serial(p, 115200, timeout=0.2)
    print(f"### {p}", flush=True)
    mode = sys.argv[1] if len(sys.argv) > 1 else "probe"
    def expect(pat, timeout, label):
        """Read until `pat` appears, or give up. Returns (ok, text)."""
        buf, end = b"", time.time() + timeout
        while time.time() < end:
            d = s.read(4096)
            if d:
                buf += d
                log.write(d); log.flush()
                sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
                if pat.encode() in buf:
                    return True, buf.decode("utf-8", "replace")
            else:
                time.sleep(0.05)
        print(f"\n### TIMEOUT waiting for {label!r} after {timeout}s", flush=True)
        return False, buf.decode("utf-8", "replace")

    def send(line):
        print(f"\n### >>> {line!r}", flush=True)
        s.write(line.encode() if isinstance(line, str) else line)
        s.flush()

    if mode == "usertests":
        log = open("/home/engineer/fpga/usertests-driven.log", "wb", buffering=0)
        # Leave fesvr if xv6 is running; Ctrl-C returns to the ARM shell.
        send(b"\x03"); time.sleep(1); drain(s, 2, log)
        send("\r"); ok, _ = expect("#", 10, "ARM shell")
        if not ok: sys.exit("not at the ARM shell; aborting")
        # A crashed run leaves the log dirty, which shows up next boot as
        # "ireclaim: orphaned inode" or "panic: freeing free block".
        send("cp /root/fs.img.orig /root/fs.img\r"); expect("#", 30, "copy done")
        send("cd /root && ./fesvr-zynq +blkdev=fs.img ./xv6-kernel\r")
        ok, _ = expect("init: starting sh", 120, "xv6 boot")
        if not ok: sys.exit("xv6 did not boot")
        time.sleep(1)
        send("usertests\r")
        t0 = time.time()
        ok, out = expect("ALL TESTS PASSED", 3000, "usertests")
        el = time.time() - t0
        print(f"\n### usertests finished in {el:.0f}s, passed={ok}", flush=True)
        log.close()
    elif mode == "probe":
        s.write(b"\r")                       # a bare newline: safe at any shell
        out = drain(s, 3)
        print("\n### verdict:", flush=True)
        t = out.decode("utf-8", "replace")
        if "~ #" in t or "/root #" in t: print("###   ARM shell")
        elif t.rstrip().endswith("$"):        print("###   xv6 shell")
        elif not t.strip():                   print("###   silent")
        else:                                 print("###   unrecognised")
    s.close()

main()
