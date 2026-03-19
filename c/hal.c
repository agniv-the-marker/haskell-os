/*
 * hal.c - hardware abstraction layer for haskell to use
 *
 * use gpio.c mostly as a reference for gpio stuff
 * use uart.c for uart
 * use timer.c for timer stuff
 * rpi-interrupts.h for interrupts stuff
 * need to do a heap allocator, use rpi.h as inspiration?
 *   we need to use our linker symbol for start of the heap
 *   ran into bug because microhs assumed malloc returns 0d pages
 *   this is true via mmap on linux but not bare metal
 */

#include "hal.h"

void c_gpio_set_function(unsigned pin, unsigned func) {
    if (pin > GPIO_MAX_PIN) return;
    if ((func & 0x7) != func) return;

    unsigned reg = GPIO_FSEL0 + (pin / 10) * 4;
    unsigned val = GET32(reg);
    unsigned shift = (pin % 10) * 3;
    val &= ~(0x7 << shift);
    val |= (func << shift);
    PUT32(reg, val);
}

void c_gpio_set_output(unsigned pin) {
    c_gpio_set_function(pin, 0x1);
}

void c_gpio_set_input(unsigned pin) {
    c_gpio_set_function(pin, 0x0);
}

void c_gpio_set_on(unsigned pin) {
    if (pin > GPIO_MAX_PIN) return;
    PUT32(GPIO_SET0 + (pin / 32) * 4, 1 << (pin % 32));
}

void c_gpio_set_off(unsigned pin) {
    if (pin > GPIO_MAX_PIN) return;
    PUT32(GPIO_CLR0 + (pin / 32) * 4, 1 << (pin % 32));
}

void c_gpio_write(unsigned pin, unsigned val) {
    if (val)
        c_gpio_set_on(pin);
    else
        c_gpio_set_off(pin);
}

unsigned c_gpio_read(unsigned pin) {
    if (pin > GPIO_MAX_PIN) return 0;
    unsigned val = GET32(GPIO_LEV0 + (pin / 32) * 4);
    return (val >> (pin % 32)) & 0x1;
}

void c_uart_init(void) {
    dev_barrier();
    c_gpio_set_function(14, 0x2);
    c_gpio_set_function(15, 0x2);
    dev_barrier();
    unsigned r = GET32(AUX_ENABLES);
    r |= 1;
    PUT32(AUX_ENABLES, r);
    dev_barrier();
    PUT32(AUX_MU_CNTL_REG, 0); // disabled the miniuart rq
    PUT32(AUX_MU_IER_REG, 0); // disable interrupts
    PUT32(AUX_MU_IIR_REG, 6); // clears the recieve/transmit FIFO
    PUT32(AUX_MU_LCR_REG, 3); // set it to be in 8 bit mode
    PUT32(AUX_MU_MCR_REG, 0); // set RTS to 0
    PUT32(AUX_MU_BAUD_REG, 270); // for 250MHz clock
    PUT32(AUX_MU_CNTL_REG, 0b11); // enables the tx + rx
    dev_barrier();
}

unsigned c_uart_can_put8(void) {
    return GET32(AUX_MU_STAT_REG) & 0x2;
}

unsigned c_uart_has_data(void) {
    return GET32(AUX_MU_STAT_REG) & 0x1;
}

void c_uart_put8(unsigned c) {
    dev_barrier();
    while (!c_uart_can_put8())
        ;
    PUT32(AUX_MU_IO_REG, c & 0xFF);
    dev_barrier();
}

unsigned c_uart_get8(void) {
    dev_barrier();
    while (!c_uart_has_data())
        ;
    unsigned val = GET32(AUX_MU_IO_REG) & 0xFF;
    dev_barrier();
    return val;
}

static unsigned uart_tx_is_empty(void) {
    dev_barrier();
    unsigned lsr = GET32(AUX_MU_LSR_REG);
    dev_barrier();
    return (lsr & (1 << 6)) && (lsr & (1 << 5));
}

void c_uart_flush_tx(void) {
    dev_barrier();
    while (!uart_tx_is_empty())
        ;
    dev_barrier();
}

void c_uart_disable(void) {
    dev_barrier();
    c_uart_flush_tx();
    PUT32(AUX_MU_CNTL_REG, 0);
    dev_barrier();
}

// uart put out multiple char
void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n')
            c_uart_put8('\r');
        c_uart_put8(*s++);
    }
}

static const char hex_chars[] = "0123456789abcdef";

// print number as hex for debugging
void uart_put_hex(unsigned val) {
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        c_uart_put8(hex_chars[(val >> i) & 0xF]);
}

// print number as uint for debugging
// convert to ascii in reverse then print out
void uart_put_uint(unsigned val) {
    char buf[12];
    int i = 0;
    if (val == 0) {
        c_uart_put8('0');
        return;
    }
    while (val > 0) {
        buf[i++] = '0' + (val % 10);
        val /= 10;
    }
    while (--i >= 0)
        c_uart_put8(buf[i]);
}

