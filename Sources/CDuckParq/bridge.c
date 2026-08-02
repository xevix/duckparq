#include "duckparq.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "duckdb.h"

struct dpq_db_s {
  duckdb_database db;
};

struct dpq_conn_s {
  duckdb_connection conn;
};

struct dpq_cursor_s {
  duckdb_prepared_statement stmt;
  duckdb_result result;
  bool has_result;

  /* A chunk can be larger than the caller's page size, so a partially consumed
   * chunk is held here between fetches. */
  duckdb_data_chunk chunk;
  idx_t chunk_size;
  idx_t chunk_pos;
  bool exhausted;

  int32_t ncols;
  char **names;
};

/* --- small helpers ------------------------------------------------------- */

static char *dup_cstr(const char *s) {
  if (!s) s = "";
  size_t n = strlen(s) + 1;
  char *out = (char *)malloc(n);
  if (out) memcpy(out, s, n);
  return out;
}

static void set_err(char **err, const char *msg) {
  if (err && !*err) *err = dup_cstr(msg && *msg ? msg : "unknown DuckDB error");
}

void dpq_string_free(char *s) { free(s); }

const char *dpq_duckdb_version(void) { return duckdb_library_version(); }

/*
 * Trim whitespace and trailing semicolons so the statement can be wrapped in a
 * subquery. Returns a fresh string.
 */
static char *trim_statement(const char *sql) {
  if (!sql) return dup_cstr("");
  const char *start = sql;
  while (*start && (unsigned char)*start <= ' ') start++;
  const char *end = start + strlen(start);
  while (end > start) {
    unsigned char c = (unsigned char)end[-1];
    if (c <= ' ' || c == ';') {
      end--;
    } else {
      break;
    }
  }
  size_t n = (size_t)(end - start);
  char *out = (char *)malloc(n + 1);
  if (!out) return NULL;
  memcpy(out, start, n);
  out[n] = '\0';
  return out;
}

/* --- database / connection ----------------------------------------------- */

dpq_db dpq_db_open(char **err) {
  struct dpq_db_s *h = (struct dpq_db_s *)calloc(1, sizeof(*h));
  if (!h) {
    set_err(err, "out of memory");
    return NULL;
  }
  char *open_err = NULL;
  if (duckdb_open_ext(NULL, &h->db, NULL, &open_err) == DuckDBError) {
    set_err(err, open_err);
    duckdb_free(open_err);
    free(h);
    return NULL;
  }
  return h;
}

void dpq_db_close(dpq_db db) {
  if (!db) return;
  duckdb_close(&db->db);
  free(db);
}

dpq_conn dpq_conn_open(dpq_db db, char **err) {
  if (!db) {
    set_err(err, "no database");
    return NULL;
  }
  struct dpq_conn_s *c = (struct dpq_conn_s *)calloc(1, sizeof(*c));
  if (!c) {
    set_err(err, "out of memory");
    return NULL;
  }
  if (duckdb_connect(db->db, &c->conn) == DuckDBError) {
    set_err(err, "failed to connect");
    free(c);
    return NULL;
  }
  return c;
}

void dpq_conn_close(dpq_conn conn) {
  if (!conn) return;
  duckdb_disconnect(&conn->conn);
  free(conn);
}

void dpq_conn_interrupt(dpq_conn conn) {
  if (conn) duckdb_interrupt(conn->conn);
}

/* --- statement preparation ----------------------------------------------- */

static duckdb_prepared_statement prepare_bound(dpq_conn conn, const char *sql,
                                               const char *const *params,
                                               int32_t nparams, char **err) {
  duckdb_prepared_statement stmt = NULL;
  if (duckdb_prepare(conn->conn, sql, &stmt) == DuckDBError) {
    set_err(err, duckdb_prepare_error(stmt));
    duckdb_destroy_prepare(&stmt);
    return NULL;
  }
  for (int32_t i = 0; i < nparams; i++) {
    /* Bound as VARCHAR; callers cast at the comparison site where the column
     * type is known, so no user value is ever interpolated into SQL text. */
    if (duckdb_bind_varchar(stmt, (idx_t)(i + 1), params[i] ? params[i] : "") ==
        DuckDBError) {
      set_err(err, duckdb_prepare_error(stmt));
      duckdb_destroy_prepare(&stmt);
      return NULL;
    }
  }
  return stmt;
}

