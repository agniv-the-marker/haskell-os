/*
 * rts-stubs.c - runtime stubs for bare metal
 *
 * when running a lot of functions needed from eval.c/newlib libc.a/linker
 * uses libc a lot and copies the code over. used claude here since idk
 * how c works lol
 *
 * claude summary:
 *   - String/memory functions (memcpy, memset, memmove, memcmp, strlen,
 *     strcmp, strncmp, strcpy, strcat, strchr): simplified versions of
 *     cs140e libpi/libc/ implementations (same algorithms, without the
 *     alignment optimizations). strchr/strcat cite uclibc, strncmp cites
 *     clc-wiki.net in the libpi originals.
 *   - printf/putchar: same UART-routing pattern as libpi/libc/printk.c
 *   - vsnprintf/snprintf: inspired by libpi/libc/sprintk.c (vsnprintk),
 *     extended with %ld/%lld/%zd, width/precision skipping, and %p.
 *   - malloc/calloc/realloc: wrappers around kmalloc (libpi rpi.h:148),
 *     same bump-allocator-no-free philosophy as libpi.
 *   - Division helpers: ARM EABI spec, IHI0043D section 4.3.1
 *     (shift-based unsigned/signed division).
 *   - __popcountsi2: Hacker's Delight (Henry S. Warren Jr., Ch. 5),
 *     identical to LLVM compiler-rt/lib/builtins/popcountsi2.c.
 *   - __popcountdi2/__ctzdi2/__clzdi2: same split-into-32-bit pattern
 *     as LLVM compiler-rt.
 *   - I/O stubs (_write, _read, _close, etc.): newlib libgloss syscall
 *     stub convention, routed to c_uart_put8/c_uart_get8 (libpi's
 *     uart_put8/uart_get8, rpi.h:78/75).
 *   - Time stubs: route to timer_get_usec (libpi rpi.h:114) and
 *     c_delay_us (libpi's delay_us, rpi.h:106).
 *   - Process stubs (_exit, abort): call reboot (libpi rpi.h:123).
 *   - strncpy, strrchr, strstr, strdup, strndup, strtol, ctype funcs,
 *     qsort, bsearch, setlocale: textbook C standard library
 *     implementations, no specific source.
 *   - FILE* stubs, signal/pthread/environment stubs: no-op stubs to
 *     satisfy MicroHs eval.c linker demands.
 *   - LZ77 stubs: panic stubs for MicroHs compression (not needed on
 *     bare metal).
 */

#include "hal.h"
#include <stdarg.h>
#include <stdint.h>

void *memcpy(void *dest, const void *src, unsigned n);
void *memset(void *s, int c, unsigned n);
unsigned strlen(const char *s);
void *malloc(unsigned size);
void free(void *ptr);

// avoid libgcc for division so we need to define our own

unsigned __aeabi_uidiv(unsigned num, unsigned den) {
    if (den == 0) return 0;
    unsigned q = 0;
    int shift = 0;
    unsigned d = den;
    while (d <= num && !(d & (1u << 31))) { d <<= 1; shift++; }
    if (d > num) { d >>= 1; shift--; }
    for (; shift >= 0; shift--) {
        if (num >= d) { num -= d; q |= (1u << shift); }
        d >>= 1;
    }
    return q;
}

int __aeabi_idiv(int num, int den) {
    if (den == 0) return 0;
    int sign = 1;
    if (num < 0) { num = -num; sign = -sign; }
    if (den < 0) { den = -den; sign = -sign; }
    unsigned q = __aeabi_uidiv((unsigned)num, (unsigned)den);
    return sign < 0 ? -(int)q : (int)q;
}

// weak haskell entry point thats overriden by mhs output
void __attribute__((weak)) hs_main(void) {
    uart_puts("ERROR: hs_main not linked, no haskell code\r\n");
    reboot();
}

#define MALLOC_HEADER_SIZE 8

void *malloc(unsigned size) {
    unsigned char *raw = (unsigned char *)kmalloc(size + MALLOC_HEADER_SIZE);
    *(unsigned *)raw = size;
    return raw + MALLOC_HEADER_SIZE;
}

void free(void *ptr) {
    (void)ptr; // we aint freeing jack shit twin
}

void *calloc(unsigned nmemb, unsigned size) {
    unsigned total = nmemb * size;
    void *p = malloc(total);
    memset(p, 0, total);
    return p;
}

