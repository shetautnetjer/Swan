// One pipeline/index/refresh writer owns a map at a time. The native handle
// owns an OS advisory lock; release closes it without deleting the lock file.
// Zero means refusal, with an explanation in err. Readers use SQLite locks.
// Indexer children inherit ownership on failure or if Swan dies. Successful
// completion explicitly unlocks after all foreground output is published;
// idle build servers can retain descriptors without blocking the next map.
extern fn swan_writer_lock(db_path: const u8[:], err: u8[>..]&) -> i64;
extern fn swan_writer_unlock(handle: i64);
extern fn swan_writer_complete(handle: i64);