bool dpq_exec(dpq_conn conn, const char *sql, const char *const *params,
              int32_t nparams, char **err) {
  if (!conn) {
    set_err(err, "no connection");
    return false;
  }
  duckdb_prepared_statement stmt = prepare_bound(conn, sql, params, nparams, err);
  if (!stmt) return false;

  duckdb_result result;
  bool ok = duckdb_execute_prepared(stmt, &result) != DuckDBError;
  if (!ok) set_err(err, duckdb_result_error(&result));
  duckdb_destroy_result(&result);
  duckdb_destroy_prepare(&stmt);
  return ok;
}

/* --- statement classification -------------------------------------------- */

static dpq_stmt_kind map_kind(duckdb_statement_type type) {
  switch (type) {
    case DUCKDB_STATEMENT_TYPE_SELECT:      return DPQ_STMT_SELECT;
    case DUCKDB_STATEMENT_TYPE_EXPLAIN:     return DPQ_STMT_EXPLAIN;
    case DUCKDB_STATEMENT_TYPE_INSERT:      return DPQ_STMT_INSERT;
    case DUCKDB_STATEMENT_TYPE_UPDATE:      return DPQ_STMT_UPDATE;
    case DUCKDB_STATEMENT_TYPE_DELETE:      return DPQ_STMT_DELETE;
    case DUCKDB_STATEMENT_TYPE_MERGE_INTO:  return DPQ_STMT_UPDATE;
    case DUCKDB_STATEMENT_TYPE_CREATE:      return DPQ_STMT_CREATE;
    case DUCKDB_STATEMENT_TYPE_CREATE_FUNC: return DPQ_STMT_CREATE;
    case DUCKDB_STATEMENT_TYPE_DROP:        return DPQ_STMT_DROP;
    case DUCKDB_STATEMENT_TYPE_ALTER:       return DPQ_STMT_ALTER;
    case DUCKDB_STATEMENT_TYPE_COPY:        return DPQ_STMT_COPY;
    case DUCKDB_STATEMENT_TYPE_COPY_DATABASE: return DPQ_STMT_COPY;
    case DUCKDB_STATEMENT_TYPE_EXPORT:      return DPQ_STMT_EXPORT;
    case DUCKDB_STATEMENT_TYPE_ATTACH:      return DPQ_STMT_ATTACH;
    case DUCKDB_STATEMENT_TYPE_DETACH:      return DPQ_STMT_DETACH;
    case DUCKDB_STATEMENT_TYPE_SET:         return DPQ_STMT_SET;
    case DUCKDB_STATEMENT_TYPE_VARIABLE_SET: return DPQ_STMT_SET;
    case DUCKDB_STATEMENT_TYPE_LOAD:        return DPQ_STMT_LOAD;
    case DUCKDB_STATEMENT_TYPE_UPDATE_EXTENSIONS: return DPQ_STMT_LOAD;
    case DUCKDB_STATEMENT_TYPE_CALL:        return DPQ_STMT_CALL;
    case DUCKDB_STATEMENT_TYPE_TRANSACTION: return DPQ_STMT_TRANSACTION;
    case DUCKDB_STATEMENT_TYPE_PREPARE:     return DPQ_STMT_PREPARE;
    case DUCKDB_STATEMENT_TYPE_EXECUTE:     return DPQ_STMT_EXECUTE;
    case DUCKDB_STATEMENT_TYPE_VACUUM:      return DPQ_STMT_VACUUM;
    case DUCKDB_STATEMENT_TYPE_ANALYZE:     return DPQ_STMT_ANALYZE;
    default:                                return DPQ_STMT_OTHER;
  }
}

