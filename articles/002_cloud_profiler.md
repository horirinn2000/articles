---
title: "Cloud RunのメモリリークをCloud Profilerで特定した話 〜Firestore等クライアント管理の盲点とAI時代の対策〜"
emoji: "🕌"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["Go", "メモリリーク", "ヒープ", "profiler", "GoogleCloud"]
published: true
canonical: "https://qiita.com/horirinn2000/items/0a2c804ef979cf8e5a8f"
---

# 1. 起きていた問題：Cloud Runにおける「サイレントキラー」
リリース直後、負荷は安定しているにもかかわらず、Cloud Runのメモリ使用率が綺麗な右肩上がりを描き、数時間おきにインスタンスが再起動（OOMによるクラッシュ）を繰り返す現象が発生しました。

Cloud Runのようなサーバーレス環境では、メモリは限られた貴重なリソースです。メモリの肥大化は、**予期せぬスケールアウトによるコスト増**や、**コールドスタートの頻発によるレスポンス遅延に直結する**死活問題でした。当初は「どこかでのループ処理か？」と疑いましたが、原因の特定には至りませんでした。

後で判明した原因は、**Firestore、Pub/Sub、Cloud StorageなどのクライアントライブラリのClose漏れ**でした。

# 2. コードから探す絶望、Cloud Profilerという救世主
広大なソースコードから、たった1箇所のClose漏れを探すのは「砂漠で針を探す」ような作業です。特に、ライブラリの内部で確保されているメモリは、一見すると自分の書いたコードとは無関係に見えるため、推測だけで特定するのは困難でした。

ここで役立ったのが **Cloud Profiler** です。

1. **Heapプロファイルを確認**: メモリを「現在」握り続けている箇所を可視化。
2. **原因メソッドの特定**: 下図のように、特定のメソッドから伸びるメモリ消費のブロックを一目で特定。
3. **事実の突き止め**: そのメソッド内で firestore.NewClient がリクエストのたびに実行され、gRPCコネクションやGoroutineが蓄積していることが判明しました。

![Cloud ProfilerのHeapプロファイル](/images/5d1e26ab-8f3d-47db-88b4-80dc45b6ca39.png)

## 導入方法

GCP上で動作させているなら、これだけ書けばOKでした。

```go
func main() {
    if err := profiler.Start(profiler.Config{
        // Service and ServiceVersion can be automatically inferred when running
        // on App Engine.
        // ProjectID must be set if not running on GCP.
        // ProjectID: "my-project",
    }); err != nil {
        log.Printf("profile start fail\n")
    }
```

## 「ヒープ」と「割り当てられたヒープ」の使い分け

調査において、以下の違いを理解することが解決の決め手となりました。

| 指標 | 意味 | 調査の目的 |
| :--- | :--- | :--- |
| **ヒープ** | 現在保持されているメモリ | **メモリリーク**、OOMの特定 |
| **割り当てられたヒープ** | 起動から現在までに**確保された総量** | **GC負荷軽減**、一時オブジェクトの削減 |

今回の「じわじわ増える」ケースでは、ヒープを見ることで「誰が最後までメモリを握って離さないのか」を確信を持って特定できました。

# 3. なぜ「Close漏れ」が起きたのか：Cloud SDKの心理的死角
RDB（MySQL等）なら sql.Open() したら defer db.Close() するのは鉄則です。しかし、Cloud SDKのクライアントはgRPC接続を高度に抽象化しているため、**「これはCloseが必要な重いリソースである」という意識が薄れがち**です。

**隠れたリソース消費**
Closeを忘れると、メモリだけでなく以下のリソースもリークします。
* Goroutine: gRPCのストリーム維持や監視のために裏側で動き続ける。
* ファイル記述子 (Socket): 外部接続を保持し続け、上限に達すると新規接続ができなくなる。

また、Cloud SDKの多くは内部で**コネクションプーリングを自動管理**しています。そのため、**シングルトンとして1度だけ生成し、全員で使い回す**のが、リソース効率的にもパフォーマンス（接続ハンドシェイクの省略）的にもベストプラクティスです。

毎回 NewClient を呼ぶと、リクエストのたびに認証処理やネットワークのハンドシェイクが発生するため、メモリリークだけでなく、**レイテンシ（レスポンス速度）の悪化**も引き起こします。

今回のケースでは、全体の中で**たった1箇所**だけ、リクエストのたびにクライアントを生成し、かつCloseしていない箇所がありました。その1箇所が原因で、リクエストが来るたびに新しいコネクション（クライアント）が生み出され続け、メモリを食いつぶしていたのです。

# 4. 教訓：クライアント管理の設計パターン（Go）
今回の件で注意したいのは、**「何でもかんでも毎回Open/Closeすればいい」というわけではない**点です。ライフサイクルに応じた管理をプロジェクトで統一すべきです。推奨順にパターンを整理します。

