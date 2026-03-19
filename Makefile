#
# Makefile - HaskellOS build system (MicroHs)
#
# asked claude to help a lot with this. basically
# the idea is to use mhs to compile down all the haskell into a c file
# then compile the c file onto bare metal pi based on the prev. labs
# 
# based on /defs.mk, Makefile.template-fixed
#
# Usage:
#   make              - build kernel.img
#   make test-blink   - build GPIO blink test (lab 2 equivalent)
#   make test-echo    - build UART echo test (lab 7 equivalent)
#   make test-ls      - build FAT32 listing test (lab 16 equivalent)
#   make test-lisp    - build Lisp interpreter test
#   make clean        - clean build artifacts
#   make install      - copy kernel.img to SD card
#

# -------------------------------------------------------
# Toolchain
# -------------------------------------------------------
ARM     := arm-none-eabi
CC      := $(ARM)-gcc
LD      := $(ARM)-ld
OBJCOPY := $(ARM)-objcopy
OBJDUMP := $(ARM)-objdump

# MicroHs compiler (Haskell → C)
MHS     := mhs

# MicroHs runtime directory (contains eval.c, mhsffi.h, etc.)
MHS_RUNTIME := $(shell find ~/.cabal/store -path "*/MicroHs-*/runtime/eval.c" 2>/dev/null | head -1 | xargs dirname)

# -------------------------------------------------------
# Flags
# -------------------------------------------------------
CFLAGS := -O2 -Wall -Wno-unused-variable -Wno-unused-function
CFLAGS += -Wno-unused-but-set-variable -Wno-unused-label
CFLAGS += -nostdlib -nostartfiles -ffreestanding
CFLAGS += -mcpu=arm1176jzf-s -mno-unaligned-access
CFLAGS += -std=gnu99
CFLAGS += -I./c -I$(MHS_RUNTIME)

# Extra flags for eval.c (it's large and has some warnings)
EVAL_CFLAGS := $(CFLAGS) -Wno-unused-parameter -Wno-sign-compare
EVAL_CFLAGS += -Wno-missing-field-initializers -Wno-old-style-definition
EVAL_CFLAGS += -Wno-error -w

# Extra flags for generated Haskell C code
GEN_CFLAGS := $(CFLAGS) -Wno-error -w

ASFLAGS := -mcpu=arm1176jzf-s

# Link flags: use newlib's libc.a for setjmp/longjmp (architecture-specific ASM)
LIBC    := $(shell $(CC) -print-file-name=libc.a)
LIBGCC  := $(shell $(CC) -print-libgcc-file-name)
LDFLAGS := -T memmap -nostdlib

# -------------------------------------------------------
# Source files
# -------------------------------------------------------
ASM_SRCS := asm/boot.S asm/hal-asm.S

C_SRCS   := c/cstart.c c/hal.c c/rts-stubs.c c/sd.c c/emmc.c c/spi.c

HS_SRCS  := hs/Hal.hs hs/GPIO.hs hs/UART.hs hs/Timer.hs \
            hs/Alloc.hs hs/Interrupt.hs hs/FAT32.hs hs/VM.hs \
            hs/SPI.hs hs/NRF.hs \
            hs/Process.hs hs/NetChan.hs \
            hs/Parse.hs hs/Lisp.hs \
            hs/Shell.hs hs/Main.hs

# -------------------------------------------------------
# Object files
# -------------------------------------------------------
ASM_OBJS := $(ASM_SRCS:.S=.o)
C_OBJS   := $(C_SRCS:.c=.o)

# MicroHs generates a single C file, which gets compiled to one .o
# Plus eval.c from the MicroHs runtime
MHS_GEN_OBJ := build/hs_generated.o
MHS_EVAL_OBJ := build/eval.o

ALL_OBJS := $(ASM_OBJS) $(C_OBJS) $(MHS_GEN_OBJ) $(MHS_EVAL_OBJ)

