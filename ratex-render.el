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
(defvar-local ratex--inflight-requests nil)
(defvar-local ratex--inflight-waiters nil)
(defvar-local ratex--last-error nil)
(defvar-local ratex--active-fragment nil)
(defvar-local ratex--refresh-timer nil)
(defvar-local ratex--refresh-scan-timer nil)
(defvar-local ratex--refresh-queue nil)
(defvar-local ratex--refresh-generation 0)

(defconst ratex--refresh-batch-size 50)

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
  (let ((col (if (or (null ratex-color) (equal ratex-color "default"))
                 (or (frame-parameter nil 'foreground-color)
                     (face-attribute 'default :foreground nil t)
                     "black")
               ratex-color)))
    (if (or (null col) (equal col "unspecified"))
        "black"
      col)))

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
                :sentinel (lambda (process event)
                            (when (string-match-p "finished" event)
                              (let ((raw-output (with-current-buffer (process-buffer process)
                                                  (buffer-string)))
                                    (svg-list nil)
                                    (start 0))
                                
                                (while (string-match "<svg" raw-output start)
                                  (let* ((svg-start (match-beginning 0))
                                         (svg-end (string-match "</svg>" raw-output svg-start)))
                                    (when svg-end
                                      (push (substring raw-output svg-start (+ svg-end 6)) svg-list)
                                      (setq start (+ svg-end 6)))))
                                
                                (when (buffer-live-p origin-buffer)
                                  (with-current-buffer origin-buffer
                                    (funcall callback (nreverse svg-list)))))
                              (kill-buffer (process-buffer process)))))))
    (process-send-string proc (concat payload "\n"))
    (process-send-eof proc)))

