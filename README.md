# u60pro-devui-remix

这是基于 [33333s/u60pro-devui](https://github.com/33333s/u60pro-devui) v1.2.12 的 Remix 版本，保留原项目提交历史和目录结构。

本分支增加了 UFI-TOOLS 环境下的 Tailscale、Clash / Mihomo、WireGuard 和漫游锁卡屏幕控制页面：

- 从 `ui/functions/` 自动加载已安装插件对应的功能页。
- 显示 Tailscale、Clash / Mihomo、WireGuard 和漫游锁卡的紧凑状态与日常控制。
- 提供启动、停止、重启和手动刷新操作，启动/停止按真实状态高亮。
- 页面内显示最近三条带时间戳的操作记录，并保留即时 toast 反馈。
- 提供基于 Linux cpufreq 的 CPU 省电、均衡、性能和极致模式控制页面。
- 只允许调用固定控制脚本，不向自定义 HTML 暴露任意 Shell 执行能力。

对应设备路径为：

```text
/data/plugins/tailscale/tsctl.sh
/data/plugins/mihomo/mm.sh
/data/plugins/wireguard/wgctl.sh
/data/plugins/operator-lock/operatorctl.sh
```

这是 ZTE U60Pro 以及类似 SDX 系列 5G MiFi 设备前面板屏幕 UI 的一个 clean-room 开源替代实现。运行在标准 Linux 的 **DRM/KMS** 和 **evdev** 接口之上，目标是：

- 独立于原厂设备 UI 运行
- 界面用 **HTML/CSS** 描述，**不改程序就能换界面**
- 编译成单个静态 `aarch64` 二进制，拷到设备上就能运行

> 这是一个基于公开 Linux/OpenWRT 接口的独立重实现。硬件相关说明见 [docs/HARDWARE.md](docs/HARDWARE.md)。

> 💬 QQ 交流讨论群 **625439164**，欢迎进群讨论。

## 核心理念：程序固定，界面是数据

程序本身不内置任何画面。它在运行时去 `/data/plugins/u60pro-devui/ui` 读取你写的 **HTML/CSS** 并渲染到屏幕。想改界面，**完全不用重新编译**——改 HTML、推到设备、约 1 秒内自动生效。

👉 **想自己写界面，看这份教程：[docs/UI-GUIDE.md](docs/UI-GUIDE.md)**

```text
后端 zwrt-datad ──▶ HTTP /state + SSE /events (127.0.0.1:9460) ──┐
                                                                  ├─▶ u60pro-devui ──▶ 屏幕（DRM/KMS）
你写的 /data/plugins/u60pro-devui/ui/*.html + style.css ───────────┘
```

- **渲染**：[litehtml](https://github.com/litehtml/litehtml)（HTML/CSS 排版）+ FreeType（含 CJK 字体）→ 直接画进 RGB565 framebuffer。无浏览器、无 JavaScript；状态只经本机 `127.0.0.1` 的 HTTP/SSE 读取。
- **显示**：[src/drm_disp.c](src/drm_disp.c) 打开 `/dev/dri/card0`，运行时枚举面板/crtc/mode，映射 RGB565 dumb framebuffer，通过 `DIRTYFB` 提交。
- **触摸**：[src/touch_input.c](src/touch_input.c) 自动探测触摸屏并缩放坐标；电源键短按息屏、长按菜单。
- **界面**：`/data/plugins/u60pro-devui/ui` 下每个顶层 `NN-名字.html` 一页，`style.css` 共享样式；`ui/subpages/` 提供二级页面，`ui/functions/` 可放用户自定义功能页。HTML 里的 `{{令牌}}` 由程序替换成实时数据，`href="act:xxx"` 触发交互。
- **外部接口**：内建本地 `DEVUI-IPC`，保留原生状态栏；其他进程可直接把内容投到状态栏下方的内容区，并通过点击事件日志驱动自己的交互逻辑。
- **后端**：配套 `zwrt-datad`（[github.com/33333s/zwrt-datad](https://github.com/33333s/zwrt-datad)），轮询 `ubus` 后通过 `GET /state` 和 `SSE /events` 提供完整 JSON 快照；UI 只读这个本机接口，自己从不碰 ubus。

自带的示例界面（[ui/](ui/)）含四个顶层页：信号、更多功能、图表、系统设置。“更多功能”里进入 WiFi、短信、信令读取、锁频和可选测速二级页；系统页包含亮度/息屏/锁屏、USB-C 供电方向、USB 网络共享、速率单位和主题等开关。

## 构建

需要一个 POSIX shell（WSL / Linux）和自带的 aarch64 musl 工具链，不需要 root，也不要求宿主机预装 `make`。

```sh
# 一次性：下载可搬运的 aarch64 musl 工具链到 $HOME
bash scripts/_setup_toolchain.sh

# 一次性：编译静态 FreeType 和 litehtml
bash scripts/_build_freetype.sh
bash scripts/_build_litehtml.sh

# 编译正式 UI 二进制 -> ./u60pro-devui(.stripped)
bash scripts/build.sh
```

产物是单个**静态 AArch64 ELF**，无动态依赖，直接拷到设备运行。

> 也可以直接到 [Releases](https://github.com/33333s/u60pro-devui/releases) 下载编译好的二进制。

## 在设备上运行

```sh
# 推送界面文件和 Remix 控制脚本
adb shell 'mkdir -p /data/plugins/u60pro-devui/ui/functions'
adb push ui/*.html ui/*.css /data/plugins/u60pro-devui/ui/
adb push ui/functions/*.html /data/plugins/u60pro-devui/ui/functions/
adb push scripts/cpuctl.sh /data/plugins/u60pro-devui/ui/functions/cpuctl.sh
adb shell 'chmod 755 /data/plugins/u60pro-devui/ui/functions/cpuctl.sh'

# 推送并运行（先停原厂 UI 释放面板）
adb shell 'mkdir -p /data/plugins/u60pro-devui'
adb push u60pro-devui.stripped /data/plugins/u60pro-devui/u60pro-devui
adb shell '/etc/init.d/zte_topsw_devui stop; sleep 1;
           chmod 755 /data/plugins/u60pro-devui/u60pro-devui;
           nohup /data/plugins/u60pro-devui/u60pro-devui >/tmp/devui.log 2>&1 &'
```

> Windows 下用 Git-Bash 跑 `adb push /data/...` 可能因路径翻译卡住，建议用 PowerShell 跑 adb。旧版如果还把页面放在 `/data/ui`，新版 `start.sh` 和安装脚本会在首次启动时自动迁到新目录。

开机自启：把 `devui` 放到 `/data/plugins/u60pro-devui/`，把后端 `zwrt-datad` 放到 `/data/plugins/zwrt-datad/`，再用 `scripts/install-autostart.sh` 安装当前验证过的稳定链路：保留原厂 `zte_topsw_devui` 做早期屏幕/触摸 bring-up，再由 `rc.local -> /data/plugins/u60pro-devui/start.sh legacy` 晚接管。它也会顺手迁移旧版 `/data/ui` 到 `/data/plugins/u60pro-devui/ui`，并清理旧的 `/data/u60pro` 残留文件、重复钩子和实验性 `procd` 软链接。详见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 版本清单与更新

每个 release 附一个 `version.json`，声明各组件版本，供配套的「U60 DevUI 管理插件」检测更新。组件分三块、可各自独立升级：**后端 datad**、**渲染器 devui**（二进制）、**ui**（界面）。

- Remix release 的 `version.json` 合并 `datad`、`devui` 与 `ui` 三项，供原版管理器从同一个自定义源完成全新安装。

```jsonc
// Remix 聚合 version.json
{ "schema": 1,
  "datad": { "version": "0.6.7-remix.3", "asset": "zwrt-datad-aarch64" },
  "devui": { "version": "1.2.12-remix.5", "asset": "u60pro-devui-aarch64" },
  "ui":    { "version": "0.4.10-remix.3", "asset": "ui.tar.gz" } }
```

在原版管理器中选择“自定义源链接”，本版本推荐填写经过完整哈希校验的不可变 CDN 资产模板：

```text
https://fastly.jsdelivr.net/gh/scoltzero/u60pro-devui-remix@assets-v1.2.12-remix.5/{file}
```

该地址固定指向 `v1.2.12-remix.5` 的五个发布文件，不会因 CDN 分支缓存而出现清单与二进制版本不一致。正式归档仍位于 `https://github.com/scoltzero/u60pro-devui-remix/releases/latest/download`。部分设备网络访问 GitHub Release 重定向超过管理器的命令请求时限时，应使用上面的 jsDelivr 模板；后续版本需要改用对应的新资产标签。

**发版**：分别构建 DevUI 和 datad，再使用 `scripts/package-release.sh` 生成顶层平铺的 UI 包、合并版清单和 SHA-256 文件。

可直接照抄这一组命令准备 release 资产：

```sh
bash scripts/build.sh
bash scripts/package-release.sh \
  --datad ../zwrt-datad/zwrt-datad.stripped \
  --out dist/v1.2.12-remix.5
```

## 文档

- [docs/UI-GUIDE.md](docs/UI-GUIDE.md) — **自定义界面教程**（令牌、动作、限制、示例）
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — 架构、构建、数据模型、踩坑记录
- [docs/SIGNAL-CARDS.md](docs/SIGNAL-CARDS.md) — 第一页信号卡片、未激活/高铁专网标签、锁屏预览口径
- [docs/SPEEDTEST.md](docs/SPEEDTEST.md) — 可选测速后端、二级测速页、循环测速和锁屏隐藏规则
- [docs/modem.md](docs/modem.md) — 第二页信令页 / 基站信息页的页面行为与字段口径
- [docs/DEVUI-IPC.md](docs/DEVUI-IPC.md) — DevUI 内建外部画面接口（像素帧、图片、绘图命令、文字）
- [docs/HARDWARE.md](docs/HARDWARE.md) — 设备硬件接口
- [docs/REPO_BOUNDARY.md](docs/REPO_BOUNDARY.md) — 公开仓库与本地记录的边界
- [CHANGELOG.md](CHANGELOG.md) — 更新日志

## 许可证

本项目采用 [MIT](LICENSE) 许可证。litehtml（BSD）、FreeType（FTL/GPL 双授权）、stb（public domain）按各自许可证引入。

只应添加开源许可证的字体和资源，**不要加入 vendor blobs**；仓库不打包任何 ZTE 字体（运行时从设备加载），`.gitignore` 已拦截常见分析产物。
