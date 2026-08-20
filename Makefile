CC ?= cc
VERSION := 0.1.0
BUILD_DIR := build
MODULE := $(BUILD_DIR)/omarchy_autosuggest.so

CPPFLAGS += -D_DEFAULT_SOURCE -D_XOPEN_SOURCE=600
CPPFLAGS += -DOMARCHY_AUTOSUGGEST_VERSION='"$(VERSION)"'
CPPFLAGS += -I/usr/include/bash -I/usr/include/bash/include -I/usr/include/bash/builtins
CFLAGS ?= -O2 -pipe
CFLAGS += -std=c11 -fPIC -Wall -Wextra
LDFLAGS += -shared
LDLIBS += -lreadline

.PHONY: all clean check test

all: $(MODULE)

$(MODULE): src/omarchy_autosuggest.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)
	strip --strip-unneeded $@

$(BUILD_DIR):
	mkdir -p $@

check:
	$(CC) $(CPPFLAGS) -std=c11 -Wall -Wextra -fanalyzer -fsyntax-only src/omarchy_autosuggest.c
	bash -n install.sh uninstall.sh shell/init.bash tests/smoke.sh
	shellcheck -s bash install.sh uninstall.sh shell/init.bash tests/smoke.sh

test: all
	bash tests/smoke.sh

clean:
	rm -f $(MODULE)
