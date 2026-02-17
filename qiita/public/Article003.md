---
title: 【Cloud Run】DB接続が減らない？Graceful Shutdownを導入してコネクションリークを防いだ話
tags:
  - Go
  - Troubleshooting
  - gRPC
  - cloudsql
  - CloudRun
private: false
updated_at: '2026-01-28T13:31:33+09:00'
id: 1fd060d5dbe1ae3f38e5
organization_url_name: null
slide: false
ignorePublish: false
---
# はじめに

[前回の記事](https://qiita.com/horirinn2000/items/0a2c804ef979cf8e5a8f)の続き、3回目の投稿です。

今回は、Cloud Runで運用しているサービスにおいて**DB接続数やgRPCクライアントの接続が意図せず増え続けてしまう問題**と、それを**Graceful Shutdown**によって解決した事例について共有します。

Cloud Runを使っていると「コンテナは勝手に消えてくれるから管理が楽」と思いがちですが、実は消え際のマナー（Graceful Shutdown）を守らないと、DBなどのバックエンドに負荷をかけ続けてしまうという話です。

# 直面した課題：謎の接続数増加

運用しているサービスでは、インフラ構成として **Cloud Run** を採用し、Cloud Run の標準機能である**Cloud SQL 接続**設定を有効にして DB に接続していました。

リリース後、以下の現象が発生しました。

* **トラフィックはそこまで多くないのに、DB接続数が右肩上がりに増え続ける**
* 接続エラーの警告が出ることがある

Cloud Runはリクエスト数に応じてコンテナが自動的にスケールアウト（増加）・スケールイン（減少）します。コンテナが減っているはずなのに、なぜか接続だけが残り続ける...という状況でした。

## なぜ接続上限に引っかかるのか？（Cloud SQL Auth Proxy の罠）

Cloud Run の「Cloud SQL 接続」機能を使って、アプリケーションは「インスタンス接続名（`project:region:instance`）」の文字列を使ってDBに接続していました。

実はこのとき、裏側では **Cloud SQL Auth Proxy** がこっそりと起動しており、アプリはこのプロキシを経由してDBと通信しています。
アプリ側が接続を適切に切断しないと、このプロキシ上の接続が「使用中」のまま残り、**コンテナは減ったのに、プロキシとDBの間の接続だけが亡霊のように残る**というコネクションリーク状態に陥ります。

また今回の話とは異なりますが、Cloud SQL Auth Proxyを使っての接続は、Cloud Run コンテナインスタンスあたり100までという制限がありますので、1つのコンテナで大量のリクエストを処理するような設定にしている場合、この上限にも気をつける必要があります（但し、リクエストを送ることで、上限を増やすことは可能です）。

https://docs.cloud.google.com/sql/docs/quotas?hl=ja#cloud-run-limits

# Cloud Runのコンテナの増減への適切な対応が必要だった（SIGTERMの無視）

調査の結果、原因は**アプリケーションが終了シグナル（SIGTERM）を適切にハンドリングしていなかったこと**にありました。

Cloud Runはコンテナをスケールインさせる際、インスタンスに対して `SIGTERM` シグナルを送信します。
これまでアプリケーション側でこのシグナルを検知して終了処理を行う実装を入れていなかったため、以下のことが起きていました。Graceful Shutdownと呼ばれるこの実装について、Webサーバのサンプル実装などでは省略されていることも多く、問題が発生するまで、全く意識していないことでした。

1.  Cloud Runがコンテナを終了させようとして `SIGTERM` を送る。
2.  アプリは特別な処理をせず、即座に（あるいは強制終了まで待って）プロセスが落ちる。
3.  **張られていたgRPCコネクションやDBコネクションが明示的に `Close` されない。**
4.  裏で動いている Cloud SQL Auth Proxy は「まだ通信中」と判断し、接続を維持してしまう。

結果として、新しいコンテナが立ち上がるたびに接続が積み上がってしまっていました。

# 解決策：Graceful Shutdown の実装

解決策は、`SIGTERM` を検知し、アプリケーションが終了する前に**持っているコネクションを綺麗に閉じる**処理を入れることです。

Go言語での実装例は以下のようになります。

```go
package main

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
    "google.golang.org/grpc"
)

func main() {
	// 1. リソースの初期化
	// Cloud SQL Auth Proxy経由（Unixドメインソケット）での接続を想定
	db, err := sql.Open("mysql", "user:password@unix(/cloudsql/project:region:instance)/dbname")
	if err != nil {
		log.Fatal(err)
	}
    // defer db.Close() // 注意: os.Exitやシグナルによる強制終了時は実行されないため、ここでは使わない

	// gRPC接続などの初期化
	grpcConn, _ := grpc.Dial("target_address", grpc.WithInsecure())
	
	srv := &http.Server{
		Addr: ":8080",
	}

	// 2. 別のゴルーチンでサーバーを起動
	// メインスレッドはシグナル待ちでブロックするため
	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %s\n", err)
		}
	}()

	// 3. シグナル待機用のチャネル作成
	quit := make(chan os.Signal, 1)
	// SIGINT (Ctrl+C) と SIGTERM (Cloud Runからの終了合図) を監視
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	
	// シグナルが来るまでここでブロック
	<-quit
	log.Println("Shutting down server...")

	// 4. タイムアウト付きのコンテキストを作成
	// Cloud Runの終了猶予時間内に終わるように設定（例：10秒）
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 5. HTTPサーバーのGraceful Shutdown
	// 新規リクエストの受付を停止し、処理中のリクエスト完了を待つ
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatal("Server forced to shutdown:", err)
	}

	// 6. DB接続のクローズ（ここが重要！）
	// これを呼ぶことで、Auth Proxy側に切断を明示的に伝える
	if err := db.Close(); err != nil {
		log.Printf("Error closing DB: %v", err)
	}

	// 7. gRPC接続のクローズ
	if err := grpcConn.Close(); err != nil {
		log.Printf("Error closing gRPC conn: %v", err)
	}

	log.Println("Server exiting")
}
```

## ポイント

1.  **`signal.Notify`**: `syscall.SIGTERM` をリッスンすることが最も重要です。これがCloud Runからの「終了してください」という合図です。
2.  **明示的な `Close()`**: `db.Close()` や `grpcConn.Close()` を呼び出すことで、プロキシやDBサーバーに対して「この接続はもう使いません」と伝えます。これにより、プロキシ側の接続プールから即座に解放されます。
3.  **タイムアウト設定**: シャットダウン処理が無限に待機しないよう、`context.WithTimeout` を設定します。

## 補足：defer db.Close() だけではダメなのか？

前回の記事の書き方のように、Goを書いていると、「`main` の最初に `defer db.Close()` を書いておけば良いのでは？」と思うかもしれません。
しかし、Cloud Runのようなコンテナ環境での終了処理においては、それだけでは不十分なケースがあります。

### 1. log.Fatal は defer を無視する
`http.ListenAndServe` がエラーを返した際、`log.Fatal(err)` で処理を終了させることが多いですが、`log.Fatal` は内部で `os.Exit()` を呼び出します。Goの仕様上、**`os.Exit()` が呼ばれると `defer` は実行されません。**

### 2. SIGTERM はプロセスを即座に終了させる
今回のように `signal.Notify` でシグナルを検知していない場合、Cloud Runから `SIGTERM` を受け取ると、Goプログラムは直ちに終了します。`main` 関数の末尾まで処理が到達しないため、**`defer` で登録した処理も実行される前にプロセスが消滅**してしまいます。

そのため、明示的にシグナルを受け取り、サーバーを `Shutdown` させ、その後にコネクションを閉じるという**終わらせる手順**を実装する必要があります。

# 結果

この対応をリリースした直後から、効果はグラフにはっきりと現れました。

* コンテナのスケールインに合わせて、DB接続数も綺麗に下がるようになった。
* 不要な接続が残らなくなったため、接続数の警告が出なくなった。
* Cloud SQL Auth Proxy のログからも、不正な切断によるエラーが消えた。

# まとめ

Cloud Runのようなサーバーレス環境では「コンテナは使い捨て」という意識が強いですが、<strong>使い終わった後の後始末（Graceful Shutdown）</strong>をしっかり行わないと、DBなどのバックエンドリソースを食いつぶしてしまうことがあります。

特に Cloud Run の「Cloud SQL 接続」機能（裏側の Auth Proxy）を使っている場合、アプリ側からの明示的な切断がないと接続が残りやすい傾向にあります。

「接続数がなぜか減らない」と悩んでいる方は、一度アプリケーションの終了処理を見直してみることをおすすめします。

