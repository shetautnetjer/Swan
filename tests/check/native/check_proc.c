/* swan-check's process helpers: goose-lsp's pipes (lsp/native/proc.c,
   included whole so its process struct is in reach) plus one function the
   tests need and goose-lsp does not have: closing a server and learning its
   exit code. goose-lsp itself is unchanged. */
#include "../../../lsp/native/proc.c"

/* Like proc_close: closes stdin and gives the program grace_ms to exit.
   Returns its exit code, or -1 if it had to be killed or died by a signal. */
int32_t check_proc_close(int64_t h, int64_t grace_ms) {
    proc_t *p = (proc_t *)(intptr_t)h;
    close(p->in_fd);
    int status = 0;
    int32_t code = -1;
    bool exited = false;
    for (int64_t waited = 0; waited < grace_ms; waited += 20) {
        if (waitpid(p->pid, &status, WNOHANG) == p->pid) { exited = true; break; }
        struct timespec ts = {0, 20 * 1000000};
        nanosleep(&ts, NULL);
    }
    if (exited) {
        if (WIFEXITED(status)) code = WEXITSTATUS(status);
        kill(-p->pid, SIGKILL);   /* anything it left in its process group */
    } else {
        kill(-p->pid, SIGKILL);
        kill(p->pid, SIGKILL);
        waitpid(p->pid, &status, 0);
    }
    pthread_mutex_lock(&p->mu);
    p->stop = true;
    pthread_mutex_unlock(&p->mu);
    pthread_join(p->reader, NULL);
    close(p->out_fd);
    free(p->buf);
    pthread_mutex_destroy(&p->mu);
    pthread_cond_destroy(&p->cv);
    free(p);
    return code;
}
