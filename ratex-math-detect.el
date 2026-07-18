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

(defun ratex--build-fragment (beg end fixed-delim-len)
  "Extract the fragment details and compute the delimiters based on environment lengths."
  (let (open-delim close-delim content-str)
    (if fixed-delim-len
        (let ((c-beg (+ beg fixed-delim-len))
              (c-end (- end fixed-delim-len)))
          (setq open-delim (buffer-substring-no-properties beg c-beg)
                close-delim (buffer-substring-no-properties c-end end)
                content-str (buffer-substring-no-properties c-beg c-end)))
      (save-excursion
        (goto-char beg)
        (forward-char 6)
        (let ((env-start (point)))
          (forward-sexp 1)
          (let* ((env-len (- (point) env-start))
                 (open-len (+ 6 env-len))
                 (close-len (+ 4 env-len)))
            (setq open-delim (buffer-substring-no-properties beg (+ beg open-len))
                  close-delim (buffer-substring-no-properties (- end close-len) end)
                  content-str (buffer-substring-no-properties (+ beg open-len) (- end close-len)))))))
    (list :begin beg
          :end end
          :content content-str
          :open open-delim
          :close close-delim)))

(defvar ratex--math-syntax-table
  (let ((st (make-syntax-table tex-mode-syntax-table)))
    (modify-syntax-entry ?\\ "." st)
    st)
  "Syntax table for parsing balanced math delimiters.")

(defun ratex-fragments-in-buffer (&optional beg end)
  "Return all math fragments between BEG and END using native syntax mechanics."
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (fragments nil)
         (latex-handle-escaped-parens t))
    (save-excursion
      (goto-char beg)
      (with-syntax-table tex-mode-syntax-table
        (while (< (point) end)
          (let* ((pos (point))
                 (char (char-after)))
            (cond
             ((eq char ?$)
              (if (ratex--escaped-p pos)
                  (goto-char (1+ pos))
                (let ((start pos)
                      (is-double (eq (char-after (1+ pos)) ?$)))
                  (condition-case nil
                      (progn
                        (forward-sexp 1)
                        (push (ratex--build-fragment start (point) (if is-double 2 1)) fragments))
                    (error
                     (if-let* ((end-pos (ratex--find-close-delimiter (if is-double "$$" "$") start)))
                         (progn
                           (goto-char end-pos)
                           (push (ratex--build-fragment start end-pos (if is-double 2 1)) fragments))
                       (goto-char (1+ pos))))))))

             ((eq char ?\\)
              (if (ratex--escaped-p pos)
                  (goto-char (1+ pos))
                (let ((next-char (char-after (1+ pos))))
                  (cond
                   ((memq next-char '(?\[ ?\())
                    (condition-case nil
                        (let ((start pos)
                              (parse-sexp-lookup-properties nil))
                          (with-syntax-table ratex--math-syntax-table
                            (forward-char 1)
                            (forward-sexp 1))
                          (push (ratex--build-fragment start (point) 2) fragments))
                      (error
                       (if-let* ((end-pos (ratex--find-close-delimiter (if (eq next-char ?\[) "\\[" "\\(") pos)))
                           (progn
                             (goto-char end-pos)
                             (push (ratex--build-fragment pos end-pos 2) fragments))
                         (goto-char (min (point-max) (+ pos 2)))))))

                   ((eq next-char ?b)
                    (condition-case nil
                        (let ((start pos))
                          (latex-forward-sexp 1)
                          (push (ratex--build-fragment start (point) nil) fragments))
                      (error (goto-char (min (point-max) (+ pos 2))))))

                   (t (goto-char (min (point-max) (+ pos 2))))))))

             (t (goto-char (1+ pos))))))))
    (nreverse fragments)))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as a plist."
  (let ((pos (point))
        (found nil))
    (catch 'found
      (dolist (f (ratex-fragments-in-buffer (max (point-min) (- pos 2000)) 
                                            (min (point-max) (+ pos 2000))))
        (when (and (<= (plist-get f :begin) pos)
                   (< pos (plist-get f :end)))
          (setq found f)
          (throw 'found f))))
    found))

(provide 'ratex-math-detect)