# -------------------------------------------------------
# Main targets
# -------------------------------------------------------
.PHONY: all clean install test-blink test-echo test-ls test-nrf test-lisp test-process test-vm test-interrupt test-shell

all: kernel.img

kernel.img: kernel.elf
	$(OBJCOPY) $< -O binary $@
	@echo "Built kernel.img ($$(wc -c < $@) bytes)"

kernel.elf: $(ALL_OBJS) memmap
	$(LD) $(LDFLAGS) $(ALL_OBJS) $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > kernel.list

# -------------------------------------------------------
# MicroHs: Haskell → C → ARM object
# -------------------------------------------------------

# Step 1: Compile all Haskell to a single C file
build/hs_generated.c: $(HS_SRCS) | build
	$(MHS) -ihs -o $@ hs/Main.hs

# Step 2: Compile the generated C to ARM object
build/hs_generated.o: build/hs_generated.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Step 3: Compile the MicroHs eval.c runtime (local copy for debugging)
build/eval.o: c/eval.c c/config.h c/extra.c c/hal.h | build
	$(CC) $(EVAL_CFLAGS) -c $< -o $@

build:
	mkdir -p build/hs build/tests

# -------------------------------------------------------
# Assembly rules
# -------------------------------------------------------
asm/%.o: asm/%.S
	$(CC) $(CFLAGS) -c $< -o $@

# -------------------------------------------------------
# C rules
# -------------------------------------------------------
c/%.o: c/%.c c/hal.h
	$(CC) $(CFLAGS) -c $< -o $@

# -------------------------------------------------------
# Test targets (mirror cs140e lab tests)
# -------------------------------------------------------

# Lab 2 equivalent: GPIO blink test
test-blink: test-blink.img
	@echo "Built test-blink.img — copy to SD card as kernel.img"

test-blink.img: test-blink.elf
	$(OBJCOPY) $< -O binary $@

test-blink.elf: $(ASM_OBJS) $(C_OBJS) build/test_blink.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_blink.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-blink.list

build/test_blink.c: tests/blink.hs hs/Hal.hs hs/GPIO.hs hs/UART.hs hs/Timer.hs | build
	$(MHS) -ihs -o $@ $<

build/test_blink.o: build/test_blink.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Lab 7 equivalent: UART echo test
test-echo: test-echo.img
	@echo "Built test-echo.img — copy to SD card as kernel.img"

test-echo.img: test-echo.elf
	$(OBJCOPY) $< -O binary $@

test-echo.elf: $(ASM_OBJS) $(C_OBJS) build/test_echo.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_echo.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-echo.list

build/test_echo.c: tests/echo.hs hs/Hal.hs hs/UART.hs | build
	$(MHS) -ihs -o $@ $<

build/test_echo.o: build/test_echo.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Lab 16 equivalent: FAT32 directory listing test
test-ls: test-ls.img
	@echo "Built test-ls.img — copy to SD card as kernel.img"

test-ls.img: test-ls.elf
	$(OBJCOPY) $< -O binary $@

test-ls.elf: $(ASM_OBJS) $(C_OBJS) build/test_ls.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_ls.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-ls.list

build/test_ls.c: tests/ls.hs hs/Hal.hs hs/UART.hs hs/FAT32.hs hs/Alloc.hs | build
	$(MHS) -ihs -o $@ $<

build/test_ls.o: build/test_ls.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# NRF loopback test: two-NRF single-Pi test
test-nrf: test-nrf.img
	@echo "Built test-nrf.img — copy to SD card as kernel.img"

test-nrf.img: test-nrf.elf
	$(OBJCOPY) $< -O binary $@

test-nrf.elf: $(ASM_OBJS) $(C_OBJS) build/test_nrf.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_nrf.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-nrf.list

build/test_nrf.c: tests/nrf-test.hs $(HS_SRCS) | build
	$(MHS) -ihs -o $@ $<