## 【推奨】1. 構造体へのDI（依存性注入）パターン
各ハンドラーを構造体のメソッドとして定義し、生成済みのクライアントをフィールドに持たせる方法です。型安全でテストしやすく、最も推奨されます。
```go

// Env ハンドラーが必要な依存関係をまとめる構造体
type Env struct {
	fc *firestore.Client
}

func main() {
    // 1. クライアント生成
	client, err := firestore.NewClient(ctx, "project-id")
    if err != nil {
		log.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close() // main 終了時に確実に Close

    // 2. 構造体に注入
	env := &Env{fc: client}

	router := gin.Default()

    // 3. メソッドとしてハンドラーを登録
	router.POST("/users", env.CreateUser)
    
	// サーバー起動
    log.Println("Server starting on :8080")
    if err := router.Run(":8080"); err != nil {
        log.Fatalf("failed to run server: %v", err)
    }
}

// CreateUser は Env のメソッドなので、e.fc を使い回せる
func (e *Env) CreateUser(c *gin.Context) {
	// ここで e.fc を使って操作（Close はしない！）
	// e.fc.Collection("users").Add(...)
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}
```

## 2. sync.Once によるシングルトンパターン
必要になった瞬間に一度だけ初期化するパターンです。
```go

var (
	fc *firestore.Client
	once       sync.Once
)

// GetFc: 必要になったタイミングで一度だけ初期化する（シングルトン）
func GetFc() *firestore.Client {
	once.Do(func() {
		ctx := context.Background()
		client, err := firestore.NewClient(ctx, "your-project-id")
		if err != nil {
			log.Fatalf("Firestoreの初期化に失敗: %v", err) 
		}
		fc = client
		log.Println("Firestore client initialized (Singleton)")
	})
	return fc
}

// CloseFc: mainから呼び出して、シングルトンインスタンスを安全に閉じる
func CloseFc() {
	if fc != nil {
		log.Println("Closing Firestore singleton instance...")
		fc.Close()
	}
}

func main() {
	
	router := gin.Default()
    
	router.POST("/data", PostHandler)
    
    // mainのListenAndServeの直前で一度 GetFc() を空呼び（素振り）しておくと、
    // 起動時に接続エラーを検知して Fail Fast できる。
    // GetFc()

	// サーバー起動
	log.Println("Server starting on :8080")
    if err := router.Run(":8080"); err != nil {
        log.Fatalf("failed to run server: %v", err)
    }

	// deferできないので、graceful shutdownでCloseFc()を呼び出すべき（今回は省略）
}

func PostHandler(c *gin.Context) {
	// どこからでも必要な時に GetFc() を呼べるのは便利ではある
    // 初回のみ sync.Once で初期化される。
	db := GetFc()

	_, err := db.Collection("logs").Add(c.Request.Context(), map[string]interface{}{
		"at": time.Now(),
	})

	if err != nil {
		c.JSON(500, gin.H{"error": "DB error"})
		return
	}
    
	c.JSON(200, gin.H{"status": "success"})
}
```

## 3. 【非推奨】Contextにセットするパターン
c.Get("fc") のように取り出す方法は、型アサーションが必要でランタイムエラーのリスクがあるため、避けるべきです。
```go
// ミドルウェアの定義
func FcMiddleware(client *firestore.Client) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Set("fc", client)
		c.Next()
	}
}

func main() {
    // 1. クライアント生成
	client, err := firestore.NewClient(ctx, "project-id")
    if err != nil {
		log.Fatalf("Failed to create client: %v", err)
	}
	defer client.Close() // これを最後に確実に実行させたい

	router := gin.Default()

    // 2. ミドルウェアに登録
    router.Use(FcMiddleware(client)) // 全ルートに適用

    router.POST("/users", func(c *gin.Context) {
		// ミドルウェアでSetしたContextから取り出す
		db, _ := c.Get("fc")
		client := db.(*firestore.Client) //このパターンのここが良くないポイント
		// ... 操作
	})
    
    // サーバー起動
    log.Println("Server starting on :8080")
    if err := router.Run(":8080"); err != nil {
        log.Fatalf("failed to run server: %v", err)
    }
}
```

今回のメモリリークは「入り口（生成）」の問題でしたが、Graceful Shutdownは「出口（破棄）」の品質を担保します。Cloud Runのようにインスタンスが頻繁に立ち上がる環境では、古い接続をDB側に残さない（ゾンビ接続にしない）ようにしないと、接続が増え続ける別の問題になります。ここはまた別途記事を書きます。

# 5. まとめ：プロジェクトとしての方針決定とAIエージェントへの伝達
Cloud SDKのクライアントは、サービスによって「シングルトンで使い回すのが推奨されるもの」が多いです。だからこそ、「ここではCloseしていなくても、どこかで管理されているだろう」という甘い判断が生まれてしまいます。

今回のような「入り口（生成）」のミスを防ぐには、今のAI時代においては、人間が気をつけるだけでなく、AIエージェントにプロジェクトのルールを教え込むのも必要です。AGENTS.md や CLAUDE.md に以下の指針を明文化しておくことで、AIが勝手にクライアントを生成するのを防げます。
```md
## Client Lifecycle Rules
- Firestore/PubSub/Storage: ハンドラー内で新規クライアントを生成(NewClient)してはいけません。
- `internal/db` 等で初期化済みのシングルトン、またはDIされたインスタンスを使い回してください。
- 接続のClose忘れはメモリリークに直結するため、生成と破棄の場所を厳格に管理してください。
```

# 6. 最後に
今回の経験を糧に、今後は下記3つを意識していきたいです。
* **クライアントのライフサイクルを統一する**
* **プロファイラを常時有効にする**
* **AGENTS.mdやCLAUDE.mdに書く**

同じようにサービスでのメモリ管理に悩む方の参考になれば幸いです。

※ この記事は [Qiita](https://qiita.com/horirinn2000/items/0a2c804ef979cf8e5a8f) に投稿した内容を転載したものです。
