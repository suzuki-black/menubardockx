# MenuBarDockX

<p align="center">
  <!-- アプリアイコン（差し替え予定: docs/screenshots/icon.png） -->
  <img src="docs/screenshots/icon.png" alt="MenuBarDockX" width="128">
</p>

<p align="center">
  <strong>macOS のメニューバーを、見える場所に取り戻す。</strong>
</p>

<p align="center">
  macOS 14 (Sonoma) 以降 &nbsp;/&nbsp; Apple Silicon &amp; Intel 対応<br>
  Swift / AppKit / サードパーティ依存ゼロ / ローカル完結
</p>

<p align="center">
  <a href="../../releases/tag/v1.0.0"><img src="https://img.shields.io/badge/version-v1.0.0-blue" alt="v1.0.0"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey">
  <img src="https://img.shields.io/badge/license-MIT-green">
</p>

---

## スクリーンショット

<!-- スクリーンショットは差し替え予定。blur=240px / brightness=1.10 / saturation=0.88 適用済み UI -->

| オーバーフローパネル | 設定パネル | DEBUG メニュー（Debug ビルドのみ）|
|:---:|:---:|:---:|
| ![overflow](docs/screenshots/overflow_panel.png) | ![settings](docs/screenshots/settings_panel.png) | ![debug](docs/screenshots/debug_menu.png) |
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
| オーバーフロー自動検出 | 隠れたアイコンを検出すると自動でアプリアイコンが ⟫ に切り替わる |
| オーバーフローパネル | ⟫ 左クリックでフローティングパネルを表示・操作 |
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

溢れ時:  [隠れたアイコン…] 🔵 🟠 📦  [    ⟫    ]  |システム|
                                              ↑
                                    左クリック  → オーバーフローパネル
                                    右クリック  → 設定メニュー
```

---

## アプリメニューの構成

アプリアイコンを左クリックすると表示されるメニューです。

| 項目 | 説明 |
|------|------|
| このアプリについて… | アプリ名・バージョン・著作権情報を表示 |
| MenuBarDockX を終了 | アプリを終了（ショートカット: `⌘Q`）|
| — DEBUG — *(Debug ビルドのみ)* | 以下のデバッグ項目を含む |
| 　擬似ノッチ | ノッチ環境をシミュレート |
| 　ダミーアイコンでバーを埋める | オーバーフロー状態をテスト |
| 　JetBrains Toolbox を常に表示 | 左右クリック転送を検証 |
| 　ダミーアイコン数（サブメニュー）| 1〜20 個から選択 |
| 　アクセシビリティ権限を確認 | 権限状態の確認・設定へ誘導 |

---

## 編集モード

### 編集モードの入り方

1. **⟫** を左クリックしてオーバーフローパネルを開く
2. パネル右上の **歯車アイコン** をクリックして設定パネルを開く
3. 設定パネル最上部の **「編集モード」ボタン** を押す（「✏️ 編集中」と表示されれば ON）

編集モードを終了するには、同じボタンをもう一度押します。

### 操作方法

| 操作 | 効果 |
|------|------|
| アイコンをドラッグ（アイコン行内） | パネル内でアイコンの表示順を並び替え |
| アイコンをタブへドラッグ | ドロップしたタブのカテゴリに割り当て |
| アイコンを右クリック | カテゴリ選択メニューを表示してカテゴリを変更 |

### 編集モードの視覚フィードバック

- 各アイコンに白い点線ボーダーが表示されます
- ドラッグ中はゴーストビューとドロップ位置インジケーターが表示されます
- アイコンをタブ上にドラッグすると対象タブがハイライトされます
- 歯車アイコンが完全不透明になり、編集中であることを示します

### 変更の永続化

並び替えとカテゴリ変更はアプリ終了後も保持されます。  
データは Application Support / MenuBarDockX / items.json に保存されます。

---

## オーバーフローパネルの背景色（技術解説）

パネル背景は **メニューバーの実際の色をリアルタイムサンプリング** して再現します。  
壁紙由来の blur 色・ライト/ダークモード・メニューバーの透明度すべてに自動追従します。

### 処理パイプライン

```
① CGWindowListCreateImage
   └ メニューバー全幅をピクセル解像度でキャプチャ
        ↓
