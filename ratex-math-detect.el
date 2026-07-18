;;; ratex-math-detect.el --- Math fragment detection -*- lexical-binding: t; -*-

(require 'tex-mode)

(defun ratex--escaped-p (pos)
  "Return non-nil if the character at POS is escaped by a backslash."
  (save-excursion
    (goto-char pos)
    (let ((count 0))
      (while (and (> (point) (point-min))
                  (= (char-before) ?\\))
        (setq count (1+ count))
        (backward-char 1))
      (= (% count 2) 1))))

(defun ratex--find-close-delimiter (open beg)
  "Find the unescaped closing delimiter for OPEN starting after BEG."
  (let ((close (cond ((string-equal open "$$") "$$")
                     ((string-equal open "$") "$")
                     ((string-equal open "\\(") "\\)")
                     ((string-equal open "\\[") "\\]")))
        found)
    (save-excursion
      (goto-char (+ beg (length open)))
      (let ((pattern (regexp-quote close)))
        (while (and (re-search-forward pattern nil t) (not found))
          (let ((match-beg (match-beginning 0)))
            (unless (ratex--escaped-p match-beg)
              (setq found (point))))))
      found)))

(defun ratex--make-fragment (beg)
  "Create a math fragment plist starting at BEG using tex-mode parsers."
  (save-excursion
    (goto-char beg)
    (when-let* ((open (cond ((looking-at "\\$\\$") "$$")
                            ((looking-at "\\$") "$")
                            ((looking-at "\\\\(") "\\(")
                            ((looking-at "\\\\\\[") "\\[")))
                (f-end (or (condition-case nil
                               (let ((latex-handle-escaped-parens t))
                                 (with-syntax-table tex-mode-syntax-table
                                   (latex-forward-sexp-1))
                                 (let ((p (point)))
                                   (and (> p beg) p)))
                             (error nil))
                           (ratex--find-close-delimiter open beg)))
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
          (if (ratex--escaped-p m-beg)
              (goto-char m-end)
            (if-let* ((fragment (ratex--make-fragment m-beg)))
                (progn
                  (push fragment fragments)
                  (goto-char (plist-get fragment :end)))
              (goto-char m-end))))))
    (nreverse fragments)))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as a plist."
  (let ((pos (point))
        found)
    (dolist (f (ratex-fragments-in-buffer (max (point-min) (- pos 2000)) 
                                          (min (point-max) (+ pos 2000))))
      (when (and (<= (plist-get f :begin) pos)
                 (< pos (plist-get f :end)))
        (setq found f)))
    found))

(provide 'ratex-math-detect)
