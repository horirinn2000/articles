---
title: 【GCP】Cloud TraceとOpenTelemetryで「遅い処理」を特定する。Spannerのエンドツーエンドトレースと「スパンスパイク」による課金死を防ぐ
tags:
  - 'Go'
  - 'GCP'
  - 'CloudTrace'
  - 'OpenTelemetry'
  - 'Spanner'
private: false
updated_at: ''
id: null
organization_url_name: null
slide: false
ignorePublish: false
---

# はじめに

今回は<strong>「Cloud Trace（分散トレーシング）」</strong>の話です。

「ログでエラーは見つけたけど、結局どの処理が重いの？」
「マイクロサービス間の通信のどこで詰まっているのか分からない」
「Cloud Spannerのクエリがアプリケーション側で遅いのか、DB側で遅いのか判別がつかない」

そんな時に役立つのが Cloud Trace です。
今回は、業界標準である<strong>OpenTelemetry (OTel)</strong> を使って Go アプリを計装する方法と、<strong>Cloud Spanner の詳細なレイテンシまで追える「エンドツーエンド トレース」</strong>の導入、そして Logging とは全く異なる<strong>「課金の罠」</strong>について解説します。

# 1. そもそもスパン (Span) とは？

用語解説として「そもそもスパンって何？」という方のために簡単におさらいします。

**スパン (Span) とは、「1つの具体的な処理のかたまり」と「そこにかかった時間」を記録したデータ**のことです。
たとえば、「Webサーバーがリクエストを受け取ってから返すまで」全体で1つの大きなスパン（親スパン）になり、その内部で行われる「DBからデータを取得する処理」や「外部APIへの通信処理」などが、それぞれ子スパンとして記録されます。

* **親スパン**: `GET /users/:id` (全体で 200ms)
  * **子スパン 1**: `SELECT * FROM users` (DB処理に 50ms)
  * **子スパン 2**: `外部のサービスAPI呼び出し` (通信に 150ms)

これらの一連のスパンの集まり（木構造）を **トレース (Trace)** と呼びます。
これを見ることで、「200ms遅延している原因は、外部API呼び出しのせいだ」ということが一目で分かるようになります。

# 2. 課金体系の違い：LoggingとTraceは「敵」が違う

まず、ここを理解していないと請求書を見て倒れることになります。
Cloud Logging と Cloud Trace は、課金の基準が全く異なります。

| サービス | 課金基準 | コストの敵 |
| :--- | :--- | :--- |
| **Cloud Logging** | **容量 (GiB)** | 長いスタックトレース、大量の文字列出力 |
| **Cloud Trace** | **スパン数 (Count)** | ループ処理、大量の細かい関数呼び出し |

### Cloud Trace の課金モデル
Cloud Trace は、**「取り込んだスパンの数（100万スパンあたり）」**で課金されます（最初の250万スパン/月は無料）。

例えば、1回のリクエストで内部的に 100回 DB クエリを投げる処理があったとします。
ログなら「1行」で済むかもしれませんが、トレースだと「100スパン」発生します。
これが高負荷で回ると、データサイズは小さくても**スパン数が爆発し、課金が急増**します。

つまり、**Trace のコスト削減の鍵は「スパンの数を間引く（サンプリング）」こと**です。

# 3. OpenTelemetry (OTel) の導入とサンプリング設定

以前は OpenCensus や Google 独自のライブラリを使っていましたが、現在はベンダーニュートラルな **OpenTelemetry** を使うのが正解です。

## 必要なパッケージ
```bash
go get go.opentelemetry.io/otel
go get go.opentelemetry.io/otel/sdk
go get go.opentelemetry.io/otel/propagation
go get github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/trace
```

## 実装例：トレーサーの初期化とサンプリング
Cloud Run などのアプリケーションでコンテキストを伝播しつつ、Cloud Traceにスパンを送る初期化実装です。