② 中央 1px 行を切り出し
   └ 幅全体 × 1px の細長い画像（Retina 2x では ~2880px 幅）
        ↓
③ CIGaussianBlur (radius = 240px)
   └ 横方向に平滑化して虹色縞を除去
   └ Retina 2x: 240px ≈ 120pt 相当のぼかし
   └ clampedToExtent() で端部の暗化アーティファクトを防止
        ↓
④ CIColorControls
   └ brightness ×1.10 / saturation ×0.88
   └ macOS vibrancy 相当の明度・低彩度に近づける
        ↓
⑤ layer.contentsRect でスライスを指定
   └ パネルの X 位置に対応する水平スライスのみ表示
   └ パネルがどの位置にあっても真下の色と一致
```

### 自動再サンプリングのトリガー

- ライト/ダーク切り替え（`NSSystemColorsDidChange`）
- 壁紙変更（`NSWorkspace.activeSpaceDidChangeNotification`）
- パネル表示時（`showPanel()` 直後）

---

## 設定項目一覧

歯車ボタン（パネル右上）から変更できます。

| 設定項目 | デフォルト | 範囲 | 説明 |
|----------|-----------|------|------|
| 編集モード | OFF | — | ON にするとドラッグ並び替え・カテゴリ変更が可能 |
| 表示モード | フラット | フラット / カテゴリ | フラット: 全アイコンを一列表示。カテゴリ: タブで分類表示 |
| アイコン幅 | 40pt | 32〜48pt（2pt 刻み）| アイコンセルの幅 |
| 明度補正 | ×1.10 | 0.80〜1.20 | 背景色の明度補正。vibrancy 相当の明度に調整済み |
| 彩度補正 | ×0.88 | 0.70〜1.10 | 背景色の彩度補正。vibrancy 相当の低彩度に調整済み |
| 背景の不透明度 | 1.0 | 0.0〜1.0 | 0.0=透明 / 1.0=サンプリング色でソリッド表示 |
| クリック後にパネルを閉じる | ON | — | アイコンクリック後にパネルを自動で閉じる |

---

## デバッグ機能（Debug ビルド限定）

`Debug` configuration でビルドした場合のみ、右クリックメニューに  
**オレンジ色の `— DEBUG —`** セクションが表示されます。  
`Release` ビルドでは `#if DEBUG` により完全に除外されます。

| デバッグ項目 | 説明 |
|-------------|------|
| 擬似ノッチ (Simulate Notch) | 画面中央に 200pt 幅の仮想ノッチを表示し、ノッチ搭載環境をシミュレート |
| ダミーアイコンでバーを埋める | 指定個数の NSStatusItem を追加してオーバーフロー状態をテスト |
| JetBrains Toolbox を常に表示 | Toolbox を強制表示して左右クリック転送の動作を検証 |
| ダミーアイコン数（サブメニュー）| 1 / 2 / 3 / 5 / 8 / 10 / 15 / 20 個から選択 |
| アクセシビリティ権限を確認 | 現在の権限状態を確認。未許可の場合はシステム設定へ誘導 |

---

## スキーママイグレーション

UserDefaults の設定値は起動時にバージョンチェックされ、  
古い設定のまま使っているユーザーにも新しいデフォルト値が自動適用されます。

| バージョン | 変更内容 |
|-----------|---------|
| v1 | 初期リリース（`panelOpacity` = blur の不透明度）|
| v2 | `panelOpacity` の意味を反転（0.0=透明 / 1.0=不透明）|
| v3 | v2 移行の再保証（不完全移行ケースへの対処）|
| v4 | NSVisualEffectView を廃止、純 NSView + サンプリング色方式に移行。`panelOpacity` デフォルト → 1.0 |
| v5（現在）| `blendBrightness` を 1.10 に更新。既存ユーザーの UserDefaults を自動上書き |

移行は `DataStore.migrateIfNeeded()` が `init()` の直後に 1 回だけ実行します。  
`"schemaVersion"` キーで管理し、最新バージョン到達後は二度と走りません。

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

## ライセンス

[MIT License](LICENSE)  
Copyright © 2026 suzuki-black

---

## リリースノート

### v1.0.0 — 最初の安定版リリース

> **[GitHub Releases](../../releases/tag/v1.0.0)** からダウンロード可能（配布準備中）

