---
title: 【GCP】MetabaseをCloud Runで動かす。Read Replicaで負荷分散し、Nginxサイドカーで「IP制限」をかける鉄壁構成
tags:
  - nginx
  - Security
  - cloudsql
  - Metabase
  - CloudRun
private: false
updated_at: '2026-03-21T08:31:22+09:00'
id: 8c567e8330dd4534c424
organization_url_name: null
slide: false
ignorePublish: false
---
# はじめに

今回は、データの可視化（BIツール）として人気の高い **Metabase** のアーキテクチャ最適化とセキュリティ対策について解説します。

「エンジニアじゃなくてもSQLなしでデータ分析ができる」
これはデータ民主化の観点で素晴らしいことですが、インフラエンジニアからすると**恐怖の始まり**でもあります。

営業やマーケティングチームが作成した「超重量級の集計クエリ（数百万行のJOINなど）」が、**サービスが稼働している本番DB（Primary）** に直接飛んでしまったらどうなるでしょうか？
当然、CPU利用率は跳ね上がり、サービスの応答速度は低下し、最悪の場合はダウンタイムを引き起こします。

さらに、社内向けツールとはいえ、管理画面をインターネットにフルオープンにするのはセキュリティ的にNGです。

そこで今回は、Metabase を Cloud Run で構築しつつ、以下の2点で**本番サービスを守りつつ、セキュリティも担保する**構成を紹介します。

1. **Cloud SQL Read Replica**: 重いクエリをレプリカに逃がし、本番環境への影響をゼロにする。
2. **Nginx サイドカー**: Cloud Armor（有料）や外部ロードバランサを使わずに、コンテナだけで強固な IP 制限をかける。

# 1. アーキテクチャ：OLTPとOLAPを分離する

まず大原則として、アプリケーションが読み書きするデータベース（OLTP）と、分析用のデータベース（OLAP用途）は物理的に分離する必要があります。

* **Primary（書き込み/読み込み）**: GoやRailsなどのアプリケーション本体が接続。ミリ秒単位の高速な応答が求められる。
* **Read Replica（読み込み専用）**: Metabase 等のBIツールが接続。数分かかる重いクエリが走ってもPrimaryには一切影響を与えない。

## Cloud SQL での Read Replica 作成
GCPコンソールから、既存の Cloud SQL インスタンスを選択し、「リードレプリカを作成」をクリックするだけです。
数分待つだけで、データが同期された複製DBが出来上がります。

> **💡 ワンポイントアドバイス**
> レプリカのインスタンス費用は追加で発生しますが、ここは妥協してはいけないコストです。「本番サービス停止のリスク」と天秤にかければ非常に安い保険と言えます。

# 2. セキュリティ：Nginxサイドカーで安価にIP制限

Metabase (OSS版) 自体には IP 制限機能が組み込まれていません。
GCP で IP 制限を行う王道パターンは **Cloud Load Balancing + Cloud Armor** の組み合わせですが、これらは月額数千円〜の固定費がかかってしまいます。

そこで、Cloud Run の **サイドカー（マルチコンテナ）機能** を活用し、前段に **Nginx** を配置して IP フィルタリングを行います。この構成なら追加のインフラコストはほぼゼロです。

## 構成イメージ
* **Container 1 (Ingress)**: Nginx (ポート `8080` でリクエストを受付 → 許可IPかチェック → `localhost:3000` へ転送)
* **Container 2 (Sidecar)**: Metabase 本体 (ポート `3000` で起動。外部からの直接アクセスは遮断)

## Nginx の設定 (`nginx.conf`)

特定の IP（オフィスの固定IPや社内VPNなど）のみを許可し、それ以外からのアクセスには `403 Forbidden` を返すシンプルな設定です。

```nginx
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    server {
        listen 8080;

        # ここでアクセスを許可するIPを指定
        allow 203.0.113.10; # オフィス固定IP
        allow 198.51.100.0/24; # VPN帯域
        deny all; # それ以外は全て拒否

        location / {
            # サイドカーのMetabase (Container 2) へ転送
            proxy_pass http://127.0.0.1:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        
        # ヘルスチェック用 (Cloud Runの死活監視が通るようにアクセスログを切る)
        location /_health {
            access_log off;
            return 200 'OK';
        }
    }
}
```

これを `nginx.conf` として保存し、専用の Dockerfile で Nginx イメージを作成・Pushしておきます。

# 3. Cloud Run へのデプロイ (`service.yaml`)

サイドカー構成は `gcloud` コマンドの引数だけで構築しようとすると非常に複雑になるため、YAMLファイル（`service.yaml`）を定義してデプロイするのがベストプラクティスです。

> **🚨 注意1: JavaアプリとUnixソケットの深刻な罠**
> Cloud Run には Cloud SQL 接続用の便利なアノテーション（Unixソケット経由）がありますが、**Java（Metabase本体）の標準DBドライバはUnixソケット通信にネイティブ対応していません。** そのため、公式イメージをそのままアノテーションで繋ごうとすると `UnknownHostException` 等で立ち上がらずクラッシュします。
> この罠を回避するため、本記事では **Cloud SQL Auth Proxy** の公式コンテナを「3つ目のサイドカー」として相乗りさせ、内部的に TCPポート（`127.0.0.1:3306`, `3307`）へ変換してあげるアーキテクチャを採用しています。