```go
package main

import (
	"context"
	"log"
	"os"

	texporter "github.com/GoogleCloudPlatform/opentelemetry-operations-go/exporter/trace"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() func() {
	// 1. Google Cloud Trace 用の Exporter を作成
	// 引数なし（オプションなし）で生成すると、Cloud Run などの
	// 実行環境（メタデータサーバー）から自動でプロジェクトID等を取得してくれます。
	exporter, err := texporter.New()
	// 別の環境で実行する場合は以下のようにプロジェクトIDを指定する
	// exporter, err := texporter.New(texporter.WithProjectID("your-project-id"))
	if err != nil {
		log.Fatalf("texporter.New: %v", err)
	}

	// 2. トレーサープロバイダの設定（サンプリングが命）
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		// ※ 5% の確率でトレース開始。親がトレースされている場合はそれに従う。
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(0.05))),
	)
	otel.SetTracerProvider(tp)

	// 3. コンテキスト伝播を設定（Cloud RunやSpannerなどの連携に必須）
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return func() {
		if err := tp.Shutdown(context.Background()); err != nil {
			log.Fatal(err)
		}
	}
}
```

### OTelの各コンポーネントの役割

上記の初期化コードで登場する主要な設定には、それぞれ以下の役割があります。

1. **Exporter (エクスポーター)**:
   * **役割**: アプリケーション内で作られたトレースデータ（スパン）を、外部のバックエンドシステム（今回の場合は Google Cloud Trace）に送信・書き出しする役割を持ちます。
   * **ポイント**: Cloud Run や GCE などの GCP 上で動かす場合、`texporter.New()` と引数なしで呼び出すだけで、GCP の「メタデータサーバー」に問い合わせて**自動的に現在のプロジェクトIDを推論・設定**してくれます。そのため、わざわざ環境変数で `GOOGLE_CLOUD_PROJECT` を渡す必要はありません。
2. **TracerProvider (トレーサープロバイダ)**:
   * **役割**: トレーサー（スパンを実際に生成する主体）を作成・管理する工場の役割を果たします。
   * **ポイント**: プロバイダの生成時に「どの Exporter にデータを送るか（`WithBatcher`）」や「どのくらいの頻度でデータを記録するか（`WithSampler`：後述）」といった、トレーシング全体の中核となるルールを設定します。
3. **`otel.SetTracerProvider(tp)`**:
   * **役割**: 作成した TracerProvider を、Go アプリケーション全体（グローバル）でデフォルトとして使えるように登録するおまじないです。
   * **ポイント**: これを設定しておくことで、全く別のパッケージや外部ライブラリ（Spannerクライアントや GORM プラグインなど）を利用した際にも、同じ設定で自動的に Cloud Trace へデータが送信されるようになります。
4. **`otel.SetTextMapPropagator(...)`**:
   * **役割**: プロセス間（例えば Cloud Runのロードバランサからアプリへ、またはアプリからDBへ）でトレースIDなどの「コンテキスト情報」を受け渡し（伝播）するための標準フォーマットをグローバルに設定します。
   * **ポイント**: `propagation.TraceContext{}` を設定することで、W3C標準である `traceparent` ヘッダなどを使用したコンテキストの抽出・注入が行われるようになります。この設定が抜けていると、サービスごとにトレースの線がぶつ切りになってしまいます。

### コスト削減の要「サンプリング設定」

上記の `sdktrace.WithSampler` の部分が重要です。

* **全量記録 (AlwaysSample) は危険**: 開発環境なら良いですが、本番でやるとアクセス数に比例して課金が青天井になります。
* **推奨は RatioBased + ParentBased**: `sdktrace.TraceIDRatioBased(0.05)` で新規リクエストの **5% だけ** に絞り、`ParentBased` で「上位レイヤーでサンプリング対象に選ばれたコンテキスト」を引き継ぎます。

# 4. APIサーバーのエントリポイントで「親スパン」を開始する

APIサーバーなどの場合、**最上流の「リクエストを受け取った時点」で一番大元の親スパン（ルートスパン）を開始し、それを下流の全体に伝播させる**必要があります。

これを行うために、HTTPサーバーのフレームワークに応じた<strong>OpenTelemetryミドルウェア（インターセプタ）</strong>を導入します。

