# jarvis_app

personal agent desktop client

## 构建前置：PDFium 二进制

PDF 预览用 `pdfrx`（PDFium）。它的构建 hook 会在**构建期**从 GitHub 下载原生库，
到不了 GitHub 的机器第一次 `flutter test` / `flutter build` 会报
`PDFium download failed`。此时把 PDFium 归档手动放进 hook 的缓存目录（或先配好
镜像 / 代理）再重试即可，仓库里不提供下载脚本。

## 构建前置：视频查看器的原生库

视频预览用 `media_kit`（libmpv），Android / iOS / macOS / Windows / Linux 同一套 API。
`media_kit_libs_video` 把各端原生库随依赖分发，因此：

- 首次 `flutter pub get` 会多下几十 MB，`build/` 体积与安装包也明显变大——这是
  "五端都能播"的代价（官方 `video_player` 在 Windows / Linux 没有实现）；
- 构建机到不了 pub.dev 时，先配镜像再拉依赖：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
```

桌面上 libmpv 由 `media_kit_libs_video` 随包提供，不需要宿主机预装 mpv。
macOS 打包脚本 `../scripts/package-macos.sh` 会连同这些动态库一起签名，改签名规则时别漏掉它们。

## 可选依赖：ffmpeg（视频封面）

视频产物卡片与右栏预览的封面，是服务端在**生成视频成功后**用 `ffmpeg` 抽的第一帧。
没装也能用：抽帧失败只记一条 warn，卡片回退到播放图标占位块。

```bash
brew install ffmpeg        # macOS
# Windows / Linux 从发行版包管理器装，确保 `ffmpeg` 在 PATH 里
```

- 只在服务端机器上需要，客户端不需要；
- 装好之后新视频在生成时就有封面；旧视频会在**第一次打开卡片时**按需补一张并缓存；
- 抽帧失败（没有命令、超时、文件损坏）都不会让视频生成失败。

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