void *realloc(void *ptr, unsigned size) {
    if (size == 0) { free(ptr); return (void*)0; }
    if (!ptr) return malloc(size);
    unsigned char *old_raw = (unsigned char *)ptr - MALLOC_HEADER_SIZE;
    unsigned old_size = *(unsigned *)old_raw;
    void *p = malloc(size);
    unsigned to_copy = old_size < size ? old_size : size;
    memcpy(p, ptr, to_copy);
    return p;
}

void *_sbrk(int incr) { return malloc(incr > 0 ? (unsigned)incr : 0); }
void *mmap(void *a, unsigned len, int p, int f, int fd, unsigned o) {
    (void)a; (void)p; (void)f; (void)fd; (void)o; return malloc(len);
}
int munmap(void *a, unsigned len) { (void)a; (void)len; return 0; }
int brk(void *a) { (void)a; return 0; }

int _write(int fd, const char *buf, int count) {
    (void)fd;
    for (int i = 0; i < count; i++) {
        if (buf[i] == '\n') c_uart_put8('\r');
        c_uart_put8(buf[i]);
    }
    return count;
}

int _read(int fd, char *buf, int count) {
    (void)fd;
    for (int i = 0; i < count; i++) buf[i] = c_uart_get8();
    return count;
}

int _close(int fd) { (void)fd; return -1; }
int _open(const char *p, int f, int m) { (void)p; (void)f; (void)m; return -1; }
int _lseek(int fd, int o, int w) { (void)fd; (void)o; (void)w; return -1; }
int _fstat(int fd, void *st) { (void)fd; (void)st; return -1; }
int _isatty(int fd) { (void)fd; return 1; }

// eval.c needs stdout/stderr/stdin and wants them to be FILE* 
// so we can just do a dummy one lol

typedef struct { int fd; } FILE_t;
static FILE_t stdout_file = { 1 };
static FILE_t stderr_file = { 2 };
static FILE_t stdin_file  = { 0 };
FILE_t *stdout = &stdout_file;
FILE_t *stderr = &stderr_file;
FILE_t *stdin  = &stdin_file;

int fprintf(void *s, const char *fmt, ...) { (void)s; uart_puts(fmt); return 0; }
int printf(const char *fmt, ...) { uart_puts(fmt); return 0; }
int putchar(int c) { if (c == '\n') c_uart_put8('\r'); c_uart_put8(c); return c; }
int fputc(int c, void *s) { (void)s; return putchar(c); }
int fputs(const char *s, void *st) { (void)st; uart_puts(s); return 0; }
int fflush(void *s) { (void)s; c_uart_flush_tx(); return 0; }
void *fopen(const char *p, const char *m) { (void)p; (void)m; return (void*)0; }
int fclose(void *s) { (void)s; return 0; }
unsigned fread(void *p, unsigned sz, unsigned n, void *s) { (void)p; (void)sz; (void)n; (void)s; return 0; }
unsigned fwrite(const void *p, unsigned sz, unsigned n, void *s) {
    (void)s; const char *c = (const char *)p; unsigned t = sz * n;
    for (unsigned i = 0; i < t; i++) { if (c[i] == '\n') c_uart_put8('\r'); c_uart_put8(c[i]); }
    return n;
}
int setvbuf(void *s, char *b, int m, unsigned sz) { (void)s; (void)b; (void)m; (void)sz; return 0; }

// for newlib's getenv (eval.c uses it)
char **environ = (char **)0;
char *getenv(const char *name) { (void)name; return (char *)0; }

typedef void (*sighandler_t)(int);
sighandler_t signal(int sig, sighandler_t h) { (void)sig; (void)h; return (sighandler_t)0; }
int sigaction(int sig, const void *a, void *o) { (void)sig; (void)a; (void)o; return 0; }
int sigprocmask(int h, const void *s, void *o) { (void)h; (void)s; (void)o; return 0; }

// mhs eval.c uses pthreads

typedef unsigned long pthread_t;
typedef unsigned long pthread_mutex_t;
typedef unsigned long pthread_cond_t;
typedef unsigned long pthread_key_t;

