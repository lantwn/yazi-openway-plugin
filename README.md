# open-with.yazi

在 yazi 的**原生 picker** 里列出系统桌面应用，按大写的 `O` 直接选择“用什么打开”。

它解决的是 yazi 的一个空白：`open --interactive` 只会列出 `[opener]` 里配置过的命令，不会自动读取系统里注册的 MIME 应用。这个插件通过 GIO（Nautilus 使用的同一套数据）发现应用，再把它们临时注入 yazi 的原生 picker。

## 效果

假设你有一个文本文件，`yazi.toml` 里只配置了：

```toml
[opener]
edit = [{ run = "nvim %s", desc = "Edit in Yazi (nvim)", block = true }]

[open]
rules = [{ mime = "text/*", use = "edit" }]
```

按下 `O` 后，picker 会显示：

```text
╭ Open with: ──────────────────────────────╮
│  Edit in Yazi (nvim)                    │
│   Reveal in file manager                │
│ * Neovim                                │
│   Vim                                   │
╰──────────────────────────────────────────╯
```

（`*` 表示 GIO 的默认应用。）

- 原生 `edit/reveal/play` 仍然保留。
- 系统应用来自 GIO，不需要手写每个应用。
- 选中系统应用后由 GIO 启动；`Terminal=true`、flatpak、`%f/%F` 等细节都由 GIO 处理。
- 支持多选（按 `Space` 选择多个文件），只列出所有文件都能打开的应用交集。

## 依赖

- Linux 桌面（GIO/XDG）
- yazi **>= 26.5.6**（需要 dynamic `rt.open` / `rt.opener` Lua API；在 26.9.1 上测试）
- Python 3 + PyGObject（`Gio`、`GioUnix`，没有 `GioUnix` 时会回退到 `Gio.DesktopAppInfo`）
- GLib/GIO、`file` 命令（yazi 本身也依赖 `file`）

Arch：

```sh
sudo pacman -S python-gobject glib2 file
```

Debian/Ubuntu：

```sh
sudo apt install python3-gi gir1.2-glib-2.0 file
```

Fedora：

```sh
sudo dnf install python3-gobject glib2 file
```

不需要 `fzf`。

## 安装

把本仓库作为插件目录，目录名**必须是** `open-with.yazi`：

```sh
# 方式一：脚本安装（只创建 symlink，不改 keymap）
./install.sh

# 方式二：手动 symlink
mkdir -p ~/.config/yazi/plugins
# 如果目标已存在，先备份/移走
ln -s /path/to/yazi-open-way ~/.config/yazi/plugins/open-with.yazi
```

`~/.config/yazi` 的位置遵循 `YAZI_CONFIG_HOME`；如果你改过 yazi 配置目录，请放到对应的 `plugins/open-with.yazi`。

> 插件里的 helper 路径按 `open-with.yazi` 这个目录名拼出来的；如果目录名不同，系统应用不会被注入，插件会回退到原生 picker。

## 键位

在 `~/.config/yazi/keymap.toml` 里加：

```toml
[[mgr.prepend_keymap]]
on   = "O"
run  = "plugin open-with"
desc = "Open with (native picker + system apps)"
```

建议保留 `<S-Enter>` 作为纯原生菜单的退路：

```toml
[[mgr.prepend_keymap]]
on   = "<S-Enter>"
run  = "open --interactive"
desc = "Open with configured openers"
```

`prepend_keymap` 会覆盖默认的 `O` 绑定。

## Picker 配置

系统应用可能比较多，建议把原生 picker 调高一些：

```toml
[pick]
open_title  = "Open with:"
open_origin = "hovered"
open_offset = [ 0, 1, 60, 15 ]
```

另外建议把原生 opener 的 `desc` 改成可读的名字，否则 picker 里会显示字面量 `$EDITOR`：

```toml
[opener]
edit = [
	{ run = "nvim %s", desc = "Edit in Yazi (nvim)", block = true },
]
open = [
	{ run = "xdg-open %s1", desc = "Open (default)" },
]
reveal = [
	{ run = "xdg-open %d1", desc = "Reveal in file manager" },
]
```

## 使用

- 悬停文件按 `O`：打开 picker。
- `Space` 选中多个文件后按 `O`：只显示所有选中文件都能打开的应用。
- `Esc` 取消。
- 选中系统应用后，GIO 会启动它；如果应用是 `Terminal=true`，会开一个新终端窗口。
  - 想在 yazi 当前终端里编辑，选原生的 `Edit in Yazi (nvim)`；两者不要混淆。
