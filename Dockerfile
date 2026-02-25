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