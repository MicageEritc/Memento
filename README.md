# 留刻

留刻（Memento）是一个 macOS 桌面小工具。它按你设定的间隔截屏，把画面交给模型去判断你当时在做什么，再把结果写回本机。所有数据都留在你的电脑上，不上传任何服务器。

## 它能做什么

- 定时截屏，间隔可以在设置里改
- 把截图发给模型分析当前活动。在线 API 和本机运行的模型都支持
- 活动分成九类：办公与文档、沟通与协作、阅读与研究、编程开发、设计创作、影音娱乐、生活购物、系统工具、待机离席
- 每天的数据存成图片加一段 JSON，放在 ~/Documents/留刻/截图日志/ 下
- 状态栏常驻一个图标，点开能看当天记录、改设置、启停录制

## 构建

仓库是一个 Swift Package，用 Xcode 命令行工具里的 swift 就能编译：

    cd 留刻（仓库目录）
    swift build -c release --disable-sandbox

想打包成能直接打开的 .app，用仓库里的脚本：

    bash build-app.sh

脚本会编译、把资源拷进 bundle、做一次 ad-hoc 签名，最后做资源自检。产物是 留刻.app，用 open 打开即可。当前版本 2.2.0。

## 系统要求

- macOS 14 或更高
- 需要「屏幕录制」权限（系统设置 - 隐私与安全性 - 屏幕录制）。没授权截不到屏
- 第一次启动会弹录屏授权框，允许后才能用

## 配置

模型相关的配置写在 ~/Library/Application Support/留刻/config.json，里面主要有：

- 用哪个模型、API 地址、Key
- 截屏间隔
- 数据保留规则，比如只删图片、保留 JSON

Key 现在是以明文存在这个文件里，这是有意为之：换成钥匙串这类方式后，签名一变 macOS 就会每次弹授权框，反而更烦。文件在你自己机器上，自己看管好即可。

## 数据存放位置

- 截图与日志：~/Documents/留刻/截图日志/YYYY-MM/screenshots/YYYY-MM-DD/*.jpg 和同名 JSON
- 运行日志：~/Library/Application Support/留刻/lens.log
- 配置：~/Library/Application Support/留刻/config.json

## 关于 bundle id

打包用的 bundle id 固定是 app.memento.lens，不要改。改了之后 macOS 的录屏授权会失效，需要重新授权。

## 许可证

仓库暂时没有放 LICENSE 文件。代码公开不代表可以自由用于商业用途，有需要使用前请先联系作者。
