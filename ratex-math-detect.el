;;; ratex-math-detect.el --- Math fragment detection -*- lexical-binding: t; -*-

(require 'tex-mode)
(require 'seq)
(require 'subr-x)

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
  (when-let* ((close (cond ((string-equal open "$$") "$$")
                           ((string-equal open "$") "$")
                           ((string-equal open "\\(") "\\)")
                           ((string-equal open "\\[") "\\]"))))
    (let (found)
      (save-excursion
        (goto-char (+ beg (length open)))
        (let ((pattern (regexp-quote close)))
          (while (and (re-search-forward pattern nil t) (not found))
            (let ((match-beg (match-beginning 0)))
              (unless (ratex--escaped-p match-beg)
                (setq found (point))))))
        found))))

(defun ratex--find-close-environment (env beg)
  "Find the closing \\end{ENV} for \\begin{ENV} starting after BEG."
  (save-excursion
    (goto-char beg)
    (let ((open-re (concat "\\\\begin{" (regexp-quote env) "}"))
          (close-re (concat "\\\\end{" (regexp-quote env) "}"))
          (depth 1)
          found)
      (while (and (> depth 0)
                  (re-search-forward (concat open-re "\\|" close-re) nil t))
        (let ((match-beg (match-beginning 0)))
          (unless (ratex--escaped-p match-beg)
            (if (string-prefix-p "\\begin" (match-string 0))
                (setq depth (1+ depth))
              (setq depth (1- depth))
              (when (= depth 0)
                (setq found (point)))))))
      found)))

(defun ratex--build-fragment (beg end fixed-delim-len)
  "Extract the fragment details and compute the delimiters based on environment lengths."
  (if fixed-delim-len
      (let ((c-beg (+ beg fixed-delim-len))
            (c-end (- end fixed-delim-len)))
        `((begin . ,beg)
          (end . ,end)
          (content . ,(buffer-substring-no-properties c-beg c-end))
          (open . ,(buffer-substring-no-properties beg c-beg))
          (close . ,(buffer-substring-no-properties c-end end))))
    `((begin . ,beg)
      (end . ,end)
      (content . ,(buffer-substring-no-properties beg end))
      (open . "")
      (close . ""))))

(defun ratex-fragments-in-buffer (&optional beg end)
  "Return all math fragments between BEG and END."
  (let* ((beg (or beg (point-min)))
         (end (or end (point-max)))
         (fragments nil))
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let ((pos (point))
              (char (char-after)))
          (cond
           ((eq char ?$)
            (if (ratex--escaped-p pos)
                (goto-char (1+ pos))
              (let* ((is-double (eq (char-after (1+ pos)) ?$))
                     (delim (if is-double "$$" "$"))
                     (delim-len (if is-double 2 1))
                     (close-pos (ratex--find-close-delimiter delim pos)))
                (if close-pos
                    (progn
                      (push (ratex--build-fragment pos close-pos delim-len) fragments)
                      (goto-char close-pos))
                  (goto-char (+ pos delim-len))))))

           ((eq char ?\\)
            (if (ratex--escaped-p pos)
                (goto-char (1+ pos))
              (let ((next-char (char-after (1+ pos))))
                (cond
                 ((memq next-char '(?\[ ?\())
                  (let* ((delim (if (eq next-char ?\[) "\\[" "\\("))
                         (close-pos (ratex--find-close-delimiter delim pos)))
                    (if close-pos
                        (progn
                          (push (ratex--build-fragment pos close-pos 2) fragments)
                          (goto-char close-pos))
                      (goto-char (+ pos 2)))))

                 ((eq next-char ?b)
                  (if (looking-at "\\\\begin{\\([a-zA-Z0-9*]+\\)}")
                      (let* ((env (match-string 1))
                             (open-len (length (match-string 0)))
                             (close-pos (ratex--find-close-environment env (+ pos open-len))))
                        (if close-pos
                            (progn
                              (push (ratex--build-fragment pos close-pos nil) fragments)
                              (goto-char close-pos))
                          (goto-char (+ pos open-len))))
                    (goto-char (+ pos 2))))

                 (t (goto-char (1+ pos)))))))

           (t (goto-char (1+ pos)))))))
    (nreverse fragments)))

(defun ratex-fragment-at-point ()
  "Return the math fragment around point as an alist."
  (let ((pos (point)))
    (seq-find (lambda (f)
                (and (<= (alist-get 'begin f) pos)
                     (< pos (alist-get 'end f))))
              (ratex-fragments-in-buffer (max (point-min) (- pos 2000))
                                         (min (point-max) (+ pos 2000))))))

(provide 'ratex-math-detect)