### パターンA: Gin を使用する場合 (`otelgin`)

Gin を使用している場合は、専用のミドルウェアである `otelgin` をエンドポイント群の根元に組み込むのが最も簡単です。これにより、すべての一連の処理が1つのトランザクション（トレース）として綺麗に繋がります。

```bash
go get go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin
```

```go
import (
	"github.com/gin-gonic/gin"
	"go.opentelemetry.io/contrib/instrumentation/github.com/gin-gonic/gin/otelgin"
)

func main() {
	// TracerProviderの初期化 (前述の initTracer() を呼ぶ)
	cleanup := initTracer()
	defer cleanup()

	r := gin.Default()

	// 1. 全リクエストに自動でトレース用の親スパンを貼るミドルウェアを登録
	r.Use(otelgin.Middleware("my-api-server"))

	r.GET("/users/:id", func(c *gin.Context) {
		// 2. 超重要：c.Request.Context() で伝播されたコンテキストを取り出し、下流へ渡す！
		ctx := c.Request.Context()

		userID := c.Param("id")
		
		// DB呼び出し等へ ctx を渡す（ここで子スパンが親と紐づく）
		user, err := GetUser(ctx, db, userID)
		// ...
	})

	r.Run(":8080")
}
```

> **なぜ `c` をそのまま渡してはいけないのか？**
> `*gin.Context` 自体も `context.Context` インターフェースを満たしていますが、**そのまま下流の関数やDB呼び出しに渡すのは絶対にやめましょう。** 主に以下の2つの理由があります。
> 1. **データ競合・バグのリスク**: Gin はパフォーマンスのためにコンテキストを再利用（プーリング）しているため、非同期処理などでコンテキストのライフサイクルがズレると、別のリクエストとデータが混ざるという致命的なバグを引き起こす可能性があります。
> 2. **完全なポータビリティ（フレームワーク非依存）**: 下流の関数が「Gin特有のコンテキスト」に依存しなくなります。標準のコンテキストとして渡しておけば、将来的に別のWebフレームワーク（Echoなど）に乗り換えたくなった際や、バッチ処理から同じ関数を呼び出したくなった際にも、下流のコードを一切書き直すことなくスムーズに移行できます。
> 
> OTel が注入した純粋で安全なコンテキストを取り出すために、必ず **`ctx := c.Request.Context()`** として標準のコンテキストを抽出してから下流に渡してください。

### パターンB: 標準 `net/http` を使用する場合 (`otelhttp`)

Goの標準構成である `net/http` を使用している場合は、ハンドラを `otelhttp.NewHandler` でラップするだけで同様の監視が可能になります。

```bash
go get go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

```go
import (
	"net/http"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func main() {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// リクエストに含まれる Context を下流へ渡す
		ctx := r.Context()
		_ = CalculateHeavyTax(ctx, "user1")
		w.Write([]byte("Hello, World!"))
	})

	// ハンドラ自体を OTel のハンドラでラップして名前を付ける
	wrappedHandler := otelhttp.NewHandler(handler, "hello-api")
	
	http.Handle("/hello", wrappedHandler)
	http.ListenAndServe(":8080", nil)
}
```

これで大元の親スパンが作られました！ここからさらに、「SpannerやCloud SQLなどの外部通信先」への計装を繋ぎ込んでいきましょう。

# 5. Cloud Spanner の「エンドツーエンド トレース」を有効にする

単純にアプリケーション内でスパンを自作する（`tr.Start(ctx, "span-name")`）のも有用ですが、Go アプリケーションから **Cloud Spanner** を利用している場合、<strong>「エンドツーエンドのトレース（End-to-end Tracing）」</strong>を有効にすることで劇的に可視性が上がります。

これにより、クライアントから GFE（Google Front End）、Spanner API サーバーまでのレイテンシをシームレスに追いかけることが可能です。

## Spanner Client 側の設定

Spannerクライアントの初期化時に `EnableEndToEndTracing: true` パラメータを追加します。

```go
import (
	"context"

	"cloud.google.com/go/spanner"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
)

