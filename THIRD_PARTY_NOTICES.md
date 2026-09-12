# 第三方说明

Kisetsu 使用或连接多个独立项目与服务。各项目、名称和商标归其权利人所有：

- FastAPI、HTTPX、Uvicorn 与 Pydantic 用于自托管后端。
- Swift、SwiftUI、Xcode、macOS 与 iOS 属于 Apple 生态。
- qBittorrent 与 Transmission 是可选下载器。
- Plex、Bangumi 与 TMDB 是可选媒体或元数据服务。

Python 依赖及其版本范围记录在 `backend/pyproject.toml`。Kisetsu 不包含上述服务
的凭证，也不代表这些项目提供官方认可或支持。

站点刷流的产品行为曾参考 GPL-3.0 项目 MoviePilot-Plugins/brushflow 的公开功能，
但本仓库未引入其插件框架、源代码或界面资源。若后续加入第三方源码或素材，必须
同时加入对应许可证和归属说明后方可发布。