- 默认应用前面有 `*`；helper 在启动后会调用 `Gio.AppInfo.set_as_last_used_for_type()`，让 GIO 的“最近使用”排序和 Nautilus 一致。

## 工作原理

```text
按 O
  └─ plugin open-with
       ├─ sync：收集文件、yazi MIME、匹配到的 open rule
       ├─ async：python helper --list <paths>
       │           └─ GIO 枚举 default/recommended/fallback/all 应用，求交集
       ├─ sync：清理旧 openwith_*，注册动态 opener，
       │         把系统应用追加到对应 open rule 的 use
       └─ ya.emit("open", { interactive = true })
              └─ yazi 原生 picker：原生 opener + 系统应用
                     └─ 选中应用 → opener.run：
                        python helper --launch <desktop-id> -- %s
                        └─ Gio.AppInfo.launch()
```

几个关键点：

### 两套 MIME

- **找 yazi 的 open rule**：用 `file:mime()`；为空时回退到 `file -bL --mime-type`，并按 yazi `mime.local` 的规则归一化（去掉 `x-`/`vnd.` 前缀，空文件是 `inode/empty`）。
- **找系统应用**：helper 用 GIO 的 `standard::content-type` 自己查。

不要混用：GIO 对空文件可能给 `application/x-zerosize`，yazi 是 `inode/empty`；`.c` 文件 GIO 可能是 `text/x-csrc`，yazi 归一化后是 `text/c`。

### 清理

picker 选中后没有回调，所以临时 opener 会在下一次按 `O` 时清理：

1. 删除所有 `openwith_*` opener；
2. 从所有 open rule 的 `use` 里过滤掉 `openwith_*`；
3. 重新注入当前应用。

残留项只在同一 MIME 的原生菜单里可见，且是有效的；不会无限累积。

### 多选

helper 对所有选中文件的 GIO MIME 求应用交集。插件把同一批应用追加到每个文件匹配的 rule，`open_do` 自己也会对 `use` 求交集。没有共同应用时，插件回退到原生 picker。

### 目录 / 远程文件

MVP 只处理本地普通文件（`url.spec.is_regular` 且不是目录）。目录、`trash://`、`sftp://`、搜索视图等会直接回退到原生 picker，不会注入系统应用。

## 排错

1. 先单独跑 helper：

   ```sh
   python3 ~/.config/yazi/plugins/open-with.yazi/assets/open-with-gio --list -- /etc/hosts
   ```

   正常会输出类似：

   ```json
   {"mimes":["text/plain"],"apps":[{"id":"nvim.desktop","name":"Neovim","default":true}]}
   ```

2. 检查 PyGObject：

   ```sh
   python3 -c 'import gi; gi.require_version("Gio","2.0"); from gi.repository import Gio, GioUnix; print("ok")'
   ```

3. 开日志：

   ```sh
   OPEN_WITH_DEBUG=1 YAZI_LOG=debug yazi
   # 日志里搜 open-with / openwith / helper
   ```

4. 确认插件目录名是 `open-with.yazi`，并且 `main.lua`、`assets/open-with-gio` 都在里面。

5. 如果 `python3` 不是带 PyGObject 的解释器：

   ```sh
   OPEN_WITH_PYTHON=/usr/bin/python3 yazi
   ```

## 已知限制

- 只支持 Linux/GIO；其他平台回退到原生 picker。
- 原生 picker **没有 fzf 的模糊搜索/预览**，应用多了靠方向键滚动；需要模糊搜索可以改用 `Bt-Shz/open-with-gio.yazi` 的 fzf 方案。
- 依赖 yazi 实验性的 dynamic open/opener API（26.5.6+）；如果以后 API 改动，插件需要跟进。
- 没有“查看所有应用 / 设为默认应用”的 UI；目前只做“选择并打开”，GIO 的 last-used 会更新。设为默认可以后续加 `Ctrl+O` 之类的入口。
- 只显示 GIO 能发现的 `.desktop` 应用；没有 desktop entry 的命令不会出现。
- 视觉模式（`v`）的多选没有专门处理；建议用 `Space` 选择。
- 系统应用的 `desc` 只有文字，没有图标；TUI picker 的限制。
- 临时 opener 使用 `openwith_` 前缀；请不要在 `[opener]` 里手写同名组。

## 文件

```text
main.lua                 # yazi 插件：sync 收集 + async GIO + sync 注入 + emit open
assets/open-with-gio     # Python GIO helper：--list / --launch
install.sh               # 创建插件 symlink（不改 keymap）
examples/keymap.toml     # 键位示例
examples/yazi.toml       # picker 配置示例
tests/test_helper.py     # helper 的独立测试
LICENSE
```

## License

MIT
