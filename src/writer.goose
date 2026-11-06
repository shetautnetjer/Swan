// One pipeline/index/refresh writer owns a map at a time. The native handle
// owns an OS advisory lock; release closes it without deleting the lock file.
// Zero means refusal, with an explanation in err. Readers use SQLite locks.
// Indexer children inherit ownership until they exit, including if Swan dies.
extern fn swan_writer_lock(db_path: const u8[:], err: u8[>..]&) -> i64;
extern fn swan_writer_unlock(handle: i64);
