# ratex.el

> [!NOTE]  
This is a fork of [ratex.el](https://github.com/gongshangzheng/ratex.el) with changes that can no longer be merged upstream. Doesn't have the ratex RPC (instead uses batch CLI) and uses tex-mode.el for parsing. While it is compatible with GPL 3, this hasn't been defined by the original author.


[简体中文](./README.zh-CN.md)

`ratex.el` is an Emacs-focused inline maths preview package built on top of the upstream [RaTeX](https://github.com/erweixin/RaTeX) engine.

It is designed to render LaTeX maths fragments inside Emacs with a small async backend, SVG output, and minimal setup.

## Demo

![ratex.el demo](./assets/demo.gif)

## Features

- Async inline maths preview inside Emacs
- SVG rendering backed by RaTeX
- Batch rendering of maths fragments via `ratex-render-math-batch-async`
- Entry and exit hooks for fragment interaction via `ratex-enter-fragment-hook` and `ratex-leave-fragment-hook`
- Lightweight in-buffer rendering flow
- Works with `latex-mode`, `LaTeX-mode`, `org-mode`, and `markdown-mode`

## Repository layout

- `ratex.el`: core minor mode, user commands, and global setup
- `ratex-render.el`: asynchronous batch rendering engine executing `ratex-executable-path`
- `ratex-overlays.el`: overlay management and image display lifecycle
- `ratex-math-detect.el`: LaTeX maths delimiter parsing and fragment detection

## Requirements

- Emacs 29.1 or newer
- A checkout with submodules initialised
- The `render-svg` executable (or path configured via `ratex-executable-path`)

## Installation


```elisp
(package-vc-install '(ratex :url "https://github.com/elij/ratex.el"))
```

Or

```elisp
(add-to-list 'load-path "/path/to/ratex.el")
(require 'ratex)
```

Or

```elisp
(use-package ratex
  :vc (:url "https://github.com/elij/ratex.el")
  :config
  (global-ratex-mode 1))
```

Enable it manually in the current buffer:

```elisp
M-x ratex-mode
```

Or enable it automatically for common text and maths modes:

```elisp
(require 'ratex)
(global-ratex-mode 1)
```

In Org files, you can also control RaTeX per file with a keyword:

```org
#+ratex: t
```

Use `#+ratex: nil` (or `off`) to disable it for a specific Org file, even when `global-ratex-mode` is enabled.

Equivalent explicit hook setup:

```elisp
(add-hook 'latex-mode-hook #'ratex-mode)
(add-hook 'LaTeX-mode-hook #'ratex-mode)
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
```

## How it works

Maths fragments are rendered asynchronously in batches using `ratex-render-math-batch-async`, which executes the binary configured by `ratex-executable-path` (defaulting to `"render-svg"`). The process passes fragment content strings to the executable and receives rendered SVG data in response.

When point moves into or out of maths fragments, `ratex.el` triggers dedicated hooks:
- `ratex-enter-fragment-hook`: executed when point enters a fragment. Hook functions receive two arguments: the fragment property list and the cached SVG image object (or `nil` if not cached).
- `ratex-leave-fragment-hook`: executed when point leaves a fragment. Hook functions receive one argument: the fragment property list that was exited.

By default, when point enters a fragment, its inline overlay preview is hidden. When point leaves that fragment, it is rendered again and updated asynchronously.

## Usage

The interaction model operates as follows:
- When `ratex-mode` is enabled, visible formulas in the current buffer are rendered once.
- When point enters a maths fragment, the inline overlay preview is hidden, and `ratex-enter-fragment-hook` runs.
- While point stays inside that fragment, no background rendering occurs automatically.
- When point leaves that fragment, `ratex-leave-fragment-hook` runs, and only that fragment is rendered again.

All LaTeX delimiters are supported.

You can trigger a full buffer refresh manually with:

```elisp
M-x ratex-refresh-previews
```

## Example

In a LaTeX, Org, or Markdown buffer, place point inside:

```tex
\(\frac{1}{2}\)
```

or:

```tex
\[
\int_0^1 x^2\,dx
\]
```

`ratex.el` renders the fragment asynchronously and displays the SVG preview through an overlay.

## Customisation

Customisation options defined in `ratex-render.el`:

- `ratex-font-size`: backend SVG font size (defaults to `16.0`).
- `ratex-color`: formula colour string passed to the backend renderer (defaults to `"default"`, which dynamically uses the current frame foreground colour, or an explicit colour name or hex string).
- `ratex-executable-path`: executable path for rendering (defaults to `"render-svg"`).

### Example configuration

```elisp
(use-package ratex
  :config
  (setq ratex-color "default")
  (setq ratex-font-size 16.0)
  (setq ratex-executable-path "render-svg")
  (global-ratex-mode 1))
```

If you want an explicit formula colour regardless of the active frame theme:

```elisp
(setq ratex-color "#ffffff")
```

## Real-time preview editing

You can implement real-time preview editing while typing inside a fragment by connecting `ratex-enter-fragment-hook` and `ratex-leave-fragment-hook` with `after-change-functions`.

### Posframe real-time editing

This example uses `posframe` to display a floating child frame that updates as you edit:

```elisp
(defun ratex-posframe-update (&rest _)
  "Update posframe preview while editing inside a fragment."
  (when-let* ((current (ratex--active-fragment-at-point)))
    (ratex-render-math-batch-async
     (list (plist-get current :content))
     (lambda (svgs)
       (when-let* ((svg (car svgs)))
         (posframe-show " *ratex-preview-posframe*"
                        :string (propertize " " 'display (create-image svg 'svg t))
                        :position (plist-get current :begin)))))))

(add-hook 'ratex-enter-fragment-hook
          (lambda (fragment image)
            (add-hook 'after-change-functions #'ratex-posframe-update nil t)
            (when image
              (posframe-show " *ratex-preview-posframe*"
                             :string (propertize " " 'display image)
                             :position (plist-get fragment :begin)))))

(add-hook 'ratex-leave-fragment-hook
          (lambda (_)
            (remove-hook 'after-change-functions #'ratex-posframe-update t)
            (posframe-hide " *ratex-preview-posframe*")))
```

### Overlay real-time editing

This example attaches an inline overlay directly below the fragment text:

```elisp
(defvar ratex-demo-overlay nil)

(defun ratex-overlay-update (&rest _)
  "Update inline overlay preview while editing inside a fragment."
  (when-let* ((current (ratex--active-fragment-at-point)))
    (ratex-render-math-batch-async
     (list (plist-get current :content))
     (lambda (svgs)
       (when-let* ((svg (car svgs))
                   (ov ratex-demo-overlay))
         (move-overlay ov (plist-get current :end) (plist-get current :end))
         (overlay-put ov 'after-string
                      (concat "\n" (propertize " " 'display (create-image svg 'svg t)))))))))

(add-hook 'ratex-enter-fragment-hook
          (lambda (fragment image)
            (add-hook 'after-change-functions #'ratex-overlay-update nil t)
            (setq ratex-demo-overlay (make-overlay (plist-get fragment :end)
                                                   (plist-get fragment :end)))
            (when image
              (overlay-put ratex-demo-overlay 'after-string
                           (concat "\n" (propertize " " 'display image))))))

(add-hook 'ratex-leave-fragment-hook
          (lambda (_)
            (remove-hook 'after-change-functions #'ratex-overlay-update t)
            (when ratex-demo-overlay
              (delete-overlay ratex-demo-overlay)
              (setq ratex-demo-overlay nil))))
```
