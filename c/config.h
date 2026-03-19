/*
 * config.h - base off of:
 * https://github.com/augustss/MicroHs/blob/master/src/runtime/stm32f4/config.h
 * 
 * mostly the same? just need to add a ton of FFI stuff
 *
 * needed to increase the heap/stack due to bugs but probably can be optimized
 * 
 * included by mhsffi.h (via eval.c) before any other mhs code.
 */

#ifndef CONFIG_H
#define CONFIG_H

// disable everything not needed on baremetal
#define WANT_STDIO    0   // no stdio, just uart
#define WANT_FD       0
#define WANT_MEM      0
#define WANT_BUF      0
#define WANT_CRLF     0
#define WANT_BASE64   0
// mhs currently requires utf8 as haskell strings are utf8
#define WANT_UTF8     1
#define WANT_FLOAT    0
#define WANT_FLOAT32  0
#define WANT_FLOAT64  0
#define WANT_MATH     0
#define WANT_INT64    0
#define WANT_MD5      0
#define WANT_TICK     0
#define WANT_ARGS     0   // no command-line args on baremetal
#define WANT_DIR      0
#define WANT_TIME     0
#define WANT_SIGINT   0
#define WANT_ERRNO    0
#define WANT_GMP      0
#define WANT_LZ77     0
#define WANT_RLE      0
#define WANT_BWT      0

// runtime tuning
#define GCRED      0      // no gc reduction lol
#define INTTABLE   1      // fixed small cache table of ints
#define SANITY     0      // skip sanity checks
#define STACKOVL   1      // check for stack overflow

// increased the stack because was getting stack overflow bugs
#define HEAP_CELLS 100000 // ~800KB at 8 bytes/cell on 32-bit
#define STACK_SIZE 10000

// get the platform hook HAL macros via hal.h
#include "hal.h"

static inline int mhs_ffs(int x) {
    return __builtin_ffs(x);
}
#define FFS mhs_ffs

void myexit(int n);
#define EXIT myexit

int mhs_getraw(void);
#define GETRAW mhs_getraw

void mhs_putraw(int c);
#define PUTRAW mhs_putraw

intptr_t mhs_gettimemilli(void);
#define GETTIMEMILLI mhs_gettimemilli

#define ERR(s)     do { uart_puts("ERR: " s "\r\n"); EXIT(1); } while(0)
#define ERR1(s,a)  do { uart_puts("ERR: " s "\r\n"); EXIT(1); } while(0)

int mhs_printf(const char *fmt, ...);
#define PRINT mhs_printf

// FFI_EXTRA needs to export hal functions to haskell's ffi + give # of inputs
#define FFI_EXTRA \
  { "c_gpio_set_function", 2, (funptr_t)c_gpio_set_function }, \
  { "c_gpio_set_output",   1, (funptr_t)c_gpio_set_output   }, \
  { "c_gpio_set_input",    1, (funptr_t)c_gpio_set_input    }, \
  { "c_gpio_set_on",       1, (funptr_t)c_gpio_set_on       }, \
  { "c_gpio_set_off",      1, (funptr_t)c_gpio_set_off      }, \
  { "c_gpio_write",        2, (funptr_t)c_gpio_write        }, \
  { "c_gpio_read",         1, (funptr_t)c_gpio_read         }, \
  { "c_uart_init",         0, (funptr_t)c_uart_init         }, \
  { "c_uart_put8",         1, (funptr_t)c_uart_put8         }, \
  { "c_uart_get8",         0, (funptr_t)c_uart_get8         }, \
  { "c_uart_has_data",     0, (funptr_t)c_uart_has_data     }, \
  { "c_timer_get_usec",    0, (funptr_t)c_timer_get_usec    }, \
  { "c_delay_us",          1, (funptr_t)c_delay_us          }, \
  { "c_delay_ms",          1, (funptr_t)c_delay_ms          }, \
  { "kmalloc",             1, (funptr_t)kmalloc             }, \
  { "kmalloc_aligned",     2, (funptr_t)kmalloc_aligned     }, \
  { "reboot",              0, (funptr_t)reboot              }, \
  { "uart_put_hex",        1, (funptr_t)uart_put_hex        }, \
  { "uart_put_uint",       1, (funptr_t)uart_put_uint       }, \
  { "PUT32",               2, (funptr_t)PUT32               }, \
  { "GET32",               1, (funptr_t)GET32               }, \
  { "dev_barrier",         0, (funptr_t)dev_barrier         }, \
  { "pi_sd_init",          0, (funptr_t)pi_sd_init          }, \
  { "pi_sd_read",          3, (funptr_t)pi_sd_read          }, \
  { "pi_sd_write",         3, (funptr_t)pi_sd_write         }, \
  { "mmu_enable",          0, (funptr_t)mmu_enable          }, \
  { "mmu_disable",         0, (funptr_t)mmu_disable         }, \
  { "mmu_set_ttbr0",       1, (funptr_t)mmu_set_ttbr0       }, \
  { "mmu_set_domain",      1, (funptr_t)mmu_set_domain      }, \
  { "mmu_inv_tlb",         0, (funptr_t)mmu_inv_tlb         }, \
  { "mmu_get_domain",      0, (funptr_t)mmu_get_domain      }, \
  { "timer_interrupt_init", 1, (funptr_t)timer_interrupt_init }, \
  { "uart_interrupt_init",  0, (funptr_t)uart_interrupt_init  }, \
  { "c_timer_tick_count",   0, (funptr_t)c_timer_tick_count   }, \
  { "c_uart_rx_has_data",   0, (funptr_t)c_uart_rx_has_data   }, \
  { "c_uart_rx_read",       0, (funptr_t)c_uart_rx_read       }, \
  { "c_spi_init",           2, (funptr_t)c_spi_init           }, \
  { "c_spi_transfer",       3, (funptr_t)c_spi_transfer       }, \
  { "c_spi_set_chip_select", 1, (funptr_t)c_spi_set_chip_select },

#endif /* CONFIG_H */
