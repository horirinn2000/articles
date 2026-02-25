---
title: 【Go】Cloud RunでAlpineを卒業しよう。Distroless採用時の「デバッグ」と「CI/検証環境」の正解パターン
tags:
  - Go
  - CloudRun
  - Distroless
  - Alpine
  - GCP
private: false
updated_at: ''
id: null
organization_url_name: null
slide: false
ignorePublish: false
---

# はじめに

今回は、GoアプリケーションをCloud Runで動かす際の**ベースイメージ選び**と、それに伴う**運用テクニック**について話します。

「Cloud Runのコンテナといえば、とりあえず軽量な `Alpine`」と思っていませんか？
私は最近、本番環境では **Distroless** を、ローカル開発では **Debian(bookworm-slim)** を使い分ける運用に完全に切り替えました。

今回は、なぜ Alpine をやめたのか（特にパフォーマンスと互換性の観点から）、そして「シェルがない」Distroless をどうやってデバッグ・開発していくのか、その具体的なノウハウを共有します。

# なぜ Alpine (musl) をやめるのか？

かつては「軽量＝正義」で `alpine` 一択でしたが、Go の本番運用において、Alpine が採用している `musl libc` はいくつかの**隠れた地雷**を持っています。対して、Debian系が採用している `glibc`（または純粋なGoのランタイム）は、その問題を解決します。

## 1. メモリアロケータの性能差 (malloc)

SQLiteやKafkaクライアントなど、C言語のライブラリに依存するパッケージを使い、**CGO を有効（`CGO_ENABLED=1`）にしてビルドする場合**、この問題が直撃します。
`glibc` の `malloc` はマルチスレッド環境でのロック競合を減らす最適化が施されていますが、`musl` は省メモリ優先です。高負荷時に Alpine だけ CPU 使用率が跳ね上がったり、レイテンシが悪化したりするのは、このロック競合が原因であるケースが少なくありません。

## 2. 恐怖の「ndots:5」問題と DNS 解決の遅延

CGOを使わない完全な静的バイナリ（`CGO_ENABLED=0`）であっても、Alpine を避けるべき理由があります。それが DNS 解決の挙動です。

Kubernetes (GKE) や Cloud Run などのコンテナ環境では、内部DNSを引くために `resolv.conf` に `ndots:5` などの検索ドメイン設定が自動付与されます。
* **glibc系 / Go標準リゾルバ:** Aレコード（IPv4）とAAAAレコード（IPv6）を並列で効率よく問い合わせます。
* **musl系:** 検索ドメイン（`search`）を順番に、しかもIPv4とIPv6を**シーケンシャルに**問い合わせる挙動をすることがあり、外部APIを叩く際のレイテンシが不必要に増加する「ndots:5 問題」のトリガーになりやすいです。

これらの理由から、特にパフォーマンスと信頼性が求められる Cloud Run 環境では、**「標準的で最適化された Debian 系」** を使うのが、シニアエンジニアとしての「安眠のための選択」です。

# 本番運用の正解：Google Distroless

では、Debian ベースなら何でもいいかというと、本番環境には攻撃対象領域（アタックサーフェス）が極小である **Google Distroless** が最適です。

ただし、ここで<strong>「CGOの有無」によって選ぶべきDistrolessのタグが変わる</strong>という極めて重要なポイントがあります。

### パターンA：完全な静的バイナリ（CGO_ENABLED=0）の場合
* **正解イメージ:** `gcr.io/distroless/static-debian13`
* **解説:** C言語の機能に一切頼らず、Goのコンパイラが必要なものをすべて1つのバイナリに詰め込んでいる状態です。OSの `libc` すら不要なため、純粋にバイナリと証明書（ca-certificates）、タイムゾーン情報（tzdata）しか入っていない `static` イメージを使います。容量はわずか数MBで済みます。

### パターンB：Cライブラリ依存がある（CGO_ENABLED=1）の場合
* **正解イメージ:** `gcr.io/distroless/base-debian13`
* **解説:** `go-sqlite3` などを使うため CGO を有効にした場合、OS側のC標準ライブラリ（`libc`）を間借りして動くことになります。そのため、`static` イメージに入れると「libcが見つからない」と即死します。この場合は、高性能な `glibc` が最初から同封されている `base` イメージを選ぶのが正解です。

> debian13の部分はその時の安定版を使うようにしてください。


# 課題1：シェルがないとデバッグできない？

Distroless 最大のメリットは「シェルがないこと」ですが、それは同時に**トラブルシューティング時、コンテナに入って調査できない**というデメリットでもあります。
`docker exec` や Cloud Run のコンテナへのExec（シェル接続）は `/bin/sh` が存在しないと動作しません。

## 解決策：緊急時は `:debug` タグを使う

実は、Google の Distroless イメージには、トラブルシューティング専用の **`:debug` タグ** が用意されています。これには `busybox` (軽量なシェル環境) が含まれています。

**トラブル時:** 一時的に Dockerfile（またはデプロイ設定）を書き換えます。
```dockerfile
# デバッグ時だけこれにする（baseの場合も同様に base-debian13:debug があります）
FROM gcr.io/distroless/static-debian13:debug
```
※注意：Cloud Runでデバッグイメージをデプロイする際は、**必ずトラフィック割り当てを 0% にして新しいリビジョンとしてデプロイ**し、そのリビジョンに直接タグURL等でアクセスしてください。本番のトラフィックをデバッグコンテナに流してはいけません。

