SHELL := /bin/bash
ROOT  := $(shell pwd)

VENDOR      := $(ROOT)/Vendor/duckdb
VENDOR_LIB  := $(VENDOR)/lib
VENDOR_INC  := $(VENDOR)/include
VENDOR_STAMP:= $(VENDOR)/.stamp

FIXTURES := $(ROOT)/.fixtures
BUILD    := $(ROOT)/.build
APP      := $(BUILD)/DuckParq.app

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# DuckDB's statically linked extensions are registered through the generated
# extension loader. The linker discards archive members nothing references, so
# the extension archives must be force-loaded or the parquet reader silently
# never registers.
FORCE_LOAD_LIBS := \
  libduckdb_generated_extension_loader.a \
  libparquet_extension.a \
  libcore_functions_extension.a \
  libjson_extension.a \
  libicu_extension.a \
  libautocomplete_extension.a

FORCE_LOAD_FLAGS := $(foreach l,$(FORCE_LOAD_LIBS),-Wl,-force_load,$(VENDOR_LIB)/$(l))

DUCKDB_LINK := -L$(VENDOR_LIB) $(FORCE_LOAD_FLAGS) \
  -lduckdb_static \
  -lduckdb_fmt -lduckdb_pg_query -lduckdb_re2 -lduckdb_miniz \
  -lduckdb_utf8proc -lduckdb_hyperloglog -lduckdb_fastpforlib \
  -lduckdb_skiplistlib -lduckdb_mbedtls -lduckdb_fsst \
  -lduckdb_yyjson -lduckdb_zstd \
  -lc++

.PHONY: all vendor fixtures smoke build release test app run install clean distclean

all: build

vendor: $(VENDOR_STAMP)

$(VENDOR_STAMP):
	@./scripts/fetch-duckdb.sh

fixtures: $(FIXTURES)/small.parquet

$(FIXTURES)/small.parquet:
	@./scripts/make-fixtures.sh

## smoke: go/no-go gate -- proves the vendored static archives link AND that
## the parquet extension actually registered. Run this before anything else.
smoke: vendor fixtures
	@mkdir -p $(BUILD)
	cc -O2 -Wall -Wextra -I$(VENDOR_INC) scripts/smoke.c -o $(BUILD)/smoke $(DUCKDB_LINK)
	@echo
	@$(BUILD)/smoke $(FIXTURES)/small.parquet

build: vendor
	swift build

release: vendor
	swift build -c release

## test: a CLT-only toolchain has no XCTest or swift-testing, so the suite is
## an executable rather than `swift test`.
test: vendor fixtures
	swift build
	@echo
	@./.build/debug/DuckParqSelfTest

app: release
	@./scripts/make-app.sh

run: app
	open $(APP)

## install: Launch Services notices /Applications on its own schedule, so the
## document types are re-registered by hand -- otherwise Finder keeps offering
## whatever the previous copy of the bundle claimed.
install: app
	rm -rf /Applications/DuckParq.app
	cp -R $(APP) /Applications/
	@$(LSREGISTER) -f /Applications/DuckParq.app
	@echo "installed /Applications/DuckParq.app"

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf $(VENDOR) $(FIXTURES)
