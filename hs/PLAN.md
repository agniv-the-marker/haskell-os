# overall structure

first we need to bring in all the FFI so need a file for that

we need a way to allocate memory asw

what we want:

- allocation
- gpio
- uart
- timer
- interrupts
- virtual memory
- fat32 for filesystem
- nrf wireless communication
- shell

originally included threading but because of mhs instead using haskell's built in concurrency module (simple green threading, swap between 'threads' based on reduction steps used) 

ooh running lisp on pi would be cool, uses parsers? which the shell can use too