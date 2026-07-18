;;; ratex.el --- Inline LaTeX previews via RaTeX -*- lexical-binding: t; -*-

;; Author: ratex.el contributors
;; Version: 0.1.4
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, math, tools

;;; Commentary:

;; Minimal async inline math preview minor mode backed by RaTeX.

;;; Code:
(require 'subr-x)
(require 'ratex-overlays)
(require 'ratex-render)

;;;###autoload
(define-minor-mode ratex-mode
  "Minor mode for inline math previews powered by RaTeX."
  :lighter " RaTeX"
  (if ratex-mode
      (progn
        (ratex-reset-buffer-state)
        (add-hook 'post-command-hook #'ratex-handle-post-command nil t)
        (add-hook 'buffer-list-update-hook #'ratex-handle-buffer-switch)
        (ratex-initialize-previews))
    (remove-hook 'post-command-hook #'ratex-handle-post-command t)
    (remove-hook 'buffer-list-update-hook #'ratex-handle-buffer-switch)
    (ratex-handle-buffer-switch)
    (ratex-clear-overlays)
    (ratex-reset-buffer-state)))

(defun ratex--org-keyword-state ()
  "Return the requested RaTeX state from an Org `#+ratex:' keyword.

Return `enable' for values such as an empty string, `t', or `on';
return `disable' for values such as `nil' or `off'; otherwise return nil."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char (point-min))
      (let ((case-fold-search t)
            (state nil))
        (while (and (not state)
                    (re-search-forward "^[ \t]*#\\+ratex:[ \t]*\\(.*\\)$" nil t))
          (let ((value (downcase (string-trim (match-string-no-properties 1)))))
            (setq state
                  (cond
                   ((member value '("" "t" "true" "yes" "on" "enable" "enabled"))
                    'enable)
                   ((member value '("nil" "false" "no" "off" "disable" "disabled"))
                    'disable)))))
        state))))

(defun ratex--auto-enable-p ()
  "Return non-nil when `ratex-mode' should auto-enable in this buffer."
  (cond
   ((derived-mode-p 'org-mode)
    (not (eq (ratex--org-keyword-state) 'disable)))
   (t
    (derived-mode-p 'latex-mode 'LaTeX-mode 'markdown-mode))))

(defun ratex--maybe-enable ()
  "Enable `ratex-mode' when the current buffer supports RaTeX previews."
  (when (ratex--auto-enable-p)
    (ratex-mode 1)))

(defun ratex--apply-org-keyword ()
  "Apply the current Org buffer's `#+ratex:' preference."
  (pcase (ratex--org-keyword-state)
    ('enable
     (unless ratex-mode
       (ratex-mode 1)))
    ('disable
     (when ratex-mode
       (ratex-mode -1)))))

(define-globalized-minor-mode global-ratex-mode
  ratex-mode
  ratex--maybe-enable
  :group 'ratex)

;;;###autoload
(defun ratex-toggle-preview-command ()
  "Toggle RaTeX preview at point."
  (interactive)
  (ratex-toggle-preview-at-point))

;;;###autoload
(defun ratex-convert-delimiters ()
  "Convert dollar math delimiters in the current buffer.
$$...$$ becomes \\[...\\] and $...$ becomes \\(...\\).
Escaped delimiters (\\$) are left unchanged."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (let ((in-display-math nil)
          (in-inline-math nil))
      (while (re-search-forward "\\$\\$?" nil t)
        (let ((matched (match-string 0))
              (beg (match-beginning 0))
              (end (match-end 0))
              (syntax (syntax-ppss)))
          ;; Ensure we are not inside a comment or a verbatim block
          (unless (or (nth 4 syntax) (eq (nth 7 syntax) 2))
            (cond
             ;; Case 1: Double dollars $$
             ((string= matched "$$")
              (delete-region beg end)
              (if in-display-math
                  (insert "\\]")
                (insert "\\["))
              (setq in-display-math (not in-display-math)))
             
             ;; Case 2: Single dollar $ (only if not inside a $$ block)
             ((not in-display-math)
              (delete-region beg end)
              (if in-inline-math
                  (insert "\\)")
                (insert "\\("))
              (setq in-inline-math (not in-inline-math))))))))))

(add-hook 'hack-local-variables-hook #'ratex--apply-org-keyword)

(provide 'ratex)

;;; ratex.el ends here
