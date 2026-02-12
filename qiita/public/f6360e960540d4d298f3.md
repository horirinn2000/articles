---
title: 【Cloud Run】gRPCの接続安定化に「泥臭いチューニング」は要らない。EnvoyとConnectを使うべき理由
tags:
  - Go
  - connect
  - gRPC
  - envoy
  - CloudRun
private: false
updated_at: '2026-02-10T10:54:49+09:00'
id: f6360e960540d4d298f3
organization_url_name: null
slide: false
ignorePublish: false
---
# はじめに

[前回の記事](https://qiita.com/horirinn2000/items/1fd060d5dbe1ae3f38e5)の続き、4回目の投稿です。

今回は、Cloud RunでgRPCを運用する際につきまとう<strong>通信エラー（Unavailable）</strong>との戦いと、そこから得られた<strong>車輪の再発明はやめよう</strong>という教訓について話します。

結論から言うと、私は以前、アプリケーションコード側で<strong>猛烈に泥臭いチューニング</strong>をして安定化させました。
しかし今の結論は違います。<strong>そんなことはせずに、素直に Envoy と Connect を使え</strong>です。

# 直面した課題：gRPCの接続が切れる

Cloud Run × gRPC の構成では、以下のような問題が頻発します。

* **15分問題**: Cloud Runはリクエストのない状態が続くとコンテナをシャットダウンしようとします
* **負荷分散の偏り**: gRPCは接続を維持し続けるため、特定のコンテナに接続が張り付き、新しいコンテナにリクエストが流れない
* **突然のエラー**: クライアントが「まだ繋がっている」と思っている接続先が、実はすでにシャットダウンしていて `Unavailable` エラーになる

これらを解決するために、かつての私は「インフラに切られる前に、自分たちで管理する」という方針で、Goのコードに手厚い設定を入れました。

# 通った道：Goのコードによる泥臭い解決

当時実装したコードの一部です。`http.Client` の奥深くにある `Transport` 設定をオーバーライドし、TCPレベルのKeepaliveやアイドルタイムアウトを秒単位で調整していました。

## 1. クライアント側の魔改造 (http.Transport)

```go
client := &http.Client{
	Timeout: time.Duration(timeOutSecond) * time.Second,
	Transport: &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   30 * time.Second,
			KeepAlive: 30 * time.Second, // TCPレベルでのKeepalive
			DualStack: true,
		}).DialContext,
		ForceAttemptHTTP2:     true, // gRPCなので必須
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second, // アイドル状態が続けば早めに切る
		TLSHandshakeTimeout:   30 * time.Second,
		ExpectContinueTimeout: 0 * time.Second,
	},
}
```

## 2. サーバー側からの強制切断 (MaxConnectionAge)

ロードバランサに切られる前に、サーバー側から「GOAWAY」を送るための設定です。

```go
var kasp = keepalive.ServerParameters{
	MaxConnectionIdle:     5 * time.Minute,
	// 重要: インフラのタイムアウトより短く設定して、自発的に切断する
	MaxConnectionAge:      9 * time.Minute,
	MaxConnectionAgeGrace: 1 * time.Minute,
}

return grpc.NewServer(
	grpc.KeepaliveParams(kasp),
)
```

## 3. リトライ処理

接続が切れた瞬間のリトライ処理も、ミドルウェア(grpc-go-middleware)を使ってアプリケーションコード内で実装していました。

```go
// リトライの設定
retryOptions := []grpc_retry.CallOption{
	grpc_retry.WithMax(MAX_RETRY),
}
// Interceptorとしてリトライロジックを注入
opts = append(opts, grpc.WithUnaryInterceptor(grpc_retry.UnaryClientInterceptor(retryOptions...)))
opts = append(opts, grpc.WithStreamInterceptor(grpc_retry.StreamClientInterceptor(retryOptions...)))
```

## 結果どうなったか？

これで確かにエラーは減り、安定稼働しました。
しかし、ふと我に返ったときに思ったのです。

**「これ、アプリエンジニアが毎回書くコードなのか？」**
**「ネットワークの不安定さを埋めるために、ビジネスロジックと関係ないコードが肥大化していないか？」**

これはまさに、**車輪の再発明**でした。すでに世の中には、この問題を解決するための専用のツールが存在していたのです。

# たどり着いた正解：Envoy と Connect の採用

現在、私が推奨する構成は、アプリ側で複雑なパラメータチューニングを行うことではなく、**Connect**ライブラリを採用し、**Envoy**をサイドカーとして配置することです。

## 1. gRPC の辛さを解消する「Connect」

[Connect (ConnectRPC)](https://connectrpc.com/) は、gRPC互換のプロトコルでありながら、HTTP/1.1 やブラウザからのアクセスに最適化されたライブラリです。

* **なぜ使うのか**: 標準の gRPC は HTTP/2 の仕様に厳格すぎて、Cloud Run や LB との相性問題（切断時の挙動など）が起きやすいです。Connect はそのあたりを柔軟に処理してくれるため、導入するだけで通信エラーの頻度が下がります。
* **コードが綺麗になる**: インターセプタやハンドラの記述も Go らしくシンプルになり、メンテナンス性が向上します。
* **http.Clientが使える**: Connect は http.Client そのものを使えます。「HTTP クライアントのベストプラクティス（標準のプール機能）」がそのまま適用されるため、**自前でプールを作る必要がなくなります。**

## 2. 通信の守護神「Envoy」

そして最も重要なのが **Envoy** です。
Envoy というと「Istio / Service Mesh のための可視化ツール」というイメージが強いかもしれませんが、それは一面に過ぎません。

Envoy をサイドカー（アプリの前段）に入れる真のメリットは、<strong>通信の安定化機能（Resiliency）</strong>をアプリの代わりに引き受けてくれる点にあります。

* **接続管理の委譲**: アプリは `localhost` の Envoy にリクエストを投げるだけ。裏側で接続が切れていようが、Envoy が勝手に再接続してくれます。
* **高度なリトライ**: 「gRPC ステータスコードが `UNAVAILABLE` の時だけリトライする」といった処理も、Envoy なら設定一つで完了します。アプリコードに `for { retry... }` なんて書く必要はありません。
* **ヘルスチェックと外れ値検出**: 調子の悪いコンテナを自動で検知して、リクエストを送らないようにしてくれます。

# 実際に動くサンプル

口で説明するよりもコードを見たほうが早いと思いますので、今回の構成（Connect + Envoy）を実際に動かせるサンプルリポジトリを作成しました。
Envoyの設定ファイル（`envoy.yaml`）や、Connectを使ったGoのサーバー/クライアント実装が含まれています。

[https://github.com/horirinn2000/grpc-connect-envoy](https://github.com/horirinn2000/grpc-connect-envoy)

Cloud Run で gRPC を使う際のテンプレートとして参考にしてみてください。

# まとめ：餅は餅屋に

gRPC の接続維持やリトライ処理を、アプリケーションコード（`net/http` や `grpc-go` のパラメータ）で制御しようとすると、泥沼にはまります。
それは本来、**インフラストラクチャ（プロキシ）が解決すべき課題**だからです。

* **Before**: アプリエンジニアが `Keepalive` や `Transport` の仕様書を読み込み、数秒単位のパラメータ調整でネットワークの不安定さと戦う。
* **After**: **Connect** で実装し、**Envoy** をサイドカーに置く。あとは彼らが勝手にうまくやってくれる。

Cloud Run で gRPC を使うなら、自前で頑張る前に、まずはこの「モダンな構成」を検討してみてください。コードが驚くほどシンプルになり、本来のビジネスロジックに集中できるようになります。