**ランチャー機能の廃止とオーバーフローパネルへの統合**
- 独立したランチャーウィンドウ（480×480pt）を廃止
- ランチャー関連の 6 ファイル（`LauncherWindowController.swift`・`LauncherViewController.swift`・`MagneticWindowManager.swift`・`CategoryTabView.swift`・`IconItemView.swift`・`GlobalShortcutManager.swift`）を削除
- グローバルショートカット（⌥⌘M）・ウィンドウスナップを削除
- アイコンの並び替え・カテゴリ変更をオーバーフローパネル内の **編集モード** に統合

**編集モード（新機能）**
- 設定パネルの「✏️ 編集モード」ボタンで ON/OFF を切り替え
- 編集モード中はアイコンをドラッグして並び順を変更可能（sortOrder に永続化）
- 編集モード中にアイコンをタブへドラッグ＆ドロップしてカテゴリを割り当て可能（categoryID に永続化）
- 編集モード中に右クリックするとカテゴリ選択メニューが表示される（categoryID に永続化）
- 各アイコンに白い点線ボーダーを表示してモード中であることを視覚的に示す

**カテゴリ設定の永続化（バグ修正）**
- 再起動後にカテゴリ割り当てが消えていた問題を修正
- `enumerateHiddenItems(merging:)` が保存済み DTO の `categoryID` と `id` を引き継ぐよう変更し、再起動後もカテゴリ設定が保持されるように

**歯車ボタンのヒットエリア改善**
- 歯車ボタンのクリック可能範囲を 18pt → 28pt に拡大（見た目のアイコンサイズは変わらない）
- `OverflowPanelContent.hitTest` で歯車ボタンを優先判定（PassthroughView との干渉を解消）
- `zPosition = 9999` で確実に最前面に配置

**背景色エンジン**
- メニューバーの色をリアルタイムサンプリングするグラデーション方式を実装
- `CIGaussianBlur` (radius=240px) で虹色縞を完全除去
- `clampedToExtent()` による端部暗化アーティファクトの防止
- `layer.contentsRect` でパネル位置に対応した水平スライスを正確に表示

**設定・UI**
- 明度補正（×1.10）・彩度補正（×0.88）スライダーを追加
- クリック後にパネルを閉じるオプションを追加
- 「このアプリについて…」メニュー項目を追加（バージョン・著作権情報を表示）

**デバッグ機能**
- `— DEBUG —` セクションを `#if DEBUG` で隔離（Release ビルドでは完全非表示）
- アクセシビリティ権限確認を Debug メニューに移動（通常メニューからは削除）
- 擬似ノッチ・ダミーアイコン・JetBrains Toolbox 固定表示を実装

**スキーママイグレーション**
- v5: `blendBrightness` を 1.10 に更新。既存ユーザーの設定を自動書き換え
- `DataStore.migrateIfNeeded()` による冪等な移行処理

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
- [ ] Intel Mac / macOS 14 (Sonoma) での動作確認
- [ ] Code Signing / Notarization 対応
- [ ] DMG インストーラ公開
- [ ] 英語 README の追加

### アイデア段階（実装を約束するものではありません）

- 使用頻度ベースのアイコン自動並び替え
- 一時的な「フォーカスカテゴリ」機能（業務モード切り替え等）
- Read-only モード（操作せず状態確認のみ）
- カテゴリ分類の自動学習

---

## Issue / フィードバック

バグ報告・機能要望は [Issues](../../issues) にてお気軽にどうぞ。  
動作確認環境（OS バージョン・Mac モデル）を添えていただけると助かります。

---

[^overflow]: Control Center はシステム標準コントロール（Wi-Fi・Bluetooth・音量など）をまとめる Apple 独自の機能であり、サードパーティ製ステータスアイコンのオーバーフロー機構ではない。また `NSStatusItem.isVisible` はアイコンが実際には隠れていても `true` を返すため、アプリ側が「自分のアイコンが見えているか」を検知する公式 API も存在しない。参考: Jesse Squires — [How to fix Mac menu bar icons hidden by the MacBook notch](https://www.jessesquires.com/blog/2023/12/16/macbook-notch-and-menu-bar-fixes/) / Michael Tsai — [Mac Menu Bar Icons and the Notch](https://mjtsai.com/blog/2023/12/08/mac-menu-bar-icons-and-the-notch/)
