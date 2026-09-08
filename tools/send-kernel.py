#!/usr/bin/env python3
"""Push a freshly built RV64 kernel to the board over the serial console.

The board's rootfs is an initramfs living in RAM, so a new kernel can be dropped
straight into /root without touching the SD card. That turns the edit/test cycle
into about 13 seconds instead of a card swap.

    ./tools/send-kernel.py ~/xv6-riscv/kernel/kernel

Four things this gets right, each of which cost a debugging session to learn:

  * --strip-debug first. A `-ggdb -gdwarf-2` xv6 kernel is ~84% DWARF: 274KB
    becomes 44KB. fesvr only needs the symbol table (it looks up `tohost` and
    `fromhost`), which --strip-debug keeps.
  * gzip before base64, because the console is the bottleneck.
  * Wrap the base64 in lines. The tty is in canonical mode, whose line buffer is
    4096 bytes; sending one long line silently discards everything past that.
  * Pace below the line rate. There is no hardware flow control, so an overrun
    on the Zynq UART would corrupt the file with no indication.

The transfer is md5-verified on the board before it replaces the old kernel.
"""

import base64
import glob
import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import time

import serial

# The PYNQ-Z1's own FT2232H exposes two interfaces: 00 is JTAG, 01 is the PS
# UART0 console. A third ttyUSB only shows up when some other FTDI device is
# also plugged in, which is why a hardcoded /dev/ttyUSB2 works on one desk and
# talks to the wrong device on the next. The number is not stable either -- it
# moves every time the board is power cycled and its bridge re-enumerates. So
# resolve by the by-id name, which does stay put, and let $XV6_CONSOLE win.
def find_console():
    override = os.environ.get("XV6_CONSOLE")
    if override:
        return override
    byid = sorted(glob.glob(
        "/dev/serial/by-id/usb-Digilent*Adept*-if01-port0"))
    if byid:
        return os.path.realpath(byid[0])
    ports = sorted(glob.glob("/dev/ttyUSB*"))
    if len(ports) == 1:
        return ports[0]
    sys.exit("cannot identify the console port; set XV6_CONSOLE=/dev/ttyUSBn "
             "(found: %s)" % (", ".join(ports) or "none"))


PORT = find_console()
BAUD = 115200
DEST = "/root/xv6-kernel"
STRIP = "riscv64-unknown-elf-strip"

CHUNK_LINE = 76
DELAY = 0.004  # per line; the 115200 line itself caps throughput at ~11.5 KB/s


def main():
    if len(sys.argv) < 2:
        sys.exit(f"usage: {sys.argv[0]} <kernel-elf> [dest] [port]")
    src = sys.argv[1]
    dest = sys.argv[2] if len(sys.argv) > 2 else DEST
    port = sys.argv[3] if len(sys.argv) > 3 else PORT

    stripped = "/tmp/send-kernel-payload"
    shutil.copy(src, stripped)
    subprocess.check_call([STRIP, "--strip-debug", stripped])

    raw = open(stripped, "rb").read()
    md5 = hashlib.md5(raw).hexdigest()
    b64 = base64.b64encode(gzip.compress(raw, 9))
    lines = [b64[i:i + CHUNK_LINE] for i in range(0, len(b64), CHUNK_LINE)]
    print(f"{len(raw)} bytes (md5 {md5}) -> {len(b64)} base64 in {len(lines)} lines")

    s = serial.Serial(port, BAUD, timeout=0)

    def cmd(c, wait=0.8):
        s.write(c.encode() + b"\n")
        s.flush()
        time.sleep(wait)
        return s.read(262144).decode(errors="replace")

    s.reset_input_buffer()

    # Preflight: make sure we are talking to ARM Linux and not to a still-running
    # xv6. Sending 100KB+ of base64 into xv6 wedges the console for minutes while
    # its console echo drags every byte back over HTIF.
    for _ in range(3):
        s.write(b"\x03")
        s.flush()
        time.sleep(0.15)
    s.read(262144)
    s.write(b"\n")
    time.sleep(0.4)
    s.read(262144)
    s.write(b"echo LINUX-$$\n")
    s.flush()
    time.sleep(1.2)
    probe = s.read(262144).decode(errors="replace")
    if "LINUX-" not in probe:
        print("PREFLIGHT FAILED -- not at an ARM Linux prompt. Got:")
        print(repr(probe[-500:]))
        return 1
    print("preflight ok: at ARM Linux prompt")

    cmd("rm -f /root/k.new /root/k.gz; stty -echo; echo READY")

    s.write(b"base64 -d > /root/k.gz\n")
    s.flush()
    time.sleep(0.5)
    s.read(65536)

    t0 = time.time()
    for n, ln in enumerate(lines):
        s.write(ln + b"\n")
        s.flush()
        time.sleep(DELAY)
        if n and n % 400 == 0:
            print(f"  {100.0 * n / len(lines):5.1f}%  {time.time() - t0:.0f}s", flush=True)
            s.read(65536)

    s.write(b"\x04")  # EOF, so base64 -d finishes
    s.flush()
    print(f"sent in {time.time() - t0:.1f}s")
    time.sleep(1.0)
    s.read(262144)

    out = cmd("stty echo; gunzip -c /root/k.gz > /root/k.new; md5sum /root/k.new", 3.0)
    if md5 in out:
        print("md5 matches -- installing")
        cmd(f"mv /root/k.new {dest}; rm -f /root/k.gz", 1.0)
        rc = 0
    else:
        print(f"MD5 MISMATCH -- expected {md5}; not installing")
        print(out)
        rc = 1
    s.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
