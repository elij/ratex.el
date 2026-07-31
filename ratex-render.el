;;; ratex-render.el --- Async rendering client -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ratex-math-detect)
(require 'ratex-overlays)

(defvar ratex-mode)

(defgroup ratex nil
  "Inline maths rendering with RaTeX."
  :group 'tex)

(defcustom ratex-font-size 16.0
  "Default backend SVG font size."
  :type 'number)

(defcustom ratex-color "default"
  "Formula colour passed to the backend renderer.
Can be a colour name (for example \"white\" or \"black\"), a hex code,
or \"default\" to automatically use the frame foreground colour."
  :type 'string)

(defcustom ratex-executable-path "render-svg"
  "The path to the render-svg executable.
Set this to an absolute path if the binary is not in your exec-path."
  :type 'string)

(defvar-local ratex--render-cache nil)
(defvar-local ratex--active-fragment nil)

(defvar ratex-enter-fragment-hook nil
  "Hook run when point enters a RaTeX math fragment.
Functions receive two arguments: the FRAGMENT property list and the
rendered SVG image object (if available in the cache).")

(defvar ratex-leave-fragment-hook nil
  "Hook run when point leaves a RaTeX math fragment.
Functions receive one argument: the FRAGMENT property list that was
just exited.")

(defun ratex--effective-color ()
  "Return effective formula colour string for rendering."
  (if-let* ((col ratex-color)
            ((not (member col '("default" "unspecified" "")))))
      col
    (or (frame-parameter nil 'foreground-color)
        (face-attribute 'default :foreground nil t)
        "black")))

(defun ratex-render-math-batch-async (math-strings callback)
  "Render a list of MATH-STRINGS via the backend and pass the results to CALLBACK."
  (let* ((origin-buffer (current-buffer))
         (output-buf (generate-new-buffer " *ratex-svg-batch*"))
         (cmd `(,ratex-executable-path "--stdout"
                                       "--font-size" ,(number-to-string ratex-font-size)
                                       "--color" ,(ratex--effective-color)))
         
         (payload (mapconcat (lambda (s) (replace-regexp-in-string "[\r\n]+" " " s))
                             math-strings
                             "\n"))
         
         (proc (make-process
                :name "ratex-render-batch"
                :buffer output-buf
                :command cmd
                :connection-type 'pipe
                :sentinel
                (lambda (process event)
                  (when (string-match-p "finished" event)
                    (let ((raw-output (with-current-buffer (process-buffer process)
                                        (buffer-string)))
                          (svg-list nil)
                          (start 0))
                      
                      (while (string-match "<svg" raw-output start)
                        (when-let* ((svg-start (match-beginning 0))
                                    (svg-end (string-match "</svg>" raw-output svg-start)))
                          (push (substring raw-output svg-start (+ svg-end 6)) svg-list)
                          (setq start (+ svg-end 6))))
                      
                      (when (buffer-live-p origin-buffer)
                        (with-current-buffer origin-buffer
                          (funcall callback (nreverse svg-list)))))
                    (kill-buffer (process-buffer process)))))))
    (process-send-string proc (concat payload "\n"))
    (process-send-eof proc)))

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--active-fragment nil))

(defun ratex-refresh-previews (&optional include-active)
  "Refresh math previews in current buffer."
  (interactive)
  (ratex-clear-overlays)
  (let* ((fragments (ratex-fragments-in-buffer))
         (active (ratex-fragment-at-point))
         (targets (if include-active
                      fragments
                    (ratex--fragments-to-render fragments active))))
    (ratex--render-batch targets)))

(defun ratex-initialize-previews ()
  "Render all formulas once and initialize point tracking."
  (ratex-refresh-previews t)
  (when-let* ((active (setq ratex--active-fragment (ratex-fragment-at-point))))
    (ratex-remove-overlay (ratex--fragment-key active))))

(defun ratex-handle-post-command ()
  "Update state and run hooks when point enters or leaves math fragments."
  (when ratex-mode
    (let ((current (ratex--active-fragment-at-point))
          (previous ratex--active-fragment))
      (unless (and previous current
                   (ratex--same-active-context-p previous current))
        
        (when previous
          (run-hook-with-args 'ratex-leave-fragment-hook previous)
          (ratex--render-batch (list previous)))
        
        (when current
          (ratex-remove-overlay (ratex--fragment-key current))
          (let* ((cache-key (ratex--cache-key current))
                 (cached (gethash cache-key ratex--render-cache))
                 (image (and cached 
                             (ratex--response-ok-p cached) 
                             (ratex--image-from-response cached))))
            (run-hook-with-args 'ratex-enter-fragment-hook current image))))
      
      (setq ratex--active-fragment current))))

(defun ratex--render-batch (fragments)
  "Render a list of FRAGMENTS in a single asynchronous batch."
  (unless (hash-table-p ratex--render-cache)
    (setq-local ratex--render-cache (make-hash-table :test #'equal)))
  (let (to-render)
    (dolist (fragment fragments)
      (let* ((fragment-key (ratex--fragment-key fragment))
             (cache-key (ratex--cache-key fragment))
             (cached (gethash cache-key ratex--render-cache)))
        (cond
         ((not (ratex--fragment-valid-p fragment))
          (ratex-remove-overlay fragment-key))
         (cached
          (ratex--display-response fragment-key fragment cached))
         (t
          (push fragment to-render)))))
    (when to-render
      (setq to-render (nreverse to-render))
      (let ((math-strings (mapcar (lambda (f) (plist-get f :content)) to-render)))
        (ratex-render-math-batch-async
         math-strings
         (lambda (svg-list)
           (cl-loop for f in to-render
                    for svg in svg-list
                    do (let* ((cache-key (ratex--cache-key f))
                              (fragment-key (ratex--fragment-key f))
                              (response (if svg
                                            `((ok . t) (svg . ,svg))
                                          `((ok . nil) (error . "Failed to render SVG")))))
                         (puthash cache-key response ratex--render-cache)
                         (when ratex-mode
                           (ratex--display-if-visible fragment-key f response))))))))))

(defun ratex--overlay-image-for-fragment (fragment)
  "Return cached overlay image for FRAGMENT, or nil."
  (let ((key (ratex--fragment-key fragment)))
    (ratex-overlay-image-for-key key)))

(defun ratex--cached-response-for-fragment (fragment)
  "Return cached backend response for FRAGMENT, or nil."
  (let ((cache-key (ratex--cache-key fragment)))
    (when (hash-table-p ratex--render-cache)
      (gethash cache-key ratex--render-cache))))

(defun ratex--image-from-response (response)
  "Build an image object from backend RESPONSE."
  (when-let* ((svg (alist-get 'svg response)))
    (let* ((baseline (alist-get 'baseline response))
           (height (alist-get 'height response))
           (current-scale (if (bound-and-true-p text-scale-mode)
                              (expt text-scale-mode-step text-scale-mode-amount)
                            1.0))
           (ascent-val (if (and baseline height (> height 0))
                           (floor (* 100.0 (/ baseline height)))
                         'center)))
      (create-image
       svg
       'svg t
       :scale current-scale
       :ascent ascent-val))))

(defun ratex--response-ok-p (response)
  "Return non-nil when backend RESPONSE is successful."
  (eq (alist-get 'ok response) t))

(defun ratex--active-fragment-at-point ()
  "Return editable fragment at point, including rendered overlay fallback."
  (or (ratex-fragment-at-point)
      (ratex-overlay-fragment-at-point)
      (when (ratex--point-in-fragment-p ratex--active-fragment)
        ratex--active-fragment)))

(defun ratex--point-in-fragment-p (fragment)
  "Return non-nil if point is within FRAGMENT."
  (when fragment
    (let ((begin (plist-get fragment :begin))
          (end (plist-get fragment :end)))
      (and (integer-or-marker-p begin)
           (integer-or-marker-p end)
           (<= begin (point))
           (< (point) end)))))

(defun ratex--fragments-to-render (fragments active)
  "Return FRAGMENTS excluding ACTIVE."
  (cl-remove-if
   (lambda (fragment)
     (and active (ratex--same-fragment-p fragment active)))
   fragments))

(defun ratex--same-fragment-p (a b)
  "Return non-nil when fragments A and B represent the same range."
  (and (= (plist-get a :begin) (plist-get b :begin))
       (= (plist-get a :end) (plist-get b :end))
       (equal (plist-get a :content) (plist-get b :content))))

(defun ratex--same-active-context-p (a b)
  "Return non-nil when A and B are part of the same editing fragment."
  (or (ratex--same-fragment-p a b)
      (ratex--fragments-overlap-p a b)))

(defun ratex--fragment-key (fragment)
  "Return stable overlay key for FRAGMENT."
  (format "%d:%d:%s"
          (plist-get fragment :begin)
          (plist-get fragment :end)
          (plist-get fragment :content)))

(defun ratex--cache-key (fragment)
  "Return render cache key for FRAGMENT."
  (list (string-trim (plist-get fragment :content))
        ratex-font-size
        (ratex--effective-color)))

(defun ratex--fragment-valid-p (fragment)
  "Return non-nil when FRAGMENT still matches current buffer text."
  (let ((begin (plist-get fragment :begin))
        (end (plist-get fragment :end))
        (open (plist-get fragment :open))
        (content (plist-get fragment :content))
        (close (plist-get fragment :close)))
    (and (integer-or-marker-p begin)
         (integer-or-marker-p end)
         (<= (point-min) begin end (point-max))
         (string= (buffer-substring-no-properties begin end)
                  (concat open content close)))))

(defun ratex--display-if-visible (fragment-key fragment response)
  "Display RESPONSE for FRAGMENT-KEY if FRAGMENT should still be visible."
  (let ((active (ratex--active-fragment-at-point)))
    (cond
     ((not (ratex--fragment-valid-p fragment))
      (ratex-remove-overlay fragment-key))
     ((and active (ratex--same-active-context-p fragment active))
      (ratex-remove-overlay fragment-key))
     (t
      (ratex--display-response fragment-key fragment response)))))

(defun ratex--display-response (fragment-key fragment response)
  "Display backend RESPONSE for FRAGMENT identified by FRAGMENT-KEY."
  (if (not (ratex--response-ok-p response))
      (when-let* ((err (alist-get 'error response)))
        (message "RaTeX render failed: %s" err)
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         (propertize " [RaTeX Error] " 'face 'error)
         (format "RaTeX render failed: %s" err)
         fragment))
    (when-let* ((image (ratex--image-from-response response)))
      (if (ratex--point-in-fragment-p fragment)
          (ratex-remove-overlay fragment-key)
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         image
         (if (alist-get 'cached response) "RaTeX cached" "RaTeX rendered")
         fragment)))))

(defun ratex--fragments-overlap-p (a b)
  "Return non-nil if fragment A overlaps fragment B."
  (let ((ab (plist-get a :begin))
        (ae (plist-get a :end))
        (bb (plist-get b :begin))
        (be (plist-get b :end)))
    (and (< ab be) (< bb ae))))

(provide 'ratex-render)

;;; ratex-render.el ends here