int pthread_create(pthread_t *t, const void *a, void *(*f)(void*), void *arg) {
    (void)t; (void)a; (void)f; (void)arg; return -1;
}
int pthread_mutex_lock(pthread_mutex_t *m)   { (void)m; return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_init(pthread_mutex_t *m, const void *a) { (void)m; (void)a; return 0; }
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) { (void)c; (void)m; return 0; }
int pthread_cond_signal(pthread_cond_t *c)    { (void)c; return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { (void)c; return 0; }
int pthread_key_create(pthread_key_t *k, void (*d)(void*)) { (void)k; (void)d; return 0; }
void *pthread_getspecific(pthread_key_t k) { (void)k; return (void*)0; }
int pthread_setspecific(pthread_key_t k, const void *v) { (void)k; (void)v; return 0; }

struct timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int id, struct timespec *tp) {
    (void)id; unsigned us = timer_get_usec();
    tp->tv_sec = us / 1000000; tp->tv_nsec = (us % 1000000) * 1000; return 0;
}
unsigned sleep(unsigned s) { c_delay_us(s * 1000000); return 0; }
int usleep(unsigned us) { c_delay_us(us); return 0; }
int nanosleep(const struct timespec *r, struct timespec *rem) {
    (void)rem; c_delay_us(r->tv_sec * 1000000 + r->tv_nsec / 1000); return 0;
}

void _exit(int s) { (void)s; uart_puts("exit()\r\n"); reboot(); __builtin_unreachable(); }
void abort(void) { uart_puts("abort()\r\n"); reboot(); __builtin_unreachable(); }
int _getpid(void) { return 1; }
int _kill(int p, int s) { (void)p; (void)s; return -1; }

// note: these are not optimized at all, just straightforward implementations

void *memset(void *s, int c, unsigned n) {
    unsigned char *p = s; while (n--) *p++ = (unsigned char)c; return s;
}
void *memcpy(void *d, const void *s, unsigned n) {
    unsigned char *dd = d; const unsigned char *ss = s; while (n--) *dd++ = *ss++; return d;
}
void *memmove(void *d, const void *s, unsigned n) {
    unsigned char *dd = d; const unsigned char *ss = s;
    if (dd < ss) { while (n--) *dd++ = *ss++; }
    else { dd += n; ss += n; while (n--) *--dd = *--ss; }
    return d;
}
int memcmp(const void *a, const void *b, unsigned n) {
    const unsigned char *aa = a, *bb = b;
    while (n--) { if (*aa != *bb) return *aa - *bb; aa++; bb++; } return 0;
}
unsigned strlen(const char *s) { unsigned n = 0; while (*s++) n++; return n; }
int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; } return *(unsigned char*)a - *(unsigned char*)b;
}
int strncmp(const char *a, const char *b, unsigned n) {
    while (n && *a && *a == *b) { a++; b++; n--; } if (!n) return 0;
    return *(unsigned char*)a - *(unsigned char*)b;
}
char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)); return r; }
char *strncpy(char *d, const char *s, unsigned n) {
    char *r = d; while (n && (*d++ = *s++)) n--; while (n--) *d++ = '\0'; return r;
}
char *strcat(char *d, const char *s) { char *r = d; while (*d) d++; while ((*d++ = *s++)); return r; }
char *strchr(const char *s, int c) {
    while (*s) { if (*s == (char)c) return (char*)s; s++; }
    return c == '\0' ? (char*)s : (char*)0;
}
char *strrchr(const char *s, int c) {
    const char *last = (char*)0;
    while (*s) { if (*s == (char)c) last = s; s++; }
    return c == '\0' ? (char*)s : (char*)last;
}
char *strstr(const char *h, const char *n) {
    if (!*n) return (char*)h;
    for (; *h; h++) { const char *a=h, *b=n; while (*a && *b && *a==*b) {a++;b++;} if (!*b) return (char*)h; }
    return (char*)0;
}
char *strdup(const char *s) { unsigned l = strlen(s)+1; char *d = malloc(l); memcpy(d,s,l); return d; }
char *strndup(const char *s, unsigned n) {
    unsigned l = strlen(s); if (l > n) l = n;
    char *d = malloc(l+1); memcpy(d,s,l); d[l] = '\0'; return d;
}

// just typechecking

int isdigit(int c)  { return c >= '0' && c <= '9'; }
int isspace(int c)  { return c==' '||c=='\t'||c=='\n'||c=='\r'||c=='\f'||c=='\v'; }
int isalpha(int c)  { return (c>='a'&&c<='z')||(c>='A'&&c<='Z'); }
int isalnum(int c)  { return isalpha(c)||isdigit(c); }
int isupper(int c)  { return c>='A'&&c<='Z'; }
int islower(int c)  { return c>='a'&&c<='z'; }
int isprint(int c)  { return c>=0x20&&c<=0x7E; }
int iscntrl(int c)  { return (c>=0&&c<0x20)||c==0x7F; }
int ispunct(int c)  { return isprint(c)&&!isalnum(c)&&!isspace(c); }
int isxdigit(int c) { return isdigit(c)||(c>='a'&&c<='f')||(c>='A'&&c<='F'); }
int toupper(int c)  { return (c>='a'&&c<='z') ? c-32 : c; }
int tolower(int c)  { return (c>='A'&&c<='Z') ? c+32 : c; }

