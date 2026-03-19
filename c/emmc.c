/*
 * emmc.c - stolen from lab 16 (low level devel)
 *
 * need to update the references, printk, other functions
 * 
 * ran into bugs with this a lot so added a ton of delays and tests
 * turns out i was off by one somewhere else lol with gpio pin 53
 */

#include "hal.h"
#include "emmc.h"

// macros
#define printk(...) do { if (0) {} } while(0)
#define delay_us c_delay_us
#define delay_ms c_delay_ms
#define assert(x) do { if (!(x)) { uart_puts("ASSERT FAIL: " #x "\r\n"); reboot(); } } while(0)

#define GPIO_FUNC_INPUT 0
#define GPIO_FUNC_ALT3  7

static bool wait_reg_mask(reg32 *reg, u32 mask, bool set, u32 timeout) {
  for (int cycles = 0; cycles <= (int)timeout * 10; cycles++) {
    if ((*reg & mask) ? set : !set) {
      return true;
    }
    delay_us(100);
  }
  return false;
}

static u32 get_clock_divider(u32 base_clock) {
#define TARGET_RATE SD_CLOCK_HIGH
  u32 target_div = 1;

  if (TARGET_RATE <= base_clock) {
    target_div = base_clock / TARGET_RATE;
    if (base_clock % TARGET_RATE) {
      target_div = 0;
    }
  }

  int div = -1;
  for (int fb = 31; fb >= 0; fb--) {
    u32 bt = (1 << fb);
    if (target_div & bt) {
      div = fb;
      target_div &= ~(bt);
      if (target_div) {
        div++;
      }
      break;
    }
  }

  if (div == -1) div = 31;
  if (div >= 32) div = 31;
  if (div != 0) div = (1 << (div - 1));
  if (div >= 0x400) div = 0x3FF;

  u32 freqSel = div & 0xff;
  u32 upper = (div >> 8) & 0x3;
  u32 ret = (freqSel << 8) | (upper << 6) | (0 << 5);

  return ret;
}

bool emmc_setup_clock(void) {
  EMMC->control2 = 0;

  u32 rate = 250000000;

  u32 n = EMMC->control[1];
  n |= EMMC_CTRL1_CLK_INT_EN;
  n |= get_clock_divider(rate);
  n &= ~(0xf << 16);
  n |= (11 << 16);

  EMMC->control[1] = n;

  if (!wait_reg_mask(&EMMC->control[1], EMMC_CTRL1_CLK_STABLE, true, 2000)) {
    uart_puts("EMMC_ERR: SD CLOCK NOT STABLE\r\n");
    return false;
  }

  delay_ms(30);
  EMMC->control[1] |= 4;
  delay_ms(30);

  return true;
}

static emmc_device device = {0};

static const emmc_cmd INVALID_CMD = RES_CMD;

static const emmc_cmd commands[] = {
  {0, 0, 0, 0, 0, 0, 0,  0, 0, 0, 0, 0, 0, 0},
  RES_CMD,
  {0, 0, 0, 0, 0, 0, RT136, 0, 1, 0, 0, 0, 2, 0},
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 0, 0, 3, 0},
  {0, 0, 0, 0, 0, 0, 0,     0, 0, 0, 0, 0, 4, 0},
  {0, 0, 0, 0, 0, 0, RT136, 0, 0, 0, 0, 0, 5, 0},
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 0, 0, 6, 0},
  {0, 0, 0, 0, 0, 0, RT48Busy,  0, 1, 0, 0, 0, 7, 0},
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 0, 0, 8, 0},
  {0, 0, 0, 0, 0, 0, RT136, 0, 1, 0, 0, 0, 9, 0},
  RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD,
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 0, 0, 16, 0},
  {0, 0, 0, 1, 0, 0, RT48,  0, 1, 0, 1, 0, 17, 0},
  {0, 1, 1, 1, 1, 0, RT48,  0, 1, 0, 1, 0, 18, 0},
  RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD,
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 1, 0, 24, 0},
  {0, 1, 1, 0, 1, 0, RT48,  0, 1, 0, 1, 0, 25, 0},
  RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD, /* [26-31] */
  RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD, /* [32-37] */
  RES_CMD, RES_CMD, RES_CMD,                             /* [38-40] */
  {0, 0, 0, 0, 0, 0, RT48,  0, 0, 0, 0, 0, 41, 0},    /* [41] ACMD41 */
  RES_CMD, RES_CMD, RES_CMD, RES_CMD,                    /* [42-45] */
  RES_CMD, RES_CMD, RES_CMD, RES_CMD, RES_CMD,           /* [46-50] */
  {0, 0, 0, 1, 0, 0, RT48,  0, 1, 0, 1, 0, 51, 0},    /* [51] CMD51 */
  RES_CMD, RES_CMD, RES_CMD,                             /* [52-54] */
  {0, 0, 0, 0, 0, 0, RT48,  0, 1, 0, 0, 0, 55, 0},    /* [55] CMD55 */
};

