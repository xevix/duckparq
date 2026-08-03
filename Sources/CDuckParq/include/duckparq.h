/*
 * duckparq.h -- a small C ABI over DuckDB for the DuckParq Swift app.
 *
 * Everything DuckDB-shaped lives behind this header. Swift imports it directly;
 * no C++ interop, no duckdb.h leaking into Swift.
 *
 * Error convention: functions that can fail take a `char **err`. On failure they
 * return NULL/false and, if `err` is non-NULL, set it to a malloc'd message the
 * caller must release with dpq_string_free(). On success `*err` is untouched.
 *
 * Threading: a dpq_conn must be used from one thread at a time. The sole
 * exception is dpq_conn_interrupt(), which is safe to call from any thread while
 * another thread is blocked inside a query -- that is how DuckParq cancels work
 * that the user has already navigated away from.
 */
#ifndef DUCKPARQ_H
#define DUCKPARQ_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dpq_db_s *dpq_db;
typedef struct dpq_conn_s *dpq_conn;
typedef struct dpq_cursor_s *dpq_cursor;

/*
 * A block of fetched rows, laid out as one malloc'd arena rather than a cell
 * array: all text concatenated in `bytes`, cell (r, c) occupying
 * [offsets[r * cols + c], offsets[r * cols + c + 1]). `nulls` is a bitmap over
 * the same cell index; a set bit means SQL NULL (whose byte range is empty).
 *
 * This keeps a fetch to a couple of allocations instead of rows*cols of them,
 * and lets Swift build String values lazily for just the cells on screen.
 */
typedef struct {
  int32_t rows;
  int32_t cols;
  const uint8_t *bytes;
  const int32_t *offsets; /* rows * cols + 1 entries */
  const uint8_t *nulls;   /* (rows * cols + 7) / 8 bytes */
} dpq_rows;

/* Version of the statically linked DuckDB, e.g. "v1.5.5". */
const char *dpq_duckdb_version(void);

/* Release a message returned through an `err` out-parameter. */
void dpq_string_free(char *s);

/* An in-memory database. Parquet files are read directly from disk by query. */
dpq_db dpq_db_open(char **err);
void dpq_db_close(dpq_db db);

dpq_conn dpq_conn_open(dpq_db db, char **err);
void dpq_conn_close(dpq_conn conn);

/* Cancel whatever this connection is currently executing. Safe from any thread;
 * a no-op if the connection is idle. The interrupted query fails with an error
 * rather than returning partial results. */
void dpq_conn_interrupt(dpq_conn conn);

/*
 * Run a statement for effect, discarding any result (CREATE VIEW, COPY, SET...).
 * `params` are bound to $1..$nparams as VARCHAR; pass NULL/0 for none.
 */
bool dpq_exec(dpq_conn conn, const char *sql, const char *const *params,
              int32_t nparams, char **err);

/*
 * What DuckDB's own parser says a statement is.
 *
 * This is a deliberately narrow re-encoding of duckdb_statement_type rather
 * than a pass-through: anything DuckParq has not explicitly accounted for --
 * including statement types added by a future DuckDB -- arrives as
 * DPQ_STMT_OTHER, so a read-only policy built on these values fails closed.
 */
typedef enum {
  DPQ_STMT_OTHER = 0,
  DPQ_STMT_SELECT = 1,
  DPQ_STMT_EXPLAIN = 2,
  DPQ_STMT_INSERT = 3,
  DPQ_STMT_UPDATE = 4,
  DPQ_STMT_DELETE = 5,
  DPQ_STMT_CREATE = 6,
  DPQ_STMT_DROP = 7,
  DPQ_STMT_ALTER = 8,
  DPQ_STMT_COPY = 9,
  DPQ_STMT_EXPORT = 10,
  DPQ_STMT_ATTACH = 11,
  DPQ_STMT_DETACH = 12,
  DPQ_STMT_SET = 13,
  DPQ_STMT_LOAD = 14,
  DPQ_STMT_CALL = 15,
  DPQ_STMT_TRANSACTION = 16,
  DPQ_STMT_PREPARE = 17,
  DPQ_STMT_EXECUTE = 18,
  DPQ_STMT_VACUUM = 19,
  DPQ_STMT_ANALYZE = 20
} dpq_stmt_kind;

/*
 * Classify every statement in `sql` without running any of them.
 *
 * `sql` is split by DuckDB's parser, and each statement is prepared -- which
 * binds it but does not execute it -- so the classification is the database's
 * own verdict rather than a guess made by pattern-matching the text. That
 * distinction is the whole point: `SELECT 1; DROP TABLE x` is reported here as
 * two statements, one SELECT and one DROP, where any regex over the text is a
 * game of spot-the-encoding.
 *
 * Writes the first `max_kinds` classifications into `out_kinds` and returns the
 * total number of statements found, which may exceed `max_kinds`. Returns -1
 * with *err set if the text does not parse, or if any statement fails to
 * prepare (an unknown table, say) -- the same error the query would have
 * produced had it been run.
 */
int32_t dpq_statement_kinds(dpq_conn conn, const char *sql, int32_t *out_kinds,
                            int32_t max_kinds, char **err);

/*
 * Open a streaming cursor over `sql`.
 *
 * The query is wrapped as `SELECT COLUMNS(*)::VARCHAR FROM (<sql>)`, so every
 * column arrives as text already rendered by DuckDB itself. That is what a
 * viewer wants: DECIMAL, HUGEINT, TIMESTAMPTZ, LIST, STRUCT, MAP, ENUM, UNION
 * and BLOB (escaped, always valid UTF-8) all render correctly with one code
 * path here. Wrapping preserves an inner ORDER BY, so sorting stays a DuckDB
 * concern. Column *types*, when the UI needs them, come from a separate
 * DESCRIBE rather than from the cursor.
 *
 * Rows are not materialized up front -- the cursor pulls chunks on demand, which
 * is what makes scroll-to-load cheap on large files.
 */
dpq_cursor dpq_cursor_open(dpq_conn conn, const char *sql,
                           const char *const *params, int32_t nparams,
                           char **err);

/*
 * As above, but `render_as_text = 0` runs the statement exactly as given.
 *
 * Needed because the VARCHAR wrap is a SELECT over the statement, and not every
 * statement can be selected from: `SELECT * FROM (EXPLAIN ...)` is a parse
 * error. EXPLAIN is the one read-only form DuckParq admits that this applies
 * to, and it already produces VARCHAR columns, so it needs neither the cast nor
 * the wrap. Callers decide from the parsed statement kind
 * (dpq_statement_kinds), never by inspecting the text.
 */
dpq_cursor dpq_cursor_open_ex(dpq_conn conn, const char *sql,
                              const char *const *params, int32_t nparams,
                              int32_t render_as_text, char **err);

int32_t dpq_cursor_column_count(dpq_cursor cur);
/* Borrowed, valid until the cursor is closed. */
const char *dpq_cursor_column_name(dpq_cursor cur, int32_t index);

/*
 * Pull up to `max_rows` more rows. Returns NULL at end of stream (with *err
 * untouched) or on failure (with *err set). Release with dpq_rows_free().
 */
dpq_rows *dpq_cursor_fetch(dpq_cursor cur, int32_t max_rows, char **err);
void dpq_rows_free(dpq_rows *rows);

void dpq_cursor_close(dpq_cursor cur);

#ifdef __cplusplus
}
#endif

#endif /* DUCKPARQ_H */
