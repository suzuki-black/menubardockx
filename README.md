# MenuBarDockX

<p align="center">
  <img src="docs/screenshots/icon.png" alt="MenuBarDockX" width="128">
</p>

<p align="center">
  <strong>Bring your hidden menu bar icons back into view.</strong><br>
  <sub>macOS のメニューバーを、見える場所に取り戻す。</sub>
</p>

<p align="center">
  macOS 14 (Sonoma) or later &nbsp;/&nbsp; Apple Silicon &amp; Intel<br>
  Swift / AppKit / Zero third-party dependencies / Fully local
</p>

<p align="center">
  <a href="../../releases/tag/v1.0.0"><img src="https://img.shields.io/badge/version-v1.0.0-blue" alt="v1.0.0"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey">
  <img src="https://img.shields.io/badge/license-MIT-green">
</p>

---

<!-- ============================================================ -->
<!--  ENGLISH                                                      -->
<!-- ============================================================ -->

## Overview

MenuBarDockX is a macOS menu bar utility that collects icons hidden behind the notch or pushed off-screen and displays them in a floating overflow panel — right below where they disappeared.

No subscription. No telemetry. No external server. Everything runs locally.

---

## Screenshots

| Overflow Panel | Settings Panel | DEBUG Menu (Debug build only) |
|:---:|:---:|:---:|
| ![overflow](docs/screenshots/overflow_panel.png) | ![settings](docs/screenshots/settings_panel_en.png) | ![debug](docs/screenshots/debug_menu_en.png) |
| Background color sampled from the real menu bar | Brightness ×1.10 / Saturation ×0.88 | DEBUG section (hidden in Release builds) |

---

## Why MenuBarDockX?

macOS has no official overflow UI for third-party status icons.[^overflow]

As more apps run in the background, their icons silently vanish off the right edge of the menu bar. On notch-equipped Macs the problem is even worse — icons disappear behind the notch entirely.

"Is my VPN still connected?" "Is the sync agent running?" "Is the security tool active?" —  
**"Out of sight" quietly erodes workflow reliability.**

MenuBarDockX gives a simple answer: **surface every hidden icon in an organized floating panel you can actually see and click.**

---

## Features

| Feature | Description |
|---------|-------------|
| Auto overflow detection | When icons are hidden, the app icon automatically switches to ▾ |
| Overflow panel | Left-click ▾ to open the floating panel and interact with icons |
| Left / right click forwarding | Accurate forwarding via AXPressAction + CGEvent fallback |
| Menu bar color sampling | Panel background auto-matches the real menu bar color |
| Category tabs | All / System / Development / Cloud / Security / Utility |
| Auto-classification rules | Docker, JetBrains, Dropbox, 1Password, Raycast, and more |
| Edit mode | Drag to reorder, drag to tab to assign category, or right-click to change category |

### Overflow indicator behavior

```
← Left (hidden first)                Right (stable) →

Normal:   [hidden icons…] 🔵 🟠 📦  [App icon]  |System|
                                          ↑
                                Left/Right click → Settings menu

Overflow: [hidden icons…] 🔵 🟠 📦  [   ▾   ]  |System|
                                          ↑
                                Left click  → Overflow panel
                                Right click → Settings menu
```

---

## Installation

### Status: installer distribution coming soon

Code signing, notarization, and DMG packaging are **currently in preparation**.  
Watch the [Releases](../../releases) page for announcements.

### Build from source (recommended for now)

```bash
git clone https://github.com/suzuki-black/MenuBarDockX.git
cd MenuBarDockX
xcodebuild -project MenuBarDockX.xcodeproj \
           -scheme MenuBarDockX \
           -configuration Release \
           CONFIGURATION_BUILD_DIR=./build/Release
open ./build/Release/MenuBarDockX.app
```

If Gatekeeper warns you on first launch, go to  
**System Settings → Privacy & Security** and click "Open Anyway".

> **Note:** App Sandbox is disabled because the Accessibility API requires it.  
> All source code is public — you can verify exactly what the app does.

---

## Permissions

| Permission | Purpose | Where to grant |
|-----------|---------|----------------|
| Accessibility | Read and click menu bar items (AXUIElement API) | System Settings → Privacy & Security → Accessibility |
| Screen Recording *(some setups)* | Capture icon images and sample background color (CGWindowListCreateImage) | System Settings → Privacy & Security → Screen Recording |

