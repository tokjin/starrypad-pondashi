# Starrypad Pondashi

`Starrypad Pondashi` は、macOS 向けのDONNER Starrypadに特化したサンプラーパッドアプリです。  
MIDI パッドコントローラーからノート/CC を受け取り、48 スロット（3 バンク × 16 パッド）のサンプル再生を行います。

![メイン画面（左: コントロール / 中央: パッドグリッド / 右: インスペクタ）](docs/screenshot.png)

## 主な機能

- 48 スロットのサンプル管理（3 バンク × 16 パッド）
- パッドごとの詳細設定
  - ループ再生
  - フェードイン / フェードアウト
  - 再生開始位置（ms）
  - チョークグループ
  - ノートオフ追従（ゲート）
  - ベロシティ感度
  - 再トリガー動作（重ねる / 停止 / フェード停止 / 再スタート）
- MIDI マッピング
  - パッド学習（bank A/B/C）
  - フェーダー/ノブ CC 学習
  - Program Change やボタンによるバンク切替
- フェーダー / ノブ割り当て
  - マスター、PAN、コンプ、ピッチ、再生速度、リバーブ/ディレイ関連
- パッド間ドラッグ&ドロップ
  - 通常ドロップ: 置き換え（移動）
  - `Option` + ドロップ: 複製
- プリセット（キット）保存/読込（JSON）
- プロファイル JSON のエクスポート、および Application Support への保存
- 音声出力デバイス選択（システム既定 / 個別デバイス）

## 動作環境

- macOS 13.0 以降
- Xcode（Swift 5）

## 起動方法

1. このリポジトリを取得
2. `StarrypadPondashi.xcodeproj` を Xcode で開く
3. ターゲット `StarrypadPondashi` を選択して実行

## 基本的な使い方

1. **MIDI 入力を選択**  
   アプリの「設定」タブで MIDI ソースとチャンネルを指定します。
2. **パッドに音声を割り当て**  
   - パッドをクリックしてインスペクタを開き「音声を割当…」  
   - または Finder から音声ファイルをドラッグ&ドロップ
3. **再生・調整**  
   パッドクリックまたは MIDI ノート入力で再生し、インスペクタや左パネルから挙動を調整します。
4. **必要に応じて保存**  
   「設定」タブからプリセット保存/読込、プロファイル保存を行います。

## 保存データの場所

アプリは主に以下へデータを保存します（`~/Library/Application Support/StarrypadPondashi` 配下）。

- `Samples/` : 取り込んだ音声ファイル
- `Presets/` : プリセット関連データ
- `Profiles/` : 保存した MIDI プロファイル

## 付属プロファイル

- `StarrypadPondashi/Resources/StarrypadDefault.json`
  - 初期マッピング定義（パッドノート、フェーダー/ノブ CC、バンク切替など）

## 開発メモ

- UI: SwiftUI
- MIDI: CoreMIDI
- Audio: AVAudioEngine / AudioUnit
- テストターゲットは現状未作成です。

