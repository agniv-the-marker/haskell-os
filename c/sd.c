/*
 * sd.c - sd card driver via emmc. just want nicer wrappers like in pi-sd.c
 */

#include "hal.h"
#include "emmc.h"

unsigned pi_sd_init(void) {
    uart_puts("SD: Initializing via EMMC...\r\n");
    if (emmc_init()) {
        uart_puts("SD: Init OK\r\n");
        return 1;
    }
    uart_puts("SD: Init FAILED\r\n");
    return 0;
}

/*
 * Read sectors from SD card.
 *   data: destination buffer
 *   lba:  logical block address (sector number)
 *   nsec: number of sectors to read
 * Returns nonzero on success.
 */
unsigned pi_sd_read(void *data, unsigned lba, unsigned nsec) {
    int r = emmc_read(lba, (u8 *)data, nsec * 512);
    return (r > 0) ? 1 : 0;
}

/*
 * Write sectors to SD card.
 *   data: source buffer
 *   lba:  logical block address (sector number)
 *   nsec: number of sectors to write
 * Returns nonzero on success.
 */
unsigned pi_sd_write(void *data, unsigned lba, unsigned nsec) {
    int r = emmc_write(lba, (u8 *)data, nsec * 512);
    return (r > 0) ? 1 : 0;
}