int32_t dpq_statement_kinds(dpq_conn conn, const char *sql, int32_t *out_kinds,
                            int32_t max_kinds, char **err) {
  if (!conn) {
    set_err(err, "no connection");
    return -1;
  }

  duckdb_extracted_statements extracted = NULL;
  idx_t count = duckdb_extract_statements(conn->conn, sql ? sql : "", &extracted);
  if (count == 0) {
    set_err(err, duckdb_extract_statements_error(extracted));
    duckdb_destroy_extracted(&extracted);
    return -1;
  }

  for (idx_t i = 0; i < count; i++) {
    duckdb_prepared_statement stmt = NULL;
    if (duckdb_prepare_extracted_statement(conn->conn, extracted, i, &stmt) ==
        DuckDBError) {
      set_err(err, duckdb_prepare_error(stmt));
      duckdb_destroy_prepare(&stmt);
      duckdb_destroy_extracted(&extracted);
      return -1;
    }
    if (out_kinds && (int32_t)i < max_kinds)
      out_kinds[i] = (int32_t)map_kind(duckdb_prepared_statement_type(stmt));
    duckdb_destroy_prepare(&stmt);
  }

  duckdb_destroy_extracted(&extracted);
  return (int32_t)count;
}

/* --- cursor -------------------------------------------------------------- */

dpq_cursor dpq_cursor_open(dpq_conn conn, const char *sql,
                           const char *const *params, int32_t nparams,
                           char **err) {
  if (!conn) {
    set_err(err, "no connection");
    return NULL;
  }

  char *inner = trim_statement(sql);
  if (!inner) {
    set_err(err, "out of memory");
    return NULL;
  }
  /* See duckparq.h: one uniform VARCHAR path, order-preserving. */
  static const char *prefix = "SELECT COLUMNS(*)::VARCHAR FROM (";
  static const char *suffix = ")";
  size_t len = strlen(prefix) + strlen(inner) + strlen(suffix) + 1;
  char *wrapped = (char *)malloc(len);
  if (!wrapped) {
    free(inner);
    set_err(err, "out of memory");
    return NULL;
  }
  snprintf(wrapped, len, "%s%s%s", prefix, inner, suffix);
  free(inner);

  struct dpq_cursor_s *cur = (struct dpq_cursor_s *)calloc(1, sizeof(*cur));
  if (!cur) {
    free(wrapped);
    set_err(err, "out of memory");
    return NULL;
  }

  cur->stmt = prepare_bound(conn, wrapped, params, nparams, err);
  free(wrapped);
  if (!cur->stmt) {
    free(cur);
    return NULL;
  }

  duckdb_pending_result pending = NULL;
  if (duckdb_pending_prepared_streaming(cur->stmt, &pending) == DuckDBError) {
    set_err(err, duckdb_pending_error(pending));
    duckdb_destroy_pending(&pending);
    dpq_cursor_close(cur);
    return NULL;
  }
  if (duckdb_execute_pending(pending, &cur->result) == DuckDBError) {
    set_err(err, duckdb_result_error(&cur->result));
    duckdb_destroy_pending(&pending);
    duckdb_destroy_result(&cur->result);
    dpq_cursor_close(cur);
    return NULL;
  }
  duckdb_destroy_pending(&pending);
  cur->has_result = true;

  cur->ncols = (int32_t)duckdb_column_count(&cur->result);
  cur->names = (char **)calloc((size_t)(cur->ncols > 0 ? cur->ncols : 1),
                               sizeof(char *));
  if (!cur->names) {
    set_err(err, "out of memory");
    dpq_cursor_close(cur);
    return NULL;
  }
  for (int32_t i = 0; i < cur->ncols; i++)
    cur->names[i] = dup_cstr(duckdb_column_name(&cur->result, (idx_t)i));

  return cur;
}

