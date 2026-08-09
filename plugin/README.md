# plugin — amenbo プラグイン（Go）

利用者の PC（Windows / macOS / Linux）で動く。amenbo が変わるたびに、動いたレコードだけを
1件ずつ暗号化して置き場へ運ぶ。全量を通るのは初回・リセット・取りこぼしのときだけ。

| 経路 | 動く条件 |
|---|---|
| iCloud Drive のフォルダへ書く | mac |
| Cloudflare Worker へ `PUT` する | すべての OS |

2つは択一ではない。同じものを2か所へ置くだけなので、両方を同時に有効にできる。

Cloudflare 経路は、Worker と KV を利用者のアカウントに立てるところまで手伝う。
立てたあとの持ち主は利用者で、プラグインを消しても Worker と KV は残る。

## 面

| | |
|---|---|
| 観測面（引数なし） | amenbo がイベントで起動する。プロジェクトが変わったという合図として読み、動いたぶんを運ぶ |
| コマンド面 | `setup` ／ `push` ／ `qr`。stdout が返り値、stderr が人の読むもの、終了コードが判定 |

`push` は**取り残しを手で押し出す口**。観測面が自分で運ぶので、通らなかった回のぶんを後から
押し出すときに使う。**`setup` と `qr`、それに iCloud 経路への書き込みはまだ無い。**

## 設定

| キー | |
|---|---|
| `icloud_folder` | iCloud Drive のどこへ書くか（mac のみ）。利用者が手で入れるのはこれだけ |
| `worker_url` | `setup` が入れる |
| `auth_token` | `setup` が入れる（secret） |
| `encryption_key` | `setup` が入れる（secret）。端末へは QR で渡し、ネットワークには出さない |

## 作る

```
make build     # viewer を作る
make test      # gofmt / go vet / go test と、manifest の検証
make dist      # リリース資産一式と、カタログに貼る digest
```
