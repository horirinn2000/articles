---
title: Firestoreの課金を抑える！画面別データ保存の落とし穴とコスパ最強の実装術
tags:
  - アーキテクチャ
  - フロントエンド
  - Firebase
  - Firestore
  - コスト削減
private: false
updated_at: '2026-04-04T19:37:49+09:00'
id: 461ad60d07e4a98c17c7
organization_url_name: null
slide: false
ignorePublish: false
---

# はじめに

Firestoreを利用したアプリ開発で、「ユーザーデータをどう構築すべきか」悩んだことはありませんか？
画面ごとに表示する情報が異なるため、「画面A用のユーザーデータコレクション」「画面B用のコレクション」といったように、画面ごとにデータを別々のコレクションに切り分けて保存する設計にしてしまうことがあります。

しかし、この構造はFirestoreにおいて思わぬ「課金の罠」にはまる可能性があります。
本記事では、Firestore独自の課金体系を紐解きながら、よりコスパに優れたFirestore運用を実現するためのベストプラクティス（非正規化・ローカルファースト実装など）について体系的に解説します。

---

# 1. 前提：FirestoreとCloud SQLの課金体系の決定的違い

データベースの選定や設計において、「RDBMS（Cloud SQLなど）」と「NoSQL（Firestore）」の課金体系の違いを正しく理解することは極めて重要です。ここを誤解したままRDBMSの感覚で実装すると、破綻の原因になります。

| サービス | 課金のベース | 課金されるリソースの考え方 |
|---|---|---|
| **Cloud SQL (RDBMS)** | **リソース確保型** | インスタンスの「CPUコア数」「メモリ量」「ストレージ容量」「稼働時間」に対して課金されます。**処理性能の限界を超えない限り、何度データを読み書きしても料金は一定**です。アプリが使われなくても固定費が発生します。 |
| **Firestore (NoSQL)** | **従量課金型** | サーバーのスペックという概念がありません。「ドキュメントを何回取得したか（Read）」「何回保存したか（Write）」という純粋な**操作回数**に比例して無制限に課金されます。逆に言えば、誰も使わなければ維持費は0円（無料枠内）です。 |

この性質上、Firestoreで「無駄にデータを取得する（=Read回数増加）」「ちょっとした変更のたびに何度も保存する（=Write回数増加）」実装をしてしまうと、思わぬ高額請求に繋がります。

