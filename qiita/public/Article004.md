---
title: 【Go】Cloud SQLとGoのタイムゾーン沼を脱出する。「loc=local」に潜む9時間ズレの罠
tags:
  - Go
  - RDB
  - cloudsql
  - タイムゾーン
  - GoogleCloud
private: false
updated_at: '2026-02-12T09:34:23+09:00'
id: dbedccbe1fa2342bf77f
organization_url_name: null
slide: false
ignorePublish: false
---
# はじめに

[前回の記事](https://qiita.com/horirinn2000/items/f6360e960540d4d298f3)の続き、5回目の投稿です。

これまでは gRPC や Cloud Run の接続周りの話をしてきましたが、今回はもっと身近で、かつ<strong>地味にハマり続ける「タイムゾーン（Timezone）」</strong>の話をします。

Go × Cloud Run × Cloud SQL (MySQL/PostgreSQL) で開発していると、ふとした瞬間に<strong>「あれ？時間が9時間ズレてる？」</strong>という現象に遭遇しませんか？
今回は、ついやってしまいがちな<strong>「`loc=local` 設定の危険性」</strong>と、コンテナ環境での正しい対処法についてまとめます。

# 先に結論

* **`loc=local` は使うな**: 環境によって挙動が変わるリスクを排除しましょう。
* **APIは常にUTCを返す**: 変換はフロントエンドの責務。ISO 8601形式（`Z`付き）で返しましょう。
* **表示変換はヘルパー化する**: CSVやメールなど、どうしてもGo側でJSTが必要な時だけ `ToJST()` を使います。

# よくある間違い：`loc=local` の罠

Go で MySQL を使う際、標準的なドライバである `go-sql-driver/mysql` を使うことが多いと思います。
この DSN（接続文字列）の設定で、以下のようにしていませんか？

```go
// 危険な設定
dsn := "user:pass@tcp(db-host:3306)/dbname?parseTime=true&loc=local"
```

この `loc=local` は、「Go が動いているサーバー（OS）のタイムゾーン設定を使う」という意味です。
これがなぜ危険なのか、私の実体験を交えて解説します。

## 「たまたま動いている」だけの状態

ローカル開発環境（Mac/Windows）は JST なので、`loc=local` でも期待通り JST として動きます。
しかし、Cloud Run などのコンテナ環境はデフォルトで **UTC** です。そのままデプロイすると、本番環境だけ時間が9時間ズレます。

これを防ぐために、Dockerfile に以下のような記述をして無理やり解決しているケースをよく見かけます（かつての私もそうでした）。

```dockerfile
# Alpine Linuxの例（非推奨）
RUN apk add --no-cache tzdata && \
    cp /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
```

こうすればコンテナの OS 設定が JST になるため、`loc=local` でも JST として動作します。
しかし、これは<strong>「アプリケーションの挙動が、Dockerfile の特定のコマンドに依存している」</strong>という非常に脆い状態です。

もし将来、ベースイメージを `distroless` に変えたり、この `cp` コマンドをうっかり消したりすると、**アプリのコードは1行も変えていないのに、静かにデータが壊れ始めます**。

# 正解：コードで明示する

解決策はシンプルです。環境（OS）の設定に頼らず、コード（DSN）でタイムゾーンを明示しましょう。

## MySQLの場合

### パターンA：DB は UTC で保存する（推奨）

Cloud SQL はデフォルトで UTC です。グローバル対応やサマータイムを考慮すると、**内部データは UTC で統一**するのが最も安全です。

```go
// 推奨設定
dsn := "user:pass@tcp(db-host:3306)/dbname?parseTime=true&loc=UTC"
```

* **`loc=UTC`**: DB の `DATETIME` を「UTC」として解釈して `time.Time` に変換します。
* OS の設定が JST だろうが UTC だろうが、常に正しく動作します。

### パターンB：どうしても JST で保存したい

既存システムの都合などで、DB に JST の時間をそのまま入れたい場合も、`local` ではなく明示的に指定します。

```go
// URLエンコードが必要なので注意
dsn := "user:pass@tcp(db-host:3306)/dbname?parseTime=true&loc=Asia%2FTokyo"
```

## PostgreSQLの場合 (`pgx` / `lib/pq`)

PostgreSQL の場合、ドライバの設定というよりは **セッションタイムゾーン** の設定になります。
特に `TIMESTAMPTZ` 型を使っている場合、接続時に指定したタイムゾーンに合わせてサーバー側が時間を変換して返してくれます。

```go
// 推奨設定 (UTC統一)
// pgx などのドライバを使用する場合
dsn := "postgres://user:pass@db-host:5432/dbname?timezone=UTC"
```

PostgreSQL でも同様に、OS の環境変数に依存させるのではなく、接続文字列（DSN）のパラメータ timezone=UTC (または Asia/Tokyo) で明示的にコントロールするのがベストプラクティスです。

# 実装例：内部 UTC / 表示 JST

「DB は UTC だか、画面には JST で出したい」という場合の、Language & Timezone Selection Design に基づいた実装例です。

## 1. Dockerfile の修正

無理に `/etc/localtime` を書き換える必要はありませんが、Go がタイムゾーン情報を読み込めるように `tzdata` だけは入れておきます。

**Alpine の場合:**
```dockerfile
# これだけでOK。cpコマンドは不要。
RUN apk add --no-cache tzdata
```

**Distroless の場合:**
ビルドステージから `zoneinfo.zip` をコピーします。

```dockerfile
# Builder stage
FROM golang:1.23 as builder
# ... ビルド処理 ...

# Runtime stage
FROM gcr.io/distroless/static-debian13
COPY --from=builder /usr/local/go/lib/time/zoneinfo.zip /zoneinfo.zip
ENV ZONEINFO=/zoneinfo.zip
COPY --from=builder /app/main /main
CMD ["/main"]
```

## 2. Go コードでの変換

```go
package main

import (
	"fmt"
	"time"
    _ "[github.com/go-sql-driver/mysql](https://github.com/go-sql-driver/mysql)"
)

func main() {
    // 1. DB接続は UTC で固定
    // dsn := "...&loc=UTC"

	// 2. アプリ内（計算・保存）はすべて UTC で扱う
	utcTime := time.Now().UTC()
	fmt.Printf("System Time (UTC): %v\n", utcTime)

	// 3. ユーザーへの表示時のみ JST に変換する
	jst, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		// コンテナに tzdata がないとここで panic する
		panic(err)
	}

	jstTime := utcTime.In(jst)
	fmt.Printf("Display Time (JST): %v\n", jstTime)
}
```

## 3. Webアプリなら「JSONはUTCで返す」のが鉄則

ここが重要なポイントです。「画面にはJSTで出したいから、Go側で変換してからJSONを返すべきか？」という悩み。

結論は、**「Go（API）は UTC のまま返し、変換はフロントエンドに任せる」** が正解です。

## なぜフロントエンドでやるのか？

1.  **ブラウザの標準機能**: JavaScriptの `Date` オブジェクトや、`Intl.DateTimeFormat` は、UTCの文字列を受け取ると自動的に **「閲覧しているユーザーの端末設定（JSTなど）」** に合わせて表示してくれます。
2.  **グローバル対応**: 海外のユーザーがアクセスした際、バックエンドでJSTに固定して返してしまうと、海外ユーザーにとっても「日本時間」で表示されてしまい、混乱を招きます。

### Go側のJSON出力例
```json
{
  "created_at": "2026-02-12T09:00:00Z" 
}
```
末尾に `Z` (Zulu/UTC) が付いた **ISO 8601形式** で返せば、現代のフロントエンドライブラリ（Day.js, Luxon, etc.）は1行で変換できます。

## 4. それでもGo側で変換が必要なケース

「CSV出力機能」や「通知メールの送信」など、フロントエンド（ブラウザ）を通さない処理では、Go側で明示的に JST に変換する必要があります。

「`time` パッケージが優秀だから、毎回 `t.In(jst)` って書けばいいのでは？」と思うかもしれません。
しかし、実際の開発では以下の理由から<strong>「ヘルパー関数（またはパッケージ）」</strong>を作っておくのが定石です。

1.  **マジックストリングの排除**: `"Asia/Tokyo"` をあちこちに書くとタイポの元です。
2.  **エラーハンドリングの集約**: `LoadLocation` はエラーを返しますが、通常「東京」が見つからないのは異常事態なので、初期化時に確定させたい。

### おすすめの実装パターン

`pkg/timeutil` のような共通パッケージを作って、一箇所で定義してしまいましょう。

```go
package timeutil

import "time"

var jst *time.Location

func init() {
    var err error
    jst, err = time.LoadLocation("Asia/Tokyo")
    if err != nil {
        panic(err) // コンテナに tzdata がない場合、起動時に気づける
    }
}

// JST への変換関数（可読性が上がる）
func ToJST(t time.Time) time.Time {
	return t.In(jst)
}
```

こうすることで、ビジネスロジック内では `timeutil.ToJST(t)` と呼ぶだけで済み、非常にスッキリします。

# まとめ

* **`loc=local` は使うな**: 環境によって挙動が変わるリスクを排除しましょう。
* **APIは常にUTCを返す**: 変換はフロントエンドの責務。ISO 8601形式（`Z`付き）で返しましょう。
* **表示変換はヘルパー化する**: CSVやメールなど、どうしてもGo側でJSTが必要な時だけ `ToJST()` を使います。

「インフラで時間を合わせる」のではなく、**「コードで時間の意味を定義する」**。これがコンテナ時代のタイムゾーン管理の正解です。
