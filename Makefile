# Majestic Media Player — build with `make`, run with `make run`.
# Requires: nim >= 2.2, git, mpv (libmpv), mesa/libGL, libX11, libXrandr.

NIM      ?= nim
BIN      := majestic-media-player
SRC      := src/majestic.nim
NIMFLAGS ?= -d:release --hints:off

.PHONY: all deps run debug clean

all: $(BIN)

vendor/.stamp: deps.lock tools/fetch_deps.sh
	./tools/fetch_deps.sh
	touch $@

deps: vendor/.stamp

$(BIN): vendor/.stamp $(wildcard src/*.nim) assets/fonts/IBMPlexSans-Regular.ttf
	$(NIM) c $(NIMFLAGS) -o:$(BIN) $(SRC)

debug: vendor/.stamp
	$(NIM) c -d:debug --hints:off -o:$(BIN) $(SRC)

run: $(BIN)
	./$(BIN)

clean:
	rm -f $(BIN)

# Per-user install: adds the app to the launcher and to "Open With" for media.
PREFIX ?= $(HOME)/.local

.PHONY: install uninstall
install: $(BIN)
	install -Dm755 $(BIN) $(PREFIX)/bin/$(BIN)
	install -Dm644 assets/desktop/majestic-media-player.desktop $(PREFIX)/share/applications/majestic-media-player.desktop
	install -Dm644 assets/desktop/majestic-media-player.svg $(PREFIX)/share/icons/hicolor/scalable/apps/majestic-media-player.svg
	-update-desktop-database $(PREFIX)/share/applications

uninstall:
	rm -f $(PREFIX)/bin/$(BIN) $(PREFIX)/share/applications/majestic-media-player.desktop \
	      $(PREFIX)/share/icons/hicolor/scalable/apps/majestic-media-player.svg
	-update-desktop-database $(PREFIX)/share/applications