> 「ローカルで確認すればいいのでは？」と思うかもしれませんが、VPC経由でのCloud SQLへの疎通確認や、IAM権限・Secretの適用漏れなど、本番環境でしか再現しないインフラ起因のエラーは存在します。 本番環境特有の原因調査のために、コンテナ内部から curl や printenv を叩きたくなる瞬間が来ます。

# 課題2：CIや検証環境でのテストがつらい

Goの開発において、普段のコーディングは手元のPC（`go run`）で行うのが一般的です。

しかし、いざ本番へデプロイする前に、**CI（GitHub Actions等）や検証環境（Staging）でE2Eテストや結合テスト**をコンテナ上で回すフェーズがあります。

ここで Distroless（本番イメージ）をそのまま使うと、テストに必要な `curl` やデバッグツールが入っていないため、テストスクリプトが動かず手詰まりになります。

## 解決策：検証・テスト環境用には `debian:bookworm-slim` を残す

そこで、Dockerfileの **Multi-stage build** と **Target** 機能を使って、**本番用とテスト（検証）用でベースイメージを出し分ける**戦略を取ります。

現在の Distroless の中身は **Debian 13 (Bookworm)** ベースです。OSのバージョンを合わせつつ、ローカルではシェルも使える `slim` 版を使うことで、「本番との互換性を保ちつつ、開発体験（DX）を損なわない」環境が作れます。

# 実装例：Targetを使った使い分け（完全版）

以下は、最も標準的な「CGO_ENABLED=0」を前提とした実装例です。

```dockerfile
# ---------------------------------------------------
# ステージ1: ビルド環境
# ---------------------------------------------------
FROM golang:1.26-bookworm AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 を指定して「完全な静的バイナリ」を作る
# ※CGOが必要な場合は CGO_ENABLED=1 に変更してください
RUN CGO_ENABLED=0 GOOS=linux go build -o myapp main.go

# ---------------------------------------------------
# ステージ2: 検証環境 (target: dev)
# ---------------------------------------------------
# 検証用。シェルもaptも使える。
FROM debian:bookworm-slim AS dev
WORKDIR /app
# 開発に必要なツールがあればここで入れる
RUN apt-get update && apt-get install -y curl ca-certificates
COPY --from=builder /app/myapp /myapp
CMD ["/myapp"]

# ---------------------------------------------------
# ステージ3: 本番環境 (target: prod)
# ---------------------------------------------------
# 本番用。Distrolessで極小・セキュアに。
# ※CGO_ENABLED=1でビルドした場合は、ここを `base-debian13:nonroot` に変更する！
FROM gcr.io/distroless/static-debian13:nonroot AS prod

WORKDIR /

# ステージ1で作ったバイナリをコピー
# 必ず --chown=nonroot:nonroot をつけて、実行ユーザーに権限を持たせる
COPY --from=builder --chown=nonroot:nonroot /app/myapp /myapp

# 実行ユーザーを明示（nonrootタグを使っているためUID 65532が適用される）
USER nonroot:nonroot

CMD ["/myapp"]
```

**docker-compose.yml (検証用):**
```yaml
services:
  app:
    build:
      context: .
      target: dev  # ここで "dev" ステージを指定してビルド！
```

**Cloud Build / Deploy (本番用):**
デフォルト（`target` 指定なし）だとDockerfileの最後のステージ（`prod`）がビルドされるため、CI/CDのスクリプトは変更不要です。

> 罠注意：nonroot とポート番号
> nonroot は1024番以下のポート（80や443など）をバインドできません。アプリ側で http.ListenAndServe(":80", nil) のように直書きしていると権限エラーで起動に失敗するため、必ず環境変数 PORT（Cloud Runのデフォルトは8080）で起動するように実装してください。

# おまけ：Go 1.25 から変わるコンテナのCPU最適化

記事の前半で「パフォーマンス向上のために musl を避ける」と熱く語りましたが、コンテナでGoを動かす際、かつては<strong>「GOMAXPROCSの設定漏れ」</strong>というさらに凶悪なパフォーマンスの罠がありました。

かつて、コンテナ環境（Cloud RunやK8sなど）では、Goのランタイムがコンテナに割り当てられたCPU数（例: 1 vCPU）ではなく、**ホストマシンの物理CPU数（例: 64コア）を誤認してスレッドを大量生成**してしまう問題がありました。これを防ぐために、これまで多くの現場では Uber が開発した `go.uber.org/automaxprocs` をインポートしていました。

しかし、**Go 1.25 から遂に公式で対応されました。**
Goの標準ランタイムが Linuxのcgroup（CPU quota）を自動で認識し、`GOMAXPROCS` のデフォルト値をコンテナの制限に合わせて最適化してくれるようになったのです。

つまり、**Go 1.25 以降を使っていれば、面倒なライブラリのインポートや環境変数の設定なしで、デフォルトのままCloud Runにデプロイして最高のパフォーマンスが出る**ようになっています。時代は進化していますね。

# まとめ

* **脱Alpine**: CGO利用時の `musl` の罠や、静的バイナリでも起こる「ndots:5 問題」を避けるため、Goなら Debian ベースが安心。
* **CGOで選ぶDistroless**: CGOを使わないなら `static`、CGOが必須なら `base` (glibc入り) を選ぶ。
* **本番は Distroless**: セキュリティと軽量化のために `:nonroot` タグを使う。
* **緊急時は debug タグ**: トラフィック0%で `:debug` タグをデプロイすれば `sh` が使える。
* **検証環境は bookworm-slim**: OSバージョンを合わせつつ、`target` 指定で利便性を確保する。

「Distroless は不便そう」と敬遠していた方も、この使い分けを知れば、安全と便利のいいとこ取りができます。
Cloud Run の本番環境は、胸を張って Distroless でいきましょう！