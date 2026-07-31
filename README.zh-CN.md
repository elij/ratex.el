# ratex.el

> [!NOTE]  
> 这是 [ratex.el](https://github.com/gongshangzheng/ratex.el) 的一个分支（fork）。包含了一些无法合并到上游的精简改动。去除了原版的 ratex RPC 机制（改为使用批处理 CLI），并改用 `tex-mode.el` 进行解析。虽然它与 GPL 3 兼容，但原作者尚未明确许可证。

[English](./README.md)

`ratex.el` 是一个面向 Emacs 的行内数学公式预览包，底层基于上游 [RaTeX](https://github.com/erweixin/RaTeX) 引擎。

它的目标是通过微型的异步后端、SVG 输出和极简的配置，在 Emacs 中渲染 LaTeX 数学片段。

## 演示

![ratex.el 演示](./assets/demo.gif)

## 功能特性

- 在 Emacs 中异步预览行内数学公式
- 基于 RaTeX 的 SVG 渲染
- 通过 `ratex-render-math-batch-async` 批量渲染数学公式片段
- 通过 `ratex-enter-fragment-hook` 和 `ratex-leave-fragment-hook` 提供与公式片段交互的进入和退出钩子
- 借助 `tex-mode.el` 原生支持解析所有 LaTeX 分隔符（包括 `$` 和 `$$`）
- 轻量级的 buffer 内渲染流程
- 兼容 `latex-mode`、`LaTeX-mode`、`org-mode` 和 `markdown-mode`

## 仓库结构

- `ratex.el`：核心 minor mode，用户命令和全局设置
- `ratex-render.el`：执行 `ratex-executable-path` 的异步批处理渲染引擎
- `ratex-overlays.el`：overlay 管理和图像显示生命周期
- `ratex-math-detect.el`：LaTeX 数学分隔符解析和片段检测

## 环境要求

- Emacs 29.1 或更新版本
- 环境变量 PATH 中包含 `render-svg` 可执行文件（或通过 `ratex-executable-path` 配置指定路径）

## 安装方式

```elisp
(package-vc-install '(ratex :url "https://github.com/elij/ratex.el"))
```

或者

```elisp
(add-to-list 'load-path "/path/to/ratex.el")
(require 'ratex)
```

或者

```elisp
(use-package ratex
  :vc (:url "https://github.com/elij/ratex.el")
  :config
  (global-ratex-mode 1))
```

在当前 buffer 手动启用：

```elisp
M-x ratex-mode
```

或者为常见的文本和数学模式自动启用：

```elisp
(require 'ratex)
(global-ratex-mode 1)
```

在 Org 文件中，你还可以通过关键字对单个文件进行控制：

```org
#+ratex: t
```

使用 `#+ratex: nil`（或 `off`）可以对特定的 Org 文件禁用该功能，即便已经启用了 `global-ratex-mode`。

等效的显式 hook 设置：

```elisp
(add-hook 'latex-mode-hook #'ratex-mode)
(add-hook 'LaTeX-mode-hook #'ratex-mode)
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
```

## 如何工作

数学片段通过 `ratex-render-math-batch-async` 以单次批处理的方式异步渲染。该函数会执行由 `ratex-executable-path`（默认为 `"render-svg"`）配置的二进制程序。进程将片段内容字符串传递给可执行文件，并接收渲染后的 SVG 数据作为响应。

当光标进入或移出数学片段时，`ratex.el` 会触发专用钩子：

* `ratex-enter-fragment-hook`：当光标进入片段时执行。钩子函数接收两个参数：片段属性列表（plist）和缓存的 SVG 图像对象（如果没有缓存则为 `nil`）。
* `ratex-leave-fragment-hook`：当光标离开片段时执行。钩子函数接收一个参数：刚刚离开的片段属性列表。

默认情况下，当光标进入一个片段时，它的行内 overlay 预览将被隐藏。当光标离开该片段时，它会被再次异步渲染并更新。

## 使用方法

交互模型遵循以下逻辑：

* 启用 `ratex-mode` 时，将渲染当前 buffer 中可见的公式。
* 当光标进入数学片段时，行内 overlay 预览隐藏，并运行 `ratex-enter-fragment-hook`。
* 当光标停留在该片段内时，不会自动发生后台渲染。
* 当光标离开该片段时，运行 `ratex-leave-fragment-hook`，并且仅重新渲染该片段。

原生支持所有 LaTeX 分隔符。

你可以通过以下命令手动触发 buffer 全量刷新：

```elisp
M-x ratex-refresh-previews
```

## 示例

在 LaTeX、Org 或 Markdown buffer 中，将光标放在公式内部：

```tex
\(\frac{1}{2}\)
```

或者：

```tex
$$\int_0^1 x^2\,dx$$
```

`ratex.el` 会异步渲染该片段，并通过 overlay 显示 SVG 预览。

## 自定义配置

在 `ratex-render.el` 中定义的配置选项：

* `ratex-font-size`：后端 SVG 字体大小（默认为 `16.0`）。
* `ratex-color`：传递给后端渲染器的公式颜色字符串（默认为 `"default"`，它会动态使用当前 Emacs 主题的前景色；也可以是显式的颜色名称或十六进制字符串）。
* `ratex-executable-path`：用于渲染的可执行文件路径（默认为 `"render-svg"`）。

### 配置示例

```elisp
(use-package ratex
  :config
  (setq ratex-color "default")
  (setq ratex-font-size 16.0)
  (setq ratex-executable-path "render-svg")
  (global-ratex-mode 1))
```

如果你希望无论当前主题如何都使用确定的公式颜色：

```elisp
(setq ratex-color "#ffffff")
```

## 实时预览编辑

你可以通过将 `ratex-enter-fragment-hook` 和 `ratex-leave-fragment-hook` 结合 `after-change-functions` 使用，来实现片段内的实时编辑预览。

### Posframe 实时编辑

以下示例使用 `posframe` 显示一个悬浮子窗口，该窗口会随着你的输入而更新：

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

### Overlay 实时编辑

以下示例将一个内联 overlay 附加在公式文本的正下方：

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
