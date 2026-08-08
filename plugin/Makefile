BIN := viewer
# The version the assets are named after. Every tarball carries it in its filename and the catalog
# entry quotes those names, so it has to be the tag that is shipping them — a number kept by hand is
# one nobody notices is a release behind until the entry points at a file that says v1 on a v2
# release. So it is read rather than written: the release workflow passes the tag it was pushed
# with, and anywhere else it is the tag standing on this commit. `dev` when there is none, since a
# build off an untagged working copy is exactly that, and a name saying so is the honest one.
VERSION ?= $(shell git describe --tags --exact-match 2>/dev/null || echo dev)
# One asset per platform key the catalog entry publishes. This list is what a release bakes:
# the release workflow runs `dist` rather than enumerating platforms of its own, so the keys
# published and the keys checked here cannot drift apart, and a platform is added in one place.
# Nothing here needs a C toolchain or a Mac — the plugin is pure Go, so every asset
# cross-compiles from one runner.
PLATFORMS := macos-arm64 macos-x64 linux-x64 linux-arm64 windows-x64 windows-arm64

.PHONY: build test manifest install dist clean

build:
	go build -o $(BIN) .

test: manifest
	@test -z "$$(gofmt -l .)" || { echo "gofmt:"; gofmt -l .; exit 1; }
	go vet ./...
	go test ./...

# The manifest is checked against the same rules amenbo enforces at the install door, so a
# manifest that would be refused there is refused here first. It needs no store and no binding,
# but it does need amenbo on the PATH — a machine without it skips the check rather than failing
# the build over a tool that is not this repository's to require.
manifest:
	@if command -v amenbo >/dev/null 2>&1; then \
		amenbo --actor ai plugin validate dev/manifest.json; \
	else \
		echo "manifest: amenbo is not on the PATH — skipping the catalog check"; \
	fi

# Hand-install into an amenbo base dir — the author's own loop, before there is a release to
# install from:
#
#   make install AMENBO_BASE="$$AMENBO_HOME"
#
# The real route is `amenbo plugin install viewer`, which resolves the catalog entry, fetches
# the released asset and verifies its provenance before laying it down. This target skips all
# of that, so point it at a throwaway base, never at the one holding work you care about.
install: build
ifndef AMENBO_BASE
	$(error set AMENBO_BASE to the amenbo base dir to install into)
endif
	mkdir -p "$(AMENBO_BASE)/plugins/$(BIN)"
	cp $(BIN) "$(AMENBO_BASE)/plugins/$(BIN)/$(BIN)"
	cp dev/manifest.json "$(AMENBO_BASE)/plugins/$(BIN)/manifest.json"
	@echo "installed into $(AMENBO_BASE)/plugins/$(BIN) — switch it on for a project:"
	@echo "  amenbo plugin enable $(BIN)"
#
# The release build: every asset the catalog entry points at, plus the digests it quotes. The
# release workflow runs this, so what CI publishes is what this prints; run it by hand to check
# a release before tagging one.
#
# **The entry inside each tarball is the plugin's name**, flat — `<name>.exe` on Windows: that
# is the file an install lays down, and it is looked for by name.
#
# The checksums in dev/manifest.json are the ones this prints. Until the first release they are
# zeros, which is a placeholder and not a digest — the manifest is shape-valid so it can be
# checked in CI, and nothing can install from it.
dist: test
	rm -rf dist && mkdir -p dist/stage
	@set -e; for p in $(PLATFORMS); do \
		case $$p in \
			macos-arm64) os=darwin; arch=arm64;; \
			macos-x64) os=darwin; arch=amd64;; \
			linux-x64) os=linux; arch=amd64;; \
			linux-arm64) os=linux; arch=arm64;; \
			windows-x64) os=windows; arch=amd64;; \
			windows-arm64) os=windows; arch=arm64;; \
			*) echo "no GOOS/GOARCH for platform key $$p"; exit 1;; \
		esac; \
		entry=$(BIN); \
		if [ "$$os" = windows ]; then entry=$(BIN).exe; fi; \
		mkdir -p dist/stage/$$p; \
		CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build -trimpath -ldflags "-s -w" -o dist/stage/$$p/$$entry .; \
		chmod +x dist/stage/$$p/$$entry; \
		tar -czf dist/$(BIN)-$(VERSION)-$$p.tar.gz -C dist/stage/$$p $$entry; \
	done
	@echo; echo "assets for the catalog entry (checksum: sha256:<digest>):"; cd dist && shasum -a 256 *.tar.gz

clean:
	rm -f $(BIN)
	rm -rf dist