func initSpannerClient(ctx context.Context, projectID, instanceID, databaseID string) (*spanner.Client, error) {
	// ※注意: コンテキスト伝播のために ote.SetTextMapPropagator() の設定が必須ですが、
	// これはグローバル設定です。通常は main関数や initTracer() で一度だけ実行されていればOKです。
 	// otel.SetTextMapPropagator(propagation.TraceContext{})

	dbPath := "projects/" + projectID + "/instances/" + instanceID + "/databases/" + databaseID

	// EnableEndToEndTracing を true にしてクライアントを作成
	client, err := spanner.NewClientWithConfig(ctx, dbPath, spanner.ClientConfig{
		SessionPoolConfig:     spanner.DefaultSessionPoolConfig,
		EnableEndToEndTracing: true, // ★ここがポイント
	})
	if err != nil {
		return nil, err
	}
	return client, nil
}
```

### エンドツーエンド トレースで何が分かるのか？

これを有効にすると、Cloud Trace の画面上で Spanner クエリのスパン内により詳細な属性（Attributes）が付与されます。

* **ネットワークレイテンシの可視化**:
  アプリケーションと Spanner の間でのネットワークレイテンシ（通信にかかる時間）が明確になり、「DBが遅いのか、ネットワークが遅いのか」を切り分けられます。
* **処理リージョンの特定**:
  `spanner_api_frontend` という属性によって、アプリケーションのリクエストが「どのリージョン（例: `us-west1` や `asia-northeast1`）のフロントエンド」で処理されたかを確認できます。クロスリージョン呼び出しを行ってしまっていないかを簡単に検知できます。
* **その他の属性**:
  分離レベル（`SERIALIZABLE`, `REPEATABLE_READ`）の情報なども自動的にトレースへ記録されます。

# 6. Spanner以外のGCPサービスでのトレース（Cloud SQL, GCS, Pub/Subなど）

では、Spanner 以外のサービスではどうなるのでしょうか？
前述の `EnableEndToEndTracing` は **Spanner クライアント特有のオプション** ですが、他の GCP サービスでも OpenTelemetry を活用して詳細なトレースを取ることは十分に可能です。

## Cloud SQL (PostgreSQL / MySQL) の場合

Cloud SQL では、アプリケーションからデータベース内での実行（クエリ実行計画の違いによる遅延など）までを End-to-End で追うために、**「Sqlcommenter」と「Cloud SQL Insights」の組み合わせ** を利用します。

### パターンA: `database/sql` を直接使う場合（標準ライブラリ）

GORMなどのORMを使わず、標準の `database/sql` を使う場合は `otelsql` パッケージを利用してドライバをラップします。

```bash
go get go.opentelemetry.io/contrib/instrumentation/database/sql/otelsql
```

```go
import (
	"context"
	"database/sql"
	// MySQLの場合
	_ "github.com/go-sql-driver/mysql"
	"go.opentelemetry.io/contrib/instrumentation/database/sql/otelsql"
)

func initDB() *sql.DB {
	// 1. 通常の sql.Open ではなく otelsql.Open を使う
	db, err := otelsql.Open("mysql", "user:password@tcp(127.0.0.1:3306)/hello")
	if err != nil {
		panic(err)
	}

	// 2. Sqlcommenter を有効化し、トレースIDをSQL文に自動付与する設定
	err = otelsql.RegisterDBStatsMetrics(db, otelsql.WithSQLCommenter(true))
	if err != nil {
		panic(err)
	}

	return db
}

// 実際の呼び出し時
// 必ず ExecContext や QueryContext など、Contextを受け取るメソッドを使用すること！
func GetUser(ctx context.Context, db *sql.DB, id int) error {
	_, err := db.QueryContext(ctx, "SELECT * FROM users WHERE id = ?", id)
	return err
}
```

### パターンB: GORM を使った計装例

Go 言語で人気の ORM である **GORM** を使っている場合、`otelgorm` などのプラグインを導入することで、簡単にトレーススパンを生成し、さらに Sqlcommenter と連携させることができます。

```bash
go get github.com/uptrace/opentelemetry-go-extra/otelgorm
# Sqlcommenter を使う場合（GORM公式またはサードパーティ製）
```

```go
import (
	"context"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"github.com/uptrace/opentelemetry-go-extra/otelgorm"
)

