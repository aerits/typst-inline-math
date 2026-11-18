;;; typst-inline-math.el --- IPC SVG previews for Typst -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)

(defgroup typst-inline-math nil "Typst SVG previews." :group 'typst)
(defcustom typst-inline-math-daemon-command
  (list (expand-file-name "typst-renderd/target/release/typst-renderd"
                          (file-name-directory (or load-file-name buffer-file-name))))
  "Command used to start typst-renderd." :type '(repeat string) :group 'typst-inline-math)
(defcustom typst-inline-math-font-size 1.0
  "Multiplier applied to the Emacs face size when rendering math."
  :type 'number :group 'typst-inline-math)
(defcustom typst-inline-math-scale 1.0 "Emacs SVG scale." :type 'number :group 'typst-inline-math)

(defvar typst-inline-math--process nil)
(defvar typst-inline-math--partial "")
(defvar typst-inline-math--id 0)
(defvar typst-inline-math--requests (make-hash-table :test #'eql))
(defvar-local typst-inline-math--timer nil)
(defvar-local typst-inline-math--active nil)
(defvar typst-inline-math--font-hook-installed nil)

(defun typst-inline-math--foreground ()
  (let ((rgb (color-values (face-attribute 'default :foreground nil t))))
    (if rgb (apply #'format "#%02x%02x%02x" (mapcar (lambda (x) (/ x 256)) rgb)) "#000000")))
(defun typst-inline-math--font-size (position)
  "Return the buffer's effective default font size as a Typst point size."
  ;; POSITION is retained so callers can later provide face-specific sizing.
  ;; `face-at-point' may return a composite face spec in Doom, which is not a
  ;; valid argument to `face-attribute' and caused type errors here.
  (ignore position)
  (let* ((height (face-attribute 'default :height nil t))
         ;; Face heights are tenths of a point.  Fall back to 12pt if a frame
         ;; has not resolved the default face yet.
         (height (if (and (numberp height) (> height 10)) height 120))
         (scale (if (numberp typst-inline-math-font-size)
                    typst-inline-math-font-size
                  1.0))
         ;; text-scale-mode remaps `default' without changing its face
         ;; attribute, so account for its buffer-local scale explicitly.
         (text-scale (if (bound-and-true-p text-scale-mode)
                         (expt text-scale-mode-step text-scale-mode-amount)
                       1.0)))
    (format "%.3fpt" (* scale text-scale (/ height 10.0)))))
(defun typst-inline-math--escaped-p (p)
  (let ((n 0) (p (1- p))) (while (and (>= p (point-min)) (eq (char-after p) ?\\)) (setq n (1+ n) p (1- p))) (= 1 (% n 2))))
(defun typst-inline-math--expressions ()
  (save-excursion
    (goto-char (point-min))
    (let (out open)
      (while (search-forward "$" nil t)
        (let ((p (1- (point))))
          (unless (typst-inline-math--escaped-p p)
            (if open
                (progn
                  (push (list open (1+ p) (buffer-substring-no-properties (1+ open) p)) out)
                  (setq open nil))
              (setq open p)))))
      (nreverse out))))
(defun typst-inline-math--lines (beg end)
  (save-excursion
    (goto-char (1+ beg))
    (let ((limit (1- end)) out)
      (while (< (point) limit)
        (let* ((a (point)) (b (min limit (line-end-position)))
               (s (buffer-substring-no-properties a b)))
          (when (string-match "[^ \t]" s)
            (let ((x (+ a (match-beginning 0))))
              (string-match "[^ \t][ \t]*\\'" s)
              (push (list x (+ a (match-end 0))
                          (buffer-substring-no-properties x (+ a (match-end 0)))
                          a b) out)))
          (goto-char b)
          (when (< (point) limit) (forward-char 1))))
      (nreverse out))))
(defun typst-inline-math--remove () (remove-overlays (point-min) (point-max) 'typst-inline-math t))
(defun typst-inline-math--image (file) (list 'image :type 'svg :file file :ascent 'center :scale typst-inline-math-scale))
(defun typst-inline-math--active ()
  (let* ((position (point))
         (overlays (cl-remove-if-not (lambda (o) (overlay-get o 'typst-inline-math-svg))
                                     (overlays-in (point-min) (point-max))))
         ;; Multiline previews cover only the trimmed math text.  Their source
         ;; line range also includes indentation and a trailing continuation
         ;; marker, so the current line is editable from end to end.
         (next (or (cl-find-if (lambda (o) (memq o (overlays-at position))) overlays)
                   (cl-find-if (lambda (o)
                                 (let ((beg (overlay-get o 'typst-inline-math-line-beg))
                                       (end (overlay-get o 'typst-inline-math-line-end)))
                                   (and beg end (<= beg position end))))
                               overlays))))
    (when (and next (eq next typst-inline-math--active))
      (let ((anchor (overlay-get next 'typst-inline-math-preview-anchor))
            (line-end (overlay-get next 'typst-inline-math-line-end)))
        (when (and (overlayp anchor) line-end)
          (move-overlay anchor line-end line-end))))
    (unless (eq next typst-inline-math--active)
      (when (overlayp typst-inline-math--active)
        (let ((anchor (overlay-get typst-inline-math--active 'typst-inline-math-preview-anchor)))
          (when (overlayp anchor) (delete-overlay anchor))
          (overlay-put typst-inline-math--active 'typst-inline-math-preview-anchor nil))
        (overlay-put typst-inline-math--active 'display
                     (typst-inline-math--image (overlay-get typst-inline-math--active 'typst-inline-math-svg))))
      (setq typst-inline-math--active next)
      (when next
        (let* ((position (or (overlay-get next 'typst-inline-math-line-end)
                             (overlay-end next)))
               (anchor (make-overlay position position nil nil t)))
          (overlay-put next 'display nil)
          (overlay-put anchor 'typst-inline-math t)
          ;; At the exact line end, Emacs would otherwise put point after an
          ;; ordinary overlay `after-string'.  This cursor-marked spacer makes
          ;; point display before the preview image instead.
          (overlay-put anchor 'after-string
                       (concat (propertize " " 'cursor t)
                               (propertize " " 'display
                                           (typst-inline-math--image (overlay-get next 'typst-inline-math-svg)))))
          (overlay-put next 'typst-inline-math-preview-anchor anchor))))))
(defun typst-inline-math--filter (_ text)
  (let* ((all (concat typst-inline-math--partial text))
         (lines (split-string all "\n")))
    (setq typst-inline-math--partial (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (let* ((r (json-parse-string line :object-type 'hash-table))
               (id (gethash "id" r))
               (q (gethash id typst-inline-math--requests)))
          (remhash id typst-inline-math--requests)
          (when (and q (stringp (gethash "svg" r)))
            (typst-inline-math--install q (gethash "svg" r))))))))
(defun typst-inline-math--ensure ()
  (unless (and (processp typst-inline-math--process) (process-live-p typst-inline-math--process))
    (setq typst-inline-math--process (make-process :name "typst-renderd" :buffer "*typst-renderd*" :command typst-inline-math-daemon-command :connection-type 'pipe :coding 'utf-8-unix :noquery t :filter #'typst-inline-math--filter))))
(defun typst-inline-math--request (beg end math &optional line-beg line-end)
  (typst-inline-math--ensure) (let* ((id (cl-incf typst-inline-math--id)) (a (copy-marker beg)) (b (copy-marker end t))
                                     ;; Keep source-line bounds live while a
                                     ;; replacement SVG is in flight.  In
                                     ;; particular, an end marker advances
                                     ;; when text is inserted at line end.
                                     (line-a (and line-beg (copy-marker line-beg)))
                                     (line-b (and line-end (copy-marker line-end t))))
    ;; Keep the exact source range, including delimiters, so a response is
    ;; discarded only when that expression was genuinely edited in transit.
                               (puthash id (list (current-buffer) a b (buffer-substring-no-properties beg end) line-a line-b) typst-inline-math--requests)
                               (process-send-string typst-inline-math--process (concat (json-encode `((id . ,id) (math . ,math) (size . ,(typst-inline-math--font-size beg)) (foreground . ,(typst-inline-math--foreground)))) "\n"))))
(defun typst-inline-math--install (q svg)
  (pcase-let ((`(,buf ,a ,b ,source ,line-beg ,line-end) q))
    (when (buffer-live-p buf) (with-current-buffer buf
                               (when (and typst-inline-math-mode (equal source (buffer-substring-no-properties a b)))
                                 (let ((file (make-temp-file "typst-math-" nil ".svg"))) (with-temp-file file (insert svg))
                                   ;; Keep the old preview visible until this replacement is ready.
                                   (remove-overlays a b 'typst-inline-math t)
                                   (let ((o (make-overlay a b))) (overlay-put o 'typst-inline-math t) (overlay-put o 'evaporate t) (overlay-put o 'typst-inline-math-svg file) (when line-beg (overlay-put o 'typst-inline-math-line-beg line-beg) (overlay-put o 'typst-inline-math-line-end line-end)) (overlay-put o 'display (typst-inline-math--image file)) (typst-inline-math--active))))))))
(defun typst-inline-math--refresh (&optional changed-beg changed-end)
  (when typst-inline-math-mode
    (dolist (e (typst-inline-math--expressions))
      (let ((beg (nth 0 e))
            (end (nth 1 e))
            (math (nth 2 e)))
        ;; A multiline expression is a display-sized block in practice.  Give
        ;; each nonblank source line its own overlay so its preview keeps the
        ;; block's line structure instead of becoming one tall SVG.
        (if (string-match-p "\n" math)
            (dolist (line (typst-inline-math--lines beg end))
              (when (or (not changed-beg)
                        (and (<= (nth 3 line) changed-end)
                             (<= changed-beg (nth 4 line))))
                (let ((line-math (nth 2 line)))
                  ;; A trailing backslash joins lines in a single Typst math
                  ;; block, but is invalid once that line is rendered alone.
                  (when (eq (aref line-math (1- (length line-math))) ?\\)
                    (setq line-math (substring line-math 0 -1)))
                  (typst-inline-math--request
                   (nth 0 line) (nth 1 line) line-math
                   (nth 3 line) (nth 4 line)))))
          (when (or (not changed-beg) (and (<= beg changed-end) (<= changed-beg end)))
            (typst-inline-math--request beg end math)))))))
(defun typst-inline-math--changed (beg end &rest _)
  ;; Render only the edited line immediately.  A whole-block pass still runs
  ;; after the edit burst, but it must not delay the live preview.
  (typst-inline-math--refresh beg end) (when (timerp typst-inline-math--timer) (cancel-timer typst-inline-math--timer))
  (setq typst-inline-math--timer (run-with-idle-timer .25 nil (lambda (b) (when (buffer-live-p b) (with-current-buffer b (typst-inline-math--refresh)))) (current-buffer))))
(defun typst-inline-math--font-changed (&rest _)
  "Re-render active previews after a global font change."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when typst-inline-math-mode
        (typst-inline-math--refresh)))))
(defun typst-inline-math--text-scale-changed (&rest _)
  "Re-render this buffer after `text-scale-mode' changes its remapping."
  (when typst-inline-math-mode
    (typst-inline-math--refresh)))
(unless typst-inline-math--font-hook-installed
  (add-hook 'after-setting-font-hook #'typst-inline-math--font-changed)
  (with-eval-after-load 'face-remap
    (advice-add 'text-scale-mode :after #'typst-inline-math--text-scale-changed))
  (setq typst-inline-math--font-hook-installed t))
(define-minor-mode typst-inline-math-mode "Render Typst math via typst-renderd IPC." :lighter " TMath"
  (if typst-inline-math-mode (progn (add-hook 'after-change-functions #'typst-inline-math--changed nil t) (add-hook 'post-command-hook #'typst-inline-math--active nil t) (typst-inline-math--refresh))
    (remove-hook 'after-change-functions #'typst-inline-math--changed t) (remove-hook 'post-command-hook #'typst-inline-math--active t) (typst-inline-math--remove)))
(provide 'typst-inline-math)
