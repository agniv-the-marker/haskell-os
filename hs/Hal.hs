{-# LANGUAGE ForeignFunctionInterface #-}

-- | Hal.hs - Foreign Function Interface bindings to C HAL layer
--
-- claude told me how to format, since ive never used it before
-- this is just what chains asm -> c -> haskell

module Hal
  ( -- * MMIO
    put32
  , get32
  , devBarrier

    -- * GPIO
  , c_gpio_set_function
  , c_gpio_set_output
  , c_gpio_set_input
  , c_gpio_set_on
  , c_gpio_set_off
  , c_gpio_write
  , c_gpio_read

    -- * UART
  , c_uart_init
  , c_uart_put8
  , c_uart_get8
  , c_uart_has_data

    -- * Timer
  , c_timer_get_usec
  , c_delay_us
  , c_delay_ms

    -- * Memory
  , c_kmalloc
  , c_kmalloc_aligned

    -- * System
  , c_reboot

    -- * Interrupts
  , c_timer_interrupt_init
  , c_uart_interrupt_init
  , c_timer_tick_count
  , c_uart_rx_has_data
  , c_uart_rx_read

    -- * String output
  , c_uart_put_hex
  , c_uart_put_uint

    -- * SPI
  , c_spi_init
  , c_spi_transfer
  , c_spi_set_chip_select
  ) where

import Data.Word

-- | MMIO register write
foreign import ccall "PUT32" put32 :: Word32 -> Word32 -> IO ()

-- | MMIO register read
foreign import ccall "GET32" get32 :: Word32 -> IO Word32

-- | Device memory barrier
foreign import ccall "dev_barrier" devBarrier :: IO ()

-- GPIO
foreign import ccall "c_gpio_set_function" c_gpio_set_function :: Word32 -> Word32 -> IO ()
foreign import ccall "c_gpio_set_output"   c_gpio_set_output   :: Word32 -> IO ()
foreign import ccall "c_gpio_set_input"    c_gpio_set_input    :: Word32 -> IO ()
foreign import ccall "c_gpio_set_on"       c_gpio_set_on       :: Word32 -> IO ()
foreign import ccall "c_gpio_set_off"      c_gpio_set_off      :: Word32 -> IO ()
foreign import ccall "c_gpio_write"        c_gpio_write        :: Word32 -> Word32 -> IO ()
foreign import ccall "c_gpio_read"         c_gpio_read         :: Word32 -> IO Word32

-- UART
foreign import ccall "c_uart_init"     c_uart_init     :: IO ()
foreign import ccall "c_uart_put8"     c_uart_put8     :: Word32 -> IO ()
foreign import ccall "c_uart_get8"     c_uart_get8     :: IO Word32
foreign import ccall "c_uart_has_data" c_uart_has_data :: IO Word32

-- Timer
foreign import ccall "c_timer_get_usec" c_timer_get_usec :: IO Word32
foreign import ccall "c_delay_us"       c_delay_us       :: Word32 -> IO ()
foreign import ccall "c_delay_ms"       c_delay_ms       :: Word32 -> IO ()

-- Memory
foreign import ccall "kmalloc"         c_kmalloc         :: Word32 -> IO Word32
foreign import ccall "kmalloc_aligned" c_kmalloc_aligned :: Word32 -> Word32 -> IO Word32

-- System
foreign import ccall "reboot"             c_reboot             :: IO ()

-- Interrupts
foreign import ccall "timer_interrupt_init" c_timer_interrupt_init :: Word32 -> IO ()
foreign import ccall "uart_interrupt_init"  c_uart_interrupt_init  :: IO ()
foreign import ccall "c_timer_tick_count"   c_timer_tick_count     :: IO Word32
foreign import ccall "c_uart_rx_has_data"   c_uart_rx_has_data     :: IO Word32
foreign import ccall "c_uart_rx_read"       c_uart_rx_read         :: IO Word32

-- String output helpers
foreign import ccall "uart_put_hex"  c_uart_put_hex  :: Word32 -> IO ()
foreign import ccall "uart_put_uint" c_uart_put_uint :: Word32 -> IO ()

-- SPI
foreign import ccall "c_spi_init"            c_spi_init            :: Word32 -> Word32 -> IO ()
foreign import ccall "c_spi_transfer"        c_spi_transfer        :: Word32 -> Word32 -> Word32 -> IO ()
foreign import ccall "c_spi_set_chip_select" c_spi_set_chip_select :: Word32 -> IO ()
