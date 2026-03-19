/*
 * extra.c - based on
 * https://github.com/augustss/MicroHs/blob/master/src/runtime/unix/extra.c
 * 
 * need to give mhs access to functions via uart
 */

#include "hal.h"

// reboot pi
void myexit(int n) {
    if (n != 0) {
        uart_puts("EXIT with code ");
        uart_put_uint(n);
        uart_puts("\r\n");
    }
    uart_puts("Halting.\r\n");
    reboot();
    __builtin_unreachable();
}

int mhs_getraw(void) {
    if (c_uart_has_data())
        return (int)c_uart_get8();
    return -1;
}

void mhs_putraw(int c) {
    c_uart_put8((unsigned)c);
}

// eval.c needs clock_init/clock_t/clock_get/clock_sleep for threadDelay support
// timer_get_usec 32-bit so overflow at over an hour i think

// need timer function
intptr_t mhs_gettimemilli(void) {
    return (intptr_t)(timer_get_usec() / 1000);
}

int64_t mhs_clock_get_usec(void) {
    return (int64_t)timer_get_usec();
}

#define CLOCK_INIT()  do { } while(0)
#define CLOCK_T       int64_t
#define CLOCK_GET     mhs_clock_get_usec
#define CLOCK_SLEEP(us) c_delay_us((unsigned)(us))

// add debug print support with %-string commands 
// use https://cplusplus.com/reference/cstdio/printf/ 
// use https://codebrowser.dev/glibc/glibc/stdio-common/vfprintf-internal.c.html#__vfprintf_internal
#include <stdarg.h>

int mhs_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int count = 0;

    while (*fmt) {
        if (*fmt != '%') {
            if (*fmt == '\n')
                c_uart_put8('\r');
            c_uart_put8(*fmt);
            fmt++;
            count++;
            continue;
        }
        fmt++; // skip %

        // skip flags since idt they matter
        while (*fmt == '-' || *fmt == '+' || *fmt == ' ' || *fmt == '0' || *fmt == '#' || *fmt == '\'')
            fmt++;

        // width handle
        while (*fmt >= '0' && *fmt <= '9')
            fmt++;

        // precision handle
        if (*fmt == '.') {
            fmt++;
            while (*fmt >= '0' && *fmt <= '9')
                fmt++;
        }

        // length mod
        int is_long = 0;
        if (*fmt == 'l') { fmt++; is_long = 1; }
        if (*fmt == 'l') { fmt++; is_long = 2; }
        if (*fmt == 'z') { fmt++; is_long = 1; }

        // conversion
        switch (*fmt) {
        case 'd': case 'i': {
            long val = is_long >= 2 ? (long)va_arg(ap, long long) :
                       is_long == 1 ? va_arg(ap, long) :
                       (long)va_arg(ap, int);
            if (val < 0) { c_uart_put8('-'); val = -val; count++; }
            uart_put_uint((unsigned)val);
            count++;
            break;
        }
        case 'u': {
            unsigned long val = is_long >= 2 ? (unsigned long)va_arg(ap, unsigned long long) :
                                is_long == 1 ? (unsigned long)va_arg(ap, unsigned long) :
                                (unsigned long)va_arg(ap, unsigned int);
            uart_put_uint((unsigned)val);
            count++;
            break;
        }
        case 'x': case 'X': {
            unsigned long val = is_long >= 2 ? (unsigned long)va_arg(ap, unsigned long long) :
                                is_long == 1 ? (unsigned long)va_arg(ap, unsigned long) :
                                (unsigned long)va_arg(ap, unsigned int);
            uart_put_hex((unsigned)val);
            count++;
            break;
        }
        case 'p': {
            void *p = va_arg(ap, void *);
            uart_put_hex((unsigned)(uintptr_t)p);
            count++;
            break;
        }
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            uart_puts(s);
            count++;
            break;
        }
        case 'c': {
            int c = va_arg(ap, int);
            c_uart_put8(c);
            count++;
            break;
        }
        case 'f': case 'e': case 'g': {
            // WANT_FLOAT is 0 so we can skip things
            (void)va_arg(ap, double);
            uart_puts("<float>");
            count++;
            break;
        }
        case '%':
            c_uart_put8('%');
            count++;
            break;
        case '\0':
            goto done;
        default:
            c_uart_put8('%');
            c_uart_put8(*fmt);
            count++;
            break;
        }
        fmt++;
    }
done:
    va_end(ap);
    return count;
}