> **⚠️ 注意2: Metabase 用の「管理データベース（Primary）」について**
> この構成では、Cloud SQL インスタンスを「分析対象の Read Replica」と「Metabase自体のシステムデータを保存する Primary」の**2種類**指定します。
> Metabase は「ユーザー情報」や「ダッシュボードの設定」を保存（書き込み）する必要があるため、Read Replica（読み取り専用）では起動できません。本番サービスと同じ Primary の中に `metabase_app_db` などの専用データベースを事前に `CREATE DATABASE` して準備しておいてください。

```yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: metabase-secure
spec:
  template:
    metadata:
      annotations:
        # Metabaseの起動完了を待ってからNginxにトラフィックを流す
        run.googleapis.com/depends-on: "nginx=metabase"
    spec:
      containers:
        # --- 1. Nginx (Ingress / 門番役) ---
        - name: nginx
          image: gcr.io/my-project/nginx-ip-filter:latest # ビルドしたNginxイメージ
          ports:
            - containerPort: 8080 # Cloud Runから最初にリクエストを受け取るポート
          resources:
            limits:
              cpu: 500m
              memory: 256Mi
        
        # --- 2. Metabase (アプリケーション本体) ---
        - name: metabase
          image: metabase/metabase:latest
          env:
            # Metabase自身の管理データ保存先
            - name: MB_DB_TYPE
              value: "mysql" # PostgreSQLの場合は "postgres"を指定
            - name: MB_DB_DBNAME
              value: "metabase_app_db"
            - name: MB_DB_PORT
              value: "3306"  # Proxyが開放するPrimary用ポート
            - name: MB_DB_USER
              value: "metabase_user"
            - name: MB_DB_PASS
              value: "password"
            - name: MB_DB_HOST
              value: "127.0.0.1"  # Proxyコンテナ経由で接続
            # Metabaseはポート3000で起動（Ingressコンテナからのみアクセス可能）
            - name: MB_JETTY_PORT
              value: "3000"
          startupProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 15
            timeoutSeconds: 5
            periodSeconds: 10
            failureThreshold: 15 # Metabaseは起動に時間がかかるため長めに設定
          resources:
            limits:
              cpu: 2000m
              memory: 4Gi

        # --- 3. Cloud SQL Auth Proxy (DB接続用サイドカー) ---
        - name: cloud-sql-proxy
          image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:latest
          args:
            # Primaryを3306ポート、Replicaを3307ポートでローカルに開放
            - "--address=0.0.0.0"
            - "--port=3306"
            - "PROJECT:REGION:PRIMARY_INSTANCE"
            - "PROJECT:REGION:REPLICA_INSTANCE?port=3307"
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
```

準備ができたら、以下のコマンドでデプロイを実行します。

```bash
gcloud run services replace service.yaml
```

これで、「門番であるNginxを通過できた許可IPのユーザーだけがMetabaseを利用できる」セキュアな環境がデプロイされました。

# 4. Metabase 側の設定（一番重要）

Cloud Run が無事に起動したら、許可されたネットワークから Metabase の URL にアクセスし、初期セットアップを完了させます。
その後、実際にデータ分析を行う対象のデータベースを登録します。

## 対象データベース（Target DB）の接続設定

管理画面の「データベースの追加」から、以下のように設定を行います。

* **ホスト（Host）**: `127.0.0.1`
* **ポート（Port）**: `3307`
    * ⚠️ **最重要ポイント**: コンテナ内でCloud SQL Proxyが動いているため、DBのホストは `127.0.0.1` となります。また、ポートとして **3307** を指定することで確実に **Read Replica** に接続されます。
* **データベース名**: 分析対象の業務DB名
* **ユーザー名 / パスワード**: 分析用に `CREATE USER` した<strong>読み取り専用ユーザー（Read Only User）</strong>の認証情報を設定するのが鉄則です。

> **💡 補足 (Private IP接続について)**
> もし運用上の理由で Proxy コンテナ（オーバーヘッド）を挟みたくない場合、Cloud Run に Serverless VPC Access や Direct VPC Egress を設定し、ホストに Cloud SQL の Private IP（`10.x.x.x`）を直接指定して TCP 接続することも可能です。

この設定により、Metabaseから発行されるクエリはすべてレプリカに向けられるため、本番サービス（Primary）への負荷はゼロになります。

# まとめ

* **OLTPとOLAPを分離する**: アプリ用（Primary）と分析用（Read Replica）は物理的に分け、本番環境への影響を遮断する。
* **Nginxサイドカーの活用**: 高価なコンポーネント（Cloud Armor等）を使わずに、コンテナのサイドカー構成だけで安価かつ強固にIP制限をかける。
* **接続先と権限の最小化**: Metabase の分析対象データソース設定では、確実にレプリカを指定し、読み取り専用ユーザーを使用する。

「BIツールを導入したら本番DBが重くなった」「社外秘のダッシュボードがインターネット上に公開されていた」
そんな大事故を防ぐために、最初からこの堅牢な構成で構築しておくことを強くお勧めします。

データの民主化（活用）とシステムの安定稼働、そしてセキュリティ。すべてを妥協しないのがプロフェッショナルなインフラ設計です。
