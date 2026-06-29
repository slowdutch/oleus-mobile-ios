/*
 * OleusCrashCore — async-signal-safe crash capture.
 *
 * Everything that runs inside the signal handler obeys the async-signal-safe
 * contract: no malloc, no Objective-C/Swift runtime, no stdio, no
 * JSONSerialization. Just open(2)/write(2)/fsync(2) on a path prepared at
 * install time, hex formatting into stack buffers, and a bounded
 * frame-pointer walk starting from the crashed thread's register state
 * (taken from the ucontext, NOT from the handler's own stack — the handler
 * runs on a sigaltstack so its frame chain does not reach the crash).
 */

#include "include/OleusCrashCore.h"

#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ucontext.h>
#include <unistd.h>

#define OLEUS_MAX_FRAMES   128
#define OLEUS_ALT_STACK    (64 * 1024)
#define OLEUS_PATH_MAX     1024

static const int k_signals[] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP };
#define OLEUS_NSIGNALS (sizeof(k_signals) / sizeof(k_signals[0]))

static char               g_report_path[OLEUS_PATH_MAX];
static struct sigaction   g_previous[OLEUS_NSIGNALS];
static char               g_alt_stack_mem[OLEUS_ALT_STACK];
static volatile sig_atomic_t g_handling = 0;

/* ── async-signal-safe formatting ────────────────────────────────────────── */

static void safe_write(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n <= 0) return;
        buf += n;
        len -= (size_t)n;
    }
}

static void write_str(int fd, const char *s) { safe_write(fd, s, strlen(s)); }

static void write_hex(int fd, uint64_t value) {
    char buf[19]; /* "0x" + 16 nibbles + NUL */
    buf[0] = '0'; buf[1] = 'x';
    for (int i = 0; i < 16; i++) {
        unsigned nibble = (unsigned)((value >> (60 - 4 * i)) & 0xF);
        buf[2 + i] = (char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
    }
    buf[18] = '\0';
    write_str(fd, buf);
}

static void write_dec(int fd, int value) {
    char buf[12];
    int pos = 11;
    buf[pos] = '\0';
    if (value == 0) { buf[--pos] = '0'; }
    bool neg = value < 0;
    unsigned v = neg ? (unsigned)(-value) : (unsigned)value;
    while (v > 0 && pos > 1) { buf[--pos] = (char)('0' + v % 10); v /= 10; }
    if (neg) buf[--pos] = '-';
    write_str(fd, buf + pos);
}

static const char *signal_name(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGBUS:  return "SIGBUS";
        case SIGFPE:  return "SIGFPE";
        case SIGILL:  return "SIGILL";
        case SIGSEGV: return "SIGSEGV";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIGNAL";
    }
}

/* ── register state from the interrupted context ─────────────────────────── */

static void crash_registers(ucontext_t *uc, uint64_t *pc, uint64_t *lr, uint64_t *fp) {
    *pc = 0; *lr = 0; *fp = 0;
    if (uc == NULL || uc->uc_mcontext == NULL) return;
#if defined(__arm64__)
#  if defined(__DARWIN_OPAQUE_ARM_THREAD_STATE64) && __DARWIN_OPAQUE_ARM_THREAD_STATE64
    *pc = (uint64_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    *lr = (uint64_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
    *fp = (uint64_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
#  else
    *pc = (uint64_t)uc->uc_mcontext->__ss.__pc;
    *lr = (uint64_t)uc->uc_mcontext->__ss.__lr;
    *fp = (uint64_t)uc->uc_mcontext->__ss.__fp;
#  endif
#elif defined(__x86_64__)
    *pc = (uint64_t)uc->uc_mcontext->__ss.__rip;
    *fp = (uint64_t)uc->uc_mcontext->__ss.__rbp;
#endif
}

/* Bounded frame-pointer walk. Reading *fp can itself fault on a corrupted
 * stack; the re-entrancy guard makes the nested signal fall through to the
 * default handler, and the partial report (with pc/lr already written and
 * fsync'd per line batch) is still usable. */
static int walk_frames(uint64_t fp, uint64_t *frames, int max) {
    int count = 0;
    uint64_t prev = 0;
    while (count < max && fp != 0 && (fp & 0xF) == 0 && fp > prev) {
        const uint64_t *frame = (const uint64_t *)fp;
        uint64_t ret = frame[1];
        if (ret < 0x1000) break;
        frames[count++] = ret;
        prev = fp;
        fp = frame[0];
    }
    return count;
}

/* ── the handler ─────────────────────────────────────────────────────────── */

static void chain_previous(int sig, siginfo_t *info, void *uctx) {
    struct sigaction prev = { 0 };
    for (size_t i = 0; i < OLEUS_NSIGNALS; i++) {
        if (k_signals[i] == sig) { prev = g_previous[i]; break; }
    }
    if ((prev.sa_flags & SA_SIGINFO) && prev.sa_sigaction != NULL) {
        prev.sa_sigaction(sig, info, uctx);
        return;
    }
    if (prev.sa_handler != NULL && prev.sa_handler != SIG_IGN && prev.sa_handler != SIG_DFL) {
        prev.sa_handler(sig);
        return;
    }
    /* restore default and re-raise so the OS report is still generated */
    signal(sig, SIG_DFL);
    raise(sig);
}

static void oleus_signal_handler(int sig, siginfo_t *info, void *uctx) {
    if (g_handling) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    g_handling = 1;

    int fd = open(g_report_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        write_str(fd, "signal:");
        write_dec(fd, sig);
        write_str(fd, "\nname:");
        write_str(fd, signal_name(sig));
        write_str(fd, "\nfault:");
        write_hex(fd, info ? (uint64_t)(uintptr_t)info->si_addr : 0);
        write_str(fd, "\n");

        uint64_t pc, lr, fp;
        crash_registers((ucontext_t *)uctx, &pc, &lr, &fp);

        if (pc) { write_hex(fd, pc); write_str(fd, "\n"); }
        if (lr && lr != pc) { write_hex(fd, lr); write_str(fd, "\n"); }
        fsync(fd); /* pc/lr survive even if the walk below faults */

        static uint64_t frames[OLEUS_MAX_FRAMES];
        int n = walk_frames(fp, frames, OLEUS_MAX_FRAMES);
        for (int i = 0; i < n; i++) {
            if (frames[i] == lr) continue; /* first frame duplicates lr */
            write_hex(fd, frames[i]);
            write_str(fd, "\n");
        }
        fsync(fd);
        close(fd);
    }

    chain_previous(sig, info, uctx);
}

/* ── install ─────────────────────────────────────────────────────────────── */

int oleus_crash_install(const char *report_path) {
    if (report_path == NULL || strlen(report_path) >= OLEUS_PATH_MAX) return -1;
    strncpy(g_report_path, report_path, OLEUS_PATH_MAX - 1);
    g_report_path[OLEUS_PATH_MAX - 1] = '\0';

    stack_t alt = { 0 };
    alt.ss_sp = g_alt_stack_mem;
    alt.ss_size = OLEUS_ALT_STACK;
    alt.ss_flags = 0;
    sigaltstack(&alt, NULL); /* best effort — stack-overflow SIGSEGV needs it */

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = oleus_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);

    int rc = 0;
    for (size_t i = 0; i < OLEUS_NSIGNALS; i++) {
        if (sigaction(k_signals[i], &action, &g_previous[i]) != 0) rc = -1;
    }
    return rc;
}

int oleus_crash_has_pending(const char *report_path) {
    struct stat st;
    if (stat(report_path, &st) != 0) return 0;
    return st.st_size > 0 ? 1 : 0;
}
