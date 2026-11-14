// ep2test — epoll_pwait2 (syscall 441) check for the RS4 kernel, no libc.
//
// Raw syscalls only, so one source builds for arm64 (native table) and for 32-bit ARM
// (the arm64 compat table, compat_sys_epoll_pwait2): see build.sh next to this file.
// On a kernel without the backport, test 1 prints ENOSYS and the run stops there.
// Exit status: 0 = every check passed, 1 = a check failed, 2 = epoll_pwait2 missing.
//
// It also re-checks plain epoll_pwait, whose timeout path the backport rewrote
// (ms -> timespec64), so a regression in the old syscall shows up here too.

typedef unsigned long long u64;
typedef long long s64;
typedef unsigned int u32;

#if defined(__aarch64__)
#define NR_read             63
#define NR_write            64
#define NR_exit_group       94
#define NR_pipe2            59
#define NR_epoll_create1    20
#define NR_epoll_ctl        21
#define NR_epoll_pwait      22
#define NR_clock_gettime64  113   // 64-bit timespec natively
#define NR_clock_nanosleep64 115
#define NR_clone            220
#define NR_wait4            260
#define ARCH "arm64 (native table)"
static long sc6(long n, long a, long b, long c, long d, long e, long f)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
			 : "memory", "cc");
	return x0;
}
__asm__(".text\n.global _start\n_start:\n mov x29, #0\n mov x30, #0\n bl main\n mov x8, #94\n svc #0\n");
#elif defined(__arm__)
#define NR_read             3
#define NR_write            4
#define NR_exit_group       248
#define NR_pipe2            359
#define NR_epoll_create1    357
#define NR_epoll_ctl        251
#define NR_epoll_pwait      346
#define NR_clock_gettime64  403   // clock_gettime64 (__kernel_timespec)
#define NR_clock_nanosleep64 407  // clock_nanosleep_time64
#define NR_clone            120
#define NR_wait4            114
#define ARCH "arm32 (compat table)"
static long sc6(long n, long a, long b, long c, long d, long e, long f)
{
	register long r7 __asm__("r7") = n;
	register long r0 __asm__("r0") = a;
	register long r1 __asm__("r1") = b;
	register long r2 __asm__("r2") = c;
	register long r3 __asm__("r3") = d;
	register long r4 __asm__("r4") = e;
	register long r5 __asm__("r5") = f;
	__asm__ volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r5)
			 : "memory", "cc");
	return r0;
}
__asm__(".text\n.global _start\n_start:\n mov fp, #0\n mov lr, #0\n bl main\n mov r7, #248\n svc #0\n");
#elif defined(__x86_64__)
// Only to validate this test on a PC kernel that has epoll_pwait2 (qemu-user lacks 441).
#define NR_read             0
#define NR_write            1
#define NR_exit_group       231
#define NR_pipe2            293
#define NR_epoll_create1    291
#define NR_epoll_ctl        233
#define NR_epoll_pwait      281
#define NR_clock_gettime64  228
#define NR_clock_nanosleep64 230
#define NR_clone            56
#define NR_wait4            61
#define ARCH "x86-64 (host validation only)"
#define EPEV_PACKED __attribute__((packed))
static long sc6(long n, long a, long b, long c, long d, long e, long f)
{
	register long r10 __asm__("r10") = d;
	register long r8 __asm__("r8") = e;
	register long r9 __asm__("r9") = f;
	long ret;
	__asm__ volatile("syscall" : "=a"(ret) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
			 : "rcx", "r11", "memory");
	return ret;
}
__asm__(".text\n.global _start\n_start:\n xor %ebp, %ebp\n and $-16, %rsp\n call main\n mov %eax, %edi\n mov $231, %eax\n syscall\n");
#else
#error "arm64, arm or x86-64 only"
#endif
#ifndef EPEV_PACKED
#define EPEV_PACKED
#endif

#define NR_epoll_pwait2 441
#define EPOLL_CTL_ADD 1
#define EPOLLIN 0x001
#define ENOSYS 38
#define EINVAL 22
#define EFAULT 14
#define SIGCHLD 17
#define CLOCK_MONOTONIC 1

struct kts { s64 tv_sec; s64 tv_nsec; };                       // struct __kernel_timespec
#ifdef __x86_64__
struct epev { u32 events; u64 data; } EPEV_PACKED;              // x86-64 layout (12 B, packed)
#else
struct epev { u32 events; u32 pad; u64 data; };                 // arm64 / ARM EABI layout (16 B)
#endif

