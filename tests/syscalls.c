/*
 * Minimal picolibc host syscalls + stdio device for the CV32E40P example_tb
 * Verilator flow.
 *
 * The example_tb ships a newlib-style syscalls.c (underscore-prefixed
 * `_write`/`_read`/... plus `#include <newlib.h>`). The toolchain installed
 * for this project is picolibc 1.8.6:
 *   - its libc references POSIX-style syscall names (no leading underscore:
 *     `write`, `read`, `close`, ...) and `sbrk`;
 *   - its tinystdio `stdin`/`stdout`/`stderr` FILE objects are NOT defined in
 *     libc.a (only weak references); they must be supplied by the host.
 *
 * This file provides the POSIX syscall stubs, the stdio devices (stdout writes
 * to the memory-mapped peripheral 0x10000000), and `_exit` (writes the exit
 * peripheral 0x20000004).
 *
 * No functional RTL is modified; this is a new benchmark-support file only.
 */

#include <stdio.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/times.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define STDOUT_REG 0x10000000
#define EXIT_REG   0x20000004
#define STDOUT_FILENO 1

/* heap bounds are provided by link.ld (.heap section) */
extern char __heap_start[];
extern char __heap_end[];
static char *brk = __heap_start;

/* ---- stdio devices ---------------------------------------------------- */

static int stdout_putc(char c, struct __file *f)
{
    (void)f;
    *(volatile int *)STDOUT_REG = (unsigned char)c;
    return (unsigned char)c;
}

static int stdin_getc(struct __file *f)
{
    (void)f;
    return EOF;
}

static struct __file __my_stdout = FDEV_SETUP_STREAM(stdout_putc, NULL, NULL, __SWR);
static struct __file __my_stdin  = FDEV_SETUP_STREAM(NULL, stdin_getc, NULL, __SRD);
static struct __file __my_stderr = FDEV_SETUP_STREAM(stdout_putc, NULL, NULL, __SWR);

FILE *const stdout = &__my_stdout;
FILE *const stdin  = &__my_stdin;
FILE *const stderr = &__my_stderr;

/* ---- syscalls --------------------------------------------------------- */

void _exit(int status)
{
    *(volatile int *)EXIT_REG = status;
    asm volatile("wfi");
    for (;;)
        ;
}

void *sbrk(ptrdiff_t incr)
{
    char *old_brk = brk;
    char *new_brk = brk + incr;

    if (new_brk > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    brk = new_brk;
    return old_brk;
}

ssize_t write(int fd, const void *ptr, size_t len)
{
    if (fd != STDOUT_FILENO) {
        errno = ENOSYS;
        return -1;
    }
    const char *p = ptr;
    for (size_t i = 0; i < len; i++)
        *(volatile int *)STDOUT_REG = p[i];
    return len;
}

ssize_t read(int fd, void *ptr, size_t len)
{
    (void)fd;
    (void)ptr;
    (void)len;
    return 0;
}

int close(int fd)
{
    (void)fd;
    return -1;
}

off_t lseek(int fd, off_t offset, int whence)
{
    (void)fd;
    (void)offset;
    (void)whence;
    return 0;
}

int fstat(int fd, struct stat *st)
{
    (void)fd;
    st->st_mode = S_IFCHR;
    return 0;
}

int isatty(int fd)
{
    return (fd == STDOUT_FILENO);
}

int open(const char *path, int flags, ...)
{
    (void)path;
    (void)flags;
    errno = ENOENT;
    return -1;
}

int unlink(const char *path)
{
    (void)path;
    errno = ENOENT;
    return -1;
}

pid_t getpid(void)
{
    return 1;
}

int kill(pid_t pid, int sig)
{
    (void)pid;
    (void)sig;
    errno = EINVAL;
    return -1;
}

int gettimeofday(struct timeval *tv, void *tz)
{
    (void)tv;
    (void)tz;
    errno = ENOSYS;
    return -1;
}

clock_t times(struct tms *buf)
{
    (void)buf;
    return (clock_t)-1;
}

long sysconf(int name)
{
    (void)name;
    return -1;
}

int getentropy(void *buf, size_t len)
{
    (void)buf;
    (void)len;
    errno = ENOSYS;
    return -1;
}
