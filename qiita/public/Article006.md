---
title: 【GCP】「コードを眺める」のは最後にしろ。爆速ボトルネック特定フロー（Log Analytics → Trace → Profiler）
tags:
  - Go
  - performance
  - observability
  - GoogleCloud
  - CloudRun
private: false
updated_at: '2026-02-17T09:01:51+09:00'
id: 1f21837f3c0a49eb7862
organization_url_name: null
slide: false
ignorePublish: false
---

# はじめに

「アプリが重い」と言われたとき、とりあえずエディタを開いて怪しそうなコードを眺めていませんか？
あるいは、勘でインデックスを貼ったりしていませんか？

エンジニアには <strong>「推測するな、計測せよ（Measure, Don't Guess）」</strong>という鉄則があります。

コードだけを見て「ここが遅そう」と修正しても、実はそこは全体の処理時間の1%しか食っておらず、真犯人は全く別の場所（例えば非効率な正規表現や隠れGCなど）だった、というのは「パフォーマンス・チューニングあるある」です。

この記事では、Google Cloud (Cloud Run / Go) 環境における、<strong>「推測を排除し、最短距離で真犯人に辿り着くための黄金フロー」</strong>を解説します。

# 全体像：捜査の3ステップ

パフォーマンス改善は、病院の診断と同じです。いきなり手術（コード修正）はしません。以下の順序で解像度を上げていきます。

1.  **Log Analytics (トリアージ):** 「**どこ**（どのリクエスト）が悪い？」を特定する。
2.  **Cloud Trace (レントゲン):** 「**何**（DBかアプリか）が悪い？」を特定する。
3.  **Cloud Profiler / Query Insights (精密検査):** 「**なぜ**（具体的な関数・SQL）悪い？」を特定する。

---

# Step 1. Log Analytics：犯人の絞り込み（トリアージ）

Cloud TraceやProfilerは強力な「顕微鏡」ですが、全リクエスト（全患者）を検査していたら日が暮れてしまいます。
まずはLog Analytics（Cloud Logging）を使って、「重症患者」だけを選別（トリアージ）します。

漠然とログを眺めるのではなく、以下のフィルタで「異常」だけを抽出しましょう。

## ① 「遅い」リクエストを見つける (Latency Filter)
Cloud Traceへ飛ぶための出発点です。例えば「3秒以上」で絞り込みます。

```text
resource.type="cloud_run_revision"
httpRequest.latency >= "3s"
```

## ② 「エラー」を見つける (Severity Filter)
500エラーが多発している箇所を特定します。

```text
severity >= ERROR
```

## ③ 「特定のテナント」を見つける (JSON Payload)
「A社からクレームが来た」という場合、構造化ログを活用してピンポイントで抽出します。

```text
jsonPayload.tenant_id="100"
httpRequest.latency >= "5s"
```

※ tenant_idは構造化ログで出力するようにしましょう。

## 【上級編】Log Analytics (SQL) でランキングを作る
Logs Explorerではなく、対象Log Storageの「Upgrade to use ログ分析」を有効にしていれば、「ワーストランキング」を一撃で作成できます。
ここで重要なのが、**`APPROX_QUANTILES`** という呪文です。

```sql
WITH FormattedLogs AS (
  SELECT
    http_request.request_method,
    http_request.request_url,
    -- STRUCTから秒とナノ秒を取り出し、単一のFLOAT64（秒単位）に変換する
    -- ※値がNULLになるケースを想定してCOALESCEで0を補完すると安全です
    COALESCE(http_request.latency.seconds, 0) + 
    COALESCE(http_request.latency.nanos, 0) / 1000000000.0 AS latency_sec
  FROM
    `YOUR_PROJECT.global._Default._Default`
  WHERE
    resource.type = "cloud_run_revision"
    -- レイテンシが記録されているリクエストのみを対象にする
    AND http_request.latency IS NOT NULL
)

SELECT
  request_method,
  request_url,
  AVG(latency_sec) AS avg_latency,
  -- 99パーセンタイル値
  APPROX_QUANTILES(latency_sec, 100)[OFFSET(99)] AS p99_latency,
  -- 95パーセンタイル値
  APPROX_QUANTILES(latency_sec, 100)[OFFSET(95)] AS p95_latency
FROM
  FormattedLogs
GROUP BY
  1, 2
ORDER BY
  -- 99パーセンタイル値で、遅いユーザーを特定する
  p99_latency DESC
  -- 95パーセンタイル値で、遅いユーザーを特定する
  -- p95_latency DESC
  -- 単純な平均値だと、一部のユーザーが遅いことに気づけないため、あまり意味がない！
  -- avg_latency DESC
```

### なぜ「平均値 (AVG)」だけではダメなのか？
平均値は嘘をつくからです。

**例：100人のユーザーがアクセスした場合**
* **99人:** 0.1秒（爆速）で完了
* **1人:** 100秒（タイムアウト寸前）で完了

このとき、数値はどうなるでしょうか？