// clang may emit calls to these for struct copies/initialisers.
void *memset(void *d, int c, unsigned long n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, unsigned long n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

// 64-bit divide without the compiler's runtime helper (32-bit ARM would call __aeabi_*divmod).
static u64 udiv(u64 n, u64 d, u64 *rem)
{
	u64 q = 0, r = 0;
	for (int i = 63; i >= 0; i--) {
		r = (r << 1) | ((n >> i) & 1);
		if (r >= d) { r -= d; q |= 1ULL << i; }
	}
	if (rem) *rem = r;
	return q;
}

static unsigned long slen(const char *s) { unsigned long n = 0; while (s[n]) n++; return n; }
static void puts_(const char *s) { sc6(NR_write, 1, (long)s, (long)slen(s), 0, 0, 0); }
static void putnum(s64 v)
{
	char b[24]; int i = 23; int neg = v < 0; u64 u = neg ? (u64)-v : (u64)v;
	b[i] = 0;
	do { u64 d; u = udiv(u, 10, &d); b[--i] = (char)('0' + d); } while (u);
	if (neg) b[--i] = '-';
	puts_(b + i);
}

static s64 now_us(void)
{
	struct kts t;
	sc6(NR_clock_gettime64, CLOCK_MONOTONIC, (long)&t, 0, 0, 0, 0);
	return t.tv_sec * 1000000LL + (s64)udiv((u64)t.tv_nsec, 1000, 0);
}

static int fails;
static void check(const char *what, long got, long want, s64 us, s64 us_lo, s64 us_hi)
{
	int ok = got == want && us >= us_lo && us <= us_hi;
	puts_(ok ? "  PASS  " : "  FAIL  ");
	puts_(what); puts_(": ret "); putnum(got); puts_(" (want "); putnum(want); puts_("), ");
	putnum(us); puts_(" us (window "); putnum(us_lo); puts_("..");
	putnum(us_hi); puts_(")\n");
	if (!ok) fails++;
}

static long pwait2(int ep, struct epev *ev, int n, const struct kts *ts, const u64 *mask, long masksz)
{
	return sc6(NR_epoll_pwait2, ep, (long)ev, n, (long)ts, (long)mask, masksz);
}

int main(void)
{
	struct epev ev[4], add;
	int quiet[2], busy[2], ep_quiet, ep_busy;
	struct kts ts;
	u64 mask = 0;
	s64 t0;
	long r;

	memset(&add, 0, sizeof(add)); add.events = EPOLLIN; add.data = 0x1234;
	puts_("ep2test: epoll_pwait2 (441) on " ARCH "\n");
	sc6(NR_pipe2, (long)quiet, 0, 0, 0, 0, 0);
	sc6(NR_pipe2, (long)busy, 0, 0, 0, 0, 0);
	ep_quiet = (int)sc6(NR_epoll_create1, 0, 0, 0, 0, 0, 0);
	ep_busy  = (int)sc6(NR_epoll_create1, 0, 0, 0, 0, 0, 0);
	sc6(NR_epoll_ctl, ep_quiet, EPOLL_CTL_ADD, quiet[0], (long)&add, 0, 0);
	sc6(NR_epoll_ctl, ep_busy,  EPOLL_CTL_ADD, busy[0],  (long)&add, 0, 0);
	sc6(NR_write, busy[1], (long)"x", 1, 0, 0, 0);          // ep_busy is always readable

	// 1. existence: zero timeout on an idle set -> 0 at once (ENOSYS = no backport)
	ts.tv_sec = 0; ts.tv_nsec = 0;
	t0 = now_us(); r = pwait2(ep_quiet, ev, 4, &ts, 0, 0);
	if (r == -ENOSYS) {
		puts_("  epoll_pwait2 -> ENOSYS (errno 38): this kernel has NO epoll_pwait2\n");
		return 2;
	}
	check("1 zero timeout, idle set   ", r, 0, now_us() - t0, 0, 20000);

	// 2. 50 ms timeout on an idle set -> 0 after ~50 ms (hrtimer slack is small)
	ts.tv_nsec = 50 * 1000000LL;
	t0 = now_us(); r = pwait2(ep_quiet, ev, 4, &ts, 0, 0);
	check("2 50 ms timeout, idle set  ", r, 0, now_us() - t0, 49000, 150000);

	// 3. sub-millisecond: 1.5 ms -> not rounded up to whole ms like epoll_pwait's int ms
	ts.tv_nsec = 1500000;
	t0 = now_us(); r = pwait2(ep_quiet, ev, 4, &ts, 0, 0);
	check("3 1.5 ms timeout (ns res.) ", r, 0, now_us() - t0, 1400, 30000);

	// 4. ready set, NULL timeout (= block forever) -> 1 at once, data intact
	t0 = now_us(); r = pwait2(ep_busy, ev, 4, 0, 0, 0);
	check("4 ready set, NULL timeout  ", r, 1, now_us() - t0, 0, 20000);
	if (r == 1 && ev[0].data != 0x1234) { puts_("  FAIL  4b event data mangled\n"); fails++; }

	// 5. with a sigmask (sizeof(sigset_t) == 8 for native and compat)
	ts.tv_nsec = 10 * 1000000LL;
	t0 = now_us(); r = pwait2(ep_quiet, ev, 4, &ts, &mask, 8);
	check("5 10 ms + sigmask          ", r, 0, now_us() - t0, 9000, 100000);

	// 6. errors: bad tv_nsec -> EINVAL; bad timeout pointer -> EFAULT; bad sigsetsize -> EINVAL
	ts.tv_nsec = 1000000000LL;
	r = pwait2(ep_quiet, ev, 4, &ts, 0, 0);
	check("6 tv_nsec = 1e9 -> EINVAL  ", r, -EINVAL, 0, 0, 0);
	r = pwait2(ep_quiet, ev, 4, (const struct kts *)8, 0, 0);
	check("7 bad timeout ptr -> EFAULT", r, -EFAULT, 0, 0, 0);
	ts.tv_nsec = 0;
	r = pwait2(ep_quiet, ev, 4, &ts, &mask, 4);
	check("8 sigsetsize 4 -> EINVAL   ", r, -EINVAL, 0, 0, 0);

	// 9. woken, not timed out: a child writes after ~100 ms, parent waits up to 3 s
	r = sc6(NR_clone, SIGCHLD, 0, 0, 0, 0, 0);
	if (r == 0) {
		struct kts nap = { 0, 100 * 1000000LL };
		sc6(NR_clock_nanosleep64, CLOCK_MONOTONIC, 0, (long)&nap, 0, 0, 0);
		sc6(NR_write, quiet[1], (long)"y", 1, 0, 0, 0);
		sc6(NR_exit_group, 0, 0, 0, 0, 0, 0);
	}
	ts.tv_sec = 3; ts.tv_nsec = 0;
	t0 = now_us(); r = pwait2(ep_quiet, ev, 4, &ts, 0, 0);
	check("9 woken by write at ~100 ms", r, 1, now_us() - t0, 90000, 1000000);
	sc6(NR_wait4, -1, 0, 0, 0, 0, 0);

	// 10-13. regression: the old epoll_pwait (int ms) after the timespec64 conversion
	{
		char c;
		sc6(NR_read, quiet[0], (long)&c, 1, 0, 0, 0);   // drain test 9's byte: idle again
	}
	t0 = now_us(); r = sc6(NR_epoll_pwait, ep_busy, (long)ev, 4, -1, 0, 0);
	check("10 epoll_pwait -1 ms, ready ", r, 1, now_us() - t0, 0, 20000);
	t0 = now_us(); r = sc6(NR_epoll_pwait, ep_quiet, (long)ev, 4, 0, 0, 0);
	check("11 epoll_pwait 0 ms, idle   ", r, 0, now_us() - t0, 0, 20000);
	t0 = now_us(); r = sc6(NR_epoll_pwait, ep_quiet, (long)ev, 4, 30, 0, 0);
	check("12 epoll_pwait 30 ms, idle  ", r, 0, now_us() - t0, 29000, 130000);
	r = sc6(NR_epoll_pwait, ep_busy + 1000, (long)ev, 4, 0, 0, 0);
	check("13 epoll_pwait bad fd       ", r, -9 /* EBADF */, 0, 0, 0);

	puts_(fails ? "RESULT: FAIL\n" : "RESULT: PASS (all checks)\n");
	return fails ? 1 : 0;
}
