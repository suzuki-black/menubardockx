# MenuBarDockX

**macOS のメニューバーを、見える場所に取り戻す。**

> macOS 14 (Sonoma) 以降 / Apple Silicon & Intel 対応  
> 言語: Swift / AppKit / サードパーティ依存ゼロ / ローカル完結

---

## なぜ MenuBarDockX が必要なのか

macOS Tahoe では Control Center の拡張など各種改善はあるものの、  
メニューバーに収まりきらないサードパーティ製アイコンを一覧・操作できる  
**公式のオーバーフロー UI はいまだ存在しない。**[^overflow]

常駐アプリが増えるにつれて、アイコンは単純に右端から消えていく。  
ノッチ搭載 Mac ではその傾向がさらに顕著で、アイコンは黙って画面の裏に隠れる。

「VPN が切れていないか」「同期エージェントが動いているか」「セキュリティツールが有効か」——  
**見えない＝動いていない、という誤解がワークフローを静かに壊す。**

これは UI の好みの問題ではなく、ワークフローの信頼性の問題だ。

MenuBarDockX はこの問題に対して、ひとつのシンプルな答えを出す：  
**すべてのメニューバーアイコンを、フローティングパネルに整理して表示・操作できるようにする。**

---

## MenuBarDockX の立ち位置

MenuBarDockX は「アイコンを隠す」ツールではない。

Bartender などの既存ツールは「見せる／隠す」の整理に軸足を置いているが、  
MenuBarDockX の目的は異なる：

- **すべてのアイコンを一覧できる**　　　　→ 「見えない」問題の根本解決
- **カテゴリで整理できる**　　　　　　　　→ 目的別に素早くアクセス
- **左クリック・右クリックを正確に転送できる** → コンテキストメニューも含めて完全操作
- **ノッチに隠れたアイコンを専用パネルに逃がす** → ノッチ Mac での視認性を確保
- **完全ローカル完結・外部通信ゼロ**　　　→ 何を使っているかが外に漏れない

セキュリティ・VPN・開発ツールなど「常時確認が必要なアプリ」を  
カテゴリタブに整理して置けることが、このツールの核心にある。

---

## 主な機能

| 機能 | 説明 |
|------|------|
| メニューバーアイコン一覧 | 実行中の全アプリのメニューバー項目を AX API で取得・表示 |
| カテゴリタブ | すべて / システム / 開発 / クラウド / セキュリティ / ユーティリティ（カスタム追加可） |
| キーワード検索 | パネル内の検索フィールドでリアルタイム絞り込み |
| グローバルショートカット | デフォルト `⌥⌘M` でパネルをトグル表示（変更可能）|
| 左クリック／右クリック転送 | AXPressAction + CGEvent フォールバックで正確に転送 |
| ノッチ対応オーバーフローパネル | ノッチに隠れたアイコンを専用パネルで表示・操作 |
| ウィンドウスナップ | 画面端への 20px スナップ（0.12s easeOut アニメーション）|
| 自動分類ルール | Docker / JetBrains / Dropbox / 1Password / Raycast など主要アプリを自動分類 |
| カスタム分類ルール | `user_rules.json` でユーザー独自の分類ルールを追加可能 |

---

## 動作環境

| 項目 | 要件 |
|------|------|
| OS | macOS 14 (Sonoma) 以降 |
| アーキテクチャ | Apple Silicon (arm64) / Intel (x86_64) |
| 権限 | アクセシビリティ権限（初回起動時に案内）|

> **動作確認について:**  
> 現時点での開発・動作確認環境は **macOS 15 (Sequoia / Tahoe)** のみです。  
> ノッチ搭載 Mac（Apple Silicon + Notch）での実機検証は未実施です。入手次第、検証予定。

---

## インストール

### ステータス: インストーラ配布 準備中

コードサイニング・ノータリゼーション対応および DMG/PKG 形式のインストーラ公開は **現在準備中** です。  
Apple Developer Program への登録など諸手続きに時間がかかるため、配布開始時期は未定です。

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

## 権限について

| 権限 | 用途 |
|------|------|
| アクセシビリティ | メニューバー項目の取得・クリック操作（AXUIElement API）|
| 画面収録（一部環境） | アイコン画像取得のフォールバック（CGWindowListCreateImage）|

MenuBarDockX は取得した情報を **一切外部に送信しません。**  
ネットワーク通信コードは存在せず、すべての処理はローカルで完結します。  
（[ソースコードで確認できます](MenuBarDockX/)）

---

## OSS としての設計方針

- **ローカル完結** — サーバ依存なし、テレメトリなし、アカウント不要
- **検証可能** — App Sandbox 無効の理由を含め、すべてのコードを公開
- **拡張可能** — 分類ルールを JSON で追加できる設計
- **Apple 純正 API のみ** — サードパーティライブラリへの依存ゼロ

---

## ロードマップ

### 近い将来（予定）

- [ ] ノッチ搭載 Mac での実機検証・対応
- [ ] Code Signing / Notarization 対応
- [ ] DMG インストーラ公開
- [ ] 英語 README の追加

### アイデア段階（実装を約束するものではありません）

- 使用頻度ベースのアイコン自動並び替え
- 一時的な「フォーカスカテゴリ」機能（業務モード切り替え等）
- CLI / macOS Shortcuts アプリからのランチャー呼び出し
- トラブルシューティング用 Debug Overlay
- Read-only モード（操作せず状態確認のみ）
- カテゴリ分類の自動学習

---

## ビルド構成

| 項目 | 内容 |
|------|------|
| 言語 | Swift 5 |
| UI フレームワーク | AppKit（SwiftUI 不使用）|
| 最低 OS | macOS 14.0 |
| サードパーティ依存 | なし |
| App Sandbox | 無効（AX API 使用のため）|
| Hardened Runtime | 準備中 |

---

## Issue / フィードバック

バグ報告・機能要望は [Issues](../../issues) にてお気軽にどうぞ。  
動作確認環境（OS バージョン・Mac モデル）を添えていただけると助かります。

---

## ライセンス

[^overflow]: Control Center はシステム標準コントロール（Wi-Fi・Bluetooth・音量など）をまとめる Apple 独自の機能であり、サードパーティ製ステータスアイコンのオーバーフロー機構ではない。また `NSStatusItem.isVisible` はアイコンが実際には隠れていても `true` を返すため、アプリ側が「自分のアイコンが見えているか」を検知する公式 API も存在しない。参考: Jesse Squires — [How to fix Mac menu bar icons hidden by the MacBook notch](https://www.jessesquires.com/blog/2023/12/16/macbook-notch-and-menu-bar-fixes/) / Michael Tsai — [Mac Menu Bar Icons and the Notch](https://mjtsai.com/blog/2023/12/08/mac-menu-bar-icons-and-the-notch/)

[MIT License](LICENSE)

Copyright (c) 2026 suzuki-black