### How to grant Accessibility permission

1. Launch MenuBarDockX (a dialog appears automatically on first launch)
2. Open **System Settings → Privacy & Security → Accessibility**
3. Find **MenuBarDockX** in the list and turn the toggle ON
4. Restart MenuBarDockX

MenuBarDockX **never sends any data externally.**  
There is no networking code — all processing happens on your device.

---

## Usage

### App menu

Left-click the app icon in the menu bar.

| Item | Description |
|------|-------------|
| About MenuBarDockX… | Shows app name, version, and copyright |
| Quit MenuBarDockX | Quit the app (`⌘Q`) |
| — DEBUG — *(Debug builds only)* | See debug features below |

### Edit Mode

Edit mode lets you reorder icons and assign categories.

**How to enter edit mode:**

1. Left-click **▾** to open the overflow panel
2. Click the **gear icon** (top-right of the panel) to open settings
3. Press the **"Edit Mode" button** at the top of settings (shows "✏️ Editing" when ON)

Press the same button again to exit edit mode.

**Controls in edit mode:**

| Action | Effect |
|--------|--------|
| Drag icon (within icon row) | Reorder icons in the panel |
| Drag icon onto a tab | Assign to that tab's category |
| Right-click icon | Show category selection menu |

**Visual feedback:**

- A white dashed border appears around each icon
- A ghost view and drop indicator appear while dragging
- The target tab highlights when you drag an icon over it
- The gear icon becomes fully opaque to indicate edit mode is active

**Persistence:** Reorder and category changes are saved across restarts  
(`~/Library/Application Support/MenuBarDockX/items.json`)

---

## Settings

Open with the gear button (top-right of the overflow panel).

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| Edit Mode | OFF | — | Enables drag reorder and category assignment |
| Display Mode | Flat | Flat / Category | Flat: one row. Category: tabbed view |
| Icon Width | 40 pt | 32–48 pt (2 pt steps) | Width of each icon cell |
| Brightness | ×1.10 | 0.80–1.20 | Background brightness correction |
| Saturation | ×0.88 | 0.70–1.10 | Background saturation correction |
| Background Opacity | 1.0 | 0.0–1.0 | 0.0 = transparent / 1.0 = solid sampled color |
| Close panel on click | ON | — | Auto-close the panel after clicking an icon |

---

## Debug features (Debug build only)

When built in `Debug` configuration, a **orange `— DEBUG —`** section appears in the right-click menu.  
Completely excluded from `Release` builds via `#if DEBUG`.

| Item | Description |
|------|-------------|
| Simulate Notch | Renders a 200 pt virtual notch at screen center |
| Fill bar with dummy icons | Adds dummy NSStatusItems to test overflow behavior |
| Always show JetBrains Toolbox | Forces Toolbox visible to verify click forwarding |
| Dummy icon count (submenu) | Choose 1 / 2 / 3 / 5 / 8 / 10 / 15 / 20 |
| Check Accessibility permission | Reports current permission state; opens System Settings if needed |

---

## Background color engine

The panel background is generated by **real-time sampling of the actual menu bar color**,  
automatically adapting to wallpaper-derived blur, light/dark mode, and menu bar translucency.

```
① CGWindowListCreateImage
   └ Capture the full menu bar width at pixel resolution
        ↓
② Slice the center 1px row
   └ A thin strip spanning full width (~2880px on Retina 2x)
        ↓
③ CIGaussianBlur (radius = 240px)
   └ Smooth horizontally to eliminate rainbow banding
   └ clampedToExtent() prevents darkening at edges
        ↓
④ CIColorControls
   └ brightness ×1.10 / saturation ×0.88
   └ Approximates macOS vibrancy appearance
        ↓
⑤ layer.contentsRect
   └ Display only the horizontal slice matching the panel's X position
   └ Color always matches exactly what is directly above the panel
```

**Re-sampling triggers:**
- Light/Dark mode switch (`NSSystemColorsDidChange`)
- Wallpaper change (`NSWorkspace.activeSpaceDidChangeNotification`)
- Panel shown (`showPanel()`)

---

## Schema migration

Settings stored in UserDefaults are version-checked on launch.  
Users with older settings automatically receive new defaults.