static u32 sd_error_mask(sd_error err) {
  return 1 << (16 + (u32)err);
}

static void set_last_error(u32 intr_val) {
  device.last_error = intr_val & 0xFFFF0000;
  device.last_interrupt = intr_val;
}

static bool do_data_transfer(emmc_cmd cmd) {
  u32 wrIrpt = 0;
  bool write = false;

  if (cmd.direction) {
    wrIrpt = 1 << 5;
  } else {
    wrIrpt = 1 << 4;
    write = true;
  }

  u32 *data = (u32 *)device.buffer;

  for (int block = 0; block < (int)device.transfer_blocks; block++) {
    wait_reg_mask(&EMMC->int_flags, wrIrpt | 0x8000, true, 2000);
    u32 intr_val = EMMC->int_flags;
    EMMC->int_flags = wrIrpt | 0x8000;

    if ((intr_val & (0xffff0000 | wrIrpt)) != wrIrpt) {
      set_last_error(intr_val);
      return false;
    }

    u32 length = device.block_size;

    if (write) {
      for (; length > 0; length -= 4) {
        EMMC->data = *data++;
      }
    } else {
      for (; length > 0; length -= 4) {
        *data++ = EMMC->data;
      }
    }
  }

  return true;
}

static bool emmc_issue_command(emmc_cmd cmd, u32 arg, u32 timeout) {
  device.last_command_value = TO_REG(&cmd);
  reg32 command_reg = device.last_command_value;

  if (device.transfer_blocks > 0xFFFF) {
    uart_puts("EMMC_ERR: transferBlocks too large\r\n");
    return false;
  }

  dev_barrier();

  // wait for the cmdline to be free
  while (EMMC->status & EMMC_STATUS_CMD_INHIBIT) {
    delay_us(100);
  }

  // clear all interrupt flags before issuing command
  EMMC->int_flags = 0xFFFFFFFF;
  dev_barrier();

  EMMC->block_size_count = device.block_size | (device.transfer_blocks << 16);
  EMMC->arg1 = arg;
  dev_barrier();
  EMMC->cmd_xfer_mode = command_reg;
  dev_barrier();

  u32 times = 0;

  while(times < timeout) {
    u32 reg = EMMC->int_flags;
    if (reg & 0x8001) {
      break;
    }
    delay_ms(1);
    times++;
  }

  if (times >= timeout) {
    EMMC->int_flags = 0xFFFFFFFF;
    EMMC->control[1] |= EMMC_CTRL1_RESET_CMD;
    while (EMMC->control[1] & EMMC_CTRL1_RESET_CMD) { delay_us(100); }
    device.last_success = false;
    device.last_error = 0;
    return false;
  }

  u32 intr_val = EMMC->int_flags;
  EMMC->int_flags = 0xFFFF0001;

  if ((intr_val & 0xFFFF0001) != 1) {
    set_last_error(intr_val);
    device.last_success = false;
    return false;
  }

  switch(cmd.response_type) {
    case RT48:
    case RT48Busy:
      device.last_response[0] = EMMC->response[0];
      break;
    case RT136:
      device.last_response[0] = EMMC->response[0];
      device.last_response[1] = EMMC->response[1];
      device.last_response[2] = EMMC->response[2];
      device.last_response[3] = EMMC->response[3];
      break;
    default:
      break;
  }

  if (cmd.is_data) {
    do_data_transfer(cmd);
  }

  if (cmd.response_type == RT48Busy || cmd.is_data) {
    wait_reg_mask(&EMMC->int_flags, 0x8002, true, 2000);
    intr_val = EMMC->int_flags;
    EMMC->int_flags = 0xFFFF0002;

    if ((intr_val & 0xFFFF0002) != 2 && (intr_val & 0xFFFF0002) != 0x100002) {
      set_last_error(intr_val);
      return false;
    }

    EMMC->int_flags = 0xFFFF0002;
  }

  device.last_success = true;
  return true;
}

