/*
 * spi.c - spi0 driver, spi.h/nrf-hw-support.c
 */

#include "hal.h"

#define SPI0_BASE       0x20204000
#define SPI0_CS         (SPI0_BASE + 0x00)
#define SPI0_FIFO       (SPI0_BASE + 0x04)
#define SPI0_CLK        (SPI0_BASE + 0x08)
#define SPI0_DLEN       (SPI0_BASE + 0x0C)
#define SPI0_LTOH       (SPI0_BASE + 0x10)
#define SPI0_DC         (SPI0_BASE + 0x14)

#define SPI_CS_TXD      (1 << 18)   // TX FIFO can accept data
#define SPI_CS_RXD      (1 << 17)   // RX FIFO contains data
#define SPI_CS_DONE     (1 << 16)   // Transfer done
#define SPI_CS_TA       (1 << 7)    // Transfer Active
#define SPI_CS_CLEAR_RX (1 << 5)    // Clear RX FIFO (self-clearing)
#define SPI_CS_CLEAR_TX (1 << 4)    // Clear TX FIFO (self-clearing)

#define GPIO_ALT0       4

/*
 * c_spi_init: Initialize SPI0 for the given chip select and clock divider.
 *
 * chip_select: 0 for CE0 (GPIO 8), 1 for CE1 (GPIO 7)
 * clk_div: clock divider (26 for ~9.6MHz at 250MHz core clock)
 */
void c_spi_init(unsigned chip_select, unsigned clk_div) {
    dev_barrier();

    c_gpio_set_function(7,  GPIO_ALT0);   // CE1
    c_gpio_set_function(8,  GPIO_ALT0);   // CE0
    c_gpio_set_function(9,  GPIO_ALT0);   // MISO
    c_gpio_set_function(10, GPIO_ALT0);   // MOSI
    c_gpio_set_function(11, GPIO_ALT0);   // SCLK
    dev_barrier();

    // clear fifo and set chip_select
    PUT32(SPI0_CS, SPI_CS_CLEAR_RX | SPI_CS_CLEAR_TX | (chip_select & 0x3));
    dev_barrier();

    // set clock divider
    PUT32(SPI0_CLK, clk_div);
    dev_barrier();
}

/*
 * c_spi_transfer: section 10.6.1, 14 prelab
 *
 * rx_buf: receive buffer (Word32 pointer, haskell)
 * tx_buf: transmit buffer (Word32 pointer, haskell)
 * nbytes: number of bytes to transfer
 *
 * buffers must be at least nbytes long
 */
void c_spi_transfer(unsigned rx_buf, unsigned tx_buf, unsigned nbytes) {
    unsigned char *rx = (unsigned char *)rx_buf;
    unsigned char *tx = (unsigned char *)tx_buf;

    dev_barrier();

    // preserve chip_select/clear fifo/set ta
    unsigned cs = GET32(SPI0_CS);
    cs &= 0x3;  // chip select bits
    PUT32(SPI0_CS, cs | SPI_CS_CLEAR_RX | SPI_CS_CLEAR_TX | SPI_CS_TA);
    dev_barrier();

    unsigned tx_idx = 0;
    unsigned rx_idx = 0;

    while (rx_idx < nbytes) {
        // write when possible
        while (tx_idx < nbytes && (GET32(SPI0_CS) & SPI_CS_TXD)) {
            PUT32(SPI0_FIFO, tx[tx_idx]);
            tx_idx++;
        }
        // read when possible
        while (rx_idx < nbytes && (GET32(SPI0_CS) & SPI_CS_RXD)) {
            rx[rx_idx] = GET32(SPI0_FIFO) & 0xFF;
            rx_idx++;
        }
    }

    while (!(GET32(SPI0_CS) & SPI_CS_DONE))
        ;

    // return chip select
    PUT32(SPI0_CS, cs);
    dev_barrier();
}

/*
 * c_spi_set_chip_select: Switch the active chip select line.
 * Used when multiple SPI devices share the bus (e.g., two NRF modules).
 */
void c_spi_set_chip_select(unsigned chip_select) {
    dev_barrier();
    unsigned cs = GET32(SPI0_CS);
    cs = (cs & ~0x3) | (chip_select & 0x3);
    PUT32(SPI0_CS, cs);
    dev_barrier();
}
