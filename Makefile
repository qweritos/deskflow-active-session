SWIFT ?= swift
CONFIGURATION ?= release
BINARY := .build/$(CONFIGURATION)/deskflow-session-supervisor
USERS ?=

.PHONY: all build check manager manager-install install uninstall status clean

all: build

build:
	$(SWIFT) build -c $(CONFIGURATION)

check:
	./tests/smoke.sh

manager:
	./scripts/build-manager-app.sh

manager-install:
	./scripts/install-manager-app.sh

install: build
	./scripts/install.sh $(USERS)

uninstall:
	./scripts/uninstall.sh $(USERS)

status:
	./scripts/status.sh $(USERS)

clean:
	$(SWIFT) package clean