int32_t dpq_cursor_column_count(dpq_cursor cur) { return cur ? cur->ncols : 0; }

const char *dpq_cursor_column_name(dpq_cursor cur, int32_t index) {
  if (!cur || index < 0 || index >= cur->ncols) return NULL;
  return cur->names[index];
}

/* Row block being accumulated across however many chunks a page spans. */
typedef struct {
  uint8_t *bytes;
  size_t bytes_len;
  size_t bytes_cap;
  int32_t *offsets;
  size_t offsets_len;
  size_t offsets_cap;
  uint8_t *nulls;
  size_t nulls_cap;
  bool failed;
} builder;

static bool builder_reserve_bytes(builder *b, size_t extra) {
  if (b->bytes_len + extra <= b->bytes_cap) return true;
  size_t cap = b->bytes_cap ? b->bytes_cap : 4096;
  while (cap < b->bytes_len + extra) cap *= 2;
  uint8_t *p = (uint8_t *)realloc(b->bytes, cap);
  if (!p) return false;
  b->bytes = p;
  b->bytes_cap = cap;
  return true;
}

static bool builder_push_offset(builder *b, int32_t value) {
  if (b->offsets_len + 1 > b->offsets_cap) {
    size_t cap = b->offsets_cap ? b->offsets_cap * 2 : 1024;
    int32_t *p = (int32_t *)realloc(b->offsets, cap * sizeof(int32_t));
    if (!p) return false;
    b->offsets = p;
    b->offsets_cap = cap;
  }
  b->offsets[b->offsets_len++] = value;
  return true;
}

static bool builder_mark_null(builder *b, size_t cell) {
  size_t need = cell / 8 + 1;
  if (need > b->nulls_cap) {
    size_t cap = b->nulls_cap ? b->nulls_cap : 128;
    while (cap < need) cap *= 2;
    uint8_t *p = (uint8_t *)realloc(b->nulls, cap);
    if (!p) return false;
    memset(p + b->nulls_cap, 0, cap - b->nulls_cap);
    b->nulls = p;
    b->nulls_cap = cap;
  }
  b->nulls[cell / 8] |= (uint8_t)(1u << (cell % 8));
  return true;
}

static void builder_dispose(builder *b) {
  free(b->bytes);
  free(b->offsets);
  free(b->nulls);
}

/* Every column is VARCHAR thanks to the COLUMNS(*)::VARCHAR wrap, so this is
 * the only value path in the bridge. */
static void append_cell(builder *b, duckdb_vector vec, idx_t row, size_t cell) {
  uint64_t *validity = duckdb_vector_get_validity(vec);
  if (validity && !duckdb_validity_row_is_valid(validity, row)) {
    if (!builder_mark_null(b, cell)) b->failed = true;
    return;
  }
  duckdb_string_t *strings = (duckdb_string_t *)duckdb_vector_get_data(vec);
  duckdb_string_t s = strings[row];
  uint32_t len = duckdb_string_t_length(s);
  const char *data = duckdb_string_t_data(&s);
  if (len > 0) {
    if (!builder_reserve_bytes(b, len)) {
      b->failed = true;
      return;
    }
    memcpy(b->bytes + b->bytes_len, data, len);
    b->bytes_len += len;
  }
}

