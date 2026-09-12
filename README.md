# Kisetsu

> [!IMPORTANT]
> Kisetsu 以 **source-available** 方式公开源码，采用
> [PolyForm Noncommercial License 1.0.0](LICENSE)，禁止商业使用。
> 它不属于 OSI 认可的开源软件。另请先阅读[使用限制与免责声明](NOTICE.md)：
> 本项目不允许在中国大陆使用、部署、分发、镜像、宣传或推广。

Kisetsu 是一套面向 macOS 与 iPhone 的自托管媒体订阅和整理工具。它通过本地
FastAPI 后端连接订阅源、下载器与 Plex，在 Apple 平台客户端中完成资源搜索、
订阅刷新、下载任务管理、媒体识别、整理确认和 Plex 播放列表管理。

![macOS 概览](docs/screenshots/macos-overview.png)

![macOS 订阅](docs/screenshots/macos-subscriptions.png)

<p align="center">
  <img src="docs/screenshots/iphone-overview.png" width="280" alt="iPhone 概览">
  <img src="docs/screenshots/iphone-subscriptions.png" width="280" alt="iPhone 订阅">
</p>

## 功能

- 关键词、Mikan 番组和 RSS 订阅，支持字幕组、分辨率、集数与正则筛选。
- DMHY、Mikan、Nyaa 及已配置 PT 站点的资源搜索。
- qBittorrent 与 Transmission 下载任务管理。
- Bangumi/TMDB 元数据识别，单集、多集和电影整理预览。
- 订阅进度、下载历史、待整理与整理记录的统一任务视图。
- Plex 媒体映射与播放列表浏览。
- macOS 与 iPhone 原生 SwiftUI 客户端，自托管 FastAPI 后端。

Kisetsu 不提供媒体内容、站点账号、Cookie、API Key、下载器或 Plex Server。

## 系统要求

- macOS 15 或更高版本。
- iOS 26 或更高版本。
- Python 3.11 或更高版本。
- 按需准备 qBittorrent、Transmission、Plex 和元数据服务凭证。

> [!NOTE]
> 自托管后端目前仅在 macOS 上完成运行与回归测试。Linux、Windows、NAS、
> 容器及其他环境尚未验证，需要使用者自行测试兼容性并承担相应风险。

## 本地运行

```bash
git clone https://github.com/MIAONECYAN/Kisetsu.git
cd Kisetsu

python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -e ./backend
./script/start_backend.sh
```

构建并启动 macOS 客户端：

```bash
./script/build_and_run.sh
```

iPhone 客户端使用 Xcode 打开 `AppleClient/KisetsuMobile.xcodeproj`。首次启动后，
在 App 中填写 iPhone 可以访问的自托管后端地址。项目不包含签名证书；Release
中的 IPA 也未签名，安装前必须使用自己的证书签名。

## 配置

运行时配置和凭证只保存在本地，不应提交到 Git：

```bash
cp .env.example .env
```

下载器、站点、通知、AI 与 Plex 凭证建议通过客户端设置页保存。Kisetsu 将认证
资料存入独立的 `kisetsu-secrets.sqlite3`；它是权限隔离存储，不是加密保险库。
不要分享 `data/`、数据库、日志或配置文件。

## AI 编写声明

**本仓库中的代码由 AI 工具完整生成；需求定义、审核、测试和发布由项目维护者负责。**
公开源码不代表代码没有缺陷，维护者和使用者仍需自行审查安全性与适用性。

## 安全与隐私

请不要在公开 Issue 中粘贴 Token、Cookie、数据库、日志、下载链接或媒体路径。
发现安全问题时请使用 GitHub 的私密漏洞报告功能。

## 许可与限制

源码使用 [PolyForm Noncommercial License 1.0.0](LICENSE)，仅允许许可证定义的
非商业用途。本项目不是 OSI 认可的开源软件。地区限制、免责声明及第三方服务
说明见 [NOTICE.md](NOTICE.md)；第三方项目与商标说明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