| Version | Change |
|---------|--------|
| v1 | Initial release (`panelOpacity` = blur opacity) |
| v2 | Inverted `panelOpacity` meaning (0.0 = transparent / 1.0 = opaque) |
| v3 | Re-assured v2 migration (handles incomplete migration cases) |
| v4 | Replaced NSVisualEffectView with pure NSView + sampled color. Default `panelOpacity` → 1.0 |
| v5 (current) | Updated `blendBrightness` to 1.10; auto-overwrites existing UserDefaults |

Migration runs once at launch via `DataStore.migrateIfNeeded()`, managed by the `"schemaVersion"` key.

---

## Requirements

| Item | Requirement |
|------|-------------|
| OS | macOS 14 (Sonoma) or later |
| Architecture | Apple Silicon (arm64) / Intel (x86_64) |
| Permission | Accessibility (prompted on first launch) |

> **Tested on:** macOS 15 (Sequoia) / Apple Silicon (notch model)  
> Intel Mac / macOS 14 (Sonoma) have not been formally tested.

---

## For developers

### Build configuration

| Item | Detail |
|------|--------|
| Language | Swift 5 |
| UI framework | AppKit (no SwiftUI) |
| Minimum OS | macOS 14.0 |
| Third-party dependencies | None |
| App Sandbox | Disabled (required for AX API) |

### File responsibilities

| File | Role |
|------|------|
| `AppDelegate.swift` | App launch, StatusItem management, menu construction |
| `DataStore.swift` | UserDefaults persistence, schema migration (`migrateIfNeeded`) |
| `OverflowUI.swift` | Overflow panel UI, edit mode, background color sampling (`MenuBarGradientSampler`) |
| `DebugMenuManager.swift` | Debug menu, simulated notch, dummy icons (`#if DEBUG`) |
| `MenuBarEnumerator.swift` | Menu bar item enumeration via AX API |
| `EnvironmentChecker.swift` | Accessibility permission check and report |
| `Category.swift` | Category definitions and auto-classification rules |
| `MenuBarItem.swift` | Menu bar item model and DTO |

### OSS design principles

- **Fully local** — No servers, no telemetry, no accounts required
- **Verifiable** — All code is public, including why App Sandbox is disabled
- **Extensible** — Classification rules are designed to be added via JSON
- **Apple APIs only** — Zero third-party library dependencies

---

## Roadmap

### Near-term (planned)

- [x] Verified on notch-equipped Mac (macOS 15 / Apple Silicon)
- [x] Menu bar color sampling for panel background (blur + brightness/saturation)
- [x] Edit mode (drag reorder, drag-to-tab category assignment, right-click category change)
- [x] Category persistence across restarts
- [x] v1.0.0 stable release
- [x] Bilingual README (English + Japanese)
- [ ] Verified on Intel Mac / macOS 14 (Sonoma)
- [ ] Code Signing / Notarization
- [ ] DMG installer release

### Ideas (not committed)

- Usage-frequency-based auto sorting
- "Focus category" mode (work context switching)
- Read-only mode (status monitoring without interaction)
- Machine-learned auto-classification

---

## Issues / Feedback

Bug reports and feature requests are welcome via [Issues](../../issues).  
Please include your macOS version and Mac model.

---

## License

[MIT License](LICENSE)  
Copyright © 2026 suzuki-black

---

<!-- ============================================================ -->
<!--  日本語                                                       -->
<!-- ============================================================ -->

<br>

---

<p align="center"><strong>— 日本語 —</strong></p>

---

## 概要

MenuBarDockX は、ノッチに隠れたり画面外に押し出されたメニューバーアイコンを収集し、フローティングパネルに表示する macOS ユーティリティです。

サブスクリプションなし。テレメトリなし。外部サーバーなし。すべてローカルで完結します。

---

## スクリーンショット

| オーバーフローパネル | 設定パネル | DEBUG メニュー（Debug ビルドのみ）|
|:---:|:---:|:---:|
| ![overflow](docs/screenshots/overflow_panel.png) | ![settings](docs/screenshots/settings_panel_ja.png) | ![debug](docs/screenshots/debug_menu_ja.png) |
| メニューバーと色が一致した背景 | 明度 ×1.10 / 彩度 ×0.88 | DEBUG セクション（Release では非表示）|

---

