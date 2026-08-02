/*
 * Static-link smoke gate.
 *
 * This exists to answer one question before any app code is written: does
 * linking the vendored DuckDB static archives actually register the parquet
 * reader? Statically linked DuckDB extensions are pulled in by
 * libduckdb_generated_extension_loader.a, and the linker will happily drop
 * archive members nothing references -- hence -force_load on the extension
 * archives in the link line (see the Makefile).
 *
 * So this deliberately queries a real parquet file rather than SELECT 42.
 * It also exercises the exact streaming path the bridge uses:
 *   prepare -> pending_prepared_streaming -> execute_pending -> fetch_chunk
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "duckdb.h"

static int fail(const char *what, const char *err) {
  fprintf(stderr, "FAIL: %s: %s\n", what, err ? err : "(no message)");
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <fixture.parquet>\n", argv[0]);
    return 2;
  }

  printf("duckdb library version: %s\n", duckdb_library_version());

  duckdb_database db;
  duckdb_connection con;
  char *open_err = NULL;
  if (duckdb_open_ext(NULL, &db, NULL, &open_err) == DuckDBError) {
    int rc = fail("duckdb_open_ext", open_err);
    duckdb_free(open_err);
    return rc;
  }
  if (duckdb_connect(db, &con) == DuckDBError) return fail("duckdb_connect", NULL);

  /* The parquet reader is only reachable if the static extension registered. */
  char sql[4096];
  snprintf(sql, sizeof sql,
           "SELECT id, category, score FROM read_parquet($1) ORDER BY id LIMIT 5");

  duckdb_prepared_statement stmt;
  if (duckdb_prepare(con, sql, &stmt) == DuckDBError) {
    int rc = fail("duckdb_prepare", duckdb_prepare_error(stmt));
    duckdb_destroy_prepare(&stmt);
    return rc;
  }
  if (duckdb_bind_varchar(stmt, 1, argv[1]) == DuckDBError)
    return fail("duckdb_bind_varchar", NULL);

  duckdb_pending_result pending;
  if (duckdb_pending_prepared_streaming(stmt, &pending) == DuckDBError) {
    int rc = fail("duckdb_pending_prepared_streaming", duckdb_pending_error(pending));
    duckdb_destroy_pending(&pending);
    return rc;
  }

  duckdb_result result;
  if (duckdb_execute_pending(pending, &result) == DuckDBError) {
    int rc = fail("duckdb_execute_pending", duckdb_result_error(&result));
    duckdb_destroy_result(&result);
    return rc;
  }
  duckdb_destroy_pending(&pending);

  printf("streaming result: %s\n",
         duckdb_result_is_streaming(result) ? "yes" : "no (materialized)");

  idx_t ncols = duckdb_column_count(&result);
  for (idx_t c = 0; c < ncols; c++)
    printf("%-12s", duckdb_column_name(&result, c));
  printf("\n");

  idx_t total_rows = 0;
  for (;;) {
    duckdb_data_chunk chunk = duckdb_fetch_chunk(result);
    if (!chunk) break;
    idx_t nrows = duckdb_data_chunk_get_size(chunk);
    for (idx_t r = 0; r < nrows; r++) {
      for (idx_t c = 0; c < ncols; c++) {
        duckdb_vector vec = duckdb_data_chunk_get_vector(chunk, c);
        uint64_t *validity = duckdb_vector_get_validity(vec);
        if (validity && !duckdb_validity_row_is_valid(validity, r)) {
          printf("%-12s", "NULL");
          continue;
        }
        /* Only enough type handling for the gate; the real bridge casts
         * everything to VARCHAR in SQL and reads one uniform path. */
        duckdb_logical_type lt = duckdb_column_logical_type(&result, c);
        duckdb_type t = duckdb_get_type_id(lt);
        duckdb_destroy_logical_type(&lt);
        if (t == DUCKDB_TYPE_VARCHAR) {
          duckdb_string_t *strs = (duckdb_string_t *)duckdb_vector_get_data(vec);
          duckdb_string_t s = strs[r];
          const char *p = duckdb_string_is_inlined(s) ? s.value.inlined.inlined
                                                      : s.value.pointer.ptr;
          printf("%-12.*s", (int)s.value.inlined.length, p);
        } else {
          int64_t *vals = (int64_t *)duckdb_vector_get_data(vec);
          printf("%-12lld", (long long)vals[r]);
        }
      }
      printf("\n");
    }
    total_rows += nrows;
    duckdb_destroy_data_chunk(&chunk);
  }

  duckdb_destroy_result(&result);
  duckdb_destroy_prepare(&stmt);
  duckdb_disconnect(&con);
  duckdb_close(&db);

  if (total_rows == 0) {
    fprintf(stderr, "FAIL: parquet query returned no rows\n");
    return 1;
  }
  printf("\nOK: read %llu rows of parquet from a statically linked DuckDB\n",
         (unsigned long long)total_rows);
  return 0;
}
