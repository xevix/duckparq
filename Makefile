SHELL := /bin/bash
ROOT  := $(shell pwd)

VENDOR      := $(ROOT)/Vendor/duckdb
VENDOR_LIB  := $(VENDOR)/lib
VENDOR_INC  := $(VENDOR)/include
VENDOR_STAMP:= $(VENDOR)/.stamp

# Vortex ships as a signed, loadable extension rather than a static archive, so
# it is vendored separately and copied into the bundle -- see
# scripts/fetch-extensions.sh and DuckDBEngine.extensionURL(named:).
EXTENSIONS  := $(ROOT)/Vendor/duckdb-extensions
EXT_STAMP   := $(EXTENSIONS)/.stamp
VORTEX_EXT  := $(EXTENSIONS)/vortex.duckdb_extension

FIXTURES := $(ROOT)/.fixtures
BUILD    := $(ROOT)/.build
APP      := $(BUILD)/DuckParq.app

# SwiftUI's macros -- @State, @Bindable, @Environment -- are expanded by a
# compiler plugin that ships inside Xcode and not with the Command Line Tools.
# Build with the CLT selected and every view fails on its first property with
#
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be
#   found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
#
# which reads like a defect in the code and is not one. It also drags a trail of
# nonsense warnings behind it, because a view that cannot see AppModel's types
# decides that nothing in it throws.
#
# So: if the active developer directory has no such plugin and Xcode is
# installed, point *this build* at Xcode. `xcode-select -p` is deliberately left
# alone -- changing it needs sudo and changes the whole machine, where this
# changes one build and nothing else. An explicit DEVELOPER_DIR in the
# environment always wins, and a machine with Xcode already selected (CI, for
# one) never reaches the switch.
SWIFTUI_PLUGIN := Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
XCODE_DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

ifeq ($(origin DEVELOPER_DIR),undefined)
  ifeq ($(wildcard $(shell xcode-select -p 2>/dev/null)/$(SWIFTUI_PLUGIN)),)
    ifneq ($(wildcard $(XCODE_DEVELOPER_DIR)/$(SWIFTUI_PLUGIN)),)
      export DEVELOPER_DIR := $(XCODE_DEVELOPER_DIR)
    endif
  endif
endif

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

.PHONY: all vendor extensions fixtures smoke build release test app run install clean distclean

all: build

vendor: $(VENDOR_STAMP)

$(VENDOR_STAMP):
	@./scripts/fetch-duckdb.sh

extensions: $(EXT_STAMP)

$(EXT_STAMP): scripts/fetch-extensions.sh
	@./scripts/fetch-extensions.sh

fixtures: $(FIXTURES)/small.parquet

# Depends on the script, not just on the stamp file: a checkout that already has
# fixtures needs to pick up ones added since, or `make test` runs against a set
# the tests no longer describe.
$(FIXTURES)/small.parquet: scripts/make-fixtures.sh $(EXT_STAMP)
	@./scripts/make-fixtures.sh

## smoke: go/no-go gate -- proves the vendored static archives link AND that
## the parquet extension actually registered. Run this before anything else.
smoke: vendor extensions fixtures
	@mkdir -p $(BUILD)
	cc -O2 -Wall -Wextra -I$(VENDOR_INC) scripts/smoke.c -o $(BUILD)/smoke $(DUCKDB_LINK)
	@echo
	@$(BUILD)/smoke $(FIXTURES)/small.parquet $(VORTEX_EXT) $(FIXTURES)/small.vortex

build: vendor extensions
	swift build

release: vendor extensions
	swift build -c release

## test: a CLT-only toolchain has no XCTest or swift-testing, so the suite is
## an executable rather than `swift test`.
test: vendor extensions fixtures
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
	rm -rf $(VENDOR) $(EXTENSIONS) $(FIXTURES)