unsigned c_timer_get_usec(void) {
    return timer_get_usec();
}

void c_delay_us(unsigned us) {
    unsigned start = timer_get_usec();
    while ((timer_get_usec() - start) < us)
        ;  /* spin */
}

void c_delay_ms(unsigned ms) {
    c_delay_us(ms * 1000);
}

// uart rx ring buffer, need to read from haskell
#define UART_RX_BUF_SIZE 256
static volatile unsigned char uart_rx_buf[UART_RX_BUF_SIZE];
static volatile unsigned uart_rx_head = 0;
static volatile unsigned uart_rx_tail = 0;

static void uart_rx_buf_push(unsigned ch) {
    unsigned next = (uart_rx_head + 1) % UART_RX_BUF_SIZE;
    if (next != uart_rx_tail) { // if not full
        uart_rx_buf[uart_rx_head] = (unsigned char)ch;
        uart_rx_head = next;
    }
}

unsigned uart_rx_buf_pop(void) {
    if (uart_rx_tail == uart_rx_head) return 0xFFFFFFFF;
    unsigned ch = uart_rx_buf[uart_rx_tail];
    uart_rx_tail = (uart_rx_tail + 1) % UART_RX_BUF_SIZE;
    return ch;
}

unsigned uart_rx_buf_has_data(void) {
    return uart_rx_tail != uart_rx_head;
}

static volatile unsigned timer_tick_count = 0;
volatile unsigned preempt_pending = 0;

void irq_dispatch_c(unsigned pc) {
    (void)pc;

    // check arm timer interrupt
    if (GET32(IRQ_BASIC_PENDING) & ARM_TIMER_IRQ_BIT) {
        PUT32(ARM_TIMER_IRQ_CLR, 1);  // clear interrupt
        dev_barrier();
        timer_tick_count++;
        preempt_pending = 1;  // signal eval.c to yield
    }

    // check uart rx interrupt
    if (GET32(IRQ_PENDING_1) & AUX_IRQ_BIT) {
        // drain uart fifo into ring buffer
        while (c_uart_has_data()) {
            unsigned ch = GET32(AUX_MU_IO_REG) & 0xFF;
            uart_rx_buf_push(ch);
        }
        dev_barrier();
    }
}

// after this arm should generate interrupts at this interval
void timer_interrupt_init(unsigned interval_us) {
    disable_interrupts();

    // disable interrupts
    PUT32(IRQ_DISABLE_1, 0xFFFFFFFF);
    PUT32(IRQ_DISABLE_2, 0xFFFFFFFF);
    PUT32(IRQ_DISABLE_BASIC, 0xFFFFFFFF);
    dev_barrier();

    // enable timer/timer interrupt/23 bit counter
    PUT32(ARM_TIMER_LOAD, interval_us);
    PUT32(ARM_TIMER_CONTROL,
        (1 << 7) |   // timer enabled
        (1 << 5) |   // interrupt enabled
        (1 << 1)     // 23-bit counter
    );
    dev_barrier();

    // enable arm timer interrupt
    PUT32(IRQ_ENABLE_BASIC, ARM_TIMER_IRQ_BIT);
    dev_barrier();

    enable_interrupts();
}

// enable interrupts to be recieved over uart
void uart_interrupt_init(void) {
    PUT32(AUX_MU_IER_REG, 0x1);
    dev_barrier();
    PUT32(IRQ_ENABLE_1, AUX_IRQ_BIT);
    dev_barrier();
}

unsigned c_timer_tick_count(void) { return timer_tick_count; }
unsigned c_uart_rx_has_data(void) { return uart_rx_buf_has_data(); }
unsigned c_uart_rx_read(void) { return uart_rx_buf_pop(); }

// reboot to reclaim this stack bc we lazy
static unsigned heap_ptr = 0;
static unsigned heap_end = 0;

void heap_init(void) {
    extern unsigned __heap_start__;
    heap_ptr = (unsigned)&__heap_start__;
    // align to 8 bytes
    heap_ptr = (heap_ptr + 7) & ~7;
    heap_end = heap_ptr + HEAP_SIZE;
}

void *kmalloc(unsigned nbytes) {
    heap_ptr = (heap_ptr + 7) & ~7;
    if (heap_ptr + nbytes > heap_end) {
        uart_puts("PANIC: kmalloc out of memory!\r\n");
        reboot();
    }
    void *p = (void *)heap_ptr;
    heap_ptr += nbytes;
    // we need to zero memory since eval.c assumes mallock returns 0d pages
    unsigned *wp = (unsigned *)p;
    unsigned nwords = nbytes >> 2;
    for (unsigned i = 0; i < nwords; i++)
        wp[i] = 0;
    return p;
}

void *kmalloc_aligned(unsigned nbytes, unsigned alignment) {
    heap_ptr = (heap_ptr + alignment - 1) & ~(alignment - 1);
    return kmalloc(nbytes);
}