static bool emmc_command(u32 command, u32 arg, u32 timeout) {
  if (command & 0x80000000) {
    uart_puts("EMMC_ERR: COMMAND ERROR NOT APP\r\n");
    return false;
  }

  device.last_command = commands[command];

  if (TO_REG(&device.last_command) == TO_REG(&INVALID_CMD)) {
    uart_puts("EMMC_ERR: INVALID COMMAND\r\n");
    return false;
  }

  return emmc_issue_command(device.last_command, arg, timeout);
}

static bool reset_command(void) {
  EMMC->control[1] |= EMMC_CTRL1_RESET_CMD;

  for (int i=0; i<10000; i++) {
    if (!(EMMC->control[1] & EMMC_CTRL1_RESET_CMD)) {
      return true;
    }
    delay_ms(1);
  }

  uart_puts("EMMC_ERR: Command line failed to reset\r\n");
  return false;
}

bool emmc_app_command(u32 command, u32 arg, u32 timeout) {
  if (commands[command].index >= 60) {
    uart_puts("EMMC_ERR: INVALID APP COMMAND\r\n");
    return false;
  }

  device.last_command = commands[CTApp];

  u32 rca = 0;
  if (device.rca) {
    rca = device.rca << 16;
  }

  if (emmc_issue_command(device.last_command, rca, 2000)) {
    device.last_command = commands[command];
    bool r = emmc_issue_command(device.last_command, arg, 2000);
    if (!r) { uart_puts("  ACMD fail err="); uart_put_hex(device.last_error); uart_puts("\r\n"); }
    return r;
  }

  uart_puts("  CMD55 fail err="); uart_put_hex(device.last_error);
  uart_puts(" status="); uart_put_hex(EMMC->status);
  uart_puts("\r\n");
  return false;
}

static bool check_v2_card(void) {
  bool v2Card = false;

  if (!emmc_command(CTSendIfCond, 0x1AA, 200)) {
    if (device.last_error == 0) {
      //timeout.
    } else if (device.last_error & (1 << 16)) {
      if (!reset_command()) return false;
      EMMC->int_flags = sd_error_mask(SDECommandTimeout);
    } else {
      uart_puts("EMMC_ERR: Failure sending SEND_IF_COND\r\n");
      return false;
    }
  } else {
    if ((device.last_response[0] & 0xFFF) != 0x1AA) {
      uart_puts("EMMC_ERR: Unusable SD Card\r\n");
      return false;
    }
    v2Card = true;
  }

  return v2Card;
}

static bool check_usable_card(void) {
  if (!emmc_command(CTIOSetOpCond, 0, 1000)) {
    if (device.last_error == 0) {
      //timeout.
    } else if (device.last_error & (1 << 16)) {
      if (!reset_command()) return false;
      EMMC->int_flags = sd_error_mask(SDECommandTimeout);
    } else {
      uart_puts("EMMC_ERR: SDIO Card not supported\r\n");
      return false;
    }
  }
  return true;
}

static bool check_sdhc_support(bool v2_card) {
  bool card_busy = true;

  while(card_busy) {
    u32 v2_flags = 0;
    if (v2_card) {
      v2_flags |= (1 << 30);
    }

    if (!emmc_app_command(CTOcrCheck, 0x00FF8000 | v2_flags, 2000)) {
      uart_puts("EMMC_ERR: APP CMD 41 FAILED\r\n");
      return false;
    }

    if (device.last_response[0] >> 31 & 1) {
      device.ocr = (device.last_response[0] >> 8 & 0xFFFF);
      device.sdhc = ((device.last_response[0] >> 30) & 1) != 0;
      card_busy = false;
    } else {
      delay_ms(500);
    }
  }

  return true;
}