build/test_nrf.o: build/test_nrf.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Lisp interpreter test
test-lisp: test-lisp.img
	@echo "Built test-lisp.img — copy to SD card as kernel.img"

test-lisp.img: test-lisp.elf
	$(OBJCOPY) $< -O binary $@

test-lisp.elf: $(ASM_OBJS) $(C_OBJS) build/test_lisp.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_lisp.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-lisp.list

build/test_lisp.c: tests/lisp-test.hs $(HS_SRCS) | build
	$(MHS) -ihs -o $@ $<

build/test_lisp.o: build/test_lisp.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Process (Chan, spawn, select) test
test-process: test-process.img
	@echo "Built test-process.img — copy to SD card as kernel.img"

test-process.img: test-process.elf
	$(OBJCOPY) $< -O binary $@

test-process.elf: $(ASM_OBJS) $(C_OBJS) build/test_process.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_process.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-process.list

build/test_process.c: tests/process-test.hs hs/Hal.hs hs/UART.hs hs/Timer.hs hs/Process.hs hs/Interrupt.hs | build
	$(MHS) -ihs -o $@ $<

build/test_process.o: build/test_process.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# VM (page table, MMU) test
test-vm: test-vm.img
	@echo "Built test-vm.img — copy to SD card as kernel.img"

test-vm.img: test-vm.elf
	$(OBJCOPY) $< -O binary $@

test-vm.elf: $(ASM_OBJS) $(C_OBJS) build/test_vm.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_vm.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-vm.list

build/test_vm.c: tests/vm-test.hs hs/Hal.hs hs/UART.hs hs/Timer.hs hs/Alloc.hs hs/VM.hs hs/GPIO.hs hs/Interrupt.hs | build
	$(MHS) -ihs -o $@ $<

build/test_vm.o: build/test_vm.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Interrupt (timer tick, UART RX) test
test-interrupt: test-interrupt.img
	@echo "Built test-interrupt.img — copy to SD card as kernel.img"

test-interrupt.img: test-interrupt.elf
	$(OBJCOPY) $< -O binary $@

test-interrupt.elf: $(ASM_OBJS) $(C_OBJS) build/test_interrupt.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_interrupt.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-interrupt.list

build/test_interrupt.c: tests/interrupt-test.hs hs/Hal.hs hs/UART.hs hs/Timer.hs hs/Interrupt.hs | build
	$(MHS) -ihs -o $@ $<

build/test_interrupt.o: build/test_interrupt.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# Shell (processCommand) test
test-shell: test-shell.img
	@echo "Built test-shell.img — copy to SD card as kernel.img"

test-shell.img: test-shell.elf
	$(OBJCOPY) $< -O binary $@

test-shell.elf: $(ASM_OBJS) $(C_OBJS) build/test_shell.o build/eval.o memmap
	$(LD) $(LDFLAGS) $(ASM_OBJS) $(C_OBJS) build/test_shell.o build/eval.o $(LIBC) $(LIBGCC) -o $@
	$(OBJDUMP) -D $@ > test-shell.list

build/test_shell.c: tests/shell-test.hs $(HS_SRCS) | build
	$(MHS) -ihs -o $@ $<

build/test_shell.o: build/test_shell.c c/config.h c/extra.c c/hal.h
	$(CC) $(GEN_CFLAGS) -c $< -o $@

# -------------------------------------------------------
# Utility
# -------------------------------------------------------
clean:
	rm -f asm/*.o c/*.o
	rm -rf build
	rm -f kernel.elf kernel.img kernel.list
	rm -f test-*.elf test-*.img test-*.list

# Install to SD card
# Set SDCARD to your SD card mount point
SDCARD ?= /media/$(USER)/boot
install: kernel.img
	cp kernel.img $(SDCARD)/kernel.img
	sync
	@echo "Installed to $(SDCARD)/kernel.img"
	@echo "Safely eject SD card, insert into Pi, and power on."
