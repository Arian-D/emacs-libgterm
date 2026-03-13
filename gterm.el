;;; gterm.el --- Terminal emulator for Emacs using libghostty -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Rob Christie
;; Author: Rob Christie
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))
;; Keywords: terminals, processes
;; URL: https://github.com/rwc9u/emacs-libgterm

;;; Commentary:

;; gterm is a terminal emulator for Emacs built on libghostty-vt, the
;; terminal emulation library extracted from the Ghostty terminal emulator.
;;
;; This provides a similar experience to emacs-libvterm but uses Ghostty's
;; terminal engine which offers better Unicode support, SIMD-optimized
;; parsing, text reflow on resize, and Kitty graphics protocol support.
;;
;; Usage:
;;   M-x gterm

;;; Code:

(require 'cl-lib)

;; ── Module loading ──────────────────────────────────────────────────────

(defvar gterm-module-path
  (expand-file-name
   (concat "zig-out/lib/libgterm-module" module-file-suffix)
   (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the compiled gterm dynamic module.")

(unless (featurep 'gterm-module)
  (if (file-exists-p gterm-module-path)
      (module-load gterm-module-path)
    (error "gterm: module not found at %s. Run `zig build` first" gterm-module-path)))

;; ── Customization ───────────────────────────────────────────────────────

(defgroup gterm nil
  "Terminal emulator using libghostty."
  :group 'terminals)

(defcustom gterm-shell "/bin/zsh"
  "Shell program to run in gterm."
  :type 'string
  :group 'gterm)

(defcustom gterm-term-environment-variable "xterm-256color"
  "Value of TERM environment variable for the shell process."
  :type 'string
  :group 'gterm)

(defcustom gterm-max-scrollback 10000
  "Maximum number of scrollback lines."
  :type 'integer
  :group 'gterm)

;; ── Internal state ──────────────────────────────────────────────────────

(defvar-local gterm--term nil
  "The gterm terminal handle for this buffer.")

(defvar-local gterm--process nil
  "The shell process for this buffer.")

(defvar-local gterm--width 80
  "Current terminal width in columns.")

(defvar-local gterm--height 24
  "Current terminal height in rows.")

;; ── Buffer rendering ────────────────────────────────────────────────────

(defun gterm--refresh ()
  "Refresh the buffer with current terminal content."
  (when gterm--term
    (let* ((inhibit-read-only t)
           (pos (gterm-cursor-pos gterm--term))
           (cursor-row (car pos))
           (cursor-col (cdr pos)))
      (erase-buffer)
      (gterm-render gterm--term)
      ;; Position point at cursor location
      (goto-char (point-min))
      (forward-line cursor-row)
      (move-to-column cursor-col))))

;; ── Process filter ──────────────────────────────────────────────────────

(defun gterm--filter (process output)
  "Process filter: feed shell output into the terminal and refresh.
PROCESS is the shell process. OUTPUT is the raw string."
  (when-let* ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when gterm--term
          (gterm-feed gterm--term output)
          (gterm--refresh))))))

(defun gterm--sentinel (process _event)
  "Process sentinel: clean up when the shell exits.
PROCESS is the shell process."
  (when-let* ((buf (process-buffer process)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\n\n[Process terminated]\n"))))))

;; ── Input handling ──────────────────────────────────────────────────────

(defun gterm-send-string (string)
  "Send STRING to the terminal's shell process."
  (when (and gterm--process (process-live-p gterm--process))
    (process-send-string gterm--process string)))

(defun gterm-send-key ()
  "Send the last input key to the shell."
  (interactive)
  (let* ((key (this-command-keys-vector))
         (last-key (aref key (1- (length key))))
         (char (cond
                ((characterp last-key) (char-to-string last-key))
                ((eq last-key 'return) "\r")
                ((eq last-key 'backspace) "\177")
                ((eq last-key 'tab) "\t")
                ((eq last-key 'escape) "\e")
                (t nil))))
    (when char
      (gterm-send-string char))))

(defun gterm-send-return ()
  "Send return key to the shell."
  (interactive)
  (gterm-send-string "\r"))

(defun gterm-send-backspace ()
  "Send backspace to the shell."
  (interactive)
  (gterm-send-string "\177"))

(defun gterm-send-ctrl-c ()
  "Send Ctrl-C to the shell."
  (interactive)
  (gterm-send-string "\003"))

(defun gterm-send-ctrl-d ()
  "Send Ctrl-D to the shell."
  (interactive)
  (gterm-send-string "\004"))

(defun gterm-send-ctrl-z ()
  "Send Ctrl-Z to the shell."
  (interactive)
  (gterm-send-string "\032"))

;; ── Window size tracking ────────────────────────────────────────────────

(defun gterm--calculate-size ()
  "Calculate terminal size from the current window."
  (let ((width (window-body-width))
        (height (window-body-height)))
    (cons width height)))

(defun gterm--maybe-resize ()
  "Resize the terminal if the window size changed."
  (when gterm--term
    (let* ((size (gterm--calculate-size))
           (new-width (car size))
           (new-height (cdr size)))
      (when (or (/= new-width gterm--width)
                (/= new-height gterm--height))
        (setq gterm--width new-width
              gterm--height new-height)
        (gterm-resize gterm--term new-width new-height)
        (when (and gterm--process (process-live-p gterm--process))
          (set-process-window-size gterm--process new-height new-width))
        (gterm--refresh)))))

;; ── Mode definition ─────────────────────────────────────────────────────

(defvar gterm-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Most printable chars go directly to the shell
    (cl-loop for c from 32 to 126
             do (define-key map (char-to-string c) #'gterm-send-key))
    ;; Special keys
    (define-key map (kbd "RET") #'gterm-send-return)
    (define-key map (kbd "DEL") #'gterm-send-backspace)
    (define-key map (kbd "TAB") #'gterm-send-key)
    (define-key map (kbd "C-c C-c") #'gterm-send-ctrl-c)
    (define-key map (kbd "C-c C-d") #'gterm-send-ctrl-d)
    (define-key map (kbd "C-c C-z") #'gterm-send-ctrl-z)
    map)
  "Keymap for `gterm-mode'.")

(define-derived-mode gterm-mode fundamental-mode "GTerm"
  "Major mode for gterm terminal emulator."
  :group 'gterm
  (setq buffer-read-only t)
  (setq-local scroll-conservatively 101)
  (setq-local scroll-margin 0)
  (setq truncate-lines t)
  ;; Disable fringes to maximize terminal area
  (set-window-fringes nil 0 0)
  ;; Disable line numbers if enabled globally
  (when (bound-and-true-p display-line-numbers-mode)
    (display-line-numbers-mode -1))
  (add-hook 'window-size-change-functions
            (lambda (_frame)
              (when (derived-mode-p 'gterm-mode)
                (gterm--maybe-resize)))
            nil t)
  (add-hook 'kill-buffer-hook #'gterm--kill-buffer nil t))

(defun gterm--kill-buffer ()
  "Clean up when the gterm buffer is killed."
  (when (and gterm--process (process-live-p gterm--process))
    (delete-process gterm--process))
  (when gterm--term
    (gterm-free gterm--term)
    (setq gterm--term nil)))

;; ── Public interface ────────────────────────────────────────────────────

;;;###autoload
(defun gterm ()
  "Create a new gterm terminal buffer."
  (interactive)
  (let ((buf (generate-new-buffer "*gterm*")))
    (with-current-buffer buf (gterm-mode))
    ;; Display first so window dimensions are available
    (switch-to-buffer buf)
    (with-current-buffer buf
      (let* ((size (gterm--calculate-size))
             (cols (car size))
             (rows (cdr size)))
        ;; Create terminal instance
        (setq gterm--width cols
              gterm--height rows
              gterm--term (gterm-new cols rows))
        ;; Start shell process
        (let ((process-environment
               (append
                (list (format "TERM=%s" gterm-term-environment-variable)
                      (format "COLUMNS=%d" cols)
                      (format "LINES=%d" rows))
                process-environment)))
          (setq gterm--process
                (make-process
                 :name "gterm"
                 :buffer buf
                 :command (list gterm-shell "-l")
                 :coding 'no-conversion
                 :filter #'gterm--filter
                 :sentinel #'gterm--sentinel
                 :noquery t))
          (set-process-window-size gterm--process rows cols))))))

(provide 'gterm)

;;; gterm.el ends here
