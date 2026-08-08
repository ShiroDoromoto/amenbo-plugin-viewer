# amenbo-plugin-viewer

PC から離れているあいだも、スマートフォンから [**amenbo**](https://github.com/ShiroDoromoto/amenbo)
のタスクの進み具合を見る。**amenbo Viewer** の実装。

amenbo 本体は外部と通信しない。運営もデータをホスティングしない。**置き場は利用者が持つもの**で、
そこへ暗号化したスナップショットを片方向に運ぶ。

## 何が入っているか

| 部品 | 動く場所 |
|---|---|
| プラグイン | 利用者の PC（Windows / macOS / Linux） |
| Worker | 利用者の Cloudflare |
| iOS アプリ | iPhone |
| Android アプリ | Android 端末 |

4つは同じ契約（スナップショットの形式・暗号の形式・QR に載せるもの・エンドポイントの仕様）を
共有する。**契約が変わると4つとも変わる**ので、1つのリポジトリに置いてある。

## 経路は2つ

| 利用者 | 経路 | 利用者の手数 |
|---|---|---|
| **mac ＋ iPhone** | **iCloud Drive**（基本） | **ゼロ** |
| それ以外の組み合わせ | Cloudflare Worker ＋ KV（救済） | アカウントとトークンの用意 |

置き場が違うだけで、運ぶ物・暗号・一方通行・全量の上書きは共通である。

## ドキュメント

| | |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | アーキテクチャ。2つの経路、Worker の役割、暗号、鍵の受け渡し |
| [`docs/implementation.md`](docs/implementation.md) | 4つの部品でやること。名前の対応、外部の手続き |
| [`docs/sequencing.md`](docs/sequencing.md) | 本体・カタログと跨ぐ依存、壊さない順序 |

## 名前

| | 名前 |
|---|---|
| リポジトリ | `amenbo-plugin-viewer` |
| アプリ名（ストア表示） | **amenbo Viewer** |
| バンドル ID / パッケージ名 | `work.amenbo.viewer` |

## 状態

**設計中。** 実装は始まっていない。本体側で必要な口も未実装なので、
[`docs/sequencing.md`](docs/sequencing.md) の順序に沿って進める。
