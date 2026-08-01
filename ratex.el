;;; ratex.el --- Inline LaTeX previews via RaTeX -*- lexical-binding: t; -*-

;; Author: ratex.el contributors
;; Version: 0.1.7
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tex, math, tools

;;; Commentary:

;; Minimal async inline math preview minor mode backed by RaTeX.

;;; Code:
(require 'subr-x)
(require 'ratex-render)

;;;###autoload
(define-minor-mode ratex-mode
  "Minor mode for inline math previews powered by RaTeX."
  :lighter " RaTeX"
  (if ratex-mode
      (progn
        (ratex-reset-buffer-state)
        (add-hook 'post-command-hook #'ratex-handle-post-command nil t)
        (ratex-initialize-previews))
    (remove-hook 'post-command-hook #'ratex-handle-post-command t)
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

(add-hook 'hack-local-variables-hook #'ratex--apply-org-keyword)

(provide 'ratex)

;;; ratex.el ends here
