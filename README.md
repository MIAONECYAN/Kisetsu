<p align="center">
  <img src="AppleClient/Sources/KisetsuMobile/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="88" alt="Kisetsu 应用图标">
</p>

<h1 align="center">Kisetsu</h1>

<p align="center">
  自托管的动画订阅与媒体整理工作台<br>
  在 macOS 和 iPhone 上掌握追番进度、下载任务与 Plex 播放列表
</p>

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/icons/apple-dark.svg"><img src="docs/icons/apple.svg" width="16" height="16" alt=""></picture> macOS
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <img src="docs/icons/ios.svg" width="16" height="16" alt=""> iPhone
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <img src="docs/icons/fastapi.svg" width="16" height="16" alt=""> FastAPI
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <img src="docs/icons/plex.svg" width="16" height="16" alt=""> Plex
</p>

<p align="center">
  <a href="https://github.com/MIAONECYAN/Kisetsu/releases/latest"><strong>下载最新版本</strong></a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="#快速开始">部署与构建</a>
  &nbsp;&nbsp;·&nbsp;&nbsp;
  <a href="NOTICE.md">使用须知</a>
</p>

Kisetsu 将资源搜索、订阅跟踪、下载与整理进度、媒体识别和 Plex 播放列表放在同一套工作流里。后端由你自行运行，两端原生客户端连接同一服务；资源、凭证和媒体文件仍由你自己的环境管理。

> [!IMPORTANT]
> Kisetsu 是采用 [MIT License](LICENSE) 发布的开源软件。Kisetsu 不提供媒体内容、
> 站点账号或第三方服务；使用者应自行确保数据来源和使用行为合法，并在使用前阅读
> [NOTICE.md](NOTICE.md)。

## 核心能力

**按自己的规则订阅。** 从关键词、Mikan 番组或 RSS 创建订阅，以字幕组、分辨率、集数范围和正则表达式缩小匹配范围。订阅可归入持久化分组，按分组、搜索词和“订阅完成”状态查看；更换默认分组不会移动已有订阅。

**看清实际进度。** 概览集中呈现订阅焦点、下载与待整理任务、最近整理和 Plex 中已有的播放列表。“订阅完成”依据订阅目标范围内的下载与整理进度判定，而不是仅凭启用状态或海报文字。

**跟随持续更新的番组。** 新建订阅默认开启“刷新时自动更新总集数”：手动或自动刷新时，若可靠元数据的集数增加，才上调已有总集数；不会自动调低。若已配置并启用 Bark，增加时可收到包含原集数与新集数的通知。

**把任务接到媒体库。** 搜索支持 DMHY、Mikan、Nyaa 和已配置的 PT 站点；下载可连接 qBittorrent 或 Transmission。Bangumi/TMDB 元数据用于识别和整理动画单集、多集、合集与电影；配置 Plex 后可浏览已有播放列表。站点刷流与文件管理也提供独立入口。

这些能力依赖使用者自行配置对应站点、下载器、元数据服务及可选的 Plex、Bark。Kisetsu 不提供媒体内容、站点账号、Cookie、API Key、下载器或 Plex Server。

## 界面

以下为现有 macOS 与 iPhone 界面截图，点击可查看原图。

<table>
  <tr><th align="center">macOS · 概览</th><th align="center">iPhone · 概览</th></tr>
  <tr>
    <td align="center" width="72%"><a href="docs/screenshots/macos-overview.png"><img src="docs/screenshots/macos-overview.png" width="590" alt="macOS 概览：订阅海报与任务状态"></a></td>
    <td align="center" width="28%"><a href="docs/screenshots/iphone-overview.png"><img src="docs/screenshots/iphone-overview.png" width="170" alt="iPhone 概览：订阅海报与 Plex 播放列表"></a></td>
  </tr>
  <tr><th align="center">macOS · 订阅</th><th align="center">iPhone · 订阅</th></tr>
  <tr>
    <td align="center"><a href="docs/screenshots/macos-subscriptions.png"><img src="docs/screenshots/macos-subscriptions.png" width="590" alt="macOS 订阅列表：海报、进度与操作入口"></a></td>
    <td align="center"><a href="docs/screenshots/iphone-subscriptions.png"><img src="docs/screenshots/iphone-subscriptions.png" width="170" alt="iPhone 订阅列表：整理进度与订阅操作"></a></td>
  </tr>