## なぜ MenuBarDockX が必要なのか

macOS には、メニューバーに収まりきらないサードパーティ製アイコンを一覧・操作できる  
**公式のオーバーフロー UI が存在しない。**[^overflow]

常駐アプリが増えるにつれて、アイコンは右端から黙って消えていく。  
ノッチ搭載 Mac ではその傾向がさらに顕著で、アイコンは画面の裏に隠れる。

「VPN が切れていないか」「同期エージェントが動いているか」「セキュリティツールが有効か」——  
**見えない＝動いていない、という誤解がワークフローを静かに壊す。**

MenuBarDockX はこの問題に対してひとつのシンプルな答えを出す：  
**隠れたメニューバーアイコンを、フローティングパネルに整理して表示・操作できるようにする。**

---

## 主な機能

| 機能 | 説明 |
|------|------|
| オーバーフロー自動検出 | 隠れたアイコンを検出すると自動でアプリアイコンが ▾ に切り替わる |
| オーバーフローパネル | ▾ 左クリックでフローティングパネルを表示・操作 |
| 左クリック／右クリック転送 | AXPressAction + CGEvent フォールバックで正確に転送 |
| メニューバー色サンプリング | パネル背景をメニューバーの実際の色に自動追従させる |
| カテゴリ表示 | すべて / システム / 開発 / クラウド / セキュリティ / ユーティリティでタブ分け |
| 自動分類ルール | Docker / JetBrains / Dropbox / 1Password / Raycast など主要アプリを自動分類 |
| 編集モード | パネル内でアイコンをドラッグして並び替え、タブへドラッグまたは右クリックでカテゴリを変更 |

### オーバーフローインジケーターの動作

```
← 左（隠れやすい）              右（安定）→

通常時:  [隠れたアイコン…] 🔵 🟠 📦  [アプリアイコン]  |システム|
                                              ↑
                                    左右クリック → 設定メニュー

溢れ時:  [隠れたアイコン…] 🔵 🟠 📦  [    ▾    ]  |システム|
                                              ↑
                                    左クリック  → オーバーフローパネル
                                    右クリック  → 設定メニュー
```

---

## インストール

### ステータス: インストーラ配布 準備中

コードサイニング・ノータリゼーション対応および DMG 配布は **現在準備中** です。  
配布開始時は [Releases](../../releases) ページにてお知らせします。

### ソースからビルドして使う（現時点の推奨手順）

```bash
git clone https://github.com/suzuki-black/MenuBarDockX.git
cd MenuBarDockX
xcodebuild -project MenuBarDockX.xcodeproj \
           -scheme MenuBarDockX \
           -configuration Release \
           CONFIGURATION_BUILD_DIR=./build/Release
open ./build/Release/MenuBarDockX.app
```

初回起動時に Gatekeeper の警告が表示される場合は、  
**システム設定 → プライバシーとセキュリティ** から「このまま開く」を選択してください。

> **注意:** アクセシビリティ API を使用するため、App Sandbox は無効化されています。  
> ソースコードはすべて公開されており、何をしているかは自分で確認できます。

---

## 必要な権限

| 権限 | 用途 | 設定場所 |
|------|------|----------|
| アクセシビリティ | メニューバー項目の取得・クリック操作（AXUIElement API）| システム設定 → プライバシーとセキュリティ → アクセシビリティ |
| 画面収録（一部環境）| アイコン画像取得・背景色サンプリング（CGWindowListCreateImage）| システム設定 → プライバシーとセキュリティ → 画面収録 |

### アクセシビリティ権限の許可手順

1. MenuBarDockX を起動する（初回起動時に自動でダイアログが表示される）
2. **システム設定 → プライバシーとセキュリティ → アクセシビリティ** を開く
3. リストに **MenuBarDockX** が表示されていることを確認し、トグルを ON にする
4. MenuBarDockX を再起動する

MenuBarDockX は取得した情報を **一切外部に送信しません。**  
ネットワーク通信コードは存在せず、すべての処理はローカルで完結します。

---

## 使い方

### アプリメニューの構成

アプリアイコンを左クリックすると表示されるメニューです。

| 項目 | 説明 |
|------|------|
| About MenuBarDockX… | アプリ名・バージョン・著作権情報を表示 |
| Quit MenuBarDockX | アプリを終了（ショートカット: `⌘Q`）|
| — DEBUG — *(Debug ビルドのみ)* | 以下のデバッグ項目を含む |

