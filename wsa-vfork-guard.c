#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/user.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Original Houdini only. One execution watch changes RDI for one clone flag
 * combination; no code bytes, return values or protection checks are changed.
 * All zygote64 descendants can retain ptrace state. Existing applications are
 * not retroactively protected. Exec'd native programs without the bridge are
 * followed, but later same-thread dlopen of Houdini is not covered.
 */
#define VERSION "0.4.0"
#define BRIDGE "/vendor/lib64/libhoudini.so"
#define VENEER 0x30d654UL
#define SYSCALL_PC 0x30d661UL
#define MAX_THREADS 8192
#define OPTIONS (PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT | PTRACE_O_TRACESYSGOOD)
#ifndef TRAP_HWBKPT
#define TRAP_HWBKPT 4
#endif
struct tracee {
    pid_t tid, tgid;
    unsigned long watch, inherited_watch, saved[8], inherited[8];
    int used, stopped, initial, zygote, early, armed, dirty, slot;
    int signal, group_stop, inherited_valid;
};
static struct tracee tasks[MAX_THREADS];
static unsigned count, peak, clamps, hits, nonmatches, exits, errors;
static volatile sig_atomic_t stopping;
static int ready, lock_fd = -1;
static const char *state_dir;
static long long began, last_status, last_discovery;
static char last_error[160];

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}
static void log_event(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void log_event(const char *format, ...) {
    va_list args;
    printf("uptime_ms=%lld ", now_ms() - began);
    va_start(args, format);
    vprintf(format, args);
    va_end(args);
    putchar('\n');
}
static void fail(const char *operation, pid_t tid) {
    int e = errno;
    errors++;
    snprintf(last_error, sizeof(last_error), "%s tid=%d errno=%d", operation, tid, e);
    log_event("error=%s", last_error);
    stopping = 1;
}
static void on_stop(int sig) { (void)sig; stopping = 1; }
static void path_for(char *out, size_t cap, const char *file) {
    snprintf(out, cap, "%s/%s", state_dir, file);
}
static int read_small(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    ssize_t n;
    do { n = read(fd, buf, cap - 1); } while (n < 0 && errno == EINTR);
    int e = errno;
    close(fd);
    errno = e;
    if (n < 0) return -1;
    buf[n] = 0;
    return (int)n;
}
static int write_state(const char *name, const char *text) {
    char path[PATH_MAX], tmp[PATH_MAX];
    path_for(path, sizeof(path), name);
    int n = snprintf(tmp, sizeof(tmp), "%s/.%s.tmp", state_dir, name);
    if (n < 0 || (size_t)n >= sizeof(tmp)) { errno = ENAMETOOLONG; return -1; }
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    size_t len = strlen(text), done = 0;
    while (done < len) {
        ssize_t w = write(fd, text + done, len - done);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { close(fd); unlink(tmp); return -1; }
        done += (size_t)w;
    }
    if (close(fd) || rename(tmp, path)) { unlink(tmp); return -1; }
    return 0;
}
static void clear_ready(void) {
    char path[PATH_MAX];
    path_for(path, sizeof(path), "guard.ready");
    if (unlink(path) && errno != ENOENT) fail("remove-ready", 0);
    ready = 0;
}
static void status_file(int force) {
    long long now = now_ms();
    if (!force && now - last_status < 1000) return;
    last_status = now;
    unsigned zygotes = 0, armed = 0;
    for (unsigned i = 0; i < MAX_THREADS; i++) if (tasks[i].used) {
        zygotes += tasks[i].zygote && tasks[i].tid == tasks[i].tgid;
        armed += tasks[i].armed;
    }
    char buf[768];
    snprintf(buf, sizeof(buf), "version=" VERSION "\nstate=%s\nready=%d\npid=%d\nuptime_s=%lld\nzygotes=%u\nthreads=%u\nprotected_threads=%u\npeak_threads=%u\nclamps=%u\nwatch_hits=%u\nwatch_nonmatch=%u\nexits=%u\nerrors=%u\nlast_error=%s\n",
             stopping ? (count ? "stopping" : "stopped") : (ready ? "watching" : "starting"),
             ready, getpid(), (now - began) / 1000, zygotes, count, armed, peak,
             clamps, hits, nonmatches, exits, errors, last_error[0] ? last_error : "-");
    if (write_state("guard.status", buf)) fail("write-status", 0);
}
static struct tracee *find_task(pid_t tid) {
    for (unsigned i = 0; i < MAX_THREADS; i++)
        if (tasks[i].used && tasks[i].tid == tid) return &tasks[i];
    return NULL;
}
static struct tracee *new_task(pid_t tid) {
    struct tracee *t = find_task(tid);
    if (t) return t;
    for (unsigned i = 0; i < MAX_THREADS; i++) if (!tasks[i].used) {
        t = &tasks[i];
        memset(t, 0, sizeof(*t));
        t->used = 1; t->tid = tid; t->initial = 1;
        if (++count > peak) peak = count;
        return t;
    }
    errno = ENOSPC; fail("thread-capacity", tid);
    return NULL;
}
static void forget(struct tracee *t) {
    if (t->zygote && t->tid == t->tgid) clear_ready();
    t->used = 0;
    count--;
}
static pid_t process_id(pid_t tid) {
    char path[64], text[4096];
    snprintf(path, sizeof(path), "/proc/%d/status", tid);
    if (read_small(path, text, sizeof(text)) < 0) return 0;
    char *p = strstr(text, "Tgid:");
    return p ? (pid_t)strtol(p + 5, NULL, 10) : 0;
}
static unsigned long bridge_base(pid_t tid) {
    char path[64], line[2048];
    snprintf(path, sizeof(path), "/proc/%d/maps", tid);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    unsigned long base = 0;
    while (fgets(line, sizeof(line), f)) {
        unsigned long lo, hi, off;
        char perms[5]; int consumed = 0;
        if (sscanf(line, "%lx-%lx %4s %lx %*s %*s %n", &lo, &hi, perms, &off, &consumed) != 4) continue;
        char *name = line + consumed;
        name[strcspn(name, "\r\n")] = 0;
        if (off == 0 && strchr(perms, 'x') && !strcmp(name, BRIDGE) && hi - lo > SYSCALL_PC + 2) {
            base = lo; break;
        }
    }
    fclose(f);
    return base;
}
static int peek_word(pid_t tid, unsigned long address, unsigned long *value) {
    errno = 0;
    long v = ptrace(PTRACE_PEEKDATA, tid, (void *)address, NULL);
    if (v == -1 && errno) return -1;
    *value = (unsigned long)v;
    return 0;
}
static int dr_read(pid_t tid, unsigned i, unsigned long *v) {
    errno = 0;
    long x = ptrace(PTRACE_PEEKUSER, tid, (void *)(offsetof(struct user, u_debugreg) + i * sizeof(long)), NULL);
    if (x == -1 && errno) return -1;
    *v = (unsigned long)x; return 0;
}
static int dr_write(pid_t tid, unsigned i, unsigned long v) {
    return ptrace(PTRACE_POKEUSER, tid, (void *)(offsetof(struct user, u_debugreg) + i * sizeof(long)), (void *)v);
}
static int restore(struct tracee *t) {
    if (!t->dirty) return 0;
    if (dr_write(t->tid, 7, 0)) return -1;
    for (unsigned i = 0; i < 4; i++) if (dr_write(t->tid, i, t->saved[i])) return -1;
    if (dr_write(t->tid, 6, t->saved[6]) || dr_write(t->tid, 7, t->saved[7])) return -1;
    t->dirty = t->armed = 0;
    return 0;
}
static int arm(struct tracee *t) {
    if (t->armed) return 0;
    unsigned long base = bridge_base(t->tid), w0, w1;
    if (!base) return 1;
    if (peek_word(t->tid, base + VENEER, &w0) || peek_word(t->tid, base + VENEER + 8, &w1)) return -1;
    if (w0 != 0x4d00000038c0c748UL || (w1 & 0x00ffffffffffffffUL) != 0x00050fc88949c289UL) {
        errno = ENOEXEC; fail("veneer-pin", t->tid); return -1;
    }
    unsigned long current[8] = {0};
    for (unsigned i = 0; i < 8; i++) {
        if (i == 4 || i == 5) continue;
        if (dr_read(t->tid, i, &current[i])) return -1;
    }
    /* Linux can inherit DR7 enable bits while clearing the child's reported
     * address registers. Creator metadata comes from the fork event before
     * the child executes, so a zero address is not a foreign breakpoint. */
    memcpy(t->saved, current, sizeof(t->saved));
    int inherited = 0;
    if (t->inherited_valid) {
        unsigned slot = (unsigned)t->slot;
        unsigned long mask = (3UL << (2*slot)) | (15UL << (16+4*slot));
        if ((current[7] & (3UL << (2*slot))) &&
            (current[slot] == t->inherited_watch || current[slot] == 0) &&
            !(current[7] & (15UL << (16+4*slot)))) {
            inherited = 1;
            t->saved[7] = (current[7] & ~mask) | (t->inherited[7] & mask);
            t->saved[slot] = t->inherited[slot];
            t->saved[6] = current[6] & ~(1UL << slot);
        }
    }
    t->dirty = inherited;
    t->watch = base + SYSCALL_PC;
    int slot = -1;
    for (unsigned i = 0; i < 4; i++) if (!(t->saved[7] & (3UL << (2*i)))) { slot = (int)i; break; }
    if (slot < 0) {
        log_event("debug-conflict tid=%d dr7=0x%lx dr0=0x%lx dr1=0x%lx dr2=0x%lx dr3=0x%lx inherited=%d", t->tid, current[7], current[0], current[1], current[2], current[3], t->inherited_valid);
        errno = EBUSY; fail("hardware-slots-busy", t->tid); return -1;
    }
    t->slot = slot;
    unsigned long dr7 = (t->saved[7] & ~(15UL << (16+4*slot))) | (1UL << (2*slot));
    t->dirty = 1;
    if (dr_write(t->tid, 7, 0) || dr_write(t->tid, (unsigned)slot, t->watch) || dr_write(t->tid, 6, 0) || dr_write(t->tid, 7, dr7)) return -1;
    t->armed = 1; t->early = 0;
    if (t->tid == t->tgid) log_event("protected pid=%d watch=0x%lx zygote=%d", t->tgid, t->watch, t->zygote);
    if (t->zygote && !ready && !stopping) {
        if (write_state("guard.ready", VERSION "\n")) { fail("write-ready", t->tid); return -1; }
        ready = 1; log_event("ready zygote64=%d", t->tgid);
    }
    return 0;
}
static void resume(struct tracee *t, int sig) {
    if (stopping) { t->signal = sig; return; }
    enum __ptrace_request request = t->early ? PTRACE_SYSCALL : PTRACE_CONT;
    if (ptrace(request, t->tid, NULL, (void *)(long)sig)) {
        if (errno != ESRCH) fail("resume", t->tid);
    } else { t->stopped = 0; t->signal = 0; }
}
static void detach(struct tracee *t) {
    if (restore(t)) {
        if (errno != ESRCH) { fail("restore-debug-registers", t->tid); return; }
    }
    if (ptrace(PTRACE_DETACH, t->tid, NULL, (void *)(long)t->signal)) {
        if (errno != ESRCH) { fail("detach", t->tid); return; }
        /* ESRCH may mean a thread in a non-ptrace-stop, not a dead thread. */
        char path[64]; snprintf(path, sizeof(path), "/proc/%d", t->tid);
        if (!access(path, F_OK)) return;
    }
    forget(t);
}
static int owned_trap(struct tracee *t, struct user_regs_struct *regs) {
    siginfo_t si; unsigned long dr6;
    if (!t->armed || ptrace(PTRACE_GETSIGINFO, t->tid, NULL, &si) || si.si_code != TRAP_HWBKPT ||
        dr_read(t->tid, 6, &dr6) || !(dr6 & (1UL << t->slot)) ||
        ptrace(PTRACE_GETREGS, t->tid, NULL, regs)) return 0;
    return regs->rip == t->watch;
}
static void dispatch(pid_t tid, int status) {
    struct tracee *t = find_task(tid);
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
        if (t) { exits++; forget(t); }
        return;
    }
    if (!WIFSTOPPED(status)) return;
    unsigned event = (unsigned)status >> 16;
    int sig = WSTOPSIG(status);
    if (!t) {
        /* Child stop can precede the parent's fork event. Keep it parked until
         * that event supplies its exact creator's debug-register lineage. */
        t = new_task(tid);
        if (!t) return;
        t->stopped = 1; t->signal = sig; t->tgid = 0;
        return;
    }
    t->stopped = 1;
    if (event == PTRACE_EVENT_EXEC) {
        unsigned long oldtid = 0;
        if (ptrace(PTRACE_GETEVENTMSG, tid, NULL, &oldtid)) { fail("exec-event", tid); return; }
        if (oldtid != (unsigned long)tid) {
            struct tracee *old = find_task((pid_t)oldtid);
            if (old && old != t) forget(old);
        }
        /* exec clears hardware debug state and all sibling tasks. */
        t->dirty = t->armed = t->inherited_valid = 0;
        t->watch = 0; t->tgid = tid; t->early = 0;
        if (arm(t) < 0 && errno != ESRCH) fail("arm-after-exec", tid);
    }
    if (t->initial) {
        t->initial = 0;
        if (!t->tgid) t->tgid = process_id(tid);
        if (!t->tgid) { errno = ESRCH; fail("tracee-identity", tid); return; }
        if (arm(t) < 0 && errno != ESRCH) fail("arm-new-thread", tid);
        if (event == PTRACE_EVENT_STOP && (sig == SIGSTOP || sig == SIGTRAP)) {
            t->signal = 0;
            if (stopping) detach(t); else resume(t, 0);
            return;
        }
    }
    if (event == PTRACE_EVENT_FORK || event == PTRACE_EVENT_VFORK || event == PTRACE_EVENT_CLONE) {
        unsigned long child_id = 0;
        if (ptrace(PTRACE_GETEVENTMSG, tid, NULL, &child_id)) { fail("fork-event", tid); return; }
        struct tracee *child = new_task((pid_t)child_id);
        if (!child) return;
        child->tgid = process_id(child->tid);
        child->early = t->early;
        if (t->dirty) {
            child->inherited_valid = 1; child->inherited_watch = t->watch;
            child->slot = t->slot;
            memcpy(child->inherited, t->saved, sizeof(child->inherited));
        }
        if (child->stopped) {
            child->initial = 0;
            if (arm(child) < 0 && errno != ESRCH) fail("arm-parked-child", child->tid);
            child->signal = 0;
            if (stopping) detach(child); else resume(child, 0);
        }
        t->signal = 0;
    } else if (event == PTRACE_EVENT_EXIT || event == PTRACE_EVENT_EXEC) {
        t->signal = 0;
    } else if (event == PTRACE_EVENT_STOP) {
        t->signal = 0;
        if (sig != SIGTRAP) {
            t->group_stop = 1;
            if (!stopping) {
                if (ptrace(PTRACE_LISTEN, tid, NULL, NULL)) { if (errno != ESRCH) fail("listen", tid); }
                else t->stopped = 0;
                return;
            }
        }
    } else if (sig == (SIGTRAP | 0x80)) {
        t->signal = 0;
        if (t->early && arm(t) < 0 && errno != ESRCH) fail("arm-loaded-bridge", tid);
    } else if (sig == SIGTRAP) {
        struct user_regs_struct regs;
        if (owned_trap(t, &regs)) {
            t->signal = 0; hits++;
            if (!stopping) {
                regs.eflags |= 0x10000;
                if (regs.rax == 56 && regs.rdi == 0x4111) {
                    regs.rdi = 0x4011; clamps++;
                    if (clamps <= 10 || clamps % 100 == 0) log_event("clamp pid=%d tid=%d count=%u flags=0x4111->0x4011", t->tgid, tid, clamps);
                } else nonmatches++;
                if (ptrace(PTRACE_SETREGS, tid, NULL, &regs) || dr_write(tid, 6, 0)) { fail("clamp-registers", tid); return; }
            }
        } else t->signal = sig;
    } else {
        t->signal = sig;
        if (sig == SIGCONT) t->group_stop = 0;
        if (sig == SIGSEGV || sig == SIGBUS || sig == SIGABRT || sig == SIGILL || sig == SIGFPE)
            log_event("fault-forward pid=%d tid=%d signal=%d", t->tgid, tid, sig);
    }
    if (stopping) detach(t); else resume(t, t->signal);
}
static unsigned pump(void) {
    unsigned n = 0;
    for (;;) {
        int status; pid_t tid = waitpid(-1, &status, __WALL | WNOHANG);
        if (tid <= 0) {
            if (tid < 0 && errno != ECHILD && errno != EINTR) fail("waitpid", 0);
            break;
        }
        dispatch(tid, status); n++;
    }
    return n;
}
static void seize(pid_t pid) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/task", pid);
    DIR *dir = opendir(path);
    if (!dir) return;
    struct dirent *entry;
    while (!stopping && (entry = readdir(dir))) {
        char *end; long id = strtol(entry->d_name, &end, 10);
        if (*end || id <= 0 || id > INT_MAX || find_task((pid_t)id)) continue;
        struct tracee *t = new_task((pid_t)id);
        if (!t) break;
        t->tgid = pid; t->zygote = 1; t->early = 1;
        if (ptrace(PTRACE_SEIZE, t->tid, NULL, (void *)(long)OPTIONS)) {
            int e = errno; forget(t); errno = e;
            if (e != ESRCH) fail("seize-zygote", (pid_t)id);
            break;
        }
        if (ptrace(PTRACE_INTERRUPT, t->tid, NULL, NULL) && errno != ESRCH) fail("interrupt-zygote", t->tid);
    }
    closedir(dir);
}
static void discover(void) {
    long long now = now_ms();
    if (ready || now - last_discovery < 250) return;
    last_discovery = now;
    DIR *dir = opendir("/proc");
    if (!dir) { fail("discover-proc", 0); return; }
    struct dirent *entry;
    while (!stopping && (entry = readdir(dir))) {
        char *end; long id = strtol(entry->d_name, &end, 10);
        if (*end || id <= 0 || id > INT_MAX || find_task((pid_t)id)) continue;
        char path[64], name[128];
        snprintf(path, sizeof(path), "/proc/%ld/cmdline", id);
        if (read_small(path, name, sizeof(name)) > 0 && !strcmp(name, "zygote64")) seize((pid_t)id);
    }
    closedir(dir);
}
static int run_guard(void) {
    char path[PATH_MAX], pidtext[32];
    began = now_ms();
    setvbuf(stdout, NULL, _IOLBF, 0);
    umask(077);
    if (mkdir(state_dir, 0700) && errno != EEXIST) return 2;
    struct stat st;
    if (lstat(state_dir, &st) || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() || chmod(state_dir, 0700)) return 2;
    path_for(path, sizeof(path), "guard.lock");
    lock_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX | LOCK_NB)) { perror("guard singleton"); return 2; }
    struct sigaction sa = {.sa_handler = on_stop};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
    signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
    clear_ready();
    snprintf(pidtext, sizeof(pidtext), "%d\n", getpid());
    if (write_state("guard.pid", pidtext)) { perror("guard.pid"); return 2; }
    log_event("wsa-vfork-guard " VERSION " starting; pre-existing apps are not protected");
    while (!stopping) {
        unsigned n = pump();
        if (!stopping) discover();
        status_file(0);
        if (!n) usleep(1000);
    }
    clear_ready();
    log_event("stopping: restoring registers and detaching; no target signals are discarded");
    /* Do not exit with an owned breakpoint in a live tracee. A stuck tracee
     * keeps the guard in stopping state; the stop helper reports a timeout. */
    long long next_interrupt = 0;
    while (count) {
        pump();
        long long now = now_ms();
        for (unsigned i = 0; i < MAX_THREADS; i++) if (tasks[i].used) {
            struct tracee *t = &tasks[i];
            if (t->stopped && t->tgid) detach(t);
            else if (now >= next_interrupt) {
                if (ptrace(PTRACE_INTERRUPT, t->tid, NULL, NULL) && errno != ESRCH && errno != EIO)
                    fail("interrupt-cleanup", t->tid);
            }
        }
        if (now >= next_interrupt) next_interrupt = now + 250;
        status_file(0);
        if (count) usleep(2000);
    }
    status_file(1);
    path_for(path, sizeof(path), "guard.pid");
    if (unlink(path) && errno != ENOENT) { perror("remove guard.pid"); return 1; }
    log_event("stopped threads=0 clamps=%u errors=%u", clamps, errors);
    close(lock_fd);
    return errors ? 1 : 0;
}
static int stop_guard(void) {
    char path[PATH_MAX], text[1024], actual[PATH_MAX], self[PATH_MAX];
    path_for(path, sizeof(path), "guard.lock");
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 && errno == ENOENT) { puts("guard: no running instance (no lock)"); return 0; }
    if (fd < 0) { perror("guard lock"); return 1; }
    if (!flock(fd, LOCK_EX | LOCK_NB)) { close(fd); puts("guard: no running instance (lock free)"); return 0; }
    close(fd);
    path_for(path, sizeof(path), "guard.pid");
    if (read_small(path, text, sizeof(text)) < 0) { perror("guard.pid"); return 1; }
    char *end; errno = 0; long pid = strtol(text, &end, 10);
    if (errno || pid <= 1 || pid > INT_MAX || (*end != '\n' && *end) || (*end == '\n' && end[1])) {
        fprintf(stderr, "guard: malformed PID file\n"); return 1;
    }
    int pidfd = (int)syscall(SYS_pidfd_open, pid, 0);
    if (pidfd < 0) { perror("pidfd_open"); return 1; }
    snprintf(path, sizeof(path), "/proc/%ld/exe", pid);
    ssize_t n = readlink(path, actual, sizeof(actual)-1);
    ssize_t m = readlink("/proc/self/exe", self, sizeof(self)-1);
    if (n < 0 || m < 0) { close(pidfd); perror("guard executable identity"); return 1; }
    actual[n] = 0; self[m] = 0;
    const char suffix[] = " (deleted)";
    size_t len = strlen(actual);
    if (len >= sizeof(suffix)-1 && !strcmp(actual+len-(sizeof(suffix)-1), suffix)) actual[len-(sizeof(suffix)-1)] = 0;
    if (strcmp(actual, self) && strcmp(actual, "/data/adb/modules/wsa_houdini_vfork_scudo/bin/wsa-vfork-guard") &&
        strcmp(actual, "/data/adb/modules_update/wsa_houdini_vfork_scudo/bin/wsa-vfork-guard")) {
        fprintf(stderr, "guard: refusing foreign executable %s\n", actual); close(pidfd); return 1;
    }
    if (syscall(SYS_pidfd_send_signal, pidfd, SIGTERM, NULL, 0) && errno != ESRCH) {
        perror("pidfd_send_signal"); close(pidfd); return 1;
    }
    struct pollfd pfd = {.fd = pidfd, .events = POLLIN};
    int r;
    do { r = poll(&pfd, 1, 15000); } while (r < 0 && errno == EINTR);
    close(pidfd);
    if (r != 1 || !(pfd.revents & POLLIN)) { fprintf(stderr, "guard: graceful stop not confirmed within 15s\n"); return 1; }
    path_for(path, sizeof(path), "guard.pid");
    if (!access(path, F_OK)) { fprintf(stderr, "guard: process exited without PID cleanup\n"); return 1; }
    path_for(path, sizeof(path), "guard.ready");
    if (!access(path, F_OK)) { fprintf(stderr, "guard: process exited without readiness cleanup\n"); return 1; }
    path_for(path, sizeof(path), "guard.status");
    if (read_small(path, text, sizeof(text)) < 0 || !strstr(text, "\nstate=stopped\n") || !strstr(text, "\nthreads=0\n")) {
        fprintf(stderr, "guard: clean detach status missing\n"); return 1;
    }
    puts("guard: stopped; verified process exited, threads=0, PID/ready removed");
    return 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { puts("wsa-vfork-guard " VERSION); return 0; }
    int stop = argc == 4 && !strcmp(argv[1], "--stop");
    int pos = stop ? 2 : 1;
    if ((stop || argc == 3) && !strcmp(argv[pos], "--state-dir") && argv[pos+1][0] == '/' &&
        strlen(argv[pos+1]) < PATH_MAX - 64) {
        state_dir = argv[pos+1];
        return stop ? stop_guard() : run_guard();
    }
    fputs("usage: wsa-vfork-guard --version | [--stop] --state-dir /absolute/path\n", stderr);
    return 2;
}
