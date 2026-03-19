# where I used llms

llms were mostly useful for rts-stubs + makefile + writing *-test.hs.

used in some bug hunting as well & figuring out what haskell i could use with MHS

code complete in vscode was used but its so ass at haskell D:

i think haskell is a fun language to write so i didnt use it that much

## it also generated this breakdown lol

```hs
┌─────────────────────────────────────────────────────────────────────┐
│                         APPLICATIONS                                │
│                                                                     │
│  ┌──────────────────────────┐  ┌──────────────────────────────────┐ │
│  │       Shell.hs           │  │          Lisp.hs                 │ │
│  │  18 commands: ls, cat,   │  │  S-expr parser, eval,            │ │
│  │  write, gpio, nrf, vm,   │──│  closures, hardware FFI          │ │
│  │  lisp, heartbeat, ...    │  │  (gpio-write, delay, print)      │ │
│  └────────┬─────────────────┘  └──────────┬───────────────────────┘ │
│           │                               │                         │
│           │         ┌─────────────────────┘                         │
│           ▼         ▼                                               │
│  ┌─────────────────────┐                                            │
│  │     Parse.hs        │  Parser combinator library                 │
│  │  satisfy → char →   │  (Functor/Applicative/Monad/Alternative)   │
│  │  many1, sepBy, word │                                            │
│  └─────────────────────┘                                            │
├─────────────────────────────────────────────────────────────────────┤
│                        SUBSYSTEMS                                   │
│                                                                     │
│  ┌────────────┐ ┌────────────┐ ┌───────────┐ ┌───────────────────┐  │ 
│  │  FAT32.hs  │ │   VM.hs    │ │ NetChan.hs│ │   Process.hs      │  │ 
│  │            │ │            │ │           │ │                   │  │ 
│  │ mount/read │ │ page table │ │ Msg ADT   │ │ Chan a, spawn,    │  │ 
│  │ write/rm   │ │ map/enable │ │ encode/   │ │ select, supervisor│  │ 
│  │ ls/rename  │ │ PTE ADTs   │ │ decode    │ │ (Erlang, live)    │  │
│  └─────┬──────┘ └─────┬──────┘ └─────┬─────┘ └────────┬──────────┘  │ 
│        │              │              │                │             │
│        │              │              │    ┌───────────┘             │
│        │              │              │    │  forkIO / MVar          │
│        ▼              │              ▼    ▼                         │
│  ┌──────────┐         │        ┌──────────────┐                     │ 
│  │  SD/EMMC │         │        │   NRF.hs     │                     │ 
│  │ (C: emmc │         │        │ NRF24L01+    │                     │ 
│  │  .c/sd.c)│         │        │ send/recv    │                     │ 
│  └─────┬────┘         │        │ ACK/retransmit                     │
│        │              │        │ exp. backoff │                     │
│        │              │        └──────┬───────┘                     │ 
├────────┼──────────────┼───────────────┼─────────────────────────────┤ 
│        │          DRIVERS             │                             │
│        │              │               │                             │
│  ┌─────┴────┐  ┌──────┴─────┐   ┌─────┴─────┐  ┌────────────────┐   │  
│  │ Alloc.hs │  │  GPIO.hs   │   │  SPI.hs   │  │ Interrupt.hs   │   │  
│  │          │  │            │   │           │  │                │   │  
│  │ alloc,   │  │ OutputPin/ │   │ init,     │  │ timer tick,    │   │  
│  │ peek/poke│  │ InputPin   │   │ transfer, │  │ UART RX ring   │   │  
│  │ (Ptr =   │  │ read/write │   │ chip sel  │  │ buffer         │   │  
│  │  Word32) │  │ toggle     │   │           │  │                │   │  
│  └─────┬────┘  └──────┬─────┘   └─────┬─────┘  └───────┬────────┘   │  
│        │              │               │                │            │ 
│  ┌─────┴────┐  ┌──────┴─────┐   ┌─────┴──────────┐     │            │  
│  │ UART.hs  │  │ Timer.hs   │   │   Main.hs      │     │            │  
│  │ putStr,  │  │ delay,     │   │ boot, MMU init,│◄────┘            │
│  │ getLine, │  │ timeIt     │   │ heartbeat,     │                  │
│  │ trace    │  │            │   │ supervisor     │                  │  
│  └─────┬────┘  └──────┬─────┘   └───────┬────────┘                  │  
├────────┼──────────────┼─────────────────┼───────────────────────────┤ 
│        │              │                 │                           │
│        └──────────────┴─────────────────┘                           │
│                       │                                             │
│                       ▼                                             │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      Hal.hs                                 │    │
│  │          30 foreign import ccall declarations               │    │
│  │   PUT32/GET32, gpio_*, uart_*, timer_*, spi_*, mmu_*        │    │ 
│  └─────────────────────────────┬───────────────────────────────┘    │
│                                │ FFI boundary                       │
│                                │ (Haskell above / C below)          │
╠════════════════════════════════╪════════════════════════════════════╣
│                                ▼                                    │
│  ┌──────────────┐  ┌──────────────┐   ┌───────────────────────────┐ │ 
│  │   hal.c      │  │   extra.c    │   │     rts-stubs.c           │ │ 
│  │ GPIO, UART,  │  │ MicroHs      │   │  libc replacement:        │ │ 
│  │ Timer, Heap, │  │ hooks:       │   │  malloc, printf, memcpy,  │ │ 
│  │ Interrupts,  │  │ getraw,      │   │  division, pthread stubs, │ │ 
│  │ Ring buffer  │  │ putraw,      │   │  signal stubs, qsort,     │ │ 
│  │              │  │ printf       │   │  ctype, strtol, ...       │ │ 
│  └──────┬───────┘  └──────┬───────┘   └────────────┬──────────────┘ │ 
│         │                 │                        │                │ 
│         │    ┌────────────┴─────┐    ┌─────────────┘                │ 
│         │    │                  │    │                              │
│         ▼    ▼                  ▼    ▼                              │
│  ┌────────────────┐  ┌───────────────────────────────────────────┐  │ 
│  │   config.h     │  │           eval.c (MicroHs)                │  │ 
│  │ HEAP=100K      │  │   Combinator graph reducer + GC           │  │ 
│  │ STACK=10K      │  │   Green threads (forkIO/MVar)             │  │ 
│  │ FFI_EXTRA[38]  │  │   setjmp/longjmp context switch           │  │ 
│  └────────────────┘  │   ~7,300 lines (third-party)              │  │ 
│                      └───────────────────┬───────────────────────┘  │ 
│  ┌───────────────┐                       │    ┌────────────────┐    │ 
│  │   spi.c       │                       │    │    sd.c        │    │ 
│  │ SPI0 polled   │                       │    │  SD wrapper    │    │ 
│  │ transfer      │                       │    │  → emmc.c      │    │ 
│  └───────┬───────┘                       │    └───────┬────────┘    │ 
│          │                               │            │             │ 
╠══════════╪═══════════════════════════════╪════════════╪═════════════╣ 
│          │           ASM LAYER           │            │             │ 
│          │                               │            │             │ 
│          ▼                               ▼            ▼             │ 
│  ┌─────────────────────────────────────────────────────────────┐    │ 
│  │                     hal-asm.S                               │    │ 
│  │  PUT32/GET32, barriers (dsb/dmb), enable/disable IRQ,       │    │  
│  │  cache/TLB ops, mmu_enable/disable/set_ttbr0,               │    │  
│  │  timer_get_usec, delay_cycles,                              │    │  
│  │  irq_handler_asm → irq_dispatch_c, __aeabi_uidivmod         │    │  
│  └─────────────────────────────────────────────────────────────┘    │ 
│  ┌─────────────────────────────────────────────────────────────┐    │ 
│  │                      boot.S                                 │    │ 
│  │  _start → supervisor mode → IRQ stack → SVC stack →         │    │   
│  │  _cstart → (reboot if returns)                              │    │ 
│  └─────────────────────────────────────────────────────────────┘    │ 
╠═════════════════════════════════════════════════════════════════════╣ 
│                         HARDWARE                                    │ 
│  ┌──────┐ ┌───────┐ ┌───────┐ ┌─────┐ ┌─────────┐ ┌────────────┐    │   
│  │ GPIO │ │ UART  │ │ Timer │ │ SPI │ │ SD/EMMC │ │ NRF24L01+  │    │   
│  │ pins │ │ serial│ │ ARM   │ │ bus │ │ card    │ │ 2.4GHz     │    │  
│  └──────┘ └───────┘ └───────┘ └─────┘ └─────────┘ └────────────┘    │   
│                    BCM2835 (RPi Zero)                               │
└─────────────────────────────────────────────────────────────────────┘  
```