### 編集モード

**編集モードの入り方:**

1. **▾** を左クリックしてオーバーフローパネルを開く
2. パネル右上の **歯車アイコン** をクリックして設定パネルを開く
3. 設定パネル最上部の **「Edit Mode」ボタン** を押す（「✏️ Editing」と表示されれば ON）

編集モードを終了するには、同じボタンをもう一度押します。

**操作方法:**

| 操作 | 効果 |
|------|------|
| アイコンをドラッグ（アイコン行内） | パネル内でアイコンの表示順を並び替え |
| アイコンをタブへドラッグ | ドロップしたタブのカテゴリに割り当て |
| アイコンを右クリック | カテゴリ選択メニューを表示してカテゴリを変更 |

**視覚フィードバック:**

- 各アイコンに白い点線ボーダーが表示されます
- ドラッグ中はゴーストビューとドロップ位置インジケーターが表示されます
- アイコンをタブ上にドラッグすると対象タブがハイライトされます
- 歯車アイコンが完全不透明になり、編集中であることを示します

**永続化:** 並び替えとカテゴリ変更はアプリ終了後も保持されます  
（`~/Library/Application Support/MenuBarDockX/items.json`）

---

## 設定項目一覧

歯車ボタン（パネル右上）から変更できます。

| 設定項目 | デフォルト | 範囲 | 説明 |
|----------|-----------|------|------|
| Edit Mode | OFF | — | ON にするとドラッグ並び替え・カテゴリ変更が可能 |
| Display Mode | Flat | Flat / Category | Flat: 全アイコンを一列表示。Category: タブで分類表示 |
| Icon Width | 40 pt | 32〜48 pt（2 pt 刻み）| アイコンセルの幅 |
| Brightness | ×1.10 | 0.80〜1.20 | 背景色の明度補正 |
| Saturation | ×0.88 | 0.70〜1.10 | 背景色の彩度補正 |
| Background Opacity | 1.0 | 0.0〜1.0 | 0.0=透明 / 1.0=サンプリング色でソリッド表示 |
| Close panel on click | ON | — | アイコンクリック後にパネルを自動で閉じる |

---

## デバッグ機能（Debug ビルド限定）

`Debug` configuration でビルドした場合のみ、右クリックメニューに  
**オレンジ色の `— DEBUG —`** セクションが表示されます。  
`Release` ビルドでは `#if DEBUG` により完全に除外されます。

| デバッグ項目 | 説明 |
|-------------|------|
| Simulate Notch | 画面中央に 200pt 幅の仮想ノッチを表示し、ノッチ搭載環境をシミュレート |
| Fill bar with dummy icons | 指定個数の NSStatusItem を追加してオーバーフロー状態をテスト |
| Always show JetBrains Toolbox | Toolbox を強制表示して左右クリック転送の動作を検証 |
| Dummy icon count（サブメニュー）| 1 / 2 / 3 / 5 / 8 / 10 / 15 / 20 個から選択 |
| Check Accessibility permission | 現在の権限状態を確認。未許可の場合はシステム設定へ誘導 |

---

## オーバーフローパネルの背景色（技術解説）

パネル背景は **メニューバーの実際の色をリアルタイムサンプリング** して再現します。  
壁紙由来の blur 色・ライト/ダークモード・メニューバーの透明度すべてに自動追従します。

```
① CGWindowListCreateImage
   └ メニューバー全幅をピクセル解像度でキャプチャ
        ↓
② 中央 1px 行を切り出し
   └ 幅全体 × 1px の細長い画像（Retina 2x では ~2880px 幅）
        ↓
③ CIGaussianBlur (radius = 240px)
   └ 横方向に平滑化して虹色縞を除去
   └ clampedToExtent() で端部の暗化アーティファクトを防止
        ↓
④ CIColorControls
   └ brightness ×1.10 / saturation ×0.88
        ↓
⑤ layer.contentsRect でスライスを指定
   └ パネルの X 位置に対応する水平スライスのみ表示
```

**自動再サンプリングのトリガー:**
- ライト/ダーク切り替え（`NSSystemColorsDidChange`）
- 壁紙変更（`NSWorkspace.activeSpaceDidChangeNotification`）
- パネル表示時（`showPanel()` 直後）

