/* Swan's thin C layer for what Goose v1 has no library for: a stat call and
   running other programs (SQLite is the goose-sqlite package). Text arrives
   as a Goose slice { data, len } and goes back out by appending to a Goose
   builder. Every function here is a direct wrapper; the logic lives in
   Goose. */
#define _GNU_SOURCE
#include "goose.h"
#include <string.h>
#include <sys/stat.h>
#include <stdio.h>
#include <limits.h>

typedef struct { const uint8_t *data; int64_t len; } swan_slice;

static void append_cstr(gs_rref out, const char *s) {
    if (s) gs_bld_append(out, s, strlen(s));
}

/* A file's modification time in nanoseconds since the epoch, or -1 if it
   cannot be read. Goose's os module has no stat, and freshness needs one. */
int64_t swan_mtime_ns(swan_slice path) {
    char buf[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof buf) return -1;
    memcpy(buf, path.data, (size_t)path.len);
    buf[path.len] = 0;
    struct stat st;
    if (stat(buf, &st) != 0) return -1;
    return (int64_t)st.st_mtim.tv_sec * 1000000000LL + st.st_mtim.tv_nsec;
}

/* ---- Running other programs. Goose v1 has no subprocess API ("they arrive
   as extern fns when a program needs them", its stdlib docs say), so this is
   that extern fn. ---- */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Splits "a\0b\0c\0" into a NULL-terminated array of pointers into buf. */
static char **split_nul(char *buf, int64_t len, char **extra_from) {
    int64_t n = 0;
    for (int64_t i = 0; i < len; i++) if (buf[i] == 0) n++;
    int64_t base = 0;
    if (extra_from) while (extra_from[base]) base++;
    char **v = calloc((size_t)(n + base + 1), sizeof *v);
    if (!v) return NULL;
    int64_t k = 0;
    for (int64_t i = 0; i < base; i++) v[k++] = extra_from[i];
    for (int64_t i = 0, start = 0; i < len; i++)
        if (buf[i] == 0) { v[k++] = buf + start; start = i + 1; }
    v[k] = NULL;
    return v;
}

/* Runs argv (NUL-separated, argv[0] looked up on PATH) in cwd (empty: this
   process's), with env entries ("K=V", NUL-separated) placed before the
   inherited environment so they win. stdin is /dev/null. Appends stdout and
   stderr to the builders. Returns the exit code, 128 + signal, -1 if it could
   not start (reason in err), or -2 after killing it at timeout_ms (0: none). */
