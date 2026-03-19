/*
 * hal.h - easy way to list out every function we need for haskell in c
 *         also includes internal helpers for cstart
 */
#ifndef HAL_H
#define HAL_H

#include <stdint.h>
#include <stddef.h>

#define GPIO_BASE       0x20200000
#define AUX_BASE        0x20215000
#define TIMER_BASE      0x20003000
#define IRQ_BASE        0x2000B000

#define GPIO_FSEL0      (GPIO_BASE + 0x00)
#define GPIO_SET0       (GPIO_BASE + 0x1C)
#define GPIO_CLR0       (GPIO_BASE + 0x28)
#define GPIO_LEV0       (GPIO_BASE + 0x34)

#define AUX_ENABLES     (AUX_BASE + 0x04)
#define AUX_MU_IO_REG   (AUX_BASE + 0x40)
#define AUX_MU_IER_REG  (AUX_BASE + 0x44)
#define AUX_MU_IIR_REG  (AUX_BASE + 0x48)
#define AUX_MU_LCR_REG  (AUX_BASE + 0x4C)
#define AUX_MU_MCR_REG  (AUX_BASE + 0x50)
#define AUX_MU_LSR_REG  (AUX_BASE + 0x54)
#define AUX_MU_CNTL_REG (AUX_BASE + 0x60)
#define AUX_MU_STAT_REG (AUX_BASE + 0x64)
#define AUX_MU_BAUD_REG (AUX_BASE + 0x68)

#define TIMER_CLO       (TIMER_BASE + 0x04)

#define IRQ_BASIC_PENDING  (IRQ_BASE + 0x200)
#define IRQ_PENDING_1      (IRQ_BASE + 0x204)
#define IRQ_PENDING_2      (IRQ_BASE + 0x208)
#define IRQ_FIQ_CONTROL    (IRQ_BASE + 0x20C)
#define IRQ_ENABLE_1       (IRQ_BASE + 0x210)
#define IRQ_ENABLE_2       (IRQ_BASE + 0x214)
#define IRQ_ENABLE_BASIC   (IRQ_BASE + 0x218)
#define IRQ_DISABLE_1      (IRQ_BASE + 0x21C)
#define IRQ_DISABLE_2      (IRQ_BASE + 0x220)
#define IRQ_DISABLE_BASIC  (IRQ_BASE + 0x224)

#define ARM_TIMER_LOAD     (IRQ_BASE + 0x400)
#define ARM_TIMER_VALUE    (IRQ_BASE + 0x404)
#define ARM_TIMER_CONTROL  (IRQ_BASE + 0x408)
#define ARM_TIMER_IRQ_CLR  (IRQ_BASE + 0x40C)
#define ARM_TIMER_RAW_IRQ  (IRQ_BASE + 0x410)
#define ARM_TIMER_MASKED   (IRQ_BASE + 0x414)
#define ARM_TIMER_RELOAD   (IRQ_BASE + 0x418)

#define ARM_TIMER_IRQ_BIT  (1 << 0)

#define GPIO_GPEDS0        (GPIO_BASE + 0x40)  // Event Detect Status
#define GPIO_GPREN0        (GPIO_BASE + 0x4C)  // Rising Edge Detect Enable
#define GPIO_GPFEN0        (GPIO_BASE + 0x58)  // Falling Edge Detect Enable

#define GPIO_INT0_BIT      (1 << 17)

#define AUX_IRQ_BIT        (1 << 29)

#define SPI0_BASE       0x20204000
#define SPI0_CS_REG     (SPI0_BASE + 0x00)  // Control and Status
#define SPI0_FIFO       (SPI0_BASE + 0x04)  // TX/RX FIFO
#define SPI0_CLK_REG    (SPI0_BASE + 0x08)  // Clock Divider
#define SPI0_DLEN       (SPI0_BASE + 0x0C)  // Data Length
#define SPI0_LTOH       (SPI0_BASE + 0x10)  // LoSSI mode TOH
#define SPI0_DC         (SPI0_BASE + 0x14)  // DMA DREQ Controls

#define STACK_ADDR      0x8000000   // 128MB
#define HEAP_START_ADDR 0x0A000000  // heap starts 160 mb down
#define HEAP_SIZE       (200 * 1024 * 1024)  // 200MB heap
#define GPIO_MAX_PIN    53

// has-asm.S

extern void     put32(volatile void *addr, unsigned val);
extern unsigned get32(const volatile void *addr);
extern void     PUT32(unsigned addr, unsigned val);
extern unsigned GET32(unsigned addr);
extern void     put8(volatile void *addr, uint8_t val);
extern uint8_t  get8(const volatile void *addr);

extern void     dsb(void);
extern void     dev_barrier(void);

extern void     enable_interrupts(void);
extern void     disable_interrupts(void);

extern unsigned timer_get_usec(void);

extern void     clean_inv_dcache(void);
extern void     invalidate_tlb(void);

extern void     delay_cycles(unsigned n);

extern void     install_vector_table(void);
extern void     reboot(void);

extern volatile unsigned preempt_pending;

// hal.c

void c_gpio_set_function(unsigned pin, unsigned func);
void c_gpio_set_output(unsigned pin);
void c_gpio_set_input(unsigned pin);
void c_gpio_set_on(unsigned pin);
void c_gpio_set_off(unsigned pin);
void c_gpio_write(unsigned pin, unsigned val);
unsigned c_gpio_read(unsigned pin);

void c_uart_init(void);
void c_uart_put8(unsigned c);
unsigned c_uart_get8(void);
unsigned c_uart_has_data(void);
unsigned c_uart_can_put8(void);
void c_uart_flush_tx(void);
void c_uart_disable(void);

unsigned c_timer_get_usec(void);
void c_delay_us(unsigned us);
void c_delay_ms(unsigned ms);

void  heap_init(void);
void *kmalloc(unsigned nbytes);
void *kmalloc_aligned(unsigned nbytes, unsigned alignment);

void uart_puts(const char *s);
void uart_put_hex(unsigned val);
void uart_put_uint(unsigned val);

void irq_dispatch_c(unsigned pc);
void timer_interrupt_init(unsigned interval_us);
void uart_interrupt_init(void);
unsigned c_timer_tick_count(void);
unsigned c_uart_rx_has_data(void);
unsigned c_uart_rx_read(void);

// sd.c
unsigned pi_sd_init(void);
unsigned pi_sd_read(void *data, unsigned lba, unsigned nsec);
unsigned pi_sd_write(void *data, unsigned lba, unsigned nsec);

// hal-asm.S
void mmu_enable(void);
void mmu_disable(void);
void mmu_set_ttbr0(unsigned ttbr0);
void mmu_set_domain(unsigned domain);
void mmu_inv_tlb(void);
unsigned mmu_get_domain(void);

// spi.c
void c_spi_init(unsigned chip_select, unsigned clk_div);
void c_spi_transfer(unsigned rx_buf, unsigned tx_buf, unsigned nbytes);
void c_spi_set_chip_select(unsigned chip_select);

#endif /* HAL_H */
