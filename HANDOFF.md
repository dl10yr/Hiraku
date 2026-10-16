# Copilot (GPT-5.4) 引き継ぎ指示書 — Hiraku

## 1. アプリ概要・要件
「行ったことがある場所の雲（霧）が晴れて地図が開かれていく」シンプルなGPSログアプリです。

### 必須要件
1. **常時・バックグラウンド計測**: 初回起動時に位置情報（`Always`）とモーション権限を取得し、起動中・バックグラウンドともにGPSログを蓄積。
2. **ワンタップ停止・再開**: 画面下部のボタン一発で即座に計測を止められる。
3. **雲が晴れる地図 (Fog of War)**: OpenStreetMap タイルを表示し、未訪問エリアは雲で覆い、1回でも訪れた場所の雲をくり抜く。
4. **交通手段の判別とフィルター**: 徒歩・自転車・電車/地下鉄・車を判別し、「すべて」と「徒歩のみ」で雲の開き方を切り替えられる。
5. **地下鉄・トンネル対策**: 地下に入ってGPSが途切れ・低精度化した際のノイズ除外と、地上復帰時の区間補間。
6. **とにかくシンプル**: 余計な画面遷移を設けず、1画面で完結。

---

## 2. 現在の実装状況（骨格作成済み）
Xcode 16+ の `PBXFileSystemSynchronizedRootGroup` を使用しているため、`Hiraku/` 直下に `.swift` ファイルを追加すれば自動でビルド対象になります。

- [`Hiraku-Info.plist`](file:///Users/shuhei/swift_projects/Hiraku/Hiraku-Info.plist): `UIBackgroundModes` (`location`) と位置情報・モーション権限の説明文を設定済み。
- [`Hiraku/TrackModels.swift`](file:///Users/shuhei/swift_projects/Hiraku/Hiraku/TrackModels.swift): `TransportMode`, `RevealFilter`, `TrackPoint` のデータモデル。
- [`Hiraku/LocationRecorder.swift`](file:///Users/shuhei/swift_projects/Hiraku/Hiraku/LocationRecorder.swift):
  - `CLLocationManager` + `CMMotionActivityManager` による位置・移動手段の記録。
  - JSON (`Documents/track_points.json`) への永続化。
  - 簡易的な地下鉄ワープ補間ロジック。
- [`Hiraku/FogMapView.swift`](file:///Users/shuhei/swift_projects/Hiraku/Hiraku/FogMapView.swift):
  - `OSMTileOverlay` (`tile.openstreetmap.org`、カスタム `User-Agent` 付き)。
  - `FogOverlay` / `FogOverlayRenderer` による雲の描画と円形くり抜き。
- [`Hiraku/MyApp.swift`](file:///Users/shuhei/swift_projects/Hiraku/Hiraku/MyApp.swift):
  - 地図 + 下部フローティングバー（「すべて / 徒歩のみ」切り替え、ワンタップ「停止 / 再開」ボタン）。

---

## 3. Copilot (GPT-5.4) にお願いしたい残タスク・ブラッシュアップ

以下の優先順で実装を仕上げてください。

### Task 1: 雲（Fog）描画のソフトエッジ化とパフォーマンス改善 (`FogMapView.swift`)
- 現在 `FogOverlayRenderer` は全 `TrackPoint` をループして単一円の `fillEllipse` でクリアしているため、点が増えると重くなり、境界もくっきりしすぎています。
- **改善内容**:
  - 連続するポイント間を太いライン（`CGContext.strokePath` + `lineCap = .round`）またはラジアルグラデーションで繋ぎ、雲が自然にふわっと晴れる見た目にする。
  - 点群が数万件に増えても60fpsで描画できるよう、グリッド（タイル/空間インデックス）または距離間引きで描画対象を絞る。

### Task 2: 地下鉄・交通手段判定の精度向上 (`LocationRecorder.swift`)
- 現在、地下鉄復帰時は2点間を単純に直線補間 (`isInterpolated = true`) しています。
- **改善内容**:
  - `CMMotionActivityManager` の過去履歴クエリ (`queryActivityStarting(from:to:to:withHandler:)`) を活用し、地下にいた時間帯のアクティビティ（歩行していたか、電車に乗っていたか）を地上復帰時に正確に振り返って判定する。
  - 地下入り口付近で `horizontalAccuracy` が急激に悪化したポイント（基地局・Wi-Fi由来のジャンプ）をより厳密にフィルタリングする。

### Task 3: データ蓄積のスケーラビリティ (`LocationRecorder.swift`)
- 現在はポイント更新のたびに配列全体を `track_points.json` に書き出しています。
- **改善内容**:
  - SwiftData / SQLite、または追記型ファイル（JSON Lines 等）＋一定間隔のフラッシュに変更し、長期間ログを貯めてもI/O負荷がかからないようにする。

### Task 4: 現在地追従ボタンの追加 (`MyApp.swift` / `FogMapView.swift`)
- シンプルさを損なわない範囲で、マップをスクロールした後に現在地へ戻れる小さなボタンを1つ追加する。