// string conversion needed for parsing numeric literals

long strtol(const char *s, char **end, int base) {
    long r = 0; int sign = 1;
    while (isspace(*s)) s++;
    if (*s == '-') { sign = -1; s++; } else if (*s == '+') s++;
    if (base == 0) {
        if (*s=='0' && (s[1]=='x'||s[1]=='X')) { base=16; s+=2; }
        else if (*s=='0') { base=8; s++; } else base=10;
    } else if (base==16 && *s=='0' && (s[1]=='x'||s[1]=='X')) s+=2;
    while (*s) {
        int d; if (*s>='0'&&*s<='9') d=*s-'0';
        else if (*s>='a'&&*s<='z') d=*s-'a'+10;
        else if (*s>='A'&&*s<='Z') d=*s-'A'+10; else break;
        if (d>=base) break; r = r*base+d; s++;
    }
    if (end) *end = (char*)s; return r*sign;
}
unsigned long strtoul(const char *s, char **end, int base) { return (unsigned long)strtol(s,end,base); }
int atoi(const char *s) { return (int)strtol(s,(char**)0,10); }

/* --------------------------------------------------------- */
/* snprintf / vsnprintf (minimal)                            */
/* Inspired by libpi/libc/sprintk.c (vsnprintk): same       */
/* concept (walk format string, emit to buffer), extended    */
/* with %ld/%lld/%zd, width/precision skipping, and %p.     */
/* --------------------------------------------------------- */

static int fmt_int(char *buf, int bsz, int *pos, unsigned val) {
    char tmp[12]; int len = 0;
    if (val == 0) tmp[len++] = '0';
    else while (val > 0) { tmp[len++] = '0' + (val % 10); val /= 10; }
    for (int i = len-1; i >= 0; i--) if (*pos < bsz-1) buf[(*pos)++] = tmp[i];
    return len;
}

int vsnprintf(char *buf, unsigned size, const char *fmt, va_list ap) {
    int pos = 0; if (size == 0) return 0;
    while (*fmt) {
        if (*fmt != '%') { if (pos < (int)size-1) buf[pos++] = *fmt; fmt++; continue; }
        fmt++;
        while (*fmt=='-'||*fmt=='+'||*fmt==' '||*fmt=='0'||*fmt=='#'||*fmt=='\'') fmt++;
        while (*fmt>='0'&&*fmt<='9') fmt++;
        if (*fmt == '.') { fmt++; while (*fmt>='0'&&*fmt<='9') fmt++; }
        int is_long = 0;
        if (*fmt == 'l') { fmt++; is_long = 1; }
        if (*fmt == 'l') { fmt++; is_long = 2; }
        if (*fmt == 'z') { fmt++; is_long = 1; }
        switch (*fmt) {
        case 'd': case 'i': {
            long v = is_long ? va_arg(ap,long) : (long)va_arg(ap,int);
            if (v < 0) { if (pos<(int)size-1) buf[pos++]='-'; v=-v; }
            fmt_int(buf,size,&pos,(unsigned)v); break; }
        case 'u': { unsigned long v = is_long ? va_arg(ap,unsigned long) : (unsigned long)va_arg(ap,unsigned);
            fmt_int(buf,size,&pos,(unsigned)v); break; }
        case 'x': case 'X': { unsigned long v = is_long ? va_arg(ap,unsigned long) : (unsigned long)va_arg(ap,unsigned);
            char h[9]; int l=0; if (v==0) h[l++]='0'; else while(v){int d=v&0xF;h[l++]=d<10?'0'+d:'a'+d-10;v>>=4;}
            for (int i=l-1;i>=0;i--) if(pos<(int)size-1) buf[pos++]=h[i]; break; }
        case 'p': { void *p=va_arg(ap,void*); unsigned v=(unsigned)(uintptr_t)p;
            if(pos<(int)size-1)buf[pos++]='0'; if(pos<(int)size-1)buf[pos++]='x';
            for(int i=28;i>=0;i-=4){int d=(v>>i)&0xF; if(pos<(int)size-1)buf[pos++]=d<10?'0'+d:'a'+d-10;} break; }
        case 's': { const char *s=va_arg(ap,const char*); if(!s)s="(null)";
            while(*s&&pos<(int)size-1)buf[pos++]=*s++; break; }
        case 'c': { int c=va_arg(ap,int); if(pos<(int)size-1)buf[pos++]=c; break; }
        case '%': if(pos<(int)size-1)buf[pos++]='%'; break;
        case '\0': goto done;
        default: if(pos<(int)size-1)buf[pos++]='%'; if(pos<(int)size-1)buf[pos++]=*fmt; break;
        } fmt++;
    }
done: buf[pos]='\0'; return pos;
}

