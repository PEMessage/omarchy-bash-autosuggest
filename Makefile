CC ?= cc
PYTHON ?= python
VERSION := 0.2.1
BUILD_DIR := build
MODULE := $(BUILD_DIR)/omarchy_autosuggest.so

CPPFLAGS += -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600
CPPFLAGS += -DOMARCHY_AUTOSUGGEST_VERSION='"$(VERSION)"'
CPPFLAGS += -I/usr/include/bash -I/usr/include/bash/include -I/usr/include/bash/builtins
CFLAGS ?= -O2 -pipe
CFLAGS += -std=c11 -fPIC -Wall -Wextra
LDFLAGS += -shared
LDLIBS += -lreadline

.PHONY: all clean check rebuild test

all: $(MODULE)

$(MODULE): src/omarchy_autosuggest.c | $(BUILD_DIR)
	@set -e; \
	tmp="$@.tmp"; \
	trap 'rm -f -- "$$tmp"' EXIT HUP INT TERM; \
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o "$$tmp" $< $(LDLIBS); \
	strip --strip-unneeded "$$tmp"; \
	mv -f -- "$$tmp" $@; \
	trap - EXIT HUP INT TERM

$(BUILD_DIR):
	mkdir -p $@

rebuild:
	$(MAKE) --no-print-directory --always-make all

check:
	$(CC) $(CPPFLAGS) -std=c11 -Wall -Wextra -fanalyzer -fsyntax-only src/omarchy_autosuggest.c
	bash -n install.sh uninstall.sh shell/init.bash tests/loader.sh tests/smoke.sh
	shellcheck -s bash install.sh uninstall.sh shell/init.bash tests/loader.sh tests/smoke.sh

test: all
	bash tests/smoke.sh
	bash tests/loader.sh
	$(PYTHON) tests/interactive.py $(MODULE)

clean:
	rm -f $(MODULE) $(MODULE).tmp
