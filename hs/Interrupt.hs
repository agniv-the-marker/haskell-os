-- | Interrupt.hs - labs 4/8. haskell arm timer interrupts/uart, soft wrapper

module Interrupt
  ( -- * Initialization
    initTimerInterrupt, initUartInterrupt
    -- * Timer
  , timerTicks
    -- * UART RX (interrupt-buffered)
  , uartRxHasData, uartRxRead
  ) where

import Data.Word
import Data.Bits ((.&.))
import Hal

-- | Initialize ARM timer interrupt, period in microseconds.
initTimerInterrupt :: Word32 -> IO ()
initTimerInterrupt = c_timer_interrupt_init

-- | Enable UART receive interrupts (incoming bytes caught by IRQ handler)
initUartInterrupt :: IO ()
initUartInterrupt = c_uart_interrupt_init

-- | Get the timer tick count
timerTicks :: IO Word32
timerTicks = c_timer_tick_count

-- | Check if interrupt-buffered UART data is available.
uartRxHasData :: IO Bool
uartRxHasData = fmap (/= 0) c_uart_rx_has_data

-- | Read one byte from the interrupt ring buffer.
-- Returns Nothing if the buffer is empty.
uartRxRead :: IO (Maybe Word8)
uartRxRead = do
    w <- c_uart_rx_read
    if w == 0xFFFFFFFF
      then return Nothing
      else return (Just (fromIntegral (w .&. 0xFF)))
