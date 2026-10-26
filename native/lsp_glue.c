/* The core's door into the swan-lsp library (build/swanlsp.c), which is Goose
   compiled on its own with --standalone so the core's build never recompiles
   it. The library has its own Goose runtime, started once here. Its exports
   are declared by hand rather than through build/swanlsp.h, whose types would
   clash with the core's goose.h; slices have the same layout either way. */
#include "goose.h"
#include <stdbool.h>
#include <stdint.h>

typedef struct { const uint8_t *data; int64_t len; } lsp_slice;

void goose_init(int argc, char **argv);
uint8_t swanlsp_start(lsp_slice repo, lsp_slice log, lsp_slice init_json, lsp_slice argv, lsp_slice env,
                      lsp_slice lang_id);
const uint8_t *swanlsp_ask(lsp_slice question, int64_t *len);
void swanlsp_stop(void);

static bool started;

bool swan_lsp_start(lsp_slice repo, lsp_slice log, lsp_slice init_json, lsp_slice argv, lsp_slice env,
                    lsp_slice lang_id) {
    if (!started) { static char *args[] = {"swan-lsp", 0}; goose_init(1, args); started = true; }
    return swanlsp_start(repo, log, init_json, argv, env, lang_id) != 0;
}

void swan_lsp_ask(lsp_slice question, gs_rref out) {
    int64_t len = 0;
    const uint8_t *a = swanlsp_ask(question, &len);
    gs_bld_append(out, a, (size_t)len);
}

void swan_lsp_stop(void) { if (started) swanlsp_stop(); }
