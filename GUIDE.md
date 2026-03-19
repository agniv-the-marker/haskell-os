# Running HaskellOS on your Pi Zero

So you want to run Haskell on bare metal. Here's how.

## What you need

Hardware wise its the same spec as CS140E, software it's also the same but we use `screen` for serial communication and `mhs` for the MicroHs compiler.

## Installing MicroHs

You need GHC and Cabal to build it:

```bash
# if you don't have ghcup:
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh

cabal update
cabal install MicroHs
```

If cabal complains about `libtinfo` or `libgmp`:

```bash
mkdir -p ~/.local/lib
ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 ~/.local/lib/libtinfo.so
ln -sf /usr/lib/x86_64-linux-gnu/libgmp.so.10 ~/.local/lib/libgmp.so
LIBRARY_PATH=~/.local/lib cabal install MicroHs
```

Make sure `~/.cabal/bin` is in your PATH:

```bash
export PATH="$HOME/.ghcup/bin:$HOME/.local/bin:$HOME/.cabal/bin:$PATH"
```

Check it works:

```bash
mhs --version                # MicroHs 0.15.0.0 or similar
arm-none-eabi-gcc --version  # should already be there from cs140e
```

## Building

```bash
make                # builds kernel.img with everything
make test-blink     # just GPIO blink test
make test-echo      # just UART echo test
make test-ls        # just FAT32 directory listing
make test-nrf       # NRF loopback test (two NRFs on one Pi)
make test-lisp      # Lisp interpreter + parser combinator test
make test-process   # Process (Chan, spawn, select) test
make test-vm        # VM (page tables, MMU enable/disable) test
make test-interrupt # Interrupt (timer ticks, UART RX) test
make test-shell     # Shell (processCommand) test
make clean && make  # full rebuild
```

What `make` actually does:
1. `mhs` compiles all Haskell into one C file (`build/hs_generated.c`)
2. `arm-none-eabi-gcc` cross-compiles that + eval.c + HAL code for ARM
3. Linker puts it all together using the `memmap` linker script
4. `objcopy` strips it down to a raw binary `kernel.img`

## SD card setup

Same deal as cs140e. You need the GPU firmware files on the card:

```
SD_CARD/
├── bootcode.bin      # from cs140e / raspberrypi/firmware repo
├── start_cd.elf      # cut-down GPU firmware
├── fixup_cd.dat      # GPU memory fixup
├── config.txt        # see below
└── kernel.img        # your compiled kernel
```

`config.txt`:
```
kernel=kernel.img
kernel_old=1
disable_commandline_tags=1
enable_uart=1
start_file=start_cd.elf
fixup_file=fixup_cd.dat
```

Copy your kernel:
```bash
cp kernel.img /media/$USER/boot/kernel.img
sync
```

Or `make install SDCARD=/media/$USER/boot`.

For FAT32/LISP tests, throw some files on there too:
```bash
cp DEMO.LSP /media/$USER/boot/DEMO.LSP
```

To interact with it, run 

```bash
screen /dev/ttyUSB0 115200
```

## What you should see

Power on the Pi and you'll get:

```
  _   _           _        _ _  ___  ____
 | | | | __ _ ___| | _____| | |/ _ \/ ___|
 | |_| |/ _` / __| |/ / _ \ | | | | \___ \
 |  _  | (_| \__ \   <  __/ | | |_| |___) |
 |_| |_|\__,_|___/_|\_\___|_|_|\___/|____/

Bare-metal Haskell OS for Raspberry Pi Zero
============================================
Boot time: ... us
GPIO: Blinking pin 27 (3x)...
GPIO: Done

Enabling interrupts...
Timer + UART interrupts enabled

Attempting FAT32 mount...
FAT32: Mounted successfully

Enabling MMU...
MMU enabled

Supervisor: Starting children...
  Starting: heartbeat
  Starting: shell

====================================
 HaskellOS Shell
 Type 'help' for available commands
====================================
haskell-os>
```

## Shell commands

| Command | What it does |
|---------|-------------|
| `help` | list all commands |
| `blink [pin] [n]` | blink GPIO pin (default: pin 27, 5 times) |
| `echo` | echo typed characters, Ctrl-D to exit |
| `timer` | show system timer |
| `gpio <pin> [0\|1]` | read or write a GPIO pin |
| `ls` | list files on SD card |
| `cat <file>` | print file contents |
| `touch <file>` | create empty file |
| `write <file> <text>` | write text to file |
| `rm <file>` | delete file |
| `mv <old> <new>` | rename file |
| `info` | show FAT32 filesystem info |
| `vm` | show MMU status and verify device access |
| `heartbeat [on\|off]` | toggle background LED heartbeat (forkIO green thread) |
| `uptime` | show uptime from hardware timer interrupts |
| `nrf init [server\|client]` | init NRF radio (server=left CE=6/SPI=0, client=right CE=5/SPI=1) |
| `nrf send <msg>` | send a string message over NRF |
| `nrf recv` | receive a message (blocking with timeout) |
| `nrf stats` | show NRF send/recv/retransmit/lost counters |
| `nrf status` | read NRF STATUS register |
| `lisp` | start Lisp interpreter REPL (type `(exit)` to quit) |
| `lisp run <file>` | run a Lisp file from SD card (e.g. `lisp run FACT.LSP`) |
| `reboot` | reboot the Pi |
