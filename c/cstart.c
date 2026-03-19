/*
 * cstart.c - based on cstart.c
 *
 * can get rid of gcc/cycle_cnt and need init calls for mhs/hs/heap/vectors
 */

#include "hal.h"

extern unsigned __bss_start__, __bss_end__;
extern unsigned __heap_start__;
extern unsigned __prog_end__;

extern void mhs_init(void);

// haskell entropy point
extern void hs_main(void);

void _cstart(void) {
    // 1. Clear .bss section
    unsigned *bss = &__bss_start__;
    unsigned *bss_end = &__bss_end__;
    while (bss < bss_end)
        *bss++ = 0;

    // 2. initialize heap rn
    heap_init();

    // 3. initialize uart for uart
    c_uart_init();

    // 4. print init message
    uart_puts("HaskellOS initializing...\r\n");

    // 5. install vector table for interrupts
    install_vector_table();

    // 6. initialize mhs runtime
    uart_puts("MicroHs runtime initializing...\r\n");
    mhs_init();

    // 7. jump to the main haskell function
    uart_puts("Jumping to Haskell main...\r\n");
    hs_main();

    // 8. if we return from haskell main, print message and reboot
    uart_puts("Haskell main returned. Halting.\r\n");
    reboot();
}