int snprintf(char *buf, unsigned sz, const char *fmt, ...) {
    va_list ap; va_start(ap,fmt); int r=vsnprintf(buf,sz,fmt,ap); va_end(ap); return r;
}
int sprintf(char *buf, const char *fmt, ...) {
    va_list ap; va_start(ap,fmt); int r=vsnprintf(buf,0x7FFFFFFF,fmt,ap); va_end(ap); return r;
}
int sscanf(const char *s, const char *f, ...) { (void)s; (void)f; return 0; }

/* --------------------------------------------------------- */
/* qsort / bsearch                                           */
/* qsort: insertion sort (not quicksort), textbook.          */
/* bsearch: standard binary search, textbook.                */
/* No libpi equivalent.                                      */
/* --------------------------------------------------------- */

void qsort(void *base, unsigned n, unsigned sz, int (*cmp)(const void*,const void*)) {
    char *a = (char*)base; char *tmp = (char*)malloc(sz);
    for (unsigned i=1; i<n; i++) {
        memcpy(tmp, a+i*sz, sz); int j=(int)i-1;
        while (j>=0 && cmp(a+j*sz,tmp)>0) { memcpy(a+(j+1)*sz, a+j*sz, sz); j--; }
        memcpy(a+(j+1)*sz, tmp, sz);
    } free(tmp);
}

void *bsearch(const void *key, const void *base, unsigned n, unsigned sz,
              int (*cmp)(const void*,const void*)) {
    const char *a=(const char*)base; unsigned lo=0, hi=n;
    while (lo<hi) { unsigned m=lo+(hi-lo)/2; int c=cmp(key,a+m*sz);
        if(c<0)hi=m; else if(c>0)lo=m+1; else return(void*)(a+m*sz); }
    return (void*)0;
}

/* --------------------------------------------------------- */
/* Locale                                                    */
/* No-op stub returning "C". Required by MicroHs eval.c.     */
/* --------------------------------------------------------- */

char *setlocale(int cat, const char *loc) { (void)cat; (void)loc; return "C"; }

/* --------------------------------------------------------- */
/* MicroHs runtime stubs                                     */
/* Panic stubs for LZ77 compression (not needed on bare      */
/* metal). Required by MicroHs eval.c.                       */
/* --------------------------------------------------------- */

struct BFILE;
struct BFILE *add_lz77_decompressor(struct BFILE *bf) {
    uart_puts("PANIC: LZ77 not available\r\n"); reboot(); return bf;
}
struct BFILE *add_lz77_compressor(struct BFILE *bf) {
    uart_puts("PANIC: LZ77 not available\r\n"); reboot(); return bf;
}

/* --------------------------------------------------------- */
/* GCC builtins (avoid libgcc)                               */
/* __popcountsi2: Hacker's Delight (Henry S. Warren Jr.,     */
/*   Ch. 5), identical to LLVM compiler-rt popcountsi2.c.    */
/* __popcountdi2/__ctzdi2/__clzdi2: split 64-bit into two    */
/*   32-bit halves, same pattern as LLVM compiler-rt.        */
/* --------------------------------------------------------- */

int __popcountsi2(unsigned x) {
    x = x - ((x >> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333);
    x = (x + (x >> 4)) & 0x0F0F0F0F;
    return (x * 0x01010101) >> 24;
}
int __popcountdi2(unsigned long long x) {
    return __popcountsi2((unsigned)x) + __popcountsi2((unsigned)(x >> 32));
}
int __ctzdi2(unsigned long long x) {
    if ((unsigned)x) return __builtin_ctz((unsigned)x);
    return 32 + __builtin_ctz((unsigned)(x >> 32));
}
int __clzdi2(unsigned long long x) {
    if ((unsigned)(x >> 32)) return __builtin_clz((unsigned)(x >> 32));
    return 32 + __builtin_clz((unsigned)x);
}
