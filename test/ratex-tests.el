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
      (goto-char 11)
      (let ((fragment (ratex-fragment-at-point)))
        (expect (plist-get fragment :content) :to-equal "x^2"))))

  (it "should track points so that it does not detect fragments immediately after a closing delimiter"
    (with-temp-buffer
      (latex-mode)
      (insert "aa \\(x+1\\) bb")
      (goto-char 11)
      (expect (ratex-fragment-at-point) :to-be nil)))

  (it "should successfully identify LaTeX display bracket formulas"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\[x+1\\] b")
      (goto-char 7)
      (let ((fragment (ratex-fragment-at-point)))
        (expect (plist-get fragment :content) :to-equal "x+1"))))

  (it "should ignore escaped delimiters during bulk buffer scanning"
    (with-temp-buffer
      (latex-mode)
      (insert "price \\$5 and \\\\(x\\\\) and \\(y\\)")
      (let ((fragments (ratex-fragments-in-buffer)))
        (expect (length fragments) :to-be 1)
        (expect (plist-get (car fragments) :content) :to-equal "y"))))

  (it "should ignore escaped delimiters when checking the fragment at point"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\$x$ b")
      (goto-char 6)
      (expect (ratex-fragment-at-point) :to-be nil))
    (with-temp-buffer
      (latex-mode)
      (insert "a \\\\(x\\\\) b")
      (goto-char 6)
      (expect (ratex-fragment-at-point) :to-be nil)))

  (it "should detect formulas inside Org mode LaTeX source blocks"
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src latex\n\\(x\\)\n#+end_src\n")
      (goto-char (point-min))
      (search-forward "\\(x")
      (let ((fragment (ratex-fragment-at-point)))
        (expect fragment :not :to-be nil)
        (expect (plist-get fragment :content) :to-equal "x"))
      (let ((fragments (ratex-fragments-in-buffer)))
        (expect (length fragments) :to-be 1)
        (expect (plist-get (car fragments) :content) :to-equal "x")))))

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
      (ratex-show-overlay "1:4:x" 1 4 "IMG")
      (goto-char 1)
      (expect (ratex-rendered-overlay-at-point-p) :not :to-be nil)
      (goto-char 3)
      (expect (ratex-rendered-overlay-at-point-p) :not :to-be nil)
      (goto-char 4)
      (expect (ratex-rendered-overlay-at-point-p) :to-be nil)))

  (it "should retrieve the correct fragment metadata from the overlay at point"
    (with-temp-buffer
      (insert "abcdef")
      (ratex-show-overlay
       "2:5:x" 2 5 "IMG" nil
       '(:begin 2 :end 5 :content "x" :open "\\(" :close "\\)"))
      (goto-char 3)
      (let ((fragment (ratex-overlay-fragment-at-point)))
        (expect (plist-get fragment :content) :to-equal "x"))))

  (it "should ignore stale overlay references not matching the active table state"
    (with-temp-buffer
      (insert "abcdef")
      (let ((overlay (make-overlay 2 5)))
        (overlay-put overlay 'ratex-key "stale")
        (puthash "stale" (make-overlay 1 2) (ratex--overlay-table))
        (goto-char 3)
        (expect (ratex-rendered-overlay-at-point-p) :to-be nil)
        (delete-overlay overlay)))))

(describe "ratex-render colour and background utilities"
  (it "should normalise and trim hexadecimal and named colours"
    (expect (ratex--normalize-color-value "  #ff00aa  ") :to-equal "#ff00aa")
    (expect (ratex--normalize-color-value "   ") :to-be nil)
    (expect (ratex--normalize-color-value nil) :to-be nil))

  (it "should choose theme-aware colours dynamically based on frame background mode"
    (let ((ratex-render-color nil)
          (ratex-dark-render-color "white")
          (ratex-light-render-color "black")
          (bg-mode 'dark))
      (spy-on 'frame-parameter :and-call-fake (lambda (&rest _args) bg-mode))
      (expect (ratex--effective-render-color) :to-equal "white")
      (setq bg-mode 'light)
      (expect (ratex--effective-render-color) :to-equal "black")))

  (it "should respect explicit user overrides for render colours"
    (let ((ratex-render-color "  red  ")
          (ratex-dark-render-color "white")
          (ratex-light-render-color "black"))
      (spy-on 'frame-parameter :and-call-fake (lambda (&rest _args) 'dark))
      (expect (ratex--effective-render-color) :to-equal "red")))

  (it "should choose background posframe colours dynamically based on frame background mode"
    (let ((ratex-posframe-background-color nil)
          (ratex-dark-posframe-background-color "black")
          (ratex-light-posframe-background-color "white")
          (bg-mode 'dark))
      (spy-on 'frame-parameter :and-call-fake (lambda (&rest _args) bg-mode))
      (expect (ratex--effective-posframe-background-color) :to-equal "black")
      (setq bg-mode 'light)
      (expect (ratex--effective-posframe-background-color) :to-equal "white")))

  (it "should respect explicit user overrides for posframe background colours"
    (let ((ratex-posframe-background-color "  gray10  ")
          (ratex-dark-posframe-background-color "black")
          (ratex-light-posframe-background-color "white"))
      (spy-on 'frame-parameter :and-call-fake (lambda (&rest _args) 'light))
      (expect (ratex--effective-posframe-background-color) :to-equal "gray10"))))

(describe "ratex-render theme and configuration updates"
  (it "should trigger a preview refresh across all active buffers"
    (let ((buf-a (get-buffer-create (generate-new-buffer-name " *ratex-theme-a*")))
          (buf-b (get-buffer-create (generate-new-buffer-name " *ratex-theme-b*")))
          (buf-c (get-buffer-create (generate-new-buffer-name " *ratex-theme-c*")))
          refreshed)
      (unwind-protect
          (progn
            (with-current-buffer buf-a
              (setq-local ratex-mode t))
            (with-current-buffer buf-b
              (setq-local ratex-mode t))
            (spy-on 'ratex-refresh-previews :and-call-fake
                    (lambda (&optional include-active)
                      (push (list (current-buffer) include-active) refreshed)))
            (ratex--run-theme-refresh buf-a 'all)
            (expect (length refreshed) :to-be 2)
            (expect (member (list buf-a t) refreshed) :not :to-be nil)
            (expect (member (list buf-b t) refreshed) :not :to-be nil)
            (expect (member (list buf-c t) refreshed) :to-be nil))
        (kill-buffer buf-a)
        (kill-buffer buf-b)
        (kill-buffer buf-c))))

  (it "should trigger a preview refresh within the current buffer only"
    (let ((buf-a (get-buffer-create (generate-new-buffer-name " *ratex-theme-current-a*")))
          (buf-b (get-buffer-create (generate-new-buffer-name " *ratex-theme-current-b*")))
          refreshed)
      (unwind-protect
          (progn
            (with-current-buffer buf-a
              (setq-local ratex-mode t))
            (with-current-buffer buf-b
              (setq-local ratex-mode t))
            (spy-on 'ratex-refresh-previews :and-call-fake
                    (lambda (&optional include-active)
                      (push (list (current-buffer) include-active) refreshed)))
            (ratex--run-theme-refresh buf-b 'current)
            (expect refreshed :to-equal (list (list buf-b t))))
        (kill-buffer buf-a)
        (kill-buffer buf-b))))

  (it "should not schedule a refresh when automatic refresh is disabled"
    (spy-on 'run-with-idle-timer)
    (let ((ratex-theme-change-refresh-scope nil))
      (ratex--schedule-theme-refresh)
      (expect 'run-with-idle-timer :not :to-have-been-called))))

(describe "ratex-render bulk math fragment detection"
  (it "should detect multiple mathematical fragments in a single buffer"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b \\[y+1\\] c")
      (let ((fragments (ratex-fragments-in-buffer)))
        (expect (length fragments) :to-be 2)
        (expect (mapcar (lambda (f) (plist-get f :content)) fragments)
                :to-equal '("x" "y+1")))))

  (it "should respect range limits when scanning a buffer"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b \\(y\\) c")
      (let ((fragments (ratex-fragments-in-buffer 9 (point-max))))
        (expect (length fragments) :to-be 1)
        (expect (plist-get (car fragments) :content) :to-equal "y")))))

(describe "ratex-render rendering coordination"
  (it "should queue visible fragments for rendering while excluding the active fragment"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b \\(y\\) c")
      (goto-char 6)
      (let* ((fragments (ratex-fragments-in-buffer))
             (active (ratex-fragment-at-point))
             (targets (ratex--fragments-to-render fragments active)))
        (expect (length fragments) :to-be 2)
        (expect (length targets) :to-be 1)
        (expect (plist-get (car targets) :content) :to-equal "y"))))

  (it "should render all non-active previews when refreshing"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b \\(y\\) c")
      (goto-char 6)
      (let (rendered)
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) rendered)))
        (spy-on 'ratex--drop-stale-overlays :and-return-value nil)
        (spy-on 'ratex--visible-fragments :and-call-fake
                (lambda () (ratex-fragments-in-buffer)))
        (spy-on 'ratex--schedule-full-refresh-scan :and-return-value nil)
        (ratex-refresh-previews)
        (expect rendered :to-equal '("y")))))

  (it "should render all previews including active when include-active is non-nil"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b \\(y\\) c")
      (goto-char 6)
      (let (rendered)
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) rendered)))
        (spy-on 'ratex--drop-stale-overlays :and-return-value nil)
        (spy-on 'ratex--visible-fragments :and-call-fake
                (lambda () (ratex-fragments-in-buffer)))
        (spy-on 'ratex--schedule-full-refresh-scan :and-return-value nil)
        (ratex-refresh-previews t)
        (expect (sort rendered #'string<) :to-equal '("x" "y")))))

  (it "should queue refresh tasks and run them in batch sizes"
    (with-temp-buffer
      (latex-mode)
      (let ((ratex--refresh-batch-size 2)
            rendered)
        (insert "\\(a\\) \\(b\\) \\(c\\)")
        (setq-local ratex-mode t)
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) rendered)))
        (spy-on 'ratex--drop-stale-overlays :and-return-value nil)
        (spy-on 'ratex--visible-fragments :and-call-fake
                (lambda () (ratex-fragments-in-buffer)))
        (spy-on 'ratex--schedule-refresh-batch :and-return-value nil)
        (spy-on 'ratex--schedule-full-refresh-scan :and-return-value nil)
        (ratex-refresh-previews t)
        (expect (sort rendered #'string<) :to-equal '("a" "b"))
        (expect (length ratex--refresh-queue) :to-be 1)))))

(describe "ratex-render cache key generation"
  (it "should generate different cache keys when render colours change"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (ratex-render-color "#000000")
             (key-a (ratex--cache-key fragment))
             (ratex-render-color "#ffffff")
             (key-b (ratex--cache-key fragment)))
        (expect key-a :not :to-equal key-b))))

  (it "should generate different cache keys when theme-aware render colours change"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (ratex-render-color nil)
             (ratex-dark-render-color "#ffffff")
             (ratex-light-render-color "#000000")
             (bg-mode 'dark))
        (spy-on 'frame-parameter :and-call-fake (lambda (&rest _args) bg-mode))
        (let ((key-a (ratex--cache-key fragment)))
          (setq bg-mode 'light)
          (let ((key-b (ratex--cache-key fragment)))
            (expect key-a :not :to-equal key-b))))))

  (it "should generate different cache keys when the font directory changes"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (ratex-font-dir "/tmp/fonts-a")
             (key-a (ratex--cache-key fragment))
             (ratex-font-dir "/tmp/fonts-b")
             (key-b (ratex--cache-key fragment)))
        (expect key-a :not :to-equal key-b)))))

(describe "ratex-render error handling"
  (it "should display render errors in error-indicative SVG overlays with correctly escaped XML entities"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(\\bad{\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (fragment-key (ratex--fragment-key fragment))
             shown)
        (spy-on 'create-image :and-call-fake
                (lambda (data type data-p &rest props)
                  (list :data data :type type :data-p data-p :props props)))
        (spy-on 'ratex-show-overlay :and-call-fake
                (lambda (key beg end image help-echo overlay-fragment style)
                  (setq shown (list key beg end image help-echo overlay-fragment style))))
        (ratex--display-response
         fragment-key
         fragment
         '((ok . :false) (error . "parse error: expected } <and>")))
        (expect ratex--last-error :to-equal "parse error: expected } <and>")
        (expect (nth 0 shown) :to-equal fragment-key)
        (expect (string-match-p "#fff59d" (plist-get (nth 3 shown) :data)) :not :to-be nil)
        (expect (string-match-p "#c00000" (plist-get (nth 3 shown) :data)) :not :to-be nil)
        (expect (string-match-p "&lt;and&gt;" (plist-get (nth 3 shown) :data)) :not :to-be nil)
        (expect (nth 4 shown) :to-equal "RaTeX render failed: parse error: expected } <and>")))))

(describe "ratex-render preview initialisation and tracking"
  (it "should render all previews on initialisation then hide the active fragment overlay"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b")
      (goto-char 5)
      (let (include-active removed-key)
        (spy-on 'ratex-refresh-previews :and-call-fake
                (lambda (&optional include)
                  (setq include-active include)))
        (spy-on 'ratex-remove-overlay :and-call-fake
                (lambda (key)
                  (setq removed-key key)))
        (ratex-initialize-previews)
        (expect include-active :not :to-be nil)
        (expect removed-key :to-equal "3:8:x")
        (expect (plist-get ratex--active-fragment :content) :to-equal "x"))))

  (it "should hide overlays when the cursor enters a fragment and render them when it leaves"
    (with-temp-buffer
      (latex-mode)
      (insert "a \\(x\\) b")
      (let (removed ensured)
        (setq-local ratex-mode t)
        (setq-local ratex--active-fragment nil)
        (spy-on 'ratex-remove-overlay :and-call-fake
                (lambda (key)
                  (push key removed)))
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) ensured)))
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
      (goto-char 4)
      (setq-local ratex-mode t)
      (setq-local ratex--active-fragment (ratex-fragment-at-point))
      (insert "y")
      (let (removed ensured)
        (spy-on 'ratex-remove-overlay :and-call-fake
                (lambda (key)
                  (push key removed)))
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) ensured)))
        (ratex-handle-post-command)
        (expect removed :to-be nil)
        (expect ensured :to-be nil))))

  (it "should expand the inline overlay fallback when moving point inside a rendered formula"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)z")
      (let ((fragment '(:begin 1 :end 6 :content "x" :open "\\(" :close "\\)"))
            ensured)
        (setq-local ratex-mode t)
        (setq-local ratex--active-fragment nil)
        (ratex-show-overlay "1:6:x" 1 6 "IMG" nil fragment)
        (goto-char 3)
        (spy-on 'ratex-fragment-at-point :and-return-value nil)
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (value)
                  (push (plist-get value :content) ensured)))
        (ratex-handle-post-command)
        (expect (ratex-rendered-overlay-at-point-p) :to-be nil)
        (expect (plist-get ratex--active-fragment :content) :to-equal "x")
        (goto-char 7)
        (ratex-handle-post-command)
        (expect ensured :to-equal '("x")))))

(describe "ratex-render minibuffer edit preview"
  (it "should update minibuffer edit preview after a live edit"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (goto-char 3)
      (setq-local ratex-mode t)
      (setq-local ratex-edit-preview 'minibuffer)
      (setq-local ratex--preview-enabled t)
      (setq-local ratex--active-fragment (ratex-fragment-at-point))
      (setq-local ratex--minibuffer-visible t)
      (setq-local ratex--minibuffer-fragment ratex--active-fragment)
      (insert "y")
      (let (hidden ensured)
        (spy-on 'ratex--hide-minibuffer :and-call-fake
                (lambda ()
                  (setq hidden t)))
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) ensured)))
        (ratex-handle-post-command)
        (expect hidden :to-be nil)
        (expect ensured :to-equal '("yx")))))

  (it "should keep old minibuffer image preview until replacement occurs"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (goto-char 3)
      (setq-local ratex-mode t)
      (setq-local ratex-edit-preview 'minibuffer)
      (setq-local ratex--preview-enabled t)
      (setq-local ratex--active-fragment (ratex-fragment-at-point))
      (setq-local ratex--minibuffer-visible t)
      (setq-local ratex--minibuffer-fragment ratex--active-fragment)
      (setq-local ratex--minibuffer-image "OLD-IMAGE")
      (insert "y")
      (let (messages ensured)
        (spy-on 'message :and-call-fake
                (lambda (format-string &rest args)
                  (push (and format-string (apply #'format format-string args))
                        messages)))
        (spy-on 'ratex--ensure-fragment-preview :and-call-fake
                (lambda (fragment)
                  (push (plist-get fragment :content) ensured)))
        (ratex-handle-post-command)
        (expect ensured :to-equal '("yx"))
        (expect (length messages) :to-be 1)
        (expect (car messages) :not :to-be nil)
        (expect (car messages) :not :to-equal ""))))

  (it "should replace minibuffer preview image and visibility state"
    (with-temp-buffer
      (let ((fragment '(:begin 1 :end 6 :content "x" :open "\\(" :close "\\)"))
            message-text)
        (spy-on 'message :and-call-fake
                (lambda (format-string &rest args)
                  (setq message-text (apply #'format format-string args))))
        (ratex--replace-minibuffer-preview fragment "NEW-IMAGE")
        (expect message-text :not :to-be nil)
        (expect ratex--minibuffer-visible :not :to-be nil)
        (expect ratex--minibuffer-fragment :to-equal fragment)
        (expect ratex--minibuffer-image :to-equal "NEW-IMAGE"))))

  (it "should update minibuffer preview on display-if-visible when matching active fragment"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(x\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (key (ratex--fragment-key fragment))
             displayed)
        (goto-char 3)
        (setq-local ratex-mode t)
        (setq-local ratex-edit-preview 'minibuffer)
        (setq-local ratex--preview-enabled t)
        (setq-local ratex--active-fragment fragment)
        (spy-on 'ratex--display-minibuffer :and-call-fake
                (lambda (value _response &optional _image)
                  (setq displayed (plist-get value :content))
                  t))
        (spy-on 'ratex-remove-overlay :and-return-value nil)
        (ratex--display-if-visible
         key fragment '((ok . t) (svg . "<svg/>") (baseline . 1.0) (height . 1.0)))
        (expect displayed :to-equal "x"))))

  (it "should display an error in the minibuffer when rendering fails"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(\\bad{\\)")
      (let* ((fragment (car (ratex-fragments-in-buffer)))
             (key (ratex--fragment-key fragment))
             displayed)
        (goto-char 4)
        (setq-local ratex-mode t)
        (setq-local ratex-edit-preview 'minibuffer)
        (setq-local ratex--preview-enabled t)
        (setq-local ratex--active-fragment fragment)
        (setq-local ratex--minibuffer-visible t)
        (setq-local ratex--minibuffer-fragment fragment)
        (spy-on 'message :and-call-fake
                (lambda (format-string &rest args)
                  (setq displayed (apply #'format format-string args))))
        (spy-on 'ratex-remove-overlay :and-return-value nil)
        (ratex--display-if-visible
         key fragment '((ok . :false) (error . "parse error")))
        (expect displayed :not :to-be nil)
        (expect displayed :not :to-equal "")))))

(describe "ratex-render process coordination"
  (it "should process multiple requests for the same formula through a single async render call"
    (with-temp-buffer
      (latex-mode)
      (insert "\\(A\\) xx \\(A\\)")
      (let* ((fragments (ratex-fragments-in-buffer))
             (first (nth 0 fragments))
             (second (nth 1 fragments))
             (first-key (ratex--fragment-key first))
             (second-key (ratex--fragment-key second))
             (request-count 0)
             callback
             seen)
        (setq-local ratex-mode t)
        (ratex-reset-buffer-state)
        (spy-on 'ratex-render-math-async :and-call-fake
                (lambda (_math-string cb)
                  (setq request-count (1+ request-count))
                  (setq callback cb)))
        (spy-on 'ratex--display-if-visible :and-call-fake
                (lambda (fragment-key _fragment _response)
                  (push fragment-key seen)))
        (ratex--ensure-fragment-preview first)
        (ratex--ensure-fragment-preview second)
        (expect request-count :to-be 1)
        (funcall callback "<svg/>")
        (expect (sort seen #'string<)
                :to-equal (sort (list first-key second-key) #'string<)))))))

(provide 'ratex-tests)

;;; ratex-tests.el ends here