---

## スキーママイグレーション

UserDefaults の設定値は起動時にバージョンチェックされ、  
古い設定のまま使っているユーザーにも新しいデフォルト値が自動適用されます。

| バージョン | 変更内容 |
|-----------|---------|
| v1 | 初期リリース（`panelOpacity` = blur の不透明度）|
| v2 | `panelOpacity` の意味を反転（0.0=透明 / 1.0=不透明）|
| v3 | v2 移行の再保証（不完全移行ケースへの対処）|
| v4 | NSVisualEffectView を廃止、純 NSView + サンプリング色方式に移行 |
| v5（現在）| `blendBrightness` を 1.10 に更新。既存ユーザーの UserDefaults を自動上書き |

移行は `DataStore.migrateIfNeeded()` が `init()` の直後に 1 回だけ実行します。

---

## 動作環境

| 項目 | 要件 |
|------|------|
| OS | macOS 14 (Sonoma) 以降 |
| アーキテクチャ | Apple Silicon (arm64) / Intel (x86_64) |
| 権限 | アクセシビリティ権限（初回起動時に案内）|

> **動作確認環境:** macOS 15 (Sequoia) / Apple Silicon（ノッチ搭載）  
> Intel Mac / macOS 14 (Sonoma) での動作確認は未実施です。

---

## 開発者向け情報

### ビルド構成

| 項目 | 内容 |
|------|------|
| 言語 | Swift 5 |
| UI フレームワーク | AppKit（SwiftUI 不使用）|
| 最低 OS | macOS 14.0 |
| サードパーティ依存 | なし |
| App Sandbox | 無効（AX API 使用のため）|

### ファイル構成と責務

| ファイル | 責務 |
|---------|------|
| `AppDelegate.swift` | アプリ起動・StatusItem 管理・メニュー構築 |
| `DataStore.swift` | UserDefaults 永続化・スキーマ移行（`migrateIfNeeded`）|
| `OverflowUI.swift` | オーバーフローパネル UI・編集モード・背景色サンプリング（`MenuBarGradientSampler`）|
| `DebugMenuManager.swift` | デバッグメニュー・擬似ノッチ・ダミーアイコン管理（`#if DEBUG`）|
| `MenuBarEnumerator.swift` | AX API によるメニューバー項目の列挙 |
| `EnvironmentChecker.swift` | アクセシビリティ権限の確認・レポート表示 |
| `Category.swift` | カテゴリ定義・自動分類ルール |
| `MenuBarItem.swift` | メニューバー項目モデル・DTO |

### コード整合性チェック（v1.0.0 時点）

| チェック項目 | 状態 | 補足 |
|-------------|------|------|
| ランチャー関連 dead code の除去 | ✅ 完了 | 6 ファイル削除、AppDelegate・DataStore から参照を完全除去 |
| `DataStore.windowFrame` / `shortcut` の削除 | ✅ 完了 | ランチャー専用だったプロパティを除去 |
| `AppDelegate.checkPermissions()` の削除 | ✅ 完了 | メニュー項目削除に伴う dead code を除去 |
| アクセシビリティ権限確認の移動先 | ✅ 完了 | `DebugMenuManager.checkPermissions()` に集約 |
| `DataStore.migrateIfNeeded()` の起動順序 | ✅ 完了 | `init()` の最後、他の処理より前に実行 |
| `OverflowSettings` デフォルト値と `decodeIfPresent` フォールバックの一致 | ✅ 完了 | `blendBrightness = 1.10`、`blendSaturation = 0.88` で統一 |
| `defaultBlurRadius` の統一 | ✅ 完了 | `MenuBarGradientSampler.defaultBlurRadius = 240` |
| `#if DEBUG` による Release からの除外 | ✅ 完了 | `DebugMenuManager` 全体と `addDebugSection` 呼び出し |
| `migrateIfNeeded` の冪等性 | ✅ 完了 | `schemaVersion = 5` 到達後は二度と実行されない |
| `PassthroughView` のトラッキング干渉 | ✅ 完了 | `updateTrackingAreas()` / `cursorUpdate(with:)` を空実装で抑制 |
| 歯車ボタンの hitTest 優先順位 | ✅ 完了 | `OverflowPanelContent.hitTest` でボタンを先行判定 |
| タブの hitTest 修正 | ✅ 完了 | `bounds` → `frame` に変更し、正しいタブが選択されるよう修正 |
| 再起動後のカテゴリ保持 | ✅ 完了 | `enumerateHiddenItems(merging:)` で DTO の `categoryID` / `id` を復元 |
| タブへのドラッグ＆ドロップ | ✅ 完了 | 編集モード中にアイコンをタブにドロップしてカテゴリ割り当て可能 |
| カテゴリ割り当て後のタブ遷移 | ✅ 完了 | 割り当て後は `refreshContent(selectCategoryID: Category.allItems.id)` で「すべて」タブへ戻る |