| 指標 | 計算式 | 結果 | 判断 |
| :--- | :--- | :--- | :--- |
| **平均値 (AVG)** | `(0.1×99 + 100) ÷ 100` | **約 1.1秒** | 「平均1秒なら優秀じゃん！」(誤診) |
| **P99** | 下から99%目の人のタイム | **100秒** | **「一部のユーザーが死んでる！緊急事態だ！」(正解)** |

Webサービスでは、「運の悪い1%のユーザー」を救うために、平均ではなく **P99 (99パーセンタイル)** や **P95 (95パーセンタイル)** を監視するのが鉄則です。

### 使い分けの目安
| 指標 | OFFSET(...) | 意味 | 用途 |
| :--- | :--- | :--- | :--- |
| **P50 (Median)** | `OFFSET(50)` | 中央値 | 「普通のユーザー」の体感速度 |
| **P95** | `OFFSET(95)` | ワースト5%の境界 | 一般的なパフォーマンス目標<br>（外れ値を少し許容） |
| **P99** | `OFFSET(99)` | ワースト1%の境界 | 厳格なSLA目標<br>（ほとんど全てのユーザーに高速に返す） |

### SQLの解説
* `APPROX_QUANTILES(..., 100)`: データを高速に100分割（近似計算）します。
* `[OFFSET(99)]`: その99番目の境界値（＝一番遅い部類）を取得します。

---

# Step 2. Log Analytics から Cloud Trace への「ジャンプ」

ここが最も重要な連携ポイントです。
ログで見つけた「遅いリクエスト」の詳細を開いてみてください。GCPのログには自動的に `trace` (Trace ID) が付与されています。

* **アクション:** ログ詳細にある **[トレースを表示 (View in Trace)]** ボタンをクリック。
* **結果:** そのリクエスト **単体** のウォーターフォールチャート（Cloud Trace）に直接飛びます。

ここで、遅延の原因が大まかに判明します。

* **パターンA:** DBのスパン（`db.query` など）がやたら長い
    * 👉 **Cloud SQL Query Insights** へ進む（インデックス不足、ロック待ちなど）
* **パターンB:** アプリ処理のスパン（何も外部を叩いていない空白の時間）が長い
    * 👉 **Cloud Profiler** へ進む（ここがコードの問題）

---

# Step 3. Cloud Profiler：真犯人（関数）の特定

「アプリの処理時間が長い（パターンB）」とわかった時、ここで初めて **Cloud Profiler** の出番です。

## なぜ「コードレビュー」じゃダメなのか？

人間の目によるコードレビューは「推測」に過ぎません。Profiler（実測値）と人間の直感がいかにズレるか、具体例を見てみましょう。

| ケース | 人間の目（推測） | Profilerの真実（計測結果） |
| :--- | :--- | :--- |
| **1.CPU** | 「ループ処理してるけど計算量は $O(N)$ だし問題ないはず」 | `regexp.Compile`（正規表現コンパイル）をループ内で毎回呼んでおり、CPUの80%を使っていた。 |
| **2.メモリ** | 「ただのログ出力と文字列結合だし、軽微だろう」 | `fmt.Sprintf` が大量の一時オブジェクトを生成し、Goの **GC (ガベージコレクション)** が頻発してCPUを食いつぶしていた。 |
| **3.排他制御** | 「並列処理 (`go func`) してるから速いはず」 | `Mutex` のロック待ち時間が長く、実は直列処理より遅くなっていた。 |

これらは、静的なコードを見ているだけでは絶対に見抜けません。
Profilerのフレームグラフを見て、**「一番幅を取っている（時間を食っている）関数」** を特定して初めて、エディタを開き、その関数だけを修正すべきなのです。

# Tips: もう一つの武器 OpenTelemetry (Otel)

もしProfilerの導入が難しい、あるいはもっと手軽にコード内の区間を測りたい場合は、**OpenTelemetry (otel)** のカスタムスパンが役立ちます。

「怪しいロジック」の前後に数行追加するだけで、Cloud Trace上にその区間が表示されるようになります。

```go
// 怪しいロジックの前後にこれを入れる
ctx, span := tracer.Start(ctx, "CalculateTaxLogic") // ← Cloud Traceにこの名前で表示される
defer span.End()

// ... 重そうな処理 ...
```

これを仕込んでおけば、Traceを見た段階で「DBじゃないけど、`CalculateTaxLogic` という関数だけで500msかかってるな」と一目瞭然になります。

# まとめ

パフォーマンス・チューニングにおける正しいフローは以下の通りです。

1.  **Log Analytics:** 「**どこ**が悪い？」(Where) を特定する。
2.  **Cloud Trace:** 「**何**が悪い？」(What) を特定する。
3.  **Profiler / Query Insights:** 「**なぜ**悪い？」(Why) を特定する。
4.  **IDE (VS Code等):** 特定された関数だけを修正する。

Cloud Profiler は導入も簡単（Goなら数行）で、オーバーヘッドも数%程度です。Googleも本番環境での常時稼働を推奨しています。

明日からは、とりあえずコードを眺めるのをやめて、まずは **「ログとプロファイル」** を見に行きましょう。
