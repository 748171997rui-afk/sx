# 销售看板 iOS App（云编译出签名 IPA）

手机 App 直连思迅公网系统（`http://1.12.232.80:8032`），不依赖你的电脑：
登录（验证码人工输入）→ 实时查询两张销售报表和实时库存，查过的商品/数据留在手机本地。
界面就是 `sixun-report/index.html`（iOS 直连模式自动裁剪：隐藏本地库专属模块，全部查询走实时接口）。

## 仓库结构

```
sixun-report/index.html        ← 看板页面（单一事实来源；iOS 引擎内置其中，电脑端不受影响）
ios-app/
  project.yml                  ← Xcode 工程描述（用 xcodegen 生成 .xcodeproj）
  App/BoardView.swift          ← SwiftUI 入口 + WKWebView 壳
  App/BridgeHandler.swift      ← sxboard:// 原生转发层（带 Cookie 直连思迅 / 验证码透传）
  App/Info.plist               ← App 配置（已放开 http ATS）
  Resources/index.html         ← 打包进 App 的页面（CI 自动从 sixun-report 同步；本地编译需手动拷）
exportOptions.plist            ← 导出签名 IPA 的配置（Secrets 注入占位符）
.github/workflows/build-ipa.yml ← GitHub Actions 云编译
```

## 使用步骤

1. **建 GitHub 仓库**，把整个目录推上去（至少包含 `sixun-report/index.html`、`ios-app/`、`exportOptions.plist`、`.github/`）。

2. **配 Secrets**（仓库 Settings → Secrets and variables → Actions → New repository secret）：

   | Secret | 内容 |
   |---|---|
   | `P12_BASE64` | Apple 开发者证书 .p12 的 base64。生成：`base64 -i 证书.p12 \| pbcopy`（Mac）或 Windows `certutil -encode 证书.p12 out.txt` 后取内容 |
   | `P12_PASSWORD` | 导出 .p12 时设的密码 |
   | `KEYCHAIN_PASSWORD` | 随便设一个强密码（CI 临时钥匙串用） |
   | `MOBILEPROVISION_BASE64` | 描述文件 .mobileprovision 的 base64（开发者后台下载，类型须与 EXPORT_METHOD 一致：真机直装用 ad-hoc 或 development） |
   | `APPLE_TEAM_ID` | Team ID（开发者账号 Membership 页，10 位） |
   | `SIGNING_CERT_NAME` | 证书常用名，如 `Apple Distribution: 你的公司名 (TEAMID)`，在钥匙串里能看到 |
   | `EXPORT_METHOD` | `ad-hoc`（分发给注册设备直装）或 `development` 或 `app-store-connect` |

3. **注册测试设备**：开发者后台 → Devices，把测试 iPhone 的 UDID 加进去；ad-hoc 描述文件要包含这些设备。

4. **跑编译**：GitHub 仓库 → Actions → Build iOS IPA → Run workflow。完成后在该次运行页下载 `SalesBoard-ipa` 工件，解压得到 `.ipa`。

5. **装到手机**：用 Apple Configurator（Mac）、Xcode Devices 窗口、或爱思助手/AltStore 把 ipa 装进已注册 UDID 的手机。

## App 里怎么用

1. 打开 App 会自动弹登录框：输思迅账号、密码、图片验证码（跟电脑端登录框完全一样，支持「强制登录」踢下线）。
2. 三个页签：卖场商品销售汇总 / 门店销售汇总 / 实时库存 —— 全部直连思迅实时接口，日期区间、类别/门店下拉、前十排行、CSV 导出都能用。
3. 实时库存页：输条码/编码直接查；查过的商品会记在手机里，输名称可以翻出最近查过的。
4. 数据只存在手机本地，退出登录即清空会话。

## 已知边界

- iOS 不允许 App 常驻后台，所以没有"每 60 秒自动比对"——打开 App 时查询即为实时数据。
- 库存「按名称搜全库」在 App 里只覆盖**最近查过的商品**（思迅库存接口没有名称条件，全库索引需要后台全量同步，那是电脑端做的事）。
- 修改了 `sixun-report/index.html` 后，重新推送 GitHub 即自动重新出包（CI 每次从 `sixun-report/` 同步页面）。
- 想换思迅地址：改 `BridgeHandler.swift` 里的 `target` 常量和 `index.html` 里 `sx_target` 的默认值。
