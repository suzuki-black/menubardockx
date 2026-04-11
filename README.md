# MenuBarDockX

macOS のメニューバーに常駐するアイコンを、フローティングパネルに整理して表示・操作できるランチャーアプリです。

> macOS 14 (Sonoma) 以降対応 / Apple Silicon & Intel 対応

---

## 概要

macOS のメニューバーは常駐アプリが増えるにつれて窮屈になり、ノッチ搭載 Mac ではアイコンが隠れてしまうこともあります。  
MenuBarDockX はメニューバーのアイコンをすべて取得し、カテゴリ別に整理されたフローティングパネルからワンクリックで操作できます。

---

## 主な機能

- **メニューバーアイコン一覧表示** — 実行中の全アプリのメニューバー項目を取得して表示
- **カテゴリタブ** — すべて / システム / 開発 / クラウド / セキュリティ / ユーティリティ（カスタム追加も可能）
- **キーワード検索** — パネル内の検索フィールドでアイコンを絞り込み
- **グローバルショートカット** — デフォルト `⌥⌘M` でパネルをトグル表示（変更可能）
- **ノッチ対応オーバーフローパネル** — ノッチに隠れたアイコンを専用パネルで表示
- **左クリック / 右クリック** — アイコンへの左右クリックを正確に転送（右クリックメニューにも対応）
- **ウィンドウスナップ** — 画面端に近づくと自動でスナップ（20px 閾値）
- **分類ルール** — Docker・JetBrains・Dropbox・1Password・Raycast など主要アプリを自動分類。ユーザーカスタムルールも追加可能

---

## 動作環境

| 項目 | 要件 |
|------|------|
| OS | macOS 14 (Sonoma) 以降 |
| アーキテクチャ | Apple Silicon (arm64) / Intel (x86_64) |
| 権限 | アクセシビリティ権限（起動時に案内）|

---

## インストール

### DMG からインストール（推奨）

1. [Releases](../../releases) ページから最新の `MenuBarDockX-x.x.x.dmg` をダウンロード
2. DMG を開き `MenuBarDockX.app` を `/Applications` へドラッグ
3. 初回起動時に Gatekeeper の確認が表示された場合は、**システム設定 → プライバシーとセキュリティ** から「このまま開く」を選択
4. アクセシビリティ権限のダイアログが表示されたら許可する

### ソースからビルド

```bash
git clone https://github.com/<your-username>/MenuBarDockX.git
cd MenuBarDockX
xcodebuild -project MenuBarDockX.xcodeproj \
           -scheme MenuBarDockX \
           -configuration Release \
           CONFIGURATION_BUILD_DIR=./build/Release
open ./build/Release/MenuBarDockX.app
```

> **注意:** アクセシビリティ API および画面キャプチャを使用するため、App Sandbox は無効化されています。

---

## 使い方

1. アプリを起動するとメニューバーに `⊟` アイコンが表示されます
2. `⌥⌘M`（または メニューバーアイコンをクリック → ランチャーを開く）でパネルを表示
3. カテゴリタブやキーワード検索で目的のアイコンを探してクリック
4. 右クリックでコンテキストメニューを表示

### ショートカット変更

メニューバーアイコン → ショートカット設定 から変更できます（`⌥⌘M` がデフォルト）。

### カスタム分類ルール

`~/Library/Application Support/MenuBarDockX/user_rules.json` にルールを追加することで、  
独自アプリのカテゴリ分類をカスタマイズできます。

---

## 権限について

| 権限 | 用途 |
|------|------|
| アクセシビリティ | メニューバー項目の取得・クリック操作 |
| 画面収録（一部環境） | アイコン画像の取得フォールバック |

MenuBarDockX は取得した情報を外部に送信しません。すべての処理はローカルで完結します。

---

## ビルド構成

| 項目 | 内容 |
|------|------|
| 言語 | Swift 5 |
| UI フレームワーク | AppKit（SwiftUI 不使用）|
| 最低 OS | macOS 14.0 |
| App Sandbox | 無効（AX API 使用のため）|
| Hardened Runtime | 無効（開発中）|

---

## ライセンス

[MIT License](LICENSE)

Copyright (c) 2026 suzuki-black