(defun ratex-reset-buffer-state ()
  "Reset buffer-local rendering state."
  (setq-local ratex--render-cache (make-hash-table :test #'equal))
  (setq-local ratex--inflight-requests (make-hash-table :test #'equal))
  (setq-local ratex--inflight-waiters (make-hash-table :test #'equal))
  (setq-local ratex--last-error nil)
  (setq-local ratex--active-fragment nil)
  (ratex--cancel-refresh-timer)
  (setq-local ratex--refresh-queue nil)
  (setq-local ratex--refresh-generation 0))

(defun ratex-refresh-previews (&optional include-active)
  "Refresh math previews in current buffer.

When INCLUDE-ACTIVE is non-nil, render all formulas, including the one
currently under point."
  (interactive)
  (ratex--cancel-refresh-timer)
  (when (hash-table-p ratex--render-cache)
    (clrhash ratex--render-cache))
  (ratex-clear-overlays)
  (cl-incf ratex--refresh-generation)
  (let* ((fragments (ratex--visible-fragments))
         (active (ratex-fragment-at-point))
         (targets (if include-active
                      fragments
                    (ratex--fragments-to-render fragments active))))
    (ratex--enqueue-refresh-targets targets)
    (ratex--schedule-full-refresh-scan include-active ratex--refresh-generation)))

(defun ratex-initialize-previews ()
  "Render all formulas once and initialize point tracking."
  (ratex-refresh-previews t)
  (setq ratex--active-fragment (ratex-fragment-at-point))
  (when ratex--active-fragment
    (ratex-remove-overlay (ratex--fragment-key ratex--active-fragment))))

(defun ratex-handle-post-command ()
  "Update state and run hooks when point enters or leaves math fragments."
  (when ratex-mode
    (let ((current (ratex--active-fragment-at-point))
          (previous ratex--active-fragment))
      (unless (and previous current
                   (ratex--same-active-context-p previous current))
        
        (when previous
          (run-hook-with-args 'ratex-leave-fragment-hook previous)
          (ratex--ensure-fragment-preview previous))
        
        (when current
          (ratex-remove-overlay (ratex--fragment-key current))
          (let* ((cache-key (ratex--cache-key current))
                 (cached (gethash cache-key ratex--render-cache))
                 (image (when (and cached (ratex--response-ok-p cached))
                          (ratex--image-from-response cached))))
            (run-hook-with-args 'ratex-enter-fragment-hook current image))))
      
      (setq ratex--active-fragment current))))

(defun ratex--visible-fragments ()
  "Return fragments in the visible portion of the selected window."
  (let* ((window (selected-window))
         (beg (max (point-min) (window-start window)))
         (end (min (point-max) (window-end window t))))
    (ratex-fragments-in-buffer beg end)))

(defun ratex--render-batch (fragments)
  "Render a list of FRAGMENTS in batch using `ratex-render-math-batch-async'."
  (let (to-render)
    (dolist (fragment fragments)
      (let* ((fragment-key (ratex--fragment-key fragment))
             (cache-key (ratex--cache-key fragment))
             (cached (gethash cache-key ratex--render-cache))
             (inflight (gethash cache-key (ratex--inflight-table))))
        (cond
         ((not (ratex--fragment-valid-p fragment))
          (ratex-remove-overlay fragment-key))
         (cached
          (ratex--display-response fragment-key fragment cached))
         (inflight
          (ratex--enqueue-waiter cache-key fragment-key fragment))
         (t
          (ratex--enqueue-waiter cache-key fragment-key fragment)
          (puthash cache-key t (ratex--inflight-table))
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
                              (response (if svg
                                            `((ok . t) (svg . ,svg))
                                          `((ok . nil) (error . "Failed to render SVG")))))
                         (remhash cache-key (ratex--inflight-table))
                         (let ((waiters (gethash cache-key (ratex--inflight-waiters-table))))
                           (remhash cache-key (ratex--inflight-waiters-table))
                           (puthash cache-key response ratex--render-cache)
                           (when ratex-mode
                             (dolist (entry waiters)
                               (ratex--display-if-visible
                                (car entry)
                                (cdr entry)
                                response))))))))))))

(defun ratex--enqueue-refresh-targets (targets)
  "Render TARGETS in bounded batches."
  (let ((generation ratex--refresh-generation)
        (first-batch (seq-take targets ratex--refresh-batch-size))
        (rest (nthcdr ratex--refresh-batch-size targets)))
    (setq ratex--refresh-queue rest)
    (ratex--render-batch first-batch)
    (when ratex--refresh-queue
      (ratex--schedule-refresh-batch generation))))

(defun ratex--schedule-refresh-batch (generation)
  "Schedule the next refresh batch for GENERATION."
  (setq ratex--refresh-timer
        (run-with-idle-timer
         0.05 nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (ratex--run-refresh-batch generation))))
         (current-buffer))))

(defun ratex--schedule-full-refresh-scan (include-active generation)
  "Schedule a full-buffer scan for INCLUDE-ACTIVE and GENERATION."
  (setq ratex--refresh-scan-timer
        (run-with-idle-timer
         0.2 nil
         (lambda (buffer)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (ratex--run-full-refresh-scan include-active generation))))
         (current-buffer))))

(defun ratex--run-full-refresh-scan (include-active generation)
  "Scan the whole buffer and enqueue remaining previews."
  (setq ratex--refresh-scan-timer nil)
  (when (and ratex-mode (= generation ratex--refresh-generation))
    (let* ((fragments (ratex-fragments-in-buffer))
           (active (ratex-fragment-at-point))
           (targets (if include-active
                        fragments
                      (ratex--fragments-to-render fragments active)))
           (target-keys (mapcar #'ratex--fragment-key targets)))
      (ratex--drop-stale-overlays target-keys)
      (ratex--enqueue-refresh-targets targets))))

(defun ratex--run-refresh-batch (generation)
  "Render one queued refresh batch for GENERATION."
  (setq ratex--refresh-timer nil)
  (when (and ratex-mode
             (= generation ratex--refresh-generation)
             ratex--refresh-queue)
    (let ((batch (seq-take ratex--refresh-queue ratex--refresh-batch-size)))
      (setq ratex--refresh-queue (nthcdr ratex--refresh-batch-size ratex--refresh-queue))
      (ratex--render-batch batch)
      (when ratex--refresh-queue
        (ratex--schedule-refresh-batch generation)))))

(defun ratex--cancel-refresh-timer ()
  "Cancel the current refresh timer, if any."
  (when (timerp ratex--refresh-timer)
    (cancel-timer ratex--refresh-timer))
  (when (timerp ratex--refresh-scan-timer)
    (cancel-timer ratex--refresh-scan-timer))
  (setq ratex--refresh-timer nil)
  (setq ratex--refresh-scan-timer nil))

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
  (let* ((svg (alist-get 'svg response))
         (baseline (alist-get 'baseline response))
         (height (alist-get 'height response))
         (current-scale (if (bound-and-true-p text-scale-mode)
                            (expt text-scale-mode-step text-scale-mode-amount)
                          1.0))
         (ascent-val (if (and baseline height (> height 0))
                         (floor (* 100.0 (/ baseline height)))
                       'center)))
    (when svg
      (create-image
       svg
       'svg t
       :scale current-scale
       :ascent ascent-val))))

(defun ratex--preview-image-from-response (response)
  "Build a preview image from backend RESPONSE, including errors."
  (if (ratex--response-ok-p response)
      (ratex--image-from-response response)
    (ratex--error-image (alist-get 'error response))))

(defun ratex--response-ok-p (response)
  "Return non-nil when backend RESPONSE is successful."
  (eq (alist-get 'ok response) t))

(defun ratex--escape-svg-text (text)
  "Escape TEXT for use inside SVG character data."
  (replace-regexp-in-string
   "[&<>\"]"
   (lambda (match)
     (pcase match
       ("&" "&amp;")
       ("<" "&lt;")
       (">" "&gt;")
       ("\"" "&quot;")))
   (or text "")
   t t))

(defun ratex--error-svg (error)
  "Return an SVG image that displays ERROR."
  (let* ((raw-text (or error "unknown error"))
         (font-size 13)
         (padding-x 8)
         (padding-y 5)
         (max-chars 96)
         (shown (if (> (length raw-text) max-chars)
                    (concat (substring raw-text 0 (- max-chars 3)) "...")
                  raw-text))
         (text (ratex--escape-svg-text shown))
         (width (+ (* 8 (max 1 (length shown))) (* 2 padding-x)))
         (height (+ font-size (* 2 padding-y))))
    (format
     "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\"><rect width=\"100%%\" height=\"100%%\" fill=\"#fff59d\"/><text x=\"%d\" y=\"%d\" fill=\"#c00000\" font-family=\"monospace\" font-size=\"%d\">%s</text></svg>"
     width height width height padding-x (+ padding-y font-size -2) font-size text)))

(defun ratex--error-image (error)
  "Build an image object that displays ERROR."
  (create-image (ratex--error-svg error) 'svg t :ascent 80))

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

(defun ratex--inflight-table ()
  "Return request-tracking table for current buffer."
  (unless (hash-table-p ratex--inflight-requests)
    (setq-local ratex--inflight-requests (make-hash-table :test #'equal)))
  ratex--inflight-requests)

(defun ratex--inflight-waiters-table ()
  "Return waiter table for in-flight requests in current buffer."
  (unless (hash-table-p ratex--inflight-waiters)
    (setq-local ratex--inflight-waiters (make-hash-table :test #'equal)))
  ratex--inflight-waiters)

(defun ratex--enqueue-waiter (cache-key fragment-key fragment)
  "Track FRAGMENT for CACHE-KEY while backend render is in flight."
  (let* ((table (ratex--inflight-waiters-table))
         (waiters (gethash cache-key table)))
    (unless (assoc fragment-key waiters)
      (puthash cache-key
               (cons (cons fragment-key fragment) waiters)
               table))))

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

(defun ratex--drop-stale-overlays (target-keys)
  "Delete overlays not present in TARGET-KEYS."
  (let ((keep (make-hash-table :test #'equal)))
    (dolist (key target-keys)
      (puthash key t keep))
    (dolist (key (ratex-overlay-keys))
      (unless (gethash key keep)
        (ratex-remove-overlay key)))))

(defun ratex--ensure-fragment-preview (fragment)
  "Ensure FRAGMENT preview is displayed or requested."
  (ratex--render-batch (list fragment)))

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
      (progn
        (setq ratex--last-error (alist-get 'error response))
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         (ratex--error-image ratex--last-error)
         (format "RaTeX render failed: %s" ratex--last-error)
         fragment)
        (when ratex--last-error
          (message "RaTeX render failed: %s" ratex--last-error)))
    (let ((image (ratex--image-from-response response)))
      (setq ratex--last-error nil)
      (if (ratex--point-in-fragment-p fragment)
          (ratex-remove-overlay fragment-key)
        (ratex-show-overlay
         fragment-key
         (plist-get fragment :begin)
         (plist-get fragment :end)
         image
         (format "RaTeX %s" (if (alist-get 'cached response) "cached" "rendered"))
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
