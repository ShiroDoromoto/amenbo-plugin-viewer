# app — amenbo Viewer（Flutter）

iOS と Android を1本で作る。`ios/` と `android/` は Flutter がこの下に生成する。

| | 値 |
|---|---|
| ストア表示名 | amenbo Viewer |
| バンドル ID / パッケージ名 | `work.amenbo.viewer` |
| Dart のパッケージ名 | `amenbo_viewer` |

表示名は日英どちらでも通るので、言語ごとに変えず揃える。

iOS は2経路を持つ。iCloud Drive のフォルダを読む経路と、Cloudflare へ HTTPS で取りに行く経路。
Android は Cloudflare 経路だけ。復号した後の扱いはどちらも同じで、書き戻さない。

## 単独で完成していること

ストアの承認スケジュールは制御できない。このビルドが、まだ対応していない amenbo 本体や
プラグインと同居する状況は普通に起こる。だから検証に本体もプラグインも要らない形にしておく。
CI（[`.github/workflows/app.yml`](../.github/workflows/app.yml)）が `app/` だけで回るのは、
その要件をそのまま置いたもの。

ペアリング前は正常系。エラーにも空白にもせず、何をすればよいかの案内を出す。

## 署名

署名の情報はリポジトリに入れない。実機ビルドのときは Xcode で Team を選ぶ。
CI は `--no-codesign`。

## 動かす

```
make build   # pub get と analyze
make test    # flutter test
make apk     # Android。Android SDK が要る
make ipa     # iOS。Mac と Xcode が要る。署名はしない
```
