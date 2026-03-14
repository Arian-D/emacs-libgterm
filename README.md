# emacs-libgterm

Terminal emulator for Emacs built on [libghostty-vt](https://github.com/ghostty-org/ghostty), the terminal emulation library from the [Ghostty](https://ghostty.org/) terminal emulator.

This project follows the same architecture as [emacs-libvterm](https://github.com/akermu/emacs-libvterm) but uses Ghostty's terminal engine, which offers:

- SIMD-optimized VT escape sequence parsing
- Better Unicode and grapheme cluster support
- Text reflow on resize
- Kitty graphics protocol support
- Active development and maintenance

> **Status:** Early prototype. Terminal works with ANSI colors, full key handling, scrollback, cursor sync, and drag-and-drop. Some character width mismatches with Powerline/NerdFont glyphs remain.

## Requirements

- **Emacs 25.1+** compiled with `--with-modules` (dynamic module support)
- **Zig 0.15.2+** (install via `asdf install zig 0.15.2` or [ziglang.org](https://ziglang.org/download/))
- **Git** (to clone the Ghostty source)

## Installation

### use-package (recommended)

```elisp
(use-package gterm
  :load-path "/path/to/emacs-libgterm"
  :init
  ;; Auto-compile without prompting (optional)
  (setq gterm-always-compile-module t))
```

On first load, gterm will detect the missing module and compile it automatically (or prompt you). You need to have the Ghostty source vendored first (see Setup below).

### Manual

```elisp
(add-to-list 'load-path "/path/to/emacs-libgterm")
(require 'gterm)
```

Then `M-x gterm` to open a terminal.

## Setup

### 1. Clone this repository

```bash
git clone https://github.com/rwc9u/emacs-libgterm.git
cd emacs-libgterm
```

### 2. Clone Ghostty as a vendor dependency

```bash
git clone --depth 1 https://github.com/ghostty-org/ghostty.git vendor/ghostty
```

### 3. Patch Ghostty's build.zig (macOS without full Xcode only)

Ghostty's `build.zig` eagerly initializes XCFramework builds, which requires full Xcode. If you only have CommandLineTools, apply this patch to guard those behind the `emit-xcframework` flag.

In `vendor/ghostty/build.zig`:

- Wrap `GhosttyLib.initShared/initStatic` (lines ~95-102) in `if (config.app_runtime == .none and !config.target.result.os.tag.isDarwin())`
- Wrap the first `GhosttyXCFramework.init` block (lines ~150-180) in `if (config.emit_xcframework)`
- Wrap the second `GhosttyXCFramework.init` in the `run:` block (line ~212) by adding `and config.emit_xcframework` to the existing Darwin check

If you have full Xcode installed (`xcode-select -p` shows `/Applications/Xcode.app/...`), no patch is needed.

### 4. Build (or let Emacs do it)

```bash
zig build
```

Or just load gterm in Emacs — it will offer to compile automatically if the module is missing.

### 5. Run tests

```bash
zig build test
```

## Usage

| Key | Action |
|-----|--------|
| `M-x gterm` | Open a new terminal |
| Arrow keys | Navigate / command history |
| `C-y` / `Cmd-V` | Paste from kill ring |
| `C-c C-k` | Enter copy mode (select text, `y` to copy, `q` to exit) |
| `Shift-PageUp/Down` | Scroll through history |
| `C-c C-v` | Snap back to live terminal |
| `C-c C-c` | Send Ctrl-C to shell |
| `C-c C-d` | Send Ctrl-D (EOF) to shell |
| `C-c C-z` | Send Ctrl-Z (suspend) to shell |
| Drag file from Finder | Send file path to terminal |

## Build Options

```bash
# Specify custom Emacs include path (for emacs-module.h)
zig build -Demacs-include=/path/to/emacs/include

# Build with optimizations
zig build -Doptimize=ReleaseFast
```

## Architecture

```
┌──────────────┐     ┌───────────────────┐     ┌─────────────┐
│   gterm.el   │────▶│  gterm-module.so  │────▶│ ghostty-vt  │
│  (Elisp)     │     │  (Zig → C ABI)    │     │ (Zig lib)   │
│              │     │                   │     │             │
│ • PTY mgmt  │     │ • Terminal create │     │ • VT parse  │
│ • Keybinds  │     │ • Feed bytes     │     │ • Screen    │
│ • Display   │     │ • Styled render  │     │ • Cursor    │
│ • Copy/Paste│     │ • Cursor track   │     │ • Scrollback│
│ • Scrollback│     │ • Mode query     │     │ • Reflow    │
└──────────────┘     └───────────────────┘     └─────────────┘
```

## Customization

```elisp
;; Change shell (default: /bin/zsh)
(setq gterm-shell "/bin/bash")

;; Change TERM variable (default: xterm-256color)
(setq gterm-term-environment-variable "xterm-256color")

;; Auto-compile without prompting
(setq gterm-always-compile-module t)
```

## Known Issues

- **Character width mismatches** — some Unicode characters (Powerline glyphs, NerdFont icons) may render at different widths in Emacs vs the terminal, causing minor alignment issues with fancy prompts
- **No mouse support** — programs like htop that use mouse events are not yet supported
- **Full screen re-render** — each refresh redraws the entire screen; incremental dirty-row rendering is planned

## License

GPL-3.0 (required for Emacs dynamic modules)