int32_t swan_run(swan_slice argv_nul, swan_slice cwd, swan_slice env_nul, int64_t timeout_ms,
                 gs_rref out, gs_rref err) {
    char *abuf = malloc((size_t)argv_nul.len + 1), *ebuf = malloc((size_t)env_nul.len + 1);
    char cwdbuf[4096];
    if (!abuf || !ebuf || cwd.len >= (int64_t)sizeof cwdbuf) { append_cstr(err, "swan_run: bad arguments"); free(abuf); free(ebuf); return -1; }
    memcpy(abuf, argv_nul.data, (size_t)argv_nul.len);
    memcpy(ebuf, env_nul.data, (size_t)env_nul.len);
    memcpy(cwdbuf, cwd.data, (size_t)cwd.len);
    cwdbuf[cwd.len] = 0;
    char **argv = split_nul(abuf, argv_nul.len, NULL);
    char **envp = NULL;
    {   /* our entries first, then the inherited ones */
        char **ours = split_nul(ebuf, env_nul.len, NULL);
        int64_t a = 0, b = 0;
        while (ours && ours[a]) a++;
        while (environ[b]) b++;
        envp = calloc((size_t)(a + b + 1), sizeof *envp);
        for (int64_t i = 0; i < a; i++) envp[i] = ours[i];
        for (int64_t i = 0; i < b; i++) envp[a + i] = environ[i];
        free(ours);
    }
    int po[2], pe[2];
    if (!argv || !argv[0] || pipe(po) != 0 || pipe(pe) != 0) {
        append_cstr(err, "swan_run: cannot start");
        free(argv); free(envp); free(abuf); free(ebuf);
        return -1;
    }
    /* PATH lookup with our env's PATH, as execvpe would. */
    const char *path_env = NULL;
    for (char **e = envp; *e; e++) if (strncmp(*e, "PATH=", 5) == 0) { path_env = *e + 5; break; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(po[1], 1); dup2(pe[1], 2);
        close(po[0]); close(po[1]); close(pe[0]); close(pe[1]);
        int nul = open("/dev/null", O_RDONLY);
        if (nul >= 0) { dup2(nul, 0); close(nul); }
        if (cwdbuf[0] && chdir(cwdbuf) != 0) { perror("chdir"); _exit(127); }
        setpgid(0, 0);
        if (strchr(argv[0], '/')) execve(argv[0], argv, envp);
        else if (path_env) {
            char cand[4096];
            const char *p = path_env;
            while (*p) {
                const char *colon = strchr(p, ':');
                size_t dl = colon ? (size_t)(colon - p) : strlen(p);
                if (dl + strlen(argv[0]) + 2 < sizeof cand) {
                    memcpy(cand, p, dl); cand[dl] = '/';
                    strcpy(cand + dl + 1, argv[0]);
                    execve(cand, argv, envp);
                }
                if (!colon) break;
                p = colon + 1;
            }
        }
        fprintf(stderr, "swan_run: cannot run %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    close(po[1]); close(pe[1]);
    int64_t deadline = timeout_ms > 0 ? now_ms() + timeout_ms : 0;
    struct pollfd fds[2] = {{po[0], POLLIN, 0}, {pe[0], POLLIN, 0}};
    int open_fds = 2, timed_out = 0;
    char buf[65536];
    while (open_fds > 0) {
        int wait = -1;
        if (deadline) { int64_t left = deadline - now_ms(); if (left <= 0) { timed_out = 1; break; } wait = (int)left; }
        int r = poll(fds, 2, wait);
        if (r < 0) { if (errno == EINTR) continue; break; }
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t n = read(fds[i].fd, buf, sizeof buf);
            if (n > 0) gs_bld_append(i == 0 ? out : err, buf, (size_t)n);
            else { close(fds[i].fd); fds[i].fd = -1; open_fds--; }
        }
    }
    if (timed_out) kill(-pid, SIGKILL);
    for (int i = 0; i < 2; i++) if (fds[i].fd >= 0) close(fds[i].fd);
    int status = 0;
    waitpid(pid, &status, 0);
    free(argv); free(envp); free(abuf); free(ebuf);
    if (timed_out) return -2;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* The absolute path of the running executable, appended to out. */
bool swan_exe_path(gs_rref out) {
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
    if (n <= 0) return false;
    gs_bld_append(out, buf, (size_t)n);
    return true;
}

/* An absolute, symlink-free path, appended to out. */
bool swan_realpath(swan_slice path, gs_rref out) {
    char in[4096], res[PATH_MAX];
    if (path.len <= 0 || path.len >= (int64_t)sizeof in) return false;
    memcpy(in, path.data, (size_t)path.len);
    in[path.len] = 0;
    if (!realpath(in, res)) return false;
    append_cstr(out, res);
    return true;
}

/* ---- Running several programs at once, for map's indexing jobs. ---- */

/* Starts argv like swan_run, with stdout and stderr going to log_path.
   Returns its pid, or -1. */
int64_t swan_spawn(swan_slice argv_nul, swan_slice cwd, swan_slice env_nul, swan_slice log_path) {
    char *abuf = malloc((size_t)argv_nul.len + 1), *ebuf = malloc((size_t)env_nul.len + 1);
    char cwdbuf[4096], logbuf[4096];
    if (!abuf || !ebuf || cwd.len >= (int64_t)sizeof cwdbuf || log_path.len >= (int64_t)sizeof logbuf) {
        free(abuf); free(ebuf); return -1;
    }
    memcpy(abuf, argv_nul.data, (size_t)argv_nul.len);
    memcpy(ebuf, env_nul.data, (size_t)env_nul.len);
    memcpy(cwdbuf, cwd.data, (size_t)cwd.len); cwdbuf[cwd.len] = 0;
    memcpy(logbuf, log_path.data, (size_t)log_path.len); logbuf[log_path.len] = 0;
    char **argv = split_nul(abuf, argv_nul.len, NULL);
    char **ours = split_nul(ebuf, env_nul.len, NULL);
    int64_t a = 0, b = 0;
    while (ours && ours[a]) a++;
    while (environ[b]) b++;
    char **envp = calloc((size_t)(a + b + 1), sizeof *envp);
    for (int64_t i = 0; i < a; i++) envp[i] = ours[i];
    for (int64_t i = 0; i < b; i++) envp[a + i] = environ[i];
    const char *path_env = NULL;
    for (char **e = envp; *e; e++) if (strncmp(*e, "PATH=", 5) == 0) { path_env = *e + 5; break; }
    pid_t pid = fork();
    if (pid == 0) {
        int log = open(logbuf, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log >= 0) { dup2(log, 1); dup2(log, 2); close(log); }
        int nul = open("/dev/null", O_RDONLY);
        if (nul >= 0) { dup2(nul, 0); close(nul); }
        if (cwdbuf[0] && chdir(cwdbuf) != 0) _exit(127);
        if (strchr(argv[0], '/')) execve(argv[0], argv, envp);
        else if (path_env) {
            char cand[4096];
            const char *p = path_env;
            while (*p) {
                const char *colon = strchr(p, ':');
                size_t dl = colon ? (size_t)(colon - p) : strlen(p);
                if (dl + strlen(argv[0]) + 2 < sizeof cand) {
                    memcpy(cand, p, dl); cand[dl] = '/';
                    strcpy(cand + dl + 1, argv[0]);
                    execve(cand, argv, envp);
                }
                if (!colon) break;
                p = colon + 1;
            }
        }
        fprintf(stderr, "swan_spawn: cannot run %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }
    free(argv); free(ours); free(envp); free(abuf); free(ebuf);
    return pid > 0 ? (int64_t)pid : -1;
}

/* Waits for any child started by swan_spawn; its pid, or -1 when none are
   left. Its exit code (128 + signal if killed) goes to *code. */
int64_t swan_wait_any(int32_t *code) {
    int status = 0;
    pid_t pid;
    do { pid = waitpid(-1, &status, 0); } while (pid < 0 && errno == EINTR);
    if (pid < 0) return -1;
    *code = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
    return pid;
}

int64_t swan_file_size(swan_slice path) {
    char buf[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof buf) return -1;
    memcpy(buf, path.data, (size_t)path.len);
    buf[path.len] = 0;
    struct stat st;
    return stat(buf, &st) == 0 ? (int64_t)st.st_size : -1;
}

int32_t swan_cpu_count(void) { long n = sysconf(_SC_NPROCESSORS_ONLN); return n > 0 ? (int32_t)n : 1; }