</table>

## 获取版本

从 [GitHub Releases](https://github.com/MIAONECYAN/Kisetsu/releases/latest) 选择**同一版本**的后端与客户端。订阅分组等较新的功能需要相应版本的后端支持。

| 下载内容 | 说明 |
| --- | --- |
| 后端源码包 | Python 3.11+；包内目录为 `Kisetsu/backend`，不包含仓库的启动脚本 |
| macOS 客户端 | macOS 15+、Apple Silicon；ad-hoc 签名，未经 Apple 公证 |
| iPhone 客户端 | `arm64` 未签名 IPA，ZIP 内保留原名 `Kisetsu.ipa`；安装前需自行签名 |
| `SHA256SUMS.txt` | 校验上述三个发布附件 |

## 快速开始

下面的命令使用完整源码仓库；Release 中的后端源码包只包含 `backend/`，不包含这里使用的 `script/` 和 `.env.example`。

### 运行自托管后端

需要 Python 3.11 或更高版本：

```bash
git clone https://github.com/MIAONECYAN/Kisetsu.git
cd Kisetsu

python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -e ./backend
cp .env.example .env
set -a
source .env
set +a
./script/start_backend.sh
```

> [!NOTE]
> 自托管后端目前仅在 macOS 上完成运行与回归测试。Linux、Windows、NAS、容器及
> 其他平台需要使用者自行测试兼容性并承担相应风险。

在另一台设备上连接后端前，需要将监听地址及网络访问配置为该设备可以到达的地址；默认的 `127.0.0.1` 仅供本机访问。

### macOS 客户端

需要 macOS 15 或更高版本：

```bash
./script/build_and_run.sh
```

### iPhone 客户端

需要 Xcode 26 或更高版本。在仓库根目录运行：

```bash
./script/build_mobile_ipa.sh
```

输出为 `dist/Kisetsu.ipa`。该文件是 `arm64` 未签名包，安装前必须使用自己的开发者
证书签名。首次启动后，在客户端设置中填写设备可以访问的自托管后端地址。

## 配置与数据

`.env.example` 只包含本地配置模板。运行时凭证应写入未跟踪的 `.env`，或通过客户端
设置页保存。站点、通知、AI 与 Plex 认证资料存放于独立的
`kisetsu-secrets.sqlite3`；这是权限隔离存储，不是加密保险库。

不要提交或分享以下内容：

- `.env`、Token、Cookie、API Key 与签名材料。
- `data/`、SQLite 数据库及其 WAL/SHM 文件。
- 日志、备份、媒体路径和带有真实任务信息的截图。

## 项目结构

```text
AppleClient/   macOS 与 iPhone SwiftUI 客户端
backend/       FastAPI 自托管后端
script/        启动、构建与打包脚本
```

## AI 编写声明

**本仓库中的代码由 AI 工具完整生成；需求定义、审核、测试和发布由项目维护者负责。**

公开源码不代表代码没有缺陷。使用者应自行审查其安全性、兼容性与适用性。

## 许可与免责声明

源码采用 [MIT License](LICENSE)，允许在保留版权与许可声明的前提下使用、复制、
修改、合并、发布、分发、再许可及销售软件副本。

软件按现状提供。维护者不对数据丢失、下载或整理结果、版权争议、账号封禁、服务中断
及其他使用后果承担责任。使用者应自行确认数据来源及使用行为符合所在地法律与第三方
服务条款。

完整使用说明与免责声明见 [NOTICE.md](NOTICE.md)；第三方项目与商标说明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
