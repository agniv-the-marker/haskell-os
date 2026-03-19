/*
 * hal-asm.S - hardware abstraction layer asm funfctions
 *
 * we needd a lot of asm functions in cs140e, this is just all of them
 * need put32/get32 and all the flavors (staff-start.S, put-get8.S)
 * need dmb/dsb/dev_barrier (mem-barrier.S) 
 * need enable/disable_interrupts (interrupts-asm.S)
 * need cpsr_get/cpsr_set (rpi-inline-asm.h)
 * need timer_get_usec (timer.c)
 * need delay_cycles (delay-ncycles.c)
 * need rpi_cswitch, rpi_init_trampoline (lab 5 rpi-thread-asm.S)
 * need rpi_get_sp (lab 5) 
 * need install_vector_table (lab 4)
 * need MMU ops (mmu_enable, mmu_disable, mmu_set_ttbr0, etc.) (labs 13/15/17 mmu.c/your-mmu.asm.S but just ASM)
 *
 * might asw rewrite most of them to be pure assembly for ~optimization
 *
 * also need some new things:
 *   clean up the cache/tlb operations inside of the cache-support.S functions
 *   
 * needed __aeabi_uidivmod/__aeabi_idivmod for ARM EABI division support 
 * since we use C division when booting and in some C code and hella bugs
 */

.globl put32
.globl PUT32
put32:
PUT32:
    str r1, [r0]
    bx lr

.globl get32
.globl GET32
get32:
GET32:
    ldr r0, [r0]
    bx lr

.globl put8
put8:
    strb r1, [r0]
    bx lr

.globl get8
get8:
    ldrb r0, [r0]
    bx lr


.globl dsb
dsb:
    mcr p15, 0, r0, c7, c10, 4
    bx lr

.globl dev_barrier
dev_barrier:
    b dsb

.globl enable_interrupts
enable_interrupts:
    mrs r0, cpsr
    bic r0, r0, #(1<<7)
    msr cpsr_c, r0
    bx lr

.globl disable_interrupts
disable_interrupts:
    mrs r0, cpsr
    orr r0, r0, #(1<<7)
    msr cpsr_c, r0
    bx lr

.globl irq_handler_asm
irq_handler_asm:
    sub lr, lr, #4
    push {r0-r12, lr}
    mov r0, lr
    bl irq_dispatch_c 
    pop {r0-r12, lr}
    movs pc, lr 

.globl timer_get_usec
timer_get_usec:
    ldr r0, =0x20003004
    ldr r0, [r0]
    bx lr

.globl clean_inv_dcache
clean_inv_dcache:
    mov r0, #0
    mcr p15, 0, r0, c7, c14, 0
    bx lr

.globl invalidate_tlb
invalidate_tlb:
    mov r0, #0
    mcr p15, 0, r0, c8, c7, 0
    bx lr

.globl delay_cycles
delay_cycles:
    subs r0, r0, #1
    bne delay_cycles
    bx lr

@ custom mmu stuff in asm

.globl mmu_enable
mmu_enable:
    push {lr}
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 4
    mrc p15, 0, r0, c1, c0, 0
    orr r0, r0, #0x1
    mcr p15, 0, r0, c1, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 4
    pop {lr}
    bx lr

.globl mmu_disable
mmu_disable:
    push {lr}
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #0x1
    mcr p15, 0, r0, c1, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 4
    mcr p15, 0, r0, c7, c5, 4
    pop {lr}
    bx lr

.globl mmu_set_ttbr0
mmu_set_ttbr0:
    mcr p15, 0, r0, c2, c0, 0
    bx lr

.globl mmu_set_domain
mmu_set_domain:
    mcr p15, 0, r0, c3, c0, 0
    bx lr

.globl mmu_get_domain
mmu_get_domain:
    mrc p15, 0, r0, c3, c0, 0
    bx lr

.globl mmu_inv_tlb
mmu_inv_tlb:
    b invalidate_tlb


.globl install_vector_table
install_vector_table:
    push {r4-r7, lr}
    ldr r0, =_vectors
    mov r1, #0 
    ldmia r0!, {r2-r7}
    stmia r1!, {r2-r7}
    ldmia r0!, {r2-r7}
    stmia r1!, {r2-r7}
    ldmia r0!, {r2-r5}
    stmia r1!, {r2-r5}
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 4
    mcr p15, 0, r0, c7, c5, 4
    pop {r4-r7, lr}
    bx lr

/*
 * __aeabi_uidivmod: unsigned division with remainder
 *   Entry: r0 = numerator, r1 = denominator
 *   Exit:  r0 = quotient, r1 = remainder
 * Uses __aeabi_uidiv (C function) for the quotient,
 * then computes remainder = num - quot * den.
 */
.globl __aeabi_uidivmod
__aeabi_uidivmod:
    push {r4, r5, lr}
    mov r4, r0
    mov r5, r1
    bl __aeabi_uidiv @ r0 = quotient
    @ remainder = numerator - quotient * denominator
    mul r1, r0, r5          @ r1 = quot * den
    sub r1, r4, r1          @ r1 = num - quot*den = remainder
    pop {r4, r5, lr}
    bx lr

/*
 * __aeabi_idivmod: signed division with remainder
 *   Entry: r0 = numerator, r1 = denominator
 *   Exit:  r0 = quotient, r1 = remainder
 */
.globl __aeabi_idivmod
__aeabi_idivmod:
    push {r4, r5, lr}
    mov r4, r0              /* save numerator */
    mov r5, r1              /* save denominator */
    bl __aeabi_idiv          /* r0 = quotient */
    mul r1, r0, r5          /* r1 = quot * den */
    sub r1, r4, r1          /* r1 = num - quot*den = remainder */
    pop {r4, r5, lr}
    bx lr