### 参考：Firestoreの料金の考え方と無料枠
Firestoreの料金はリージョン（東京など）や為替によって変動します。最新の正確な価格は必ず[公式の料金表](https://cloud.google.com/firestore/pricing)をご確認ください。以下はコスト感覚を掴むための目安（スタンダードエディション）です。

| オペレーション | 無料枠（1日あたり） | コストの重さ（相対比較） |
|---|---|---|
| **読み込み (Read)** | 50,000 回 | 基準 |
| **削除 (Delete)** | 20,000 回 | Readよりさらに安い（Readの約3分の1） |
| **書き込み (Write)** | 20,000 回 | **最も高い（Readの約3倍のコスト）** |

このように、**書き込み（Write）は、読み込み（Read）の約3倍もコストが高い**という性質があります。だからこそ、Writeをいかに減らすかがアーキテクチャの腕の見せ所になります。

---

# 2. なぜ「画面ごとのデータ分割」はアンチパターンなのか？

「画面A用のコレクション」「画面B用のコレクション」と細かく分けてしまうと、**読み書き回数の爆発**を引き起こします。

たとえば、ある画面で「ユーザーの基本情報」と「画面Aの固有設定」と「画面Bの固有設定」をクロスして表示したい場合、RDBMSではJOINを利用して1クエリで取得できますが、FirestoreはJOINが苦手です。別々のドキュメントに対し複数回の `getDoc` を発行しなければならず、Read課金が単純に2倍、3倍に膨れ上がります。

---

# 3. 最強のアーキテクチャ：ドキュメントの統合（非正規化）

根本的な解決策として、**関連するデータを1ユーザーにつき1つ（または少数）の大きなドキュメントとしてまとめる**アプローチが重要です。これはFirestore公式でも推奨される**非正規化**（Denormalization）の考え方です。

データを大きなオブジェクトとして一つのドキュメントに詰め込むことで、圧倒的な読み込みパフォーマンスとコスト削減（1 Read）を実現できます。

## React / TypeScriptでの具体的な実装例

クライアント（Firebase SDK v9/v10）から直接アクセスし、1つの大きなドキュメントを取得・更新するアーキテクチャの例です。

### ① データの型定義
画面ごとに分散していたデータを1つの型にまとめます。

```typescript
// types/user.ts
export type UserDocument = {
  id: string;
  profile: { displayName: string; avatarUrl: string; };
  dashboardSettings: { theme: 'light' | 'dark'; showWidgets: string[]; };
  notificationSettings: { emailAlerts: boolean; pushEnabled: boolean; };
  updatedAt: number;
};
```

### ② アプリの根元で一括取得し、全画面に配る（真の 1 Read に抑える）
各コンポーネントで個別にデータ取得処理を呼び出すと、画面移動のたびにReadが発生する罠があります。これを防ぐため、**React Context** 等を用いてアプリの最上位（ルート）で一度だけ取得し、メモリ上のデータを下層の全画面へ配る設計が必須です。

```tsx
// contexts/UserDataContext.tsx
import { createContext, useContext, useState, useEffect } from 'react';
import { doc, onSnapshot } from 'firebase/firestore';
import { db } from '../lib/firebase';
import type { UserDocument } from '../types/user';

// ① コンテキストの作成
const UserDataContext = createContext<UserDocument | null>(null);

// ② アプリの根元（App.tsxなど）で1度だけラップするProvider
export const UserDataProvider = ({ userId, children }: { userId: string, children: React.ReactNode }) => {
  const [userData, setUserData] = useState<UserDocument | null>(null);

  useEffect(() => {
    if (!userId) return;
    // アプリを開いている間はずっと1つのコネクションで監視し続ける（1 Read）
    const unsubscribe = onSnapshot(doc(db, 'users', userId), (docSnap) => {
      if (docSnap.exists()) setUserData({ id: docSnap.id, ...docSnap.data() } as UserDocument);
    });
    return () => unsubscribe();
  }, [userId]);

  return (
    <UserDataContext.Provider value={userData}>
      {children}
    </UserDataContext.Provider>
  );
};

// ③ 各コンポーネントから通信不要でデータを取得するカスタムフック
export const useUserData = () => useContext(UserDataContext);
```

### ③ 部分更新（ドット記法を使った Write ）
ドキュメントが大きくなっても、全てを上書き送信する必要はありません。`updateDoc` の**ドット記法**（Dot Notation）を使うことで、特定のフィールドのみをパッチ更新できます。

```tsx
// components/DashboardSettings.tsx
import { doc, updateDoc } from 'firebase/firestore';
import { db } from '../lib/firebase';

export const updateTheme = async (userId: string, newTheme: 'light' | 'dark') => {
  const userDocRef = doc(db, 'users', userId);
  // ドット記法で指定したフィールド"だけ"を更新する（1 Write）
  await updateDoc(userDocRef, {
    'dashboardSettings.theme': newTheme,
    updatedAt: Date.now()
  });
};
```

**【補足】ドット記法とWrite課金の関係**
「一部だけの更新なら課金も安くなる？」とよく誤解されますが、いくら送るデータが小さくても**1回の通信は「1 Write」として一律課金されます**。
非正規化の本当の凄さは、「テーマ変更」と「通知設定変更」といった複数の操作をユーザーが同時に行った場合でも、**大きな1つのドキュメントなら1回のWriteで同時に保存できる**（課金が1回で済む）点にあります。

### 注意点：統合のトレードオフ（1MBの壁とホットドキュメント）
* **1MBの制限**: Firestoreの1ドキュメントの最大サイズは1MBです。チャット履歴のように**無限に増えるデータはサブコレクションに分離**するのが鉄則です。
* **ホットドキュメント**: 1秒間に複数回以上、同じドキュメントに更新が集中すると競合でエラーになります。一般的なユーザー設定レベルなら問題ありません。

---

# 4. フロントエンドでの「Write回数」最適化テクニック

非正規化で「1回あたりのWrite効率」を上げたら、次は**Writeを行う頻度自体**を減らす必要があります。

### 罠：Firestore標準のローカルキャッシュはWriteを減らさない
「Firestoreのオフライン永続化（Offline Persistence）をオンにすればWrite課金も減るのでは？」という勘違いがよく起きます。
標準のキャッシュ機能は、通信量を減らし<strong>「Read」を劇的に減らす機能</strong>ですが、「Write」は減らしません。オンライン時に `updateDoc` を呼べば、すべて即座にクラウドへ送信され課金が発生します。

### 確実な削減手法：フォームの適切な状態管理とデバウンス
本当の意味でWrite課金を減らすには、無駄な保存API呼び出しをフロントエンド側で防ぐ実装が必要です。

1. **フォーム状態のローカル保持（React Hook Form等）**:
   Firestoreのリアルタイム性に引っ張られ、`onChange`のたびに保存処理を走らせてしまうのは初心者にありがちな罠です。入力中の状態はすべてメモリ（`React Hook Form`など）で管理し、「保存ボタン（`onSubmit`）」が押された時に1度だけ送信するのが、絶対のルールです。
2. **差分書き込み**: 
   フォーム入力画面から離脱する際、**実際のデータ（State）に変更があった場合のみ**Firestoreに送信するように制御します。
3. **遅延書き込み（デバウンス）**: 
   ユーザーのテキスト入力都度保存するのではなく、「入力が一定時間（例: 2秒）停止したタイミング」でまとめて1回だけFirestoreへ書き込みます。

---

# 5. 発展編：OSSを用いた「Local-First」への昇華

究極のWrite削減は、**「操作の大半をローカルのメモリやDBで完結させ、必要な時だけ非同期でサーバーに同期する」**という**Local-Firstアーキテクチャ**の導入です。著名なOSSを活用することで、Firestoreへの負荷を最小限に抑えつつ最高のUXを提供できます。

### ① グローバル状態の localStorage 同期（Zustand + Persist）
 `Zustand` の `persist` ミドルウェアを使い、状態を自動でブラウザの `localStorage` に保持します。ユーザーの操作はすべてローカルに即時反映させ、任意のタイミング（画面離脱時や1分ベースの定期処理）で最新のZustandのデータをバッチ処理でFirestoreへ一発送信します。

### ② 究極系：Local-First DBによる自動同期（RxDB）
ネットワーク環境を問わず爆速で動くアプリ（Notion等）を作るための究極アプローチです。
フロントエンド専業のローカルデータベースである `RxDB` を導入し、アプリ側は一切Firestoreを触らずRxDBにのみ読み書きを行います（Write課金0円）。その後、RxDB標準の「Firestore Replication」機能が、バックグラウンドでローカルの差分だけを効率よくFirestoreに同期（プッシュ）してくれます。学習コストは高いものの、課金とUXの観点では最強の構成です。

---

# まとめ

Firestoreは非常にスケールしやすく強力なデータベースですが、RDBMSと同じような「正規化を重視した設計」をすると、通信回数の爆発により維持費が跳ね上がります。

1. **ドキュメントの統合**（非正規化）でReadを「1回」にまとめる
2. クラウドの**Write操作自体を減らす**（デバウンス・差分チェック）
3. 余裕があれば **Local-FirstなOSS（Zustand, RxDB）**を活用して強力な状態管理を行う

この3点を意識するだけで、Firestoreのランニングコストは嘘のように削減でき、アプリの体感速度も劇的に向上します。ぜひプロジェクトに取り入れてみてください。