func initDB() *gorm.DB {
	dsn := "host=localhost user=gorm password=gorm dbname=gorm port=9920 sslmode=disable TimeZone=Asia/Tokyo"
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		panic("failed to connect database")
	}

	// 1. GORM に OpenTelemetry プラグインを登録
	// これにより、すべてのクエリ実行時に自動でSpanが作られる
	if err := db.Use(otelgorm.NewPlugin()); err != nil {
		panic(err)
	}

	return db
}

// 実際の呼び出し時（超重要）
// 必ず db.WithContext(ctx) を使ってコンテキストを渡すこと！
// これをやらないとトレースが繋がりません。
func GetUser(ctx context.Context, db *gorm.DB, id uint) (*User, error) {
	var user User
	err := db.WithContext(ctx).First(&user, id).Error
	return &user, err
}
```

Cloud SQL 側で **Query Insights (クエリ パフォーマンス インサイト)** を有効にすると、GORM (や Sqlcommenter プラグイン) が発行した SQL に付与された Trace ID コメントを読み取り、GCP ネイティブの Cloud Trace 画面上で「アプリ側のスパン」と「DB側のクエリ実行パフォーマンス」を結合して分析できるようになります。

## その他のマネージドサービス（Cloud Storage, Pub/Sub, Firestore）

Cloud Storage, Pub/Sub, Firestore などの公式 Go クライアント（`cloud.google.com/go/...`）は、最初から内部的に OpenTelemetry（または OpenCensus）による計装ロジックが組み込まれています。

そのため、Spanner のような特別なフラグを立てずとも、**「3. OpenTelemetry (OTel) の導入とサンプリング設定」で紹介したグローバルな TracerProvider さえ初期化されていれば、自動的にスパンが記録** されます。

ただし、<strong>重要なのは「クライアントの各メソッド呼び出し時に、Trace ID が伝播された `context.Context` (ctx) を正しく渡すこと」</strong>です。これを忘れると親スパンと紐付かず、トレースが分断されてしまいます。

### 実装例

```go
// --- Cloud Storage の例 ---
client, err := storage.NewClient(ctx)
if err != nil { /* エラー処理 */ }
// HTTPハンドラ等から引き継いだ ctx を渡すことでスパンが繋がる
reader, err := client.Bucket("my-bucket").Object("file.txt").NewReader(ctx)

// --- Firestore の例 ---
fsClient, err := firestore.NewClient(ctx, "my-project")
if err != nil { /* エラー処理 */ }
// ctx を渡すことで、Get() が現在実行中のトレースの子スパンとして記録される
doc, err := fsClient.Collection("users").Doc("user1").Get(ctx)

// --- Pub/Sub (Publish) の例 ---
psClient, err := pubsub.NewClient(ctx, "my-project")
topic := psClient.Topic("my-topic")
// メッセージ送信時も、Publish() が返す Get() を ctx で待機する
res := topic.Publish(ctx, &pubsub.Message{Data: []byte("hello")})
msgID, err := res.Get(ctx)