### OSS としての設計方針

- **ローカル完結** — サーバ依存なし、テレメトリなし、アカウント不要
- **検証可能** — App Sandbox 無効の理由を含め、すべてのコードを公開
- **拡張可能** — 分類ルールを JSON で追加できる設計
- **Apple 純正 API のみ** — サードパーティライブラリへの依存ゼロ

---

## ロードマップ

### 近い将来（予定）

- [x] ノッチ搭載 Mac での実機検証（macOS 15 / Apple Silicon で確認済み）
- [x] オーバーフローパネル背景のメニューバー色サンプリング（blur + 明度/彩度補正）
- [x] 編集モード（ドラッグ並び替え・タブへのドラッグ＆ドロップでカテゴリ変更・右クリックカテゴリ変更）
- [x] カテゴリ設定の再起動後永続化
- [x] v1.0.0 安定版リリース
- [x] 英日二言語 README
- [ ] Intel Mac / macOS 14 (Sonoma) での動作確認
- [ ] Code Signing / Notarization 対応
- [ ] DMG インストーラ公開

### アイデア段階（実装を約束するものではありません）

- 使用頻度ベースのアイコン自動並び替え
- 一時的な「フォーカスカテゴリ」機能（業務モード切り替え等）
- Read-only モード（操作せず状態確認のみ）
- カテゴリ分類の自動学習

---

## リリースノート

### v1.0.0 — 最初の安定版リリース

> **[GitHub Releases](../../releases/tag/v1.0.0)** からダウンロード可能（配布準備中）

**ランチャー機能の廃止とオーバーフローパネルへの統合**
- 独立したランチャーウィンドウ（480×480pt）を廃止
- ランチャー関連の 6 ファイルを削除、アイコン並び替え・カテゴリ変更をオーバーフローパネル内の編集モードに統合

**編集モード（新機能）**
- 設定パネルの「✏️ Edit Mode」ボタンで ON/OFF を切り替え
- アイコンのドラッグ並び替え・タブへのドラッグ＆ドロップでカテゴリ割り当て・右クリックカテゴリ変更

**カテゴリ設定の永続化（バグ修正）**
- 再起動後にカテゴリ割り当てが消えていた問題を修正
- `enumerateHiddenItems(merging:)` が保存済み DTO の `categoryID` と `id` を引き継ぐよう変更

**背景色エンジン**
- `CIGaussianBlur` (radius=240px) + 明度/彩度補正でメニューバー色をリアルタイム再現

**インジケーター変更**
- オーバーフローインジケーターを `⟫` から `▾` に変更（パネルが下方向に開くことを明示）

---

## Issue / フィードバック

バグ報告・機能要望は [Issues](../../issues) にてお気軽にどうぞ。  
動作確認環境（OS バージョン・Mac モデル）を添えていただけると助かります。

---

## ライセンス

[MIT License](LICENSE)  
Copyright © 2026 suzuki-black

---

[^overflow]: Control Center is Apple's own control surface for system features (Wi-Fi, Bluetooth, volume, etc.) — it is not an overflow mechanism for third-party status icons. Furthermore, `NSStatusItem.isVisible` returns `true` even when an icon is actually hidden, so there is no official API for apps to detect whether their own icon is visible. See: Jesse Squires — [How to fix Mac menu bar icons hidden by the MacBook notch](https://www.jessesquires.com/blog/2023/12/16/macbook-notch-and-menu-bar-fixes/) / Michael Tsai — [Mac Menu Bar Icons and the Notch](https://mjtsai.com/blog/2023/12/08/mac-menu-bar-icons-and-the-notch/)
