# Changelog

All notable changes to emacs-libgterm are documented in this file.

## [0.1.0] - 2026-03-15

First public release. Built from scratch in a single vibe-coding session with Claude Code.

### Terminal Emulation
- Cell-by-cell rendering using ghostty-vt's page grid
- ANSI color and style rendering (foreground, background, bold, italic, underline, strikethrough, inverse)
- Linefeed mode (ANSI mode 20) enabled by default — Emacs strips `\r` from PTY output
- Persistent VT stream across feed calls — handles escape sequences split across PTY chunks
- Cursor visibility and style sync (block, bar, underline, hollow) from terminal state
- OSC 8 hyperlink support — clickable links with tooltip, hover highlight, and browser open

### Key Handling
- Full printable character input (ASCII 32-126)
- Arrow keys with DECCKM application cursor mode detection
- Home, End, Delete, Insert, Page Up/Down
- F1-F12 function keys
- Ctrl+A through Ctrl+Z (excluding Emacs prefix keys)
- Modified arrows: Shift, Ctrl, Alt combinations
- Escape key support

### Features
- Scrollback with Shift+PageUp/Down and snap-to-bottom on input
- Copy mode (C-c C-k) — Emacs movement keys, select with C-SPC, copy with y
- Paste from kill ring (C-y / Cmd-V) with bracketed paste mode support
- Drag-and-drop file support — drops file paths with backslash-escaped spaces
- Terminal mode query (`gterm-mode-enabled`) for arbitrary DEC/ANSI modes
- Incremental dirty-row rendering (renders only changed rows after first full render)

### Performance
- Idle-timer based refresh — drains all PTY output before rendering to prevent backpressure
- Batched refresh coalesces rapid output into single renders
- Pre-interned global Emacs symbol references for styling performance
- Style run accumulation — flushes identically-styled character runs in batches

### Build System
- Auto-compilation on first load — detects missing module and compiles via `zig build`
- Auto-clones Ghostty source if `vendor/ghostty` is missing
- Auto-applies macOS build patch (guards XCFramework init for CommandLineTools-only systems)
- Configurable Emacs include path (`-Demacs-include=`)
- Makefile with build, test, clean, and distclean targets

### Integration
- claude-code-ide backend support (separate fork with PR upstream)
- use-package compatible with straight.el, quelpa, or local clone
- Double-free guard in GC finalizer for safe cleanup

### Known Issues
- Character width mismatches with Powerline/NerdFont glyphs in fancy prompts
- No mouse support for programs like htop
- macOS only (Apple Silicon tested)