dpq_rows *dpq_cursor_fetch(dpq_cursor cur, int32_t max_rows, char **err) {
  if (!cur || !cur->has_result) {
    set_err(err, "cursor is not open");
    return NULL;
  }
  if (max_rows <= 0) max_rows = 1;

  builder b;
  memset(&b, 0, sizeof b);
  /* Leading 0; one offset follows per cell, so cells is offsets_len - 1. */
  if (!builder_push_offset(&b, 0)) {
    builder_dispose(&b);
    set_err(err, "out of memory");
    return NULL;
  }

  int32_t produced = 0;
  while (produced < max_rows && !cur->exhausted) {
    if (!cur->chunk) {
      cur->chunk = duckdb_fetch_chunk(cur->result);
      if (!cur->chunk) {
        /* End of stream, or the query failed part-way (e.g. interrupted). */
        const char *msg = duckdb_result_error(&cur->result);
        if (msg && *msg) {
          builder_dispose(&b);
          set_err(err, msg);
          return NULL;
        }
        cur->exhausted = true;
        break;
      }
      cur->chunk_size = duckdb_data_chunk_get_size(cur->chunk);
      cur->chunk_pos = 0;
      if (cur->chunk_size == 0) {
        duckdb_destroy_data_chunk(&cur->chunk);
        cur->chunk = NULL;
        continue;
      }
    }

    idx_t available = cur->chunk_size - cur->chunk_pos;
    idx_t take = (idx_t)(max_rows - produced);
    if (take > available) take = available;

    for (idx_t r = 0; r < take; r++) {
      idx_t src_row = cur->chunk_pos + r;
      for (int32_t c = 0; c < cur->ncols; c++) {
        duckdb_vector vec = duckdb_data_chunk_get_vector(cur->chunk, (idx_t)c);
        size_t cell = (size_t)(produced + (int32_t)r) * (size_t)cur->ncols + (size_t)c;
        append_cell(&b, vec, src_row, cell);
        if (b.failed || !builder_push_offset(&b, (int32_t)b.bytes_len)) {
          builder_dispose(&b);
          set_err(err, "out of memory");
          return NULL;
        }
      }
    }

    cur->chunk_pos += take;
    produced += (int32_t)take;
    if (cur->chunk_pos >= cur->chunk_size) {
      duckdb_destroy_data_chunk(&cur->chunk);
      cur->chunk = NULL;
    }
  }

  if (produced == 0) {
    builder_dispose(&b);
    return NULL; /* end of stream; *err deliberately untouched */
  }

  /* Ensure the null bitmap covers every cell even when no NULLs appeared. */
  size_t cells = (size_t)produced * (size_t)cur->ncols;
  size_t nulls_bytes = (cells + 7) / 8;
  if (b.nulls_cap < nulls_bytes) {
    uint8_t *p = (uint8_t *)realloc(b.nulls, nulls_bytes ? nulls_bytes : 1);
    if (!p) {
      builder_dispose(&b);
      set_err(err, "out of memory");
      return NULL;
    }
    memset(p + b.nulls_cap, 0, (nulls_bytes ? nulls_bytes : 1) - b.nulls_cap);
    b.nulls = p;
    b.nulls_cap = nulls_bytes;
  }
  if (!b.bytes) {
    b.bytes = (uint8_t *)calloc(1, 1); /* keep the pointer non-NULL for Swift */
    if (!b.bytes) {
      builder_dispose(&b);
      set_err(err, "out of memory");
      return NULL;
    }
  }

  dpq_rows *rows = (dpq_rows *)malloc(sizeof(dpq_rows));
  if (!rows) {
    builder_dispose(&b);
    set_err(err, "out of memory");
    return NULL;
  }
  rows->rows = produced;
  rows->cols = cur->ncols;
  rows->bytes = b.bytes;
  rows->offsets = b.offsets;
  rows->nulls = b.nulls;
  return rows;
}

void dpq_rows_free(dpq_rows *rows) {
  if (!rows) return;
  free((void *)rows->bytes);
  free((void *)rows->offsets);
  free((void *)rows->nulls);
  free(rows);
}

void dpq_cursor_close(dpq_cursor cur) {
  if (!cur) return;
  if (cur->chunk) duckdb_destroy_data_chunk(&cur->chunk);
  if (cur->has_result) duckdb_destroy_result(&cur->result);
  if (cur->stmt) duckdb_destroy_prepare(&cur->stmt);
  if (cur->names) {
    for (int32_t i = 0; i < cur->ncols; i++) free(cur->names[i]);
    free(cur->names);
  }
  free(cur);
}