// --- Pub/Sub (Subscribe) の例 ---
sub := psClient.Subscription("my-sub")
// Subscribe側では、Receiveコールバックに渡ってくる ctx に
// Publish側が自動で埋め込んでくれた Trace ID がすでに復元（Extract）されています。
err = sub.Receive(ctx, func(ctx context.Context, msg *pubsub.Message) {
	// この ctx をそのまま使って DB 書き込み等の後続処理を行えば、
	// [APIリクエスト] -> [Publish] -> (非同期の待ち時間) -> [Subscribe] -> [DB保存]
	// という分断されがちな一連の非同期処理のトレースが完全に繋がります！
	
	// 処理...
	msg.Ack()
})
```

これだけで、以下のようなクライアント視点でのレイテンシが自動的にトレース画面に描画されます。

* **Cloud Storage**: バケットへのアップロードやダウンロードの API コールレイテンシ。
* **Pub/Sub**: メッセージの Publish や Receive にかかる時間。
* **Firestore**: ドキュメントの Get や Set などに対する API 呼び出し。

※ただし、これらはあくまで「クライアントから Google の API エンドポイントを叩いて返ってくるまでのクライアント視点でのレイテンシ」であり、Spanner の `spanner_api_frontend` のような内部サーバーの処理リージョン詳細まで可視化されるわけではありません。それでも、ボトルネックの特定には十分すぎるほどの威力を発揮します。

# 7. gRPC 通信や HTTP 呼び出しのトレース

マイクロサービス環境などで、Go言語から別のサービスへ **gRPC 通信** や **HTTP 通信** を行う場合も、一工夫で呼び出し先までトレースを繋げることができます。

### パターンA: 標準 gRPC の場合 (`otelgrpc`)

gRPC 通信では、クライアント側の送信時とサーバー側の受信時にインターセプタ（Interceptor）として OTel を挟み込むことで、自動的にコンテキストが伝播し、レイテンシが記録されます。

```go
import (
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"google.golang.org/grpc"
)

// クライアント側（呼び出し元）
conn, err := grpc.Dial(
	address,
	grpc.WithTransportCredentials(insecure.NewCredentials()),
	// ★ ここにインターセプタを追加
	grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
)

// サーバー側（受け側）
server := grpc.NewServer(
	// ★ ここにインターセプタを追加
	grpc.StatsHandler(otelgrpc.NewServerHandler()),
)
```

### パターンB: Connect (connect-go) の場合 (`otelconnect`)

最近人気を集めている gRPC 互換の Web プロトコル **Connect (`connectrpc.com/connect`)** を使用している場合は、専用の `otelconnect` インターセプタを使用します。標準gRPCよりさらにシンプルに記述できます。

```go
import (
	"connectrpc.com/connect"
	"connectrpc.com/otelconnect"
)

// OTelインターセプタを作成
interceptor, err := otelconnect.NewInterceptor()
if err != nil {
	panic(err)
}

// サーバー側（ハンドラの登録時にオプションとして渡す）
mux.Handle(
	pingv1connect.NewPingServiceHandler(
		&pingServer{},
		connect.WithInterceptors(interceptor), // ★ ここに追加
	),
)