static bool check_ocr(void) {
  for (int i = 0; i < 5; i++) {
    if (emmc_app_command(CTOcrCheck, 0, 2000)) {
      device.ocr = (device.last_response[0] >> 8 & 0xFFFF);
      return true;
    }
    delay_ms(100);
  }

  uart_puts("EMMC_ERR: APP CMD 41 FAILED\r\n");
  return false;
}

static bool check_rca(void) {
  if (!emmc_command(CTSendCide, 0, 2000)) {
    uart_puts("EMMC_ERR: Failed to send CID\r\n");
    return false;
  }

  if (!emmc_command(CTSendRelativeAddr, 0, 2000)) {
    uart_puts("EMMC_ERR: Failed to send Relative Addr\r\n");
    return false;
  }

  device.rca = (device.last_response[0] >> 16) & 0xFFFF;

  if (!((device.last_response[0] >> 8) & 1)) {
    uart_puts("EMMC_ERR: Failed to read RCA\r\n");
    return false;
  }

  return true;
}

static bool select_card(void) {
  if (!emmc_command(CTSelectCard, device.rca << 16, 2000)) {
    uart_puts("EMMC_ERR: Failed to select card\r\n");
    return false;
  }

  u32 status = (device.last_response[0] >> 9) & 0xF;

  if (status != 3 && status != 4) {
    uart_puts("EMMC_ERR: Invalid Status\r\n");
    return false;
  }

  return true;
}

static bool set_scr(void) {
  if (!device.sdhc) {
    if (!emmc_command(CTSetBlockLen, 512, 2000)) {
      uart_puts("EMMC_ERR: Failed to set block len\r\n");
      return false;
    }
  }

  u32 bsc = EMMC->block_size_count;
  bsc &= ~0xFFF;
  bsc |= 0x200;
  EMMC->block_size_count = bsc;

  device.buffer = &device.scr.scr[0];
  device.block_size = 8;
  device.transfer_blocks = 1;

  if (!emmc_app_command(CTSendSCR, 0, 30000)) {
    uart_puts("EMMC_ERR: Failed to send SCR\r\n");
    return false;
  }

  device.block_size = 512;

  u32 scr0 = BSWAP32(device.scr.scr[0]);
  device.scr.version = 0xFFFFFFFF;
  u32 spec = (scr0 >> (56 - 32)) & 0xf;
  u32 spec3 = (scr0 >> (47 - 32)) & 0x1;
  u32 spec4 = (scr0 >> (42 - 32)) & 0x1;

  if (spec == 0) {
    device.scr.version = 1;
  } else if (spec == 1) {
    device.scr.version = 11;
  } else if (spec == 2) {
    if (spec3 == 0) {
      device.scr.version = 2;
    } else if (spec3 == 1) {
      if (spec4 == 0) device.scr.version = 3;
      if (spec4 == 1) device.scr.version = 4;
    }
  }

  return true;
}

static bool emmc_card_reset(void) {
  EMMC->control[1] = EMMC_CTRL1_RESET_HOST;

  if (!wait_reg_mask(&EMMC->control[1], EMMC_CTRL1_RESET_ALL, false, 2000)) {
    uart_puts("EMMC_ERR: Card reset timeout!\r\n");
    return false;
  }

  if (!emmc_setup_clock()) {
    uart_puts("EMMC_ERR: Clock setup failed!\r\n");
    return false;
  }

  EMMC->int_enable = 0;
  EMMC->int_flags = 0xFFFFFFFF;
  EMMC->int_mask = 0xFFFFFFFF;

  delay_ms(203);

  device.transfer_blocks = 0;
  device.last_command_value = 0;
  device.last_success = false;
  device.block_size = 0;

  // send it twice just in case????
  if (!emmc_command(CTGoIdle, 0, 2000)) {
    uart_puts("EMMC_WARN: First GO_IDLE failed, trying again\r\n");
    delay_ms(50);
    if (!emmc_command(CTGoIdle, 0, 2000)) {
      uart_puts("EMMC_ERR: NO GO_IDLE RESPONSE\r\n");
      return false;
    }
  }

  delay_ms(50);
  bool v2_card = check_v2_card();

  delay_ms(50);
  if (!check_sdhc_support(v2_card)) return false;

  delay_ms(50);

  if (!check_rca()) return false;
  delay_ms(50);
  if (!select_card()) return false;
  delay_ms(50);
  if (!set_scr()) return false;

  // enable all interrupts
  EMMC->int_flags = 0xFFFFFFFF;

  return true;
}

