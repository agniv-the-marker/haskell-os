/*
 * boot.S - custom boot software for haskell os on pi
 * uses staff-start.S, reboot.c, lab 4 interrupt vectors, and constants (rpi_constants.h)
 * 
 * entry point at 0x8000, set up supervisor mode, set up the stack, 
 * jump to _cstart in C, and reboot if _cstart returns.
 *
 * we need to set up the stack and jump to C graph reducer/interrupts
 */

.equ SUPER_MODE,    0x13
.equ IRQ_MODE,      0x12
.equ FIQ_MODE,      0x11
.equ ABORT_MODE,    0x17
.equ UNDEF_MODE,    0x1B
.equ SYS_MODE,      0x1F

.equ STACK_ADDR,      0x8000000   @ 128MB supervisor stack
.equ IRQ_STACK_ADDR,  0x9000000   @ 144MB IRQ stack

.section ".text.boot"

.globl _start
_start:
    mov r0, #SUPER_MODE
    orr r0, r0, #(1<<7) @ disable interrupts
    orr r0, r0, #(1<<6) @ disable FIQ
    msr cpsr, r0

    @ Prefetch flush after mode change
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 4

    @ Set up IRQ mode stack
    mov r0, #IRQ_MODE
    orr r0, r0, #(1<<7)
    orr r0, r0, #(1<<6)
    msr cpsr, r0
    ldr sp, =IRQ_STACK_ADDR

    @ Back to supervisor mode for main execution
    mov r0, #SUPER_MODE
    orr r0, r0, #(1<<7)
    orr r0, r0, #(1<<6)
    msr cpsr, r0

    @ Set up supervisor stack
    ldr sp, =STACK_ADDR
    mov fp, #0

    @ Jump to C startup
    bl _cstart

    @ If _cstart returns, reboot
    bl reboot

@ Uses libpi/staff-src/reboot.c but in ASM
.equ PM_BASE,     0x20100000
.equ PM_RSTC,     0x1c
.equ PM_WDOG,     0x24
.equ PM_PASSWORD, 0x5a000000
.equ PM_RSTC_WRCFG_FULL_RESET, 0x20

.globl reboot
reboot:
    @ Give UART time to flush
    mov r0, #0x100000
1:  subs r0, r0, #1
    bne 1b

    ldr r0, =PM_BASE
    ldr r1, =(PM_PASSWORD | 10) @ short timeout here
    str r1, [r0, #PM_WDOG]
    ldr r1, =(PM_PASSWORD | PM_RSTC_WRCFG_FULL_RESET)
    str r1, [r0, #PM_RSTC]
    @ wait for reset to happen, should never return from this
2:  b 2b

@ exception vector table layout (ldr pc, [addr] pattern) from cs140e labs/4-interrupts
.globl _vectors
_vectors:
    ldr pc, _reset_addr
    ldr pc, _undef_addr
    ldr pc, _swi_addr
    ldr pc, _prefetch_addr
    ldr pc, _data_addr
    ldr pc, _unused_addr
    ldr pc, _irq_addr
    ldr pc, _fiq_addr

_reset_addr:    .word _start
_undef_addr:    .word _unhandled
_swi_addr:      .word _unhandled
_prefetch_addr: .word _unhandled
_data_addr:     .word _unhandled
_unused_addr:   .word _unhandled
_irq_addr:      .word irq_handler_asm
_fiq_addr:      .word _unhandled

.globl _unhandled
_unhandled:
    b _unhandled
