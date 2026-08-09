# plugin — amenbo プラグイン（Go）

利用者の PC（Windows / macOS / Linux）で動く。amenbo が変わるたびに、動いたレコードだけを
1件ずつ暗号化して置き場へ運ぶ。全量を通るのは初回・リセット・取りこぼしのときだけ。

| 経路 | 動く条件 |
|---|---|
| アプリ専用の iCloud フォルダへ書く | mac ＋ **端末でアプリを一度開いてあること** |
| Cloudflare Worker へ `PUT` する | すべての OS |

2つは択一ではない。同じものを2か所へ置くだけなので、両方を同時に有効にできる。

Cloudflare 経路は、Worker とデータベースを利用者のアカウントに立てるところまで手伝う。
立てたあとの持ち主は利用者で、プラグインを消しても残る。

## iCloud 経路に設定は無い

書き先はアプリ専用のコンテナで固定。

```
~/Library/Mobile Documents/iCloud~work~amenbo~viewer/Documents/
```

**このディレクトリはプラグインが作れない。** `~/Library/Mobile Documents` は所有者にも書き込めず、
`mkdir` はファイルプロバイダに拒まれる。生やすのは OS で、契機は**端末でアプリを一度開くこと**
（mac にアプリは要らない）。生えた後は素のプロセスが普通に書ける。

だから**ディレクトリの実在がスイッチ**になる。設定は無く、食い違いようもない。無い状態は故障ではなく
**待ち**で、利用者がやることは「アプリを一度開く」だけ。

`brctl` がこのコンテナを `SYNC DISABLED (app not installed)` と表示することがあるが、同期は通る。
**判定に使わない。**

## 面

| | |
|---|---|
| 観測面（引数なし） | amenbo がイベントで起動する。プロジェクトが変わったという合図として読み、動いたぶんを運ぶ |
| コマンド面 | `setup` ／ `push` ／ `qr`。stdout が返り値、stderr が人の読むもの、終了コードが判定 |

`push` は**取り残しを手で押し出す口**。観測面が自分で運ぶので、通らなかった回のぶんを後から
押し出すときに使う。**`setup` と `qr`、それに iCloud 経路への書き込みはまだ無い。**

## 設定

**利用者が手で入れるものは1つも無い。** 3つとも `setup` が書く。

| キー | |
|---|---|
| `worker_url` | `setup` が入れる |
| `auth_token` | `setup` が入れる（secret） |
| `encryption_key` | `setup` が入れる（secret）。端末へは QR で渡し、ネットワークには出さない |

## 作る

```
make build     # viewer を作る
make test      # gofmt / go vet / go test と、manifest の検証
make dist      # リリース資産一式と、カタログに貼る digest
```
