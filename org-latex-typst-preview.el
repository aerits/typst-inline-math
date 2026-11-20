;;; org-latex-typst-preview.el --- Org LaTeX previews through Typst -*- lexical-binding: t; -*-

;; This is intentionally separate from typst-inline-math.el: the latter accepts
;; Typst syntax, while Org buffers contain LaTeX syntax and therefore use the
;; latexToTypst | typst-renderd pipeline.

(require 'cl-lib)
(require 'json)
(require 'org-element)

(defconst org-latex-typst-preview--directory
  ;; `load-file-name' is non-nil only while this file is being loaded.  Save
  ;; the location now; resolving it later from an Org buffer is incorrect.
  (file-name-directory (or load-file-name buffer-file-name default-directory)))

(defgroup org-latex-typst-preview nil
  "Render Org LaTeX fragments with Typst."
  :group 'org)

(defcustom org-latex-typst-preview-renderd-command
  (list (expand-file-name "typst-renderd/target/release/typst-renderd"
                          org-latex-typst-preview--directory))
  "Command and arguments used to start typst-renderd.
The Org preview client appends --mitex-package to this command.
For Nix, use (\"nix\" \"run\" \"path:/absolute/path/to/typst-renderd\" \"--\")."
  :type '(repeat string)
  :group 'org-latex-typst-preview)

(defcustom org-latex-typst-preview-command nil
  "Command used for the MiTeX-backed `typst-renderd' preview pipeline.
When nil, append --mitex-package to
`org-latex-typst-preview-renderd-command'.
When non-nil, this overrides the complete command, including mode arguments."
  :type '(choice (const :tag "Renderer command with MiTeX" nil) (repeat string))
  :group 'org-latex-typst-preview)

(defcustom org-latex-typst-preview-scale 1.0
  "Scale applied to SVG previews."
  :type 'number
  :group 'org-latex-typst-preview)

(defcustom org-latex-typst-preview-hover-preview nil
  "Show the active preview enlarged below the cursor's line.

When non-nil, the LaTeX fragment at point retains its normal inline preview
and also appears enlarged on a fake physical line below the cursor."
  :type 'boolean
  :group 'org-latex-typst-preview)

(defcustom org-latex-typst-preview-hover-preview-scale 3.0
  "Scale applied to a floating active preview."
  :type 'number
  :group 'org-latex-typst-preview)

(defvar org-latex-typst-preview--process nil)
(defvar org-latex-typst-preview--partial "")
(defvar org-latex-typst-preview--next-id 0)
(defvar org-latex-typst-preview--requests (make-hash-table :test #'eql))
(defvar org-latex-typst-preview-mode nil)
(defvar-local org-latex-typst-preview--timer nil)
(defvar-local org-latex-typst-preview--active nil)
(defvar-local org-latex-typst-preview--hover-overlay nil)
(defvar-local org-latex-typst-preview--hover-svg nil)
(defvar-local org-latex-typst-preview--hover-position nil)
(defvar-local org-latex-typst-preview--hover-scale nil)
(defvar-local org-latex-typst-preview--hover-width nil)
(defvar org-latex-typst-preview--font-hook-installed nil)

(defun org-latex-typst-preview--command ()
  (or org-latex-typst-preview-command
      (append org-latex-typst-preview-renderd-command '("--mitex-package"))))

(defun org-latex-typst-preview--foreground ()
  (let ((rgb (color-values (face-attribute 'default :foreground nil t))))
    (if rgb
        (apply #'format "#%02x%02x%02x" (mapcar (lambda (x) (/ x 256)) rgb))
      "#000000")))

(defun org-latex-typst-preview--font-size ()
  (let* ((height (face-attribute 'default :height nil t))
         (height (if (and (numberp height) (> height 10)) height 120))
         ;; `text-scale-mode' remaps the face without changing its `:height'.
         (text-scale (if (bound-and-true-p text-scale-mode)
                         (expt text-scale-mode-step text-scale-mode-amount)
                       1.0)))
    (format "%.3fpt" (* text-scale (/ height 10.0)))))

(defun org-latex-typst-preview--image (svg &optional scale)
  (list 'image :type 'svg :data svg :ascent 'center
        :scale (or scale org-latex-typst-preview-scale)))

(defun org-latex-typst-preview--math-body (value)
  "Remove Org's LaTeX delimiters from VALUE, retaining only math syntax."
  (cond
   ((and (string-prefix-p "\\(" value) (string-suffix-p "\\)" value))
    (substring value 2 -2))
   ((and (string-prefix-p "\\[" value) (string-suffix-p "\\]" value))
    (substring value 2 -2))
   ((and (string-prefix-p "$$" value) (string-suffix-p "$$" value))
    (substring value 2 -2))
   ((and (string-prefix-p "$" value) (string-suffix-p "$" value))
    (substring value 1 -1))
   ((string-match "\\\\begin{[^}]+}\\\\(.*\\\\)\\\\end{[^}]+}\\'" value)
    (match-string 1 value))
   (t value)))

(defun org-latex-typst-preview--escaped-p (position)
  "Return non-nil when the backslash at POSITION is itself escaped."
  (let ((slashes 0) (position (1- position)))
    (while (and (>= position (point-min)) (eq (char-after position) ?\\))
      (setq slashes (1+ slashes)
            position (1- position)))
    (= 1 (% slashes 2))))

(defun org-latex-typst-preview--parentheses-balanced-p ()
  "Return non-nil only when every unescaped `\\(' has a matching `\\)'."
  (save-excursion
    (goto-char (point-min))
    (let ((depth 0) valid)
      (setq valid t)
      (while (and valid (re-search-forward "\\\\[()]" nil t))
        (unless (org-latex-typst-preview--escaped-p (- (point) 2))
          (if (eq (char-before (point)) ?\()
              (setq depth (1+ depth))
            (if (= depth 0)
                (setq valid nil)
              (setq depth (1- depth))))))
      (and valid (= depth 0)))))

(defun org-latex-typst-preview--clear ()
  "Remove every preview, including the active source-editing anchor."
  (remove-overlays (point-min) (point-max) 'org-latex-typst-preview t)
  (setq org-latex-typst-preview--active nil)
  (org-latex-typst-preview--hide-hover-preview))

(defun org-latex-typst-preview--hide-hover-preview ()
  "Remove the fake preview line for the current buffer."
  (when (overlayp org-latex-typst-preview--hover-overlay)
    (delete-overlay org-latex-typst-preview--hover-overlay))
  (setq org-latex-typst-preview--hover-overlay nil
        org-latex-typst-preview--hover-position nil))

(defun org-latex-typst-preview--destroy-hover-preview ()
  "Remove the fake preview line and discard its cached image."
  (org-latex-typst-preview--hide-hover-preview)
  (setq org-latex-typst-preview--hover-svg nil
        org-latex-typst-preview--hover-scale nil
        org-latex-typst-preview--hover-width nil))

(defun org-latex-typst-preview--next-visual-line-position ()
  "Return the buffer position at the start of the next visual line."
  (save-excursion
    (vertical-motion 1 (selected-window))
    (point)))

(defun org-latex-typst-preview--hover-image (svg)
  "Return an image for SVG that fits within the selected window's width."
  (let* ((scale org-latex-typst-preview-hover-preview-scale)
         (image (org-latex-typst-preview--image svg scale))
         (size (image-size image t))
         (image-width (and (consp size) (car size)))
         (window-width (max 1 (- (window-body-width (selected-window) t) 16)))
         (effective-scale
          (if (and (numberp image-width) (> image-width window-width))
              (* scale (/ (float window-width) image-width))
            scale)))
    (list (if (= effective-scale scale)
              image
            (org-latex-typst-preview--image svg effective-scale))
          effective-scale window-width)))

(defun org-latex-typst-preview--show-hover-preview (svg)
  "Show SVG on a fake physical line below the current visual line."
  (if (not org-latex-typst-preview-hover-preview)
      (org-latex-typst-preview--hide-hover-preview)
    (let* ((image-info (org-latex-typst-preview--hover-image svg))
           (image (nth 0 image-info))
           (scale (nth 1 image-info))
           (window-width (nth 2 image-info))
           (position (org-latex-typst-preview--next-visual-line-position))
           ;; A real newline already follows a completed logical line.  At a
           ;; wrapped line boundary, add one so the image gets its own row.
           (prefix (if (eq (char-before position) ?\n) "" "\n"))
           (line (concat prefix (propertize " " 'display image) "\n")))
      (unless (and (org-latex-typst-preview--live-overlay-p
                    org-latex-typst-preview--hover-overlay)
                   (equal svg org-latex-typst-preview--hover-svg)
                   (= position org-latex-typst-preview--hover-position)
                   (equal scale org-latex-typst-preview--hover-scale)
                   (equal window-width org-latex-typst-preview--hover-width))
        (org-latex-typst-preview--hide-hover-preview)
        (let ((overlay (make-overlay position position nil nil t)))
          (overlay-put overlay 'after-string line)
          (setq org-latex-typst-preview--hover-overlay overlay
                org-latex-typst-preview--hover-svg svg
                org-latex-typst-preview--hover-position position
                org-latex-typst-preview--hover-scale scale
                org-latex-typst-preview--hover-width window-width))))))

(defun org-latex-typst-preview--update-hover-preview ()
  "Show the active preview below point, or hide an existing one."
  (if (and (org-latex-typst-preview--live-overlay-p
            org-latex-typst-preview--active)
           (overlay-get org-latex-typst-preview--active
                        'org-latex-typst-preview-svg))
      (org-latex-typst-preview--show-hover-preview
       (overlay-get org-latex-typst-preview--active
                    'org-latex-typst-preview-svg))
    (org-latex-typst-preview--hide-hover-preview))
  (when (org-latex-typst-preview--live-overlay-p
         org-latex-typst-preview--active)
    (let ((anchor (overlay-get org-latex-typst-preview--active
                               'org-latex-typst-preview-anchor)))
      (when (overlayp anchor)
        (overlay-put anchor 'after-string
                     (org-latex-typst-preview--active-after-string
                      (overlay-get org-latex-typst-preview--active
                                   'org-latex-typst-preview-svg)))))))

(defun org-latex-typst-preview--reload ()
  "Clear and re-render every preview in the current buffer."
  (org-latex-typst-preview--clear)
  (org-latex-typst-preview--refresh))

(defun org-latex-typst-preview--fragments ()
  "Return (BEGIN END LATEX) records for Org LaTeX fragments."
  (org-element-map (org-element-parse-buffer) 'latex-fragment
    (lambda (fragment)
      (let ((begin (org-element-property :begin fragment))
            (value (org-element-property :value fragment)))
        ;; Org's :end includes the whitespace separator after a fragment.
        ;; Do not put that separator under the image overlay: it is needed to
        ;; space inline math from following prose, and otherwise makes point
        ;; after `\\)' hide the preview as though it were inside the fragment.
        (list begin (+ begin (length value))
              (org-latex-typst-preview--math-body value))))))

(defun org-latex-typst-preview--filter (_process text)
  (let* ((all (concat org-latex-typst-preview--partial text))
         ;; Keep the empty field after a newline.  Without it, a complete
         ;; JSONL response becomes the next partial response, corrupting the
         ;; following response when process filters are called again.
         (lines (split-string all "\n" nil)))
    (setq org-latex-typst-preview--partial (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (condition-case error
            (let* ((response (json-parse-string line :object-type 'hash-table))
                   (id (gethash "id" response))
                   (request (gethash id org-latex-typst-preview--requests)))
              (remhash id org-latex-typst-preview--requests)
              (when (and request (stringp (gethash "svg" response)))
                (org-latex-typst-preview--install request (gethash "svg" response))))
          (error
           (message "org-latex-typst-preview: ignoring malformed daemon response: %s"
                    (error-message-string error))))))))

(defun org-latex-typst-preview--ensure-process ()
  (unless (and (processp org-latex-typst-preview--process)
               (process-live-p org-latex-typst-preview--process))
    (setq org-latex-typst-preview--process
          (make-process :name "org-latex-typst-preview"
                        :buffer "*org-latex-typst-preview*"
                        :command (org-latex-typst-preview--command)
                        :connection-type 'pipe :coding 'utf-8-unix :noquery t
                        :filter #'org-latex-typst-preview--filter))))

(defun org-latex-typst-preview-restart-daemon ()
  "Restart the preview pipeline and discard incomplete IPC responses.
Run this after reloading the package if a previous daemon response was
interrupted or came from an older version of the pipeline."
  (interactive)
  (when (process-live-p org-latex-typst-preview--process)
    (delete-process org-latex-typst-preview--process))
  (setq org-latex-typst-preview--process nil
        org-latex-typst-preview--partial ""
        org-latex-typst-preview--requests (make-hash-table :test #'eql))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when org-latex-typst-preview-mode
        (org-latex-typst-preview--refresh))))
  (message "org-latex-typst-preview: daemon restarted"))

(defun org-latex-typst-preview--request (begin end latex)
  (org-latex-typst-preview--ensure-process)
  (let* ((id (cl-incf org-latex-typst-preview--next-id))
         (a (copy-marker begin)) (b (copy-marker end t))
         (source (buffer-substring-no-properties begin end)))
    (puthash id (list (current-buffer) a b source)
             org-latex-typst-preview--requests)
    (process-send-string
     org-latex-typst-preview--process
     (concat (json-encode `((id . ,id) (latex . ,latex)
                            (size . ,(org-latex-typst-preview--font-size))
                            (foreground . ,(org-latex-typst-preview--foreground)))) "\n"))))

(defun org-latex-typst-preview--show (overlay)
  "Display OVERLAY without hiding Org's separator after the fragment."
  (overlay-put overlay 'display
               (org-latex-typst-preview--image
                (overlay-get overlay 'org-latex-typst-preview-svg)))
  (overlay-put overlay 'after-string nil))

(defun org-latex-typst-preview--active-after-string (svg)
  "Return the source-editing anchor that displays SVG after point."
  (concat (propertize " " 'cursor t)
          (unless (and org-latex-typst-preview-hover-preview
                       (overlayp org-latex-typst-preview--hover-overlay)
                       (overlay-buffer org-latex-typst-preview--hover-overlay))
            (propertize " " 'display (org-latex-typst-preview--image svg)))))

(defun org-latex-typst-preview--live-overlay-p (overlay)
  "Return non-nil when OVERLAY has valid positions in a live buffer."
  (and (overlayp overlay)
       (overlay-buffer overlay)
       (integer-or-marker-p (overlay-start overlay))
       (integer-or-marker-p (overlay-end overlay))))

(defun org-latex-typst-preview--install (request svg)
  (pcase-let ((`(,buffer ,begin ,end ,source) request))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and org-latex-typst-preview-mode
                   (org-latex-typst-preview--parentheses-balanced-p)
                   (equal source (buffer-substring-no-properties begin end)))
          ;; Do not delete a ready image before its replacement is ready.
          ;; Besides avoiding a visible flash, this keeps the editing anchor
          ;; stable while the user is typing inside a fragment.
          (let ((overlay
                 (cl-find-if
                  (lambda (candidate)
                    (and (overlay-get candidate 'org-latex-typst-preview)
                         (= (overlay-start candidate) begin)
                         (= (overlay-end candidate) end)))
                  (overlays-in begin end))))
            (if overlay
                (progn
                  (overlay-put overlay 'org-latex-typst-preview-svg svg)
                  (if (eq overlay org-latex-typst-preview--active)
                      (let ((anchor (overlay-get overlay
                                                 'org-latex-typst-preview-anchor)))
                        (when (overlayp anchor)
                          (overlay-put anchor 'after-string
                                       (org-latex-typst-preview--active-after-string svg)))
                        (org-latex-typst-preview--update-hover-preview)
                        ;; An overlay installed while point is inside it has
                        ;; no anchor yet.
                        (unless (overlayp anchor)
                          (setq org-latex-typst-preview--active nil)
                          (org-latex-typst-preview--reveal-at-point)))
                    (org-latex-typst-preview--show overlay)))
              (setq overlay (make-overlay begin end))
              (overlay-put overlay 'org-latex-typst-preview t)
              (overlay-put overlay 'evaporate t)
              (overlay-put overlay 'org-latex-typst-preview-svg svg)
              (org-latex-typst-preview--show overlay)
              (org-latex-typst-preview--reveal-at-point))))))))

(defun org-latex-typst-preview--refresh (&optional begin end)
  (when org-latex-typst-preview-mode
    (if (not (org-latex-typst-preview--parentheses-balanced-p))
        ;; An incomplete delimiter changes the meaning of later fragments.
        ;; Keeping any old SVG visible is misleading, so blank them all.
        (org-latex-typst-preview--clear)
      (dolist (fragment (org-latex-typst-preview--fragments))
        (pcase-let ((`(,a ,b ,latex) fragment))
          (when (or (not begin) (and (<= a end) (<= begin b)))
            (org-latex-typst-preview--request a b latex)))))))

(defun org-latex-typst-preview--changed (begin end &rest _)
  ;; Match typst-inline-math-mode: make an immediate request for the edited
  ;; fragment, then run a complete pass after the edit burst.  The timer must
  ;; restore the originating buffer because timers otherwise run in whichever
  ;; buffer is current when Emacs goes idle.
  (org-latex-typst-preview--refresh begin end)
  (when (timerp org-latex-typst-preview--timer)
    (cancel-timer org-latex-typst-preview--timer))
  (setq org-latex-typst-preview--timer
        (run-with-idle-timer
         0.25 nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (org-latex-typst-preview--refresh))))
         (current-buffer))))

(defun org-latex-typst-preview--reveal-at-point ()
  "Reveal source under point while retaining its SVG preview beside it.

This mirrors `typst-inline-math-mode': the source overlay is hidden only
while editing, and a zero-width anchor at its end displays the preview after
the source.  Thus point remains in editable LaTeX without making the preview
disappear."
  (condition-case err
      (progn
        (unless (org-latex-typst-preview--live-overlay-p
                 org-latex-typst-preview--active)
          (setq org-latex-typst-preview--active nil))
        (let ((next (cl-find-if
                     (lambda (overlay)
                       (and (org-latex-typst-preview--live-overlay-p overlay)
                            (overlay-get overlay 'org-latex-typst-preview)))
                     (overlays-at (point)))))
          (unless (eq next org-latex-typst-preview--active)
            (when (org-latex-typst-preview--live-overlay-p
                   org-latex-typst-preview--active)
              (let ((anchor (overlay-get org-latex-typst-preview--active
                                         'org-latex-typst-preview-anchor)))
                (when (overlayp anchor) (delete-overlay anchor)))
              (overlay-put org-latex-typst-preview--active
                           'org-latex-typst-preview-anchor nil)
              (org-latex-typst-preview--show org-latex-typst-preview--active))
            (setq org-latex-typst-preview--active next)
            (when next
              (let ((anchor (make-overlay (overlay-end next) (overlay-end next)
                                          nil nil t)))
                (overlay-put next 'display nil)
                (overlay-put anchor 'org-latex-typst-preview t)
                ;; The cursor-marked space keeps point before the preview image.
                (overlay-put anchor 'after-string
                             (org-latex-typst-preview--active-after-string
                              (overlay-get next 'org-latex-typst-preview-svg)))
                (overlay-put next 'org-latex-typst-preview-anchor anchor)))))
        (org-latex-typst-preview--update-hover-preview))
    (error
     (org-latex-typst-preview--reload)
     (message "org-latex-typst-preview: reloaded after error: %s"
              (error-message-string err)))))

(defun org-latex-typst-preview--font-changed (&rest _)
  "Re-render every active Org preview after a frame font change."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when org-latex-typst-preview-mode
        (org-latex-typst-preview--refresh)))))

(defun org-latex-typst-preview--text-scale-changed (&rest _)
  "Re-render this buffer after `text-scale-mode' changes its face remap."
  (when org-latex-typst-preview-mode
    (org-latex-typst-preview--refresh)))

(unless org-latex-typst-preview--font-hook-installed
  (add-hook 'after-setting-font-hook #'org-latex-typst-preview--font-changed)
  (with-eval-after-load 'face-remap
    (advice-add 'text-scale-mode :after
                #'org-latex-typst-preview--text-scale-changed))
  (setq org-latex-typst-preview--font-hook-installed t))

(define-minor-mode org-latex-typst-preview-mode
  "Preview Org LaTeX fragments through MiTeX-enabled `typst-renderd'."
  :lighter " Typst-TeX"
  (if org-latex-typst-preview-mode
      (progn
        (add-hook 'after-change-functions #'org-latex-typst-preview--changed nil t)
        (add-hook 'post-command-hook #'org-latex-typst-preview--reveal-at-point nil t)
        (org-latex-typst-preview--refresh))
    (remove-hook 'after-change-functions #'org-latex-typst-preview--changed t)
    (remove-hook 'post-command-hook #'org-latex-typst-preview--reveal-at-point t)
    (org-latex-typst-preview--clear)
    (org-latex-typst-preview--destroy-hover-preview)))

(provide 'org-latex-typst-preview)
;;; org-latex-typst-preview.el ends here