static bool do_data_command(bool write, u8 *b, u32 bsize, u32 block_no) {
  if (!device.sdhc) {
    block_no *= 512;
  }

  if (bsize < device.block_size) {
    uart_puts("EMMC_ERR: INVALID BLOCK SIZE\r\n");
    return false;
  }

  assert(device.block_size == 512);
  device.transfer_blocks = bsize / 512;

  if (bsize & 0x1ff) {
    uart_puts("EMMC_ERR: BAD BLOCK SIZE\r\n");
    return false;
  }

  device.buffer = b;

  cmd_type command = CTReadBlock;

  if (write && device.transfer_blocks > 1) {
    command = CTWriteMultiple;
  } else if (write) {
    command = CTWriteBlock;
  } else if (!write && device.transfer_blocks > 1) {
    command = CTReadMultiple;
  }

  int retry_count = 0;
  int max_retries = 3;

  while(retry_count < max_retries) {
    if (emmc_command(command, block_no, 5000)) {
      break;
    }

    if (++retry_count < max_retries) {
      uart_puts("EMMC_WARN: Retrying data command\r\n");
    } else {
      uart_puts("EMMC_ERR: Giving up data command\r\n");
      return false;
    }
  }

  return true;
}

int emmc_read(u32 sector, u8 *buffer, u32 size) {
  assert(size % 512 == 0);

  bool success = do_data_command(false, buffer, size, sector);
  if (!success) {
    uart_puts("EMMC_ERR: READ FAILED\r\n");
    return -1;
  }

  return size;
}

int emmc_write(u32 sector, u8 *buffer, u32 size) {
  assert(size % 512 == 0);

  int r = do_data_command(true, buffer, size, sector);
  if (!r) {
    uart_puts("EMMC_ERR: WRITE FAILED\r\n");
    return -1;
  }
  return size;
}

bool emmc_init(void) {
  delay_ms(100);
  c_gpio_set_function(34, GPIO_FUNC_INPUT);
  c_gpio_set_function(35, GPIO_FUNC_INPUT);
  c_gpio_set_function(36, GPIO_FUNC_INPUT);
  c_gpio_set_function(37, GPIO_FUNC_INPUT);
  c_gpio_set_function(38, GPIO_FUNC_INPUT);
  c_gpio_set_function(39, GPIO_FUNC_INPUT);

  c_gpio_set_function(48, GPIO_FUNC_ALT3);
  c_gpio_set_function(49, GPIO_FUNC_ALT3);
  c_gpio_set_function(50, GPIO_FUNC_ALT3);
  c_gpio_set_function(51, GPIO_FUNC_ALT3);
  c_gpio_set_function(52, GPIO_FUNC_ALT3);
  c_gpio_set_function(53, GPIO_FUNC_ALT3);  /* SD_DATA3 */

  device.transfer_blocks = 0;
  device.last_command_value = 0;
  device.last_success = false;
  device.block_size = 0;
  device.sdhc = false;
  device.ocr = 0;
  device.rca = 0;
  device.base_clock = 0;

  bool success = false;
  for (int i=0; i<10; i++) {
    success = emmc_card_reset();
    if (success) break;
    delay_ms(100);
    uart_puts("EMMC_WARN: Failed to reset card, trying again...\r\n");
  }

  if (!success) {
    return false;
  }

  return true;
}
