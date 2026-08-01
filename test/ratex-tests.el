;;; ratex-tests.el --- Tests for ratex.el -*- lexical-binding: t; -*-

;;; Code:

(require 'buttercup)
(require 'ratex)
(require 'ratex-render)
(require 'ratex-math-detect)

(describe "ratex-math-detect"
          (it "should detect standard inline LaTeX mathematical formulas"
              (with-temp-buffer
                (latex-mode)
                (insert "hello \\(x^2\\) world")
                (syntax-propertize (point-max))
                (goto-char 11)
                (let ((fragment (ratex-fragment-at-point)))
                  (expect (alist-get 'content fragment) :to-equal "x^2"))))

          (it "should track points so that it does not detect fragments immediately after a closing delimiter"
              (with-temp-buffer
                (latex-mode)
                (insert "aa \\(x+1\\) bb")
                (syntax-propertize (point-max))
                (goto-char 11)
                (expect (ratex-fragment-at-point) :to-be nil)))

          (it "should successfully identify LaTeX display bracket formulas"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\[x+1\\] b")
                (syntax-propertize (point-max))
                (goto-char 7)
                (let ((fragment (ratex-fragment-at-point)))
                  (expect (alist-get 'content fragment) :to-equal "x+1"))))

          (it "should ignore escaped delimiters during bulk buffer scanning"
              (with-temp-buffer
                (latex-mode)
                (insert "price \\$5 and \\\\(x\\\\) and \\(y\\)")
                (syntax-propertize (point-max))
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 1)
                  (expect (alist-get 'content (car fragments)) :to-equal "y"))))

          (it "should ignore escaped delimiters when checking the fragment at point"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\$x$ b")
                (syntax-propertize (point-max))
                (goto-char 6)
                (expect (ratex-fragment-at-point) :to-be nil))
              (with-temp-buffer
                (latex-mode)
                (insert "a \\\\(x\\\\) b")
                (syntax-propertize (point-max))
                (goto-char 6)
                (expect (ratex-fragment-at-point) :to-be nil)))

          (it "should detect formulas inside Org mode LaTeX source blocks"
              (with-temp-buffer
                (org-mode)
                (insert "#+begin_src latex\n\\(x\\)\n#+end_src\n")
                (syntax-propertize (point-max))
                (goto-char (point-min))
                (search-forward "\\(x")
                (let ((fragment (ratex-fragment-at-point)))
                  (expect fragment :not :to-be nil)
                  (expect (alist-get 'content fragment) :to-equal "x"))
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 1)
                  (expect (alist-get 'content (car fragments)) :to-equal "x"))))

          (it "should detect LaTeX environment blocks"
              (with-temp-buffer
                (latex-mode)
                (insert "text \\begin{align}\na &= b\n\\end{align} text")
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 1)
                  (expect (alist-get 'content (car fragments))
                          :to-equal "\\begin{align}\na &= b\n\\end{align}"))))

          (it "should correctly handle formulas containing internal parentheses and brackets"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(f(x)\\) b \\[g[y]\\] c")
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 2)
                  (expect (alist-get 'content (nth 0 fragments)) :to-equal "f(x)")
                  (expect (alist-get 'content (nth 1 fragments)) :to-equal "g[y]"))))

          (it "should detect dollar sign math formulas"
              (with-temp-buffer
                (latex-mode)
                (insert "inline $x+1$ and display $$y+2$$")
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 2)
                  (expect (alist-get 'content (nth 0 fragments)) :to-equal "x+1")
                  (expect (alist-get 'content (nth 1 fragments)) :to-equal "y+2")))))

(describe "ratex"
          (it "should auto-enable the minor mode only in supported major modes"
              (with-temp-buffer
                (setq major-mode 'org-mode)
                (expect (ratex--auto-enable-p) :not :to-be nil))
              (with-temp-buffer
                (setq major-mode 'text-mode)
                (expect (ratex--auto-enable-p) :to-be nil)))

          (it "should parse Org keyword values and apply them to enable or disable the minor mode"
              (with-temp-buffer
                (org-mode)
                (insert "#+ratex:\n")
                (expect (ratex--org-keyword-state) :to-be 'enable))
              (with-temp-buffer
                (org-mode)
                (insert "#+ratex: off\n")
                (expect (ratex--org-keyword-state) :to-be 'disable))
              (with-temp-buffer
                (org-mode)
                (insert "#+title: demo\n")
                (expect (ratex--org-keyword-state) :to-be nil)))

          (it "should auto-enable the minor mode only when Org keyword does not disable it"
              (with-temp-buffer
                (org-mode)
                (insert "#+ratex: nil\n")
                (expect (ratex--auto-enable-p) :to-be nil)))

          (it "should enable in supported buffers via global minor mode"
              (with-temp-buffer
                (setq major-mode 'markdown-mode)
                (let (enabled)
                  (spy-on 'ratex-mode :and-call-fake (lambda (&optional arg) (setq enabled arg)))
                  (ratex--maybe-enable)
                  (expect enabled :to-be 1))))

          (it "should enable minor mode if Org keyword specifies enable"
              (with-temp-buffer
                (org-mode)
                (insert "#+ratex: t\n")
                (let (enabled)
                  (spy-on 'ratex-mode :and-call-fake (lambda (&optional arg) (setq enabled arg)))
                  (ratex--apply-org-keyword)
                  (expect enabled :to-be 1))))

          (it "should disable minor mode if Org keyword specifies disable"
              (with-temp-buffer
                (org-mode)
                (insert "#+ratex: disabled\n")
                (let ((ratex-mode t)
                      disabled)
                  (spy-on 'ratex-mode :and-call-fake (lambda (&optional arg) (setq disabled arg)))
                  (ratex--apply-org-keyword)
                  (expect disabled :to-be -1)))))

(describe "ratex-overlays"
          (it "should detect a rendered overlay within its exact character range"
              (with-temp-buffer
                (insert "abcdef")
                (let ((ov (make-overlay 1 4)))
                  (overlay-put ov 'ratex-key "1:4:x")
                  (overlay-put ov 'ratex-image "IMG")
                  (setf (alist-get "1:4:x" ratex--overlays nil nil #'equal) ov))
                (goto-char 1)
                (expect (ratex-rendered-overlay-at-point-p) :not :to-be nil)
                (goto-char 3)
                (expect (ratex-rendered-overlay-at-point-p) :not :to-be nil)
                (goto-char 4)
                (expect (ratex-rendered-overlay-at-point-p) :to-be nil)))

          (it "should retrieve the correct fragment metadata from the overlay at point"
              (with-temp-buffer
                (insert "abcdef")
                (let ((ov (make-overlay 2 5))
                      (fragment '((begin . 2) (end . 5) (content . "x") (open . "\\(") (close . "\\)"))))
                  (overlay-put ov 'ratex-key "2:5:x")
                  (overlay-put ov 'ratex-image "IMG")
                  (overlay-put ov 'ratex-fragment fragment)
                  (setf (alist-get "2:5:x" ratex--overlays nil nil #'equal) ov))
                (goto-char 3)
                (let ((fragment (ratex-overlay-fragment-at-point)))
                  (expect (alist-get 'content fragment) :to-equal "x"))))

          (it "should ignore stale overlay references not matching the active table state"
              (with-temp-buffer
                (insert "abcdef")
                (let ((overlay (make-overlay 2 5)))
                  (overlay-put overlay 'ratex-key "stale")
                  (setf (alist-get "stale" ratex--overlays nil nil #'equal) (make-overlay 1 2))
                  (goto-char 3)
                  (expect (ratex-rendered-overlay-at-point-p) :to-be nil)
                  (delete-overlay overlay)))))

(describe "ratex-render bulk math fragment detection"
          (it "should detect multiple mathematical fragments in a single buffer"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b \\[y+1\\] c")
                (syntax-propertize (point-max))
                (let ((fragments (ratex-fragments-in-buffer)))
                  (expect (length fragments) :to-be 2)
                  (expect (mapcar (lambda (f) (alist-get 'content f)) fragments)
                          :to-equal '("x" "y+1")))))

          (it "should respect range limits when scanning a buffer"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b \\(y\\) c")
                (syntax-propertize (point-max))
                (let ((fragments (ratex-fragments-in-buffer 9 (point-max))))
                  (expect (length fragments) :to-be 1)
                  (expect (alist-get 'content (car fragments)) :to-equal "y")))))

(describe "ratex-render rendering coordination"
          (it "should queue visible fragments for rendering while excluding the active fragment"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b \\(y\\) c")
                (syntax-propertize (point-max))
                (goto-char 6)
                (let* ((fragments (ratex-fragments-in-buffer))
                       (active (ratex-fragment-at-point))
                       (targets (ratex--fragments-to-render fragments active)))
                  (expect (length fragments) :to-be 2)
                  (expect (length targets) :to-be 1)
                  (expect (alist-get 'content (car targets)) :to-equal "y"))))

          (it "should render all non-active previews when refreshing"
              (with-temp-buffer
                (latex-mode)
                (ratex-reset-buffer-state)
                (insert "a \\(x\\) b \\(y\\) c")
                (syntax-propertize (point-max))
                (goto-char 6)
                (let (rendered)
                  (spy-on 'ratex-render-math-batch-async :and-call-fake
                          (lambda (math-strings _cb)
                            (setq rendered (append rendered math-strings))))
                  (ratex-refresh-previews)
                  (expect rendered :to-equal '("y")))))

          (it "should render all previews including active when include-active is non-nil"
              (with-temp-buffer
                (latex-mode)
                (ratex-reset-buffer-state)
                (insert "a \\(x\\) b \\(y\\) c")
                (syntax-propertize (point-max))
                (goto-char 6)
                (let (rendered)
                  (spy-on 'ratex-render-math-batch-async :and-call-fake
                          (lambda (math-strings _cb)
                            (setq rendered (append rendered math-strings))))
                  (ratex-refresh-previews t)
                  (expect (sort rendered #'string<) :to-equal '("x" "y")))))

          (it "should render all missing fragments in a single batch when refreshing"
              (with-temp-buffer
                (latex-mode)
                (ratex-reset-buffer-state)
                (let (rendered)
                  (insert "\\(a\\) \\(b\\) \\(c\\)")
                  (syntax-propertize (point-max))
                  (setq-local ratex-mode t)
                  (spy-on 'ratex-render-math-batch-async :and-call-fake
                          (lambda (math-strings _cb)
                            (setq rendered (append rendered math-strings))))
                  (ratex-refresh-previews t)
                  (expect (sort rendered #'string<) :to-equal '("a" "b" "c"))))))

(describe "ratex--effective-color"
          (it "should resolve default color to frame foreground color or black"
              (let ((ratex-color "default")
                    (expected (or (frame-parameter nil 'foreground-color)
                                  (face-attribute 'default :foreground nil t)
                                  "black")))
                (expect (ratex--effective-color) :to-equal expected)))

          (it "should resolve default color to frame foreground color when set"
              (let ((ratex-color "default"))
                (spy-on 'frame-parameter :and-return-value "red")
                (expect (ratex--effective-color) :to-equal "red")))

          (it "should return explicit color when ratex-color is set to white or hex"
              (let ((ratex-color "white"))
                (expect (ratex--effective-color) :to-equal "white"))
              (let ((ratex-color "#123456"))
                (expect (ratex--effective-color) :to-equal "#123456"))))

(describe "ratex-render cache key generation"
          (it "should generate different cache keys when font size changes"
              (with-temp-buffer
                (latex-mode)
                (insert "\\(x\\)")
                (syntax-propertize (point-max))
                (let* ((fragment (car (ratex-fragments-in-buffer)))
                       (ratex-font-size 16.0)
                       (key-a (ratex--cache-key fragment))
                       (ratex-font-size 20.0)
                       (key-b (ratex--cache-key fragment)))
                  (expect key-a :not :to-equal key-b))))

          (it "should generate different cache keys when formula color changes"
              (with-temp-buffer
                (latex-mode)
                (insert "\\(x\\)")
                (syntax-propertize (point-max))
                (let* ((fragment (car (ratex-fragments-in-buffer)))
                       (ratex-color "white")
                       (key-a (ratex--cache-key fragment))
                       (ratex-color "#123456")
                       (key-b (ratex--cache-key fragment)))
                  (expect key-a :not :to-equal key-b)))))

(describe "ratex-render error handling"
          (it "should display render errors in error-indicative text overlays"
              (with-temp-buffer
                (latex-mode)
                (insert "\\(\\bad{\\)")
                (syntax-propertize (point-max))
                (let* ((fragment (car (ratex-fragments-in-buffer)))
                       (fragment-key (ratex--fragment-key fragment)))
                  (ratex--display-response
                   fragment-key
                   fragment
                   '((ok . :false) (error . "parse error: expected } <and>")))
                  (let ((ov (alist-get fragment-key ratex--overlays nil nil #'equal)))
                    (expect ov :not :to-be nil)
                    (expect (overlay-get ov 'display) :to-equal (propertize " [RaTeX Error] " 'face 'error))
                    (expect (overlay-get ov 'help-echo) :to-equal "RaTeX render failed: parse error: expected } <and>"))))))

(describe "ratex-render preview initialisation and tracking"
          (it "should render all previews on initialisation then hide the active fragment overlay"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (goto-char 5)
                (let (include-active removed-key)
                  (spy-on 'ratex-refresh-previews :and-call-fake
                          (lambda (&optional include)
                            (setq include-active include)))
                  (spy-on 'ratex--remove-overlay :and-call-fake
                          (lambda (key)
                            (setq removed-key key)))
                  (ratex-initialize-previews)
                  (expect include-active :not :to-be nil)
                  (expect removed-key :to-equal "3:8:x")
                  (expect (alist-get 'content ratex--active-fragment) :to-equal "x"))))

          (it "should hide overlays when the cursor enters a fragment and render them when it leaves"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (let (removed ensured)
                  (setq-local ratex-mode t)
                  (ratex-reset-buffer-state)
                  (setq-local ratex--active-fragment nil)
                  (spy-on 'ratex--remove-overlay :and-call-fake
                          (lambda (key)
                            (push key removed)))
                  (spy-on 'ratex--render-batch :and-call-fake
                          (lambda (fragments)
                            (dolist (f fragments)
                              (push (alist-get 'content f) ensured))))
                  (goto-char 5)
                  (ratex-handle-post-command)
                  (expect removed :to-equal '("3:8:x"))
                  (expect ensured :to-be nil)
                  (setq removed nil)
                  (goto-char 9)
                  (ratex-handle-post-command)
                  (expect removed :to-be nil)
                  (expect ensured :to-equal '("x")))))

          (it "should ignore cursor command actions when live edits are made inside the same active fragment"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (goto-char 4)
                (setq-local ratex-mode t)
                (ratex-reset-buffer-state)
                (setq-local ratex--active-fragment (ratex-fragment-at-point))
                (insert "y")
                (syntax-propertize (point-max))
                (let (removed ensured)
                  (spy-on 'ratex--remove-overlay :and-call-fake
                          (lambda (key)
                            (push key removed)))
                  (spy-on 'ratex--render-batch :and-call-fake
                          (lambda (fragments)
                            (dolist (f fragments)
                              (push (alist-get 'content f) ensured))))
                  (ratex-handle-post-command)
                  (expect removed :to-be nil)
                  (expect ensured :to-be nil))))

          (it "should expand the inline overlay fallback when moving point inside a rendered formula"
              (with-temp-buffer
                (latex-mode)
                (insert "\\(x\\)z")
                (syntax-propertize (point-max))
                (let ((fragment '((begin . 1) (end . 6) (content . "x") (open . "\\(") (close . "\\)")))
                      ensured)
                  (setq-local ratex-mode t)
                  (ratex-reset-buffer-state)
                  (setq-local ratex--active-fragment nil)
                  (let ((ov (make-overlay 1 6)))
                    (overlay-put ov 'ratex-key "1:6:x")
                    (overlay-put ov 'ratex-image "IMG")
                    (overlay-put ov 'ratex-fragment fragment)
                    (setf (alist-get "1:6:x" ratex--overlays nil nil #'equal) ov))
                  (goto-char 3)
                  (spy-on 'ratex-fragment-at-point :and-return-value nil)
                  (spy-on 'ratex--render-batch :and-call-fake
                          (lambda (fragments)
                            (dolist (f fragments)
                              (push (alist-get 'content f) ensured))))
                  (ratex-handle-post-command)
                  (expect (ratex-rendered-overlay-at-point-p) :to-be nil)
                  (expect (alist-get 'content ratex--active-fragment) :to-equal "x")
                  (goto-char 7)
                  (ratex-handle-post-command)
                  (expect ensured :to-equal '("x")))))

          (it "should call ratex-enter-fragment-hook with fragment and cached image when entering a fragment"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (setq-local ratex-mode t)
                (ratex-reset-buffer-state)
                (let* ((fragment (car (ratex-fragments-in-buffer)))
                       (cache-key (ratex--cache-key fragment))
                       (mock-img (list 'image :type 'svg :data "<svg/>"))
                       called-args)
                  (setf (alist-get cache-key ratex--render-cache nil nil #'equal) '((ok . t) (svg . "<svg/>")))
                  (spy-on 'ratex--image-from-response :and-return-value mock-img)
                  (add-hook 'ratex-enter-fragment-hook
                            (lambda (frag img)
                              (setq called-args (list frag img)))
                            nil t)
                  (goto-char 5)
                  (ratex-handle-post-command)
                  (expect (car called-args) :to-equal fragment)
                  (expect (cadr called-args) :to-equal mock-img))))

          (it "should call ratex-enter-fragment-hook with nil image when fragment is not cached"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (setq-local ratex-mode t)
                (ratex-reset-buffer-state)
                (let* ((fragment (car (ratex-fragments-in-buffer)))
                       called-args)
                  (add-hook 'ratex-enter-fragment-hook
                            (lambda (frag img)
                              (setq called-args (list frag img)))
                            nil t)
                  (goto-char 5)
                  (ratex-handle-post-command)
                  (expect (car called-args) :to-equal fragment)
                  (expect (cadr called-args) :to-be nil))))

          (it "should call ratex-leave-fragment-hook with the exited fragment when point leaves"
              (with-temp-buffer
                (latex-mode)
                (insert "a \\(x\\) b")
                (syntax-propertize (point-max))
                (setq-local ratex-mode t)
                (ratex-reset-buffer-state)
                (goto-char 5)
                (ratex-handle-post-command)
                (let ((fragment ratex--active-fragment)
                      exited-frag)
                  (add-hook 'ratex-leave-fragment-hook
                            (lambda (frag)
                              (setq exited-frag frag))
                            nil t)
                  (spy-on 'ratex--render-batch :and-return-value nil)
                  (goto-char 9)
                  (ratex-handle-post-command)
                  (expect exited-frag :to-equal fragment)))))

(describe "ratex-render process coordination"
          (it "should process multiple formulas in a single async render call"
              (with-temp-buffer
                (latex-mode)
                (insert "\\(A\\) xx \\(B\\)")
                (syntax-propertize (point-max))
                (let* ((fragments (ratex-fragments-in-buffer))
                       (first (nth 0 fragments))
                       (second (nth 1 fragments))
                       (first-key (ratex--fragment-key first))
                       (second-key (ratex--fragment-key second))
                       (request-count 0)
                       passed-strings
                       callback
                       seen)
                  (setq-local ratex-mode t)
                  (ratex-reset-buffer-state)
                  (spy-on 'ratex-render-math-batch-async :and-call-fake
                          (lambda (math-strings cb)
                            (setq request-count (1+ request-count))
                            (setq passed-strings math-strings)
                            (setq callback cb)))
                  (spy-on 'ratex--display-if-visible :and-call-fake
                          (lambda (fragment-key _fragment _response)
                            (push fragment-key seen)))
                  (ratex--render-batch fragments)
                  (expect request-count :to-be 1)
                  (expect passed-strings :to-equal '("A" "B"))
                  (funcall callback '("<svg1/>" "<svg2/>"))
                  (expect (sort seen #'string<)
                          :to-equal (sort (list first-key second-key) #'string<))))))

(describe "ratex-render-math-batch-async"
          (it "should pass --color argument in make-process command list"
              (let ((ratex-color "#123456")
                    passed-cmd)
                (spy-on 'make-process :and-call-fake
                        (lambda (&rest args)
                          (setq passed-cmd (plist-get args :command))
                          nil))
                (spy-on 'process-send-string :and-return-value nil)
                (spy-on 'process-send-eof :and-return-value nil)
                (ratex-render-math-batch-async '("x") (lambda (_svgs) nil))
                (expect (member "--color" passed-cmd) :not :to-be nil)
                (expect (cadr (member "--color" passed-cmd)) :to-equal "#123456"))))

(provide 'ratex-tests)

;;; ratex-tests.el ends here