// クライアント側（クライアント生成時にオプションとして渡す）
client := pingv1connect.NewPingServiceClient(
	http.DefaultClient,
	"https://api.example.com",
	connect.WithInterceptors(interceptor), // ★ ここに追加
)
```

この設定を行うだけで、「クライアントで発生した親スパン」から「サーバー側での処理の子スパン」へとトレースがネットワークを越えて綺麗に繋がります（分散トレーシングの醍醐味です）。

# 8. 任意のスパンを自作してボトルネックの関数を特定する

これまでは「外部サービス（DBなど）との通信」を計測してきましたが、「自分たちで書いた重い計算処理」や「特定の関数の実行時間」を測りたい場合は、**手動で任意のスパンを作成**（カスタムスパン）することができます。

手順はごくシンプルで、「トレーサーを取得して、使いたい場所で開始（`Start`）して終了（`End`）するだけ」です。

```go
import (
	"context"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

// 任意の処理時間を計測したい自作関数
func CalculateHeavyTax(ctx context.Context, userID string) error {
	// 1. Tracer を取得（名前はパッケージ名などがおすすめ）
	tr := otel.Tracer("my-app/tax-calculator")

	// 2. スパンを開始（必ず引き継いだ ctx を渡す）
	// childCtx には現在開始された新しいスパンの情報が含まれる
	childCtx, span := tr.Start(ctx, "CalculateHeavyTax")
	
	// 3. 処理が終わったら必ず終了させる（defer推奨）
	defer span.End()

	// 4. (オプション) スパンに任意の検索用タグ（属性）を付与
	span.SetAttributes(attribute.String("user.id", userID))

	// ---- ここに重い処理を書く ----
	time.Sleep(300 * time.Millisecond) // ダミーの重い処理

	// エラーが起きた場合はスパンにエラー情報を記録してマークできる
	if err := doSomething(); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, err.Error())
		return err
	}

	// ---------------------------

	// さらに別の関数を呼ぶ場合は、新しく作られた childCtx を渡す
	// return NextFunction(childCtx)

	return nil
}
```

このコードを仕込むと、Cloud Trace のコンソール上で `CalculateHeavyTax` という全く新しいスパンが独立して描画されるようになります。

* 「DBからはすぐデータが返ってきているのに、なぜかAPI全体としては遅い」
* そういう時にこのカスタムスパンを要所要所に仕込んでおくと、「データのパース（変換）処理に300msかかっていた！」というような、**コード内部のボトルネックを特定**できるようになります。

# 9. Cloud Trace エクスプローラと Analytics の活用

Cloud Trace にデータを送る設定が完了したら、Google Cloud Console の **Trace エクスプローラ** からその分析が可能になります。
Trace の真価は「単なるグラフ化」ではなく、豊富な分析（Analytics）機能にあります。

* **ヒートマップとレイテンシの可視化**:
  収集されたすべてのスパンデータが集計され、インタラクティブな「ヒートマップ」として表示されます。これにより、普段のレイテンシ分布だけでなく、「一部のリクエストだけがなぜか遅い（ロングテール）」といった異常値（外れ値）を視覚的に瞬時に発見できます。
* **強力なフィルタリング**:
  特定のサービス名、エラーの有無（ステータス）、さらにはトレースIDや属性（例: `spanner_api_frontend: us-west1`）を指定して、関心のある情報だけを絞り込むことができます。
* **パーセンタイル分析と比較**:
  「P50（中央値）、P90、P99」などのパーセンタイルグラフを確認し、システム全体のパフォーマンスの推移を追跡できます。さらに、新しいデプロイ前後でレイテンシの分布を比較し、パフォーマンス退行（デグレ）が起きていないかを分析することも可能です。
* **BigQuery やログとの連携**:
  より高度な分析を行いたい場合は、トレース（スパン）の生データを BigQuery にエクスポートして SQL で分析したり、同じ画面から関連付けられた Cloud Logging のログへシームレスにジャンプして原因を深掘りすることができます。

これらを駆使することで、「なぜ遅いのか？」「どこで遅いのか？」「いつから遅くなったのか？」というパフォーマンスの3大疑問に明確な答えを出すことができます。

# まとめ

* **Traceの課金はデータ容量ではなく「スパンの数」**: ループ処理などで無邪気にスパンを作りすぎると「課金死」に直結します。本番環境では `TraceIDRatioBased` を使い、数%程度のサンプリングに絞るのがコスト管理の鉄則です。
* **コンテキスト（`ctx`）のバケツリレーが絶対条件**: HTTPハンドラから始まり、Cloud SQL (GORM)、Pub/Subの送受信、gRPC通信に至るまで、OTelが情報を注入した `ctx` を絶対に途切れさせずに渡し続けてください。これが一連の処理を1つのトレースに繋ぐ生命線です。
* **DBのブラックボックスをこじ開ける**: Spannerの `EnableEndToEndTracing` や、Cloud SQLでの `Sqlcommenter` を活用することで、「アプリ側の問題か、ネットワークの遅延か、DB側のクエリが重いのか」という不毛な犯人探しを即座に終わらせることができます。
* **カスタムスパンで内部のボトルネックを特定**: 外部APIやDBとの通信だけでなく、自分たちで書いた重いビジネスロジックには `tr.Start()` で手動のスパンを仕込み、コード内部の遅延原因も逃さず計測しましょう。

「推測するな、計測せよ」というソフトウェア工学の格言がありますが、計測にお金をかけすぎて破産してしまっては本末転倒です。
適切なサンプリング設定でコストをコントロールしつつ、OpenTelemetryを通じたGCPエコシステム全体への分散トレーシングを駆使して、自信を持ってパフォーマンスチューニングに挑みましょう！