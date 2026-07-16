;;; ratex-math-detect.el --- Math fragment detection -*- lexical-binding: t; -*-

(require 'tex-mode)

(defun ratex--make-fragment (beg)
  "Create a math fragment plist starting at BEG using tex-mode parsers."
  (save-excursion
    (goto-char beg)
    (when-let* ((open (cond ((looking-at "\\$\\$") "$$")
                            ((looking-at "\\$") "$")
                            ((looking-at "\\\\(") "\\(")
                            ((looking-at "\\\\\\[") "\\[")))
                (f-end (condition-case nil
                           (let ((latex-handle-escaped-parens t))
                             (with-syntax-table tex-mode-syntax-table
                               (latex-forward-sexp-1))
                             (point))
                         (error nil)))
                (is-paren (string-prefix-p "\\" open))
                (content-beg (+ beg (length open)))
                (content-end (if is-paren (- f-end 2) (- f-end (length open)))))
      (list :begin beg
            :end f-end
            :content (buffer-substring-no-properties content-beg content-end)
            :open open
            :close (if is-paren (if (string-equal open "\\(") "\\)" "\\]") open)))))

(defun ratex-fragments-in-buffer (&optional beg end)
  "Return all math fragments between BEG and END."
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        fragments)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward "\\$\\$?\\|\\\\(\\|\\\\\\[" end t)
        (let ((m-beg (match-beginning 0))
              (m-end (match-end 0)))
          (with-syntax-table tex-mode-syntax-table
            (let ((state (parse-partial-sexp (point-min) m-beg)))
              (if (or (nth 3 state) (nth 4 state))
                  (goto-char m-end)
                (if-let* ((fragment (ratex--make-fragment m-beg)))
                    (progn
                      (push fragment fragments)
                      (goto-char (plist-get fragment :end)))
                  (goto-char m-end))))))))
    (nreverse fragments)))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as a plist."
  (let ((pos (point))
        found)
    (dolist (f (ratex-fragments-in-buffer (max (point-min) (- pos 2000)) 
                                          (min (point-max) (+ pos 2000))))
      (when (and (<= (plist-get f :begin) pos)
                 (<= pos (plist-get f :end)))
        (setq found f)))
    found))

(provide 'ratex-math-detect)
