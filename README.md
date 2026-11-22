# DSH for iPad

一个独立的 iPad App：模型调用、agent 循环、工具执行、文件读写**全在 iPad 本地**，不连电脑、不走网页壳。模型用你自己填的 DeepSeek API key 调，不在这台 iPad 上跑任何大模型权重。

## 它是什么

- **原生 SwiftUI App**（不是 WKWebView 套壳）。对话、会话列表、设置都是原生界面，工具调用过程以卡片形式展开。
- **agent 循环写在 Swift 里**：调 `POST /chat/completions`（SSE 流式）→ 拿到 `tool_calls` → 在 iPad 上执行工具 → 结果回填给模型 → 循环，直到模型不再要工具。
- **工具真的在这台 iPad 上跑**，不是转发给电脑：

  | 工具 | 干什么 |
  | --- | --- |
  | `list_dir` / `read_file` / `write_file` / `make_dir` / `delete_path` / `move_path` | 读写 App 沙盒里的工作目录 |
  | `fetch_url` | 用 URLSession 抓网页正文（HTML 会去标签） |
  | `run_js` | 在 JavaScriptCore 里跑 JS，用 `console.log` 看输出 |
  | `now` | 当前时间 |

- **文件在 iPad 上**：工作目录是 App 沙盒的 `Documents/workspace`，开了 `UIFileSharingEnabled`，所以能在系统「文件」App 的 **我的 iPad → DSH** 里看到、拖文件进拖文件出。
- **API key 存 Keychain**，不落 UserDefaults、不写进会话文件。
- **任务运行时提醒别切走**：发任务前弹一次确认，运行时顶部常驻条提示；切到后台会立刻标明「iOS 可能要挂起这个 App」，被打断后回来会给一句明确的原因，而不是一句莫名其妙的网络错误。

## 它不是

- **不是把模型装进 iPad。** 用的是 DeepSeek 的 API，需要网络，需要你自己的 key。
- **没有 shell。** iOS 不允许 App 起子进程（没有 `fork`/`exec`），所以不能跑命令行、不能编译代码、不能 `git`。要算数、处理文本就在 `run_js` 里跑。这是系统限制，不是实现偷懒。
- **不能阻止你切走 App。** iPadOS 只给后台几十秒（本 App 会申请一段 background task 宽限），超时后请求会被切断。真需要长时间不被打断，可以在系统设置里开「引导式访问」把自己锁在这个 App 里。

## 目录结构

```
dsh-ipad
├── .github/workflows/build-ipa.yml   GitHub Actions：macOS 上编出未签名 ipa
├── App/
│   ├── DSHApp.swift                  @main
│   ├── AppModel.swift                会话状态、SSE 请求、工具循环、持久化、后台提醒
│   ├── Models.swift                  传输与本地数据结构
│   ├── Tools.swift                   工作目录沙盒 + 9 个工具的实现
│   ├── Keychain.swift                API key 存取
│   ├── Views.swift                   界面（会话列表 / 聊天 / 设置）
│   ├── Info.plist
│   └── Assets.xcassets/              AppIcon
├── scripts/make-icon.py              从 DSH 原始图标生成 1024 AppIcon
├── project.yml                       XcodeGen 工程描述
└── README.md
```

## 一、出未签名 ipa（GitHub Actions）

本机没有 git，所以用 GitHub 网页上传，让 Actions 在 macOS 机器上编译（跑 iOS 构建必须 macOS + Xcode，Windows 上编不了）。

1. 在 GitHub 建一个仓库（私有仓库也可以；macOS runner 会消耗 Actions 分钟数）。
2. 仓库页面 → **Add file → Upload files**，把 `dsh-ipad` 里的**全部内容**拖进去：
   - `project.yml`、`App\`、`scripts\`、`README.md`、`.gitignore`
   - **一定要保留 `.github/workflows/build-ipa.yml`**（这是构建流水线本身；网页上传偶尔会漏掉 `.github` 这种隐藏目录，漏了就用 **Add file → Create new file** 手动新建同名路径，把内容粘进去）
   - 不要上传 `build\`、`artifacts\`、`*.ipa`
3. 提交到 `main`。触发方式任选：往 `main` 推送、打 `v*` tag（如 `v1.0.0`），或仓库 **Actions → build-ipa → Run workflow** 手动触发。
4. job 变绿后，在运行详情页底部下载 **DSH-ipa** artifact，解压得到 `DSH.ipa`。

流水线做的事：`brew install xcodegen` → `xcodegen generate` → `xcodebuild -sdk iphoneos ... CODE_SIGNING_ALLOWED=NO` → PlistBuddy 校验 `CFBundleIdentifier` / `CFBundleDisplayName` / `MinimumOSVersion` → 打包成 `Payload/DSH.app` 的 ipa → 上传 artifact（保留 30 天）。编译日志里 Swift 报错会原样出现，把报错贴给我就行。

## 二、签名并安装

Actions 产出的是**未签名** ipa：编译阶段关掉了签名，所以**没有 Apple 开发者账号也能编出来**，但它不能直接装。装到 iPad 上需要你用自有工具重签：

1. 用你的签名工具给 `DSH.ipa` 重签；
2. bundle id 可以按你的证书改（默认 `com.dsh.ipad`）；
3. 自签/免签描述文件通常 7 天过期，过期后 App 打不开，重签再装一次。

App 要求 **iPadOS 16.0+，仅 iPad**（用了 `NavigationSplitView`）。

## 三、第一次打开要做的事

1. 右上角齿轮 → 填 **DeepSeek API key**（`sk-...`）；接口地址默认 `https://api.deepseek.com`，用中转就改这里；模型默认 `deepseek-chat`。
2. 发第一条消息。第一次会弹一次「任务运行期间别切走」的确认——这是提醒，不是限制；关掉它可以在设置里把「开跑前提醒别切走」关掉。
3. 想让它读写文件：直接把要求说清楚（「在工作目录建一个 notes.md，写三条本周待办」）。文件落在 **文件 App → 我的 iPad → DSH** 里，也可以先把文件拖进去再让它读。

## 四、限制与注意事项

- **需要网络**：模型走 DeepSeek API。断网时工具（文件、JS、时间）还能用，模型调用不行。
- **iOS 只给 App 有限的后台时间**：长任务跑到一半切走，网络请求会被挂起切断，回来能看到明确的中断提示。别在长任务跑到一半时切 App。
- **没有 shell / 编译器 / git**：见上文「它不是」。
- **App 卸载后工作目录一起没了**：重要文件自己导出到别处。
- **API key 等于钱包**：key 存在本机 Keychain 里，别把 App 数据整个导出给别人，只装在自己信任的设备上。
- 会话存在 `Documents/sessions.json`，工作目录在 `Documents/workspace`。
