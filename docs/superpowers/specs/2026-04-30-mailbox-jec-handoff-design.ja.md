# Mailbox + JEC 引き継ぎプロトコル — 設計仕様 v1.2

- **日付**：2026-04-30
- **プロジェクト**：smolBSD
- **ステータス**：v1.2 — fb-vm-24/<aarch64-builder> の整合、ポート2222、screenソケット問題、.local ネットワークコンテキストの注意事項
- **ライセンス**：BSD-2-Clause（プロジェクトデフォルト）
- **履歴**：v1（2026-04-30 13:30 — オープンセクション延期）；v1.1（2026-04-30 14:30 — エージェント返信収集・統合）；v1.2（2026-04-30 15:00 — fb-vm-24/<aarch64-builder>整合、ポート2222、screenソケット問題、.localネットワークコンテキストの注意事項）

## 1. 目的

**共有の会話履歴なしに、Claude Opus 4.7（コンテキスト1M）エージェントチーム間で
プロジェクト状態を転送できる**ことを実証します。使用するのは以下のみです：

- 単一のBSDメールボックスファイルを交換基盤として、
- RTKおよびその他のコンテキストエンジニアリング技術で圧縮された
  Just-Enough-Context（JEC）ドロップ。

最初のテストワークロードは **smolBSD** 自体です（`plans/tinyos/TINY_OS_VS_RUMPOS_BSD_PLAN.md`
に従ったTinyOSパス）。プロトタイプでプロトコルが実証されると、基盤は実際の
（Tiny|Rump）BSDインスタンスに移行し、そこでは `/var/mail/<エージェント>` が
文字通りの引き継ぎチャネルになります。実験の両半分がそこで収束します。

## 2. 基盤

- **フォーマット**：mbox（RFC822 + `From ` セパレーター）。本文は `Content-Type: text/toml; charset=utf-8`。
- **トポロジー**：単一の共有スプール、`To:` ヘッダーでアドレス指定。1ファイル == システム状態全体。
- **パス**：`/Users/studio/smolBSD/var/mail/spool`（`/var/mail/` のミラー；スプール自体が新規クローン後も生き残るプロジェクト状態の一部となるよう、ツリー内に配置 — これが本質です）。
- **並行性**：コーディネーターのみが追記します。サブエージェントは `To:` でフィルタリングして読み取り、追記することで返信を**発行**します。コーディネーターは次のループで収集します。現段階ではロックは不要；複数のライターが現れたときに再検討します。
- **スレッド**：`Message-ID` + `In-Reply-To`、クラシックメールとまったく同じ。返信は常に `To: coordinator@smolbsd.local` に送られます。

## 3. アドレッシング規約

```
<役割>@smolbsd.local        # コーディネーターが解決するロールベースの仮想アドレス
coordinator@smolbsd.local   # オーケストレーターの受信箱
architect@smolbsd.local
builder@smolbsd.local
reviewer@smolbsd.local
researcher@smolbsd.local
```

プロトタイプフェーズでは、「アドレス」は仮想的なものです — コーディネーターが
Claude Codeサブエージェントをディスパッチし、どの `Message-ID` を読むかを
指示します。実際のBSDインスタンスに移行すると、各アドレスは実際の `passwd(5)`
エントリと実際の `/var/mail/<役割>` を持ちます。

## 4. エンベロープフォーマット（mbox + TOML本文）

### 4.1 リクエスト（コーディネーター → エージェント）

```
From smolbsd-coord Tue Apr 30 12:50:00 2026
From: coordinator@smolbsd.local
To: architect@smolbsd.local
Subject: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 12:50:00 -0000
Message-ID: <task-0001.coord@smolbsd.local>
X-Project: smolbsd
X-Phase: tinyos/forge-tiny-baseline
X-JEC-Compression: rtk-v1
Content-Type: text/toml; charset=utf-8

task_id     = "task-0001"
title       = "Bootstrap FreeBSD 15 amd64 VM with smallest stable footprint"
deadline    = "2026-05-14"

[brief]                       # JEC：散文、ソフト上限200語
summary = """..."""

[context_pointers]            # JEC：パス/sha/msgid — インラインではない
read         = ["docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md", ...]
prior_msgids = []

[acceptance]                  # 二値、テスト可能
must_pass = ["VM boots to login prompt unattended", ...]

[reply_contract]
output_to            = "coordinator@smolbsd.local"
output_format        = "mbox+toml-v1"
attestation_required = true
skills_recommended   = ["freebsd", "qemu-fleet", "freebsd-build-vm"]
tools_required       = ["Read", "Write", "Edit", "Bash"]   # §17：サブエージェントタイプがこれらのツールのいずれかを欠く場合、コーディネーターはディスパッチを拒否する
tools_allowed        = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
budget_tokens        = 80000
```

### 4.2 返信（エージェント → コーディネーター）

```
From smolbsd-architect Tue Apr 30 14:10:00 2026
From: architect@smolbsd.local
To: coordinator@smolbsd.local
Subject: Re: [task-0001] Forge Tiny Baseline — bootstrap FreeBSD amd64 VM
Date: Tue, 30 Apr 2026 14:10:00 -0000
Message-ID: <task-0001.architect@smolbsd.local>
In-Reply-To: <task-0001.coord@smolbsd.local>
References: <task-0001.coord@smolbsd.local>
X-Project: smolbsd
X-Verdict: pass
Content-Type: text/toml; charset=utf-8

task_id = "task-0001"
verdict = "pass"             # pass | fail | blocked

[[claims]]                   # reply_contract.attestation_required の場合に必須
subject  = "VM boots to login prompt"
expected = "login: prompt within 30s"
probe    = "expect(1) script timed boot"
evidence = "logs/task-0001/boot.log:line 412"
verdict  = "pass"

[[artifacts]]
path = "build/freebsd-15-amd64-tiny.qcow2"
sha  = "sha256:..."
size = "487 MiB"
git  = "abc1234"

next_recommended = ["task-0002: shrink to <256 MiB"]
```

## 5. JECプロファイル — `rtk-v1`

`X-JEC-Compression: rtk-v1` は、そのメッセージの圧縮コントラクトを宣言します。2つのレイヤーがあります：

### 5.1 アウトバウンド（コーディネーター側）

コーディネーターが `[brief]` に何かをインライン展開する場合、または `context_pointer`
をインライン展開する場合（稀；ポインターが推奨）、コンテンツはRTKで前処理されます：

| ソース                  | RTKコマンド            | 削減目標 |
|-------------------------|------------------------|------------------|
| `git status`/`diff`/`log` | `rtk git ...`          | -75%〜-92%     |
| ファイル抜粋            | `rtk read -l aggressive` | -70%（シグネチャのみ） |
| テスト/ビルド出力       | `rtk test <cmd>`       | -90%             |
| Lint出力                | `rtk lint`/`rtk tsc`   | -80%             |
| ディレクトリ一覧        | `rtk ls`/`rtk find`    | -80%             |

戦略（RTKドキュメントに準拠）：スマートフィルタリング · グルーピング · 切り詰め · 重複排除。

### 5.2 インバウンド（エージェント側）

RTKをインストールし `rtk init -g` を実行済みのエージェントは、Bashフックを自動的に
取得します。エージェント自身の `Read`/`Grep`/`Bash` 呼び出しで `context_pointers`
を展開する際も、同じ方法でフィルタリングされます。**プロトコルはエージェント側の
RTKを必須としません** — RTKが存在しない場合は生の出力に緩やかにフォールバック
（グレースフルデグラデーション）します。`X-JEC-Compression` ヘッダーは能力の宣言で
あり、要件ではありません。

## 6. ディスパッチループ

```
┌─────────────┐  1. リクエストmboxを書き込み ┌──────────────────┐
│ coordinator │ ────────────────────────► │ var/mail/spool   │
└─────────────┘                            └──────────────────┘
       │                                            │
       │ 2. サブエージェントを起動                  │
       │    "your msgid is <task-XXX.coord@..>"     │
       ▼                                            │
┌─────────────┐  3. 読み取り+解析                  │
│   subagent  │ ◄─────────────────────────────────┘
│  (コールド) │
│             │  4. 作業を実行
│             │     (Read, Bash via RTK, Edit, ...)
│             │
│             │  5. 返信mboxを追記、宛先は
│             │     To: coordinator@smolbsd.local  ┌──────────────────┐
│             │ ────────────────────────────────► │ var/mail/spool   │
└─────────────┘                                    └──────────────────┘
       │ 6. エージェント終了                              │
       ▼                                                   │
┌─────────────┐  7. 返信を収集                            │
│ coordinator │ ◄─────────────────────────────────────────┘
└─────────────┘
```

コーディネーターは1バッチでN件のリクエストを書き込み、N個のサブエージェントを
並列にディスパッチできます。各サブエージェントは自分宛のメッセージのみを読み取ります
（指示された `Message-ID` でフィルタリング）。出力は追記専用であり、スプールのmbox
構造によって自然に直列化されます。

## 7. 検証 — fleet-evalリフレックス

`~/.claude/CLAUDE.md` に従い、`verdict = "pass"` かつ `attestation_required = true`
のすべての返信は、少なくとも1つの `[[claims]]` ブロックを含まなければなりません
（MUST）。コーディネーターは返信を信頼する前に `fleet-eval verify` でクロスチェック
します。信頼できない返信はリトライをトリガーします（ポリシーは D2 で定義予定）。

## 8. 役割とエージェント割り当て

| 役割            | アドレス                       | バッキングサブエージェントタイプ              | 必要ツール（書き込み？）         |
|-----------------|-------------------------------|------------------------------------|----------------------------------|
| coordinator     | `coordinator@smolbsd.local`   | （このOpus 4.7 1Mセッション）         | Read+Write+Edit+Bash             |
| architect       | `architect@smolbsd.local`     | `feature-dev:code-architect`（RO）**または** `general-purpose`（RW） | `tools_required` フィールドに依存 — §17参照 |
| builder         | `builder@smolbsd.local`       | `general-purpose` + freebsdスキル  | Read+Write+Edit+Bash             |
| reviewer        | `reviewer@smolbsd.local`      | `pr-review-toolkit:code-reviewer`  | ほぼRead専用                      |
| researcher      | `researcher@smolbsd.local`    | `general-purpose` + Explore        | Read専用で可                     |
| security        | `security@smolbsd.local`      | `general-purpose` + redactスキル   | Read+Bash（Writeは `var/run/secrets/` 配下のエンベロープのみ） |
| ops             | `ops@smolbsd.local`           | `general-purpose` + fleet-ircスキル | Read+Write+Bash                  |

## 9. 引き継ぎ後も生き残る状態

引き継ぎ先のエージェントチームはコールドスタートし、以下のディスク上のアーティファクト
からプロジェクト状態全体を取得します（会話履歴は不要）：

1. `var/mail/spool` — スレッド化された全メッセージ履歴
2. `docs/superpowers/specs/*.md` — 設計コントラクト（本ファイル）
3. `plans/tinyos/*.md` — 元の計画
4. `.planning/*.md` — バックログ、進行中タスク
5. `jj log` — smolBSDがjjリポジトリになった時点で（TODO：`jj git init`）。マルチエージェント分離は後に `git worktree` ではなく `jj workspace add` で実現。

これは `~/.claude/CLAUDE.md` にあるAXファーストの面です：構造化された入出力、
マニフェストで発見可能、アテステーション付き、スキーマ合成可能。

## 10. クローズ済みセクション — エージェント返信からの統合

| §  | 課題                | 担当     | 返信msgid（正準記録）                    | ステータス |
|----|---------------------|----------|------------------------------------------|--------|
| 11 | シークレット取り扱い | security | `<design-d1.security@smolbsd.local>`（spool L441–711） | v1.1で統合 |
| 12 | リトライポリシー     | reviewer | `<design-d2.reviewer@smolbsd.local>`（spool L712–1057） | v1.1で統合 |
| 13 | エスカレーションチャネル | ops  | `<design-d3.ops@smolbsd.local>`（spool L215–440） | v1.1で統合 |

返信の全文はスプールにあります。以下のセクションは要約です；矛盾がある場合は、
スプール内の返信が正準です。

## 11. シークレット取り扱い（D1より）

**メカニズム**：帯域外エンベロープファイルを `var/run/secrets/<task-id>/<key>` に
モード0600で配置し、`redact` フィンガープリントを含む `.meta.toml` サイドカーを
併置します。スプールには `[secrets.<key>]` ポインターテーブルのみを載せ、値は
決して載せません。`var/run/` は `.gitignore` 対象です。

**6つのルール：**

1. シークレット値は、平文であれエンコード済みであれ、スプールに決して現れない。ポインターのみ。
2. `var/run/` はリポジトリルートで `.gitignore` 対象。ディレクトリはモード0700、エンベロープは0600。
3. エンベロープのファイル名は*キー名*を持ち、値由来のフィンガープリントは決して持たない。
4. 返信は `redact` フィンガープリント（例：`fc1dxxxx4439`）で「$key を読んだ」ことを証明する — 同一性を証明し、値は決して漏らさない。
5. エンベロープは一時的 — verdictにかかわらず、コーディネーターは収集後に `var/run/secrets/<task-id>/` をunlinkする。
6. バッキングストアが真実のソース；エンベロープはタスク単位の実体化レイヤーであり、ストレージではない。ローテーションはバッキングストア側で行う。

**ポインターテーブル**（スプール内で唯一のシークレット関連コンテンツ）：

```toml
[secrets.gitea_token]
envelope    = "var/run/secrets/task-0042/gitea_token"
fingerprint = "fc1dxxxx4439"
source      = "keychain:gitea-pat"
expires_at  = "2026-04-30T18:00:00Z"
scope       = ["gitea.local:3000/api/v1/repos/*"]   # 参考情報
```

**バッキングストア（ライセンスクリーン）：**

- プロトタイプフェーズ：`/usr/bin/security`（macOS Keychain、macOSに同梱）— 本ホストでの存在を確認済み。
- ターゲットBSD VM：`gopass`（MIT、`pass` の代替）。`pass(1)` は不可 — GPL-2.0のため禁止。
- SSH鍵型の資格情報にはssh-agent（BSD-2 + ISC）。`SSH_AUTH_SOCK` の稼働を確認済み。
- 1Password CLI（`op`）はCLAUDE.mdに言及があるが、**本ホストには未インストール**（`which op` → not found）。設計は緩やかにフォールバックする；利用可能になれば `op:vault/item` はマテリアライザーへの1行追加で対応可能。

**フェーズ間の不変性**：プロトタイプとBSD VMターゲットの間で変わるのはマテリアライザー
（ワークト例のステップ1）のみです。ステップ2〜5（サブエージェントがエンベロープを読む →
フィンガープリントを検証 → インラインで使用 → アテステーションを発行 → コーディネーターが
消去）はバイト単位で同一です。

**失効**：3つのドリル — 計画的（制御メッセージ + ドレイン）、緊急（D3のHALTマーカーと
組み合わせ、`rm -P` でエンベロープを消去、`[control] HALT-ALL`）、エンベロープ漏洩
（タスク単位のワイプ + 新msgid）。監査証跡 = スプールのjj履歴。

**設計間フック：**

- D2のリトライポリシーは、資格情報フィンガープリントの不一致を**即時エスカレーション、自動リトライなし**として扱う（リトライテーブルの前に1つ追加の述語）。
- D3のHALTマーカーは、`X-Halt-Reason: credential-fingerprint-mismatch` を認識される停止理由として受け入れる。

**実装バックログ**（今後の割り当て）：

- ops：最初のディスパッチ前に `var/run/` と `var/mail/spool.lock` を含む `.gitignore` を作成。
- coordinator：`bin/secret-materialize.nu`（CLAUDE.mdに従いNushell）、`bin/secret-wipe.nu`、`bin/spool-emit-control.nu`。

## 12. リトライポリシー（D2より）

コーディネーターは**ステートマシンのインタープリターであり、プランナーではありません**。
すべての返信カテゴリーは正確に1つの遷移にマップされます。機械的であり、ケースごとの
判断はありません。

**ステートマシン：**

```
[DISPATCHED] -> [AWAITING_REPLY] -> [HARVEST] -> [VERIFY] -> [DONE]
                                       |             |
                                       +-> [RETRY_QUEUED] -+
                                       |                   |
                                       +-> [ESCALATE]      |
                                                           |
                            (after fib backoff) <----------+
```

7つの状態：`DISPATCHED`、`AWAITING_REPLY`、`HARVEST`、`VERIFY`、`RETRY_QUEUED`、
`DONE`、`ESCALATE`。（完全なDOT有向グラフは `<design-d2.reviewer@…>` 本文にあります。）

**決定テーブル**（返信カテゴリーごとに1行、スキーマ = category、predicate、next_state、max_retries）：

| カテゴリー                | 述語                                                              | 次状態        | 最大リトライ数 |
|---------------------------|-------------------------------------------------------------------|---------------|-------------|
| `pass+verified`           | `verdict='pass'` かつ すべての `[[claims]]` の再プローブが合格    | `DONE`        | 0           |
| `pass+probe-failed`       | `verdict='pass'` かつ いずれかの `[[claims]]` の再プローブが失敗/不確定 | `RETRY_QUEUED` | **1**（バジェット半分） |
| `fail`                    | `verdict='fail'`                                                  | `RETRY_QUEUED` | 3           |
| `blocked+unblocker-named` | `verdict='blocked'` + 実行可能な `blocked_by` フィールドあり      | `RETRY_QUEUED` | 3           |
| `blocked+no-unblocker`    | `verdict='blocked'` + `blocked_by` なし                           | `ESCALATE`    | 0（即時）    |
| `no-reply`                | タイムアウト（デフォルト30分）後もディスパッチのMessage-IDに一致するメッセージなし | `RETRY_QUEUED` | 3           |
| `malformed`               | mbox解析失敗 / TOML不正 / 必須フィールド欠落 / 必須時のclaimsなしpass | `RETRY_QUEUED` | 3 |

**バックオフ：フィボナッチ** `[60, 60, 120]`、上限300秒。

**指数ではなくフィボナッチである理由**：各リトライはエージェントバジェットの
60〜100kトークンを消費します。指数 `(60→120→240→480)` では、各ステップで
プロンプトキャッシュのTTL（5分、CLAUDE.mdのScheduleWakeupガイダンスに準拠）を
使い切ってしまいます。フィボナッチは伸びが緩やかで、60を2回置くことで一時的な
フレークがキャッシュウォームな時間窓内に解消できます。上限は5分TTLに合わせています。

**`max_attempts = 3` である理由**：三の法則。（1）ベースラインで故障モードを確立；
（2）過去の失敗要約をインラインして、一時的でないことを証明；（3）最後の試行、
「合格できないならfailを繰り返すのではなく、ブロッカーを明示したblockedを返せ」
という明示的指示付き。3回超 = 無理（不合理な負荷）→ エスカレーション。

**プローブ不一致のリトライが1回だけである理由**：エージェントのリトライを重ねても、
エージェントとプローブの間の不一致は解消できません。プローブが間違っている
（オペレーターが修正）か、エージェントがハルシネーションしている（オペレーターが調整）
かのいずれかです。どちらも人間の入力が必要 → 迅速にエスカレーションします。

**リトライペイロードコントラクト** — すべてのリトライはリクエストペイロードを
必ず変更しなければなりません（純粋な再送は禁止 — 純粋なムダ）：

- `prior_attempt_msgid` — 失敗した返信のMessage-ID（no-replyの場合はNIL）
- `prior_attempt_failure` — verdict + 失敗エビデンスの先頭500文字
- `prior_attempt_count` — 1または2
- `format_violation` — パーサーエラー（`category=malformed` の場合）
- `probe_disagreement` — fleet-evalプローブ出力（`category=pass+probe-failed` の場合）
- リトライごとに新しいMessage-ID：`<task-XXX.coord.r{N}@smolbsd.local>`
- `X-Attempt: <N>` ヘッダー（1始まり；コーディネーター状態はスプールのみから再構築可能）
- `no-reply` の場合のみ：`budget_tokens` はリトライごとに倍増、上限200000

**設計間述語（テーブル前チェック）：**

- `reply.secrets_consumed[*].fingerprint` がマテリアライザーの記録したフィンガープリントと不一致 → テーブルをバイパスし、`X-Halt-Reason: credential-fingerprint-mismatch` で強制エスカレーション。機械的であり、判断ではない（D1に準拠）。

**二重ディスパッチ禁止の不変条件**：コーディネーターは、同じ `task_id` を持つ
進行中メッセージを2つ持ってはなりません（MUST NOT）。新規ディスパッチのたびに、
スプールを未応答の `<task-XXX.coord*@>` についてスキャンすることで強制します。

**明示的に挙げておくべきエッジケース：**

- `attestation_required=true` なのに `[[claims]]` のない `pass` → MALFORMEDであり、pass+verifiedではない。
- `INCONCLUSIVE` プローブ（例：SSHタイムアウト）→ probe-failedであり、pass+verifiedではない。
- PASS/FAILが混在する複数の `[[claims]]` → カテゴリーは `pass+probe-failed`。
- タイムアウト発火後のリトライ中に届いた遅延返信 → ログに記録して無視；進行中のリトライが権威を持つ。
- 同じ `In-Reply-To` を持つ2つの返信 → 先着が勝つ；2つ目はプロトコル違反としてログに記録。
- リトライ中のコーディネータークラッシュ → 再起動時、タイムアウトより古い未応答のディスパッチをスプールからスキャン；`X-Attempt` ヘッダーの試行回数を用いてno-replyとして扱う。

## 13. エスカレーションチャネル（D3より）

**プライマリ**：`user@smolbsd.local` 宛のスプール内メッセージ + `var/mail/HALT`
マーカーファイル。スプール*こそが*基盤です — 再利用すれば新しいツールのコストは
ゼロで、正しくスレッド化され、新規クローン後も生き残り、ユーザーは標準のmboxツール
（`mailx`、`less`、`grep`）を既に持っています。

**フォールバック**：`openssl s_client` 経由で `<irc-host-ip>:6697`（TLS）の `ryan`
へのワンショットErgo IRC DM。プッシュ専用のシグナルであり、正準の返信経路では
ありません。CLAUDE.mdの「LANサーバーへのプローブループ禁止」とErgoの自動ブロック
保護を尊重します — TLS試行は正確に1回、TLSハンドシェイク失敗時に6667でのプレーン
試行を任意で1回、その後は結果をHALTマーカーに記録して先へ進みます。

**一時停止マーカー**：`var/mail/HALT` — コーディネーターのティックごとの `stat()`
1回が一時停止チェックの全体です。HALTの存在が確認された場合にのみ、再開返信を
探すためにスプールを再解析します。

**HALTメッセージの形：**

```
From: coordinator@smolbsd.local
To: user@smolbsd.local
Subject: [HALT] <task-id> — <one-line cause>
Message-ID: <halt-<task-id>.coord@smolbsd.local>
In-Reply-To: <task-id.coord@smolbsd.local>
References: <all retry msgids, space-separated>
X-Priority: 1
X-Halt-Reason: retry-exhausted | claim-verification-failed | malformed-reply
             | no-reply | blocked-no-unblocker | credential-fingerprint-mismatch
X-Resume-Tag: resume-<task-id>
```

本文（TOML）はカテゴリー、試行リスト（試行ごとのmsgid+verdict+エビデンス+
プローブ結果）、last_failure要約、proposed_actions = [retry, retry-as-<role>,
abort, edit]、およびasks（コーディネーターが人間/D3に求めること）を運びます。

**HALTマーカー（TOML本文）**：`halted_at`、`task_id`、`halt_msgid`、`resume_tag`、
`reason`、`fallback_fired`、`fallback_status`。

**ユーザー返信プロトコル**：再開mboxメッセージ（`Subject: Re: [HALT]`、
`Message-ID: <resume-<task-id>.user@…>`、`X-Resume-Action: retry | retry-as-<role> |
abort | edit`）を追記した後、`rm var/mail/HALT` を実行します。`rm var/mail/HALT`
のみの場合 = abort、再ディスパッチなし。検出レイテンシ = 次のコーディネーター
ティック（HALT存在時は60秒を推奨）。

**三重失敗パス**（スプール書き込み失敗 かつ IRC失敗 かつ HALTマーカー書き込み失敗）：

1. 無条件に `var/mail/HALT` の書き込みを試行 — ファイルシステム操作1回。
2. それすら失敗した場合、構造化パニックをstderrに出力：`{"event":"smolbsd-coord-panic","task_id":"…","spool_writable":false,"irc_reachable":false,"halt_writable":false,"ts":"…"}`。終了コード78（`EX_CONFIG`）。
3. コーディネータープロセスの終了自体が最終エスカレーションです。Claude Codeハーネスのセッションログが、次回のエンゲージメント時にユーザーへシグナルを運びます。非同期制約はハーネス境界によって満たされます。

三重失敗 = 基盤整合性イベントであり、タスクレベルではありません。復旧は人間が行い、
自動再開はありません。

**タスク単位の分離**：HALTマーカーは `task_id` でキー付けされ、グローバルでは
ありません。1つのタスクが停止していても、他のタスクはディスパッチを継続します。
（D2の確認：エスカレーションされたタスクは `status=escalated` に移行；無関係な
作業のディスパッチループは継続します。）

## 17. 能力/意図の強制（ラウンド1からの教訓）

**発見された故障モード**：ラウンド1のディスパッチウェーブで、architect
（`feature-dev:code-architect`）に、`acceptance` がファイルの書き込み
（`plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`）を要求するタスクが割り当てられ
ました。そのサブエージェントタイプは**読み取り専用**です — Read/Glob/Grep/WebFetch/
TodoWriteは持っていますが、Write/Edit/Bashを持っていません。エージェントは返信内で
計画のコンテンツを生成しましたが、それを実体化できず、コーディネーターがその
ステップを代行することになりました。エージェントのツール能力をタスクの実際の必要性
に対して事前検証するものが何もなかったため、プロトコルはこれを黙って許してしまいました。

**ルール**：すべてのリクエストエンベロープは（既存の `tools_allowed` に加えて）
`tools_required` フィールドを必ず含まなければなりません（MUST）。コーディネーターは、
ツールセットが `tools_required` をカバーしないサブエージェントタイプへのタスクの
ディスパッチを拒否しなければなりません（MUST）。

**スキーマ追加**（すべてのリクエストの `[reply_contract]` に挿入、§4.1参照）：

```toml
[reply_contract]
tools_required = ["Read", "Write", "Edit", "Bash"]   # サブエージェントの実際のツールセットの部分集合でなければならない（MUST）
tools_allowed  = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]   # 追加で許可されるもの
```

**コーディネーターのプリフライトチェック**（機械的）：

```
for tool in tools_required:
    assert tool in subagent_type.available_tools
        or refuse_dispatch("capability mismatch", task_id, subagent_type, missing=tool)
```

**能力レジストリ**（コーディネーターに組み込み、各サブエージェントタイプの
文書化されたツールから導出）：

| サブエージェントタイプ          | Writeあり？ | Bashあり？ | 適する用途 |
|--------------------------------|-----------|-----------|--------------|
| `general-purpose`              | あり      | あり      | ビルド、運用、一般作業 |
| `feature-dev:code-architect`   | **なし**  | なし      | 調査・設計・計画**のみ** |
| `feature-dev:code-explorer`    | なし      | なし      | コードベース探索 |
| `feature-dev:code-reviewer`    | なし      | なし      | レビュー専用タスク |
| `pr-review-toolkit:code-reviewer` | あり (\*) | あり    | アクション付きレビュー |
| `Explore`                      | なし      | あり      | 検索中心の探索 |

(\*) 文書化されたツールリストに準拠

**失敗時の取り扱い**：能力不一致による拒否はコーディネーターレベルの拒否であり、
リトライではありません。コーディネーターは（a）能力のあるサブエージェントタイプへ
再ルーティングするか、（b）タスクを調査専用ステップ（ROサブエージェント）+
実体化ステップ（RWサブエージェント）に分割します。ラウンド1のarchitect+coordinator
パターンが正準の（b）形式です：architectがコンテンツを生成し、coordinatorが実体化
します。

**これが独立した§である理由**：この故障モードは一般化します — *意図*（タスク
ブリーフ）と*能力*（実行者）を分離するすべてのプロトコルにこのチェックが必要です。
mbox+TOML引き継ぎは、このギャップを可視化したにすぎません。

## 18. 運用ノート — <aarch64-builder> VM、ネットワークコンテキスト、スキルのドリフト（v1.2）

このセクションは、ラウンド2の到達性テスト中に発見された3つの運用上の現実を
記録します。いずれもプロトコルコントラクトを変更するものではありません；いずれも、
コールドで投入されたエージェントが基盤を実際に使うために知っておくべきことを
変更します。

### 18.1 <aarch64-builder> VMの識別子（「fb-vm-24」ドリフト）

`<hypervisor-host>` 上のFreeBSD aarch64ビルドVMは、現実には正準的に
**`<aarch64-builder>`** という名前です：これはscreenセッション名、qemuの `-name`
引数、ディスクイメージのベース名です（`/Users/studio/vms/freebsd-15-build.qcow2`、
`screen -dmS <aarch64-builder> ...` として起動）。`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md`
にある **freebsd-build-vmスキル**は、全体を通してこれを **`fb-vm-24`** と呼んで
います — 「24」はホストサフィックス（`<hypervisor-host>`）であり、スキルの散文の中で
VM名に昇格してしまったものです。**この点についてスキルは古く、別途の更新PRが
必要です**（本リポジトリの範囲外；スキルは `~/.claude/` 配下にグローバルに存在）。

**運用ルール**：freebsd-build-vmスキルを読む際は、VMレベルの識別子（screen
セッション、qemuの `-name`、イメージファイル名）について、頭の中で `fb-vm-24` を
`<aarch64-builder>` に置き換えてください。本リポジトリでスキル名 `fb-vm-24` が
シンボルとして参照される場合は、「スキル正準名（ドリフト；実際のVMは
`<aarch64-builder>`）」と注記されます。

### 18.2 SSH hostfwdポート（2225 → 2222）

freebsd-build-vmスキルは `hostfwd=tcp::2225-:22` と記載しています。<hypervisor-host>
上のグラウンドトゥルース（2026-04-30T21:33:39Zにqemu pid 29210に対する `lsof` で
確認）：`hostfwd=tcp::2222-:22`。**<aarch64-builder>へのsshにはポート2222を使用して
ください**。

```
ssh -J <hypervisor-host> -p 2222 builder@localhost      # 正しい（現在の現実）
ssh -J studio@<lan-gw-ip> -p 2225 builder@localhost  # 古いスキルの散文；使用禁止
```

### 18.3 virtfs共有パス（二重プレフィックスのラッパーバグ）

<aarch64-builder>のqemuコマンドラインは
`-virtfs local,path=/Users/studio/Users/studio/share/<aarch64-builder>,...` を
含みます。二重の `/Users/studio/Users/studio/` は**起動ラッパーのバグ**です：
`run-fb-vm-24.sh`（fleet-opsテンプレート）内で、既に絶対パスであるものにリテラルの
`~` がプレフィックスとして付けられ、文字列連結の前にシェルが `~` を
`/Users/studio` に展開したことで二重プレフィックスが生じました。

**ステータス**：fleet-ops（`vm-templates/run-freebsd-vm.sh.template`）で別途修正
すべきラッパーバグとして文書化。それまでは、ソース投入 / アーティファクト取り出し
はホスト側で二重パスを使わなければなりません：

```
# host (<hypervisor-host>) side — drop sources here:
~/Users/studio/share/<aarch64-builder>/source/        # 誤り（スキルの散文）
/Users/studio/Users/studio/share/<aarch64-builder>/source/  # 現在の現実
```

VM内部では、マウントタグ（`host0`）とマウントポイント（`/mnt/host`）は変更なし —
バグはホストパスのみです。

### 18.4 screenソケット喪失の落とし穴（qemuは生存、screen -rは失敗）

**検出方法**：<hypervisor-host>上で、`pgrep -f qemu-system-aarch64` はpid 29210を
返す（qemu稼働中）が、`screen -ls` は
`No Sockets found in /var/folders/.../screen` を返します。<aarch64-builder> VMは
ssh:2222で到達可能ですが、正準の復旧経路（`screen -r <aarch64-builder>` →
コンソール）は**機能しません** — qemuを起動したscreenセッションがソケット
ファイルを失っています。qemuプロセスはファイルディスクリプタを継承して生き残り
ましたが、screenラッパーは生き残りませんでした。

**復旧手順**（freebsd-build-vmスキル§「Launching the VM (canonical)」に準拠）：

```
# 1. Confirm both halves of the diagnostic on <hypervisor-host>:
ssh <hypervisor-host> 'pgrep -f qemu-system-aarch64; screen -ls'
#  -> qemu pid present
#  -> "No Sockets found"  --> socket lost

# 2. Kill the orphan qemu (it has no console anyway):
ssh <hypervisor-host> 'pkill -f "qemu-system-aarch64.*-name <aarch64-builder>"'

# 3. Relaunch via the canonical wrapper (re-establishes screen + socket):
ansible <hypervisor-host> -m raw -a "~/vms/run-fb-vm-24.sh"
ansible <hypervisor-host> -m raw -a "screen -ls; pgrep -f qemu-system-aarch64"
```

**これを実行してはいけない場合**：VM内で長時間ビルドが進行中の間（ssh経由で起動
した `screen -dmS smolkernel` などのVM内screenセッション）。qemuを殺すとビルドも
死にます。復旧の前に進行中ビルドがないことを確認してください — <hypervisor-host>から
`ssh -p 2222 builder@... screen -ls` を実行すればVM内のscreenセッションが一覧
されます。

### 18.5 `.local` フリートホスト名はLAN限定（ネットワークコンテキストの注意事項）

フリートの `.local` ホスト名（`qnas.local`、`ergo.local`、`searxng.local`、
`gitea.local` など、ansible管理の `/etc/hosts` エントリで `10.0.3.x` のIP —
CLAUDE.mdの「Search」セクション参照）は、**エージェントがLANに接続されている
場合にのみ解決されます**（ホストがQNAS LAN <lan-subnet> 上にある場合）。LANに
接続されていないコーディネーター（例：Tailscaleで<hypervisor-host>に到達する別の
ネットワーク上のMac）からは、解決/ルーティングに失敗します。

TailscaleはTailscale接続ノードの名前を解決します（`<hypervisor-host>` 自体はtailnet
メンバー）が、ネストしたQEMUゲスト内の非tailnetホストへのプロキシは**行いません**
（`<aarch64-builder>` はSLIRP NAT経由でのみLANに到達；LANは<aarch64-builder>を
tailnetピアとして認識しません）。

**D3エスカレーションフォールバックへの含意**（§13）：フォールバックのIRC DM
`openssl s_client <irc-host-ip>:6697` は、**LANに接続されていないコーディネーター
からは機能しません** — Tailscale経由で<hypervisor-host>しか見えないMacから
`<irc-host-ip>` へのルートは存在しません。HALTマーカー + スプールメッセージの
プライマリ経路（§13）は依然として機能する（ファイルシステムローカルであるため）
ので、設計は壊れていません。フォールバックはベストエフォートであり、LAN外で
発火した場合は「HALTマーカーに記録、fallback_status = 'no-route'」に縮退します。

**設計変更なし**：D3の三重失敗パス（§13）は既にこのケースをカバーしています —
フォールバック失敗はログに記録され、致命的ではありません。この注意事項は、
「なぜIRCフォールバックが黙って何もしなかったのか」をデバッグする前に、コールドで
投入されたエージェントが認識しておくべき明示的なネットワークコンテキストの前提に
すぎません。

### 18.6 Gitea ホストは <gitea-host>:3001 であり gitea.local:3000 ではない

`gitea.local`（CLAUDE.mdのフリートDNSによる）は `<nas-ip>`（QNAS）に解決されますが、
Giteaは実際には `<gitea-host>` の `<internal-ip>:3001` で稼働しています。そのホストの
ポート3000はTensorZeroです。CLAUDE.mdのフリートホスト名テーブルは、このエントリに
ついて古くなっています。

**Tailscaleからのトンネル（カンファレンス / リモート）：**
```sh
ssh -fN -L 3001:<internal-ip>:3001 home@<tailscale-ip>   # <internal-host> jump
# then: jj git remote add gitea http://localhost:3001/studio/smolBSD.git
```

**LANから直接：** `http://<internal-ip>:3001/`

## 14. 注意事項と既知の制限

1. **このClaude Codeインスタンスには `sequential-thinking` MCPサーバーがロードされていません**。段階的推論はそのMCP経由ではなくプロンプト内で行われます。ユーザーが後でインストールしてもプロトコルは変わりません — コーディネーター内部の問題です。
2. **smolBSDはv1.1時点でjjリポジトリになりました**（`jj git init` 実行済み；コミット `24b600c3` がラウンド1を記録）。マルチエージェント分離は後に `jj workspace add ../smolBSD-<role>` で実現。
3. **メモリは存在するが疎です**。`~/.claude/projects/-Users-studio-smolBSD/memory/MEMORY.md` は3つのエントリ（Knox/TrustZoneの背景、BRAP L1決定、jj-not-gitのVCS選好）をインデックスしています。仕様、計画、スプールが引き続き主要な永続状態です。
4. **スプールの単一ライター前提**は、コーディネーターが唯一の生産者である間のみ成立します。マルチコーディネーターのシナリオにはロックが必要 — v1の範囲外です。
5. **サブエージェントのコンテキスト漏れ**：このOpusセッションが `Agent` ツールを使うとき、サブエージェントは暗黙のハーネスコンテキスト（スキルインデックス、CLAUDE.md）を一部継承します。真の「共有コンテキストなし」には、別個の `claude` 呼び出しか別のハーネスへの移行が必要です — §15参照。
6. **RTKはエージェント側で任意であり、本ホストには未インストールです**（`which rtk` → not found）。アウトバウンド圧縮（サイドA）はコーディネーターのプリインライン処理で守られます；インバウンド（サイドB）は `brew install rtk && rtk init -g` の実行後に有効になります。RTKのないエージェントは緩やかにフォールバックしますが、より大きな出力を生成します。
7. **信頼境界**：コーディネーターは `[[claims]]` を独立に検証しなければなりません。アライメントの崩れたサブエージェントはclaimsを捏造しうる；`fleet-eval` が評価リフレックスのゲートです。**ラウンド1のclaimsはまだ再プローブされていません** — 未対応のフォローアップです。
8. **RTKはApache-2.0** — ライセンスはユーザーの許可リストにあります。上流で変更された場合は再評価します。
9. **能力/意図のギャップ**はv1に存在し、v1.1の§17でクローズされました。スプール内の既存リクエストには `tools_required` フィールドがありません — ラウンド1に限り経過措置として容認されます。
10. **引用のハルシネーションリスク**：ラウンド1のarchitectは、独立に検証されていない「vermaden 2026-02のブログ記事」を引用しました。エージェントが持ち込んだ引用は、クロスチェックされるまで低信頼として扱ってください。実質的な技術内容（oci-image-runtime.conf、MINIMALコンフィグ、Makefile.vm）は [cgit.freebsd.org](https://cgit.freebsd.org/src/tree/sys/amd64/conf/) に対して検証可能です。
11. **`.gitignore` は未作成** — D1シークレット設計は、最初の資格情報ディスパッチの前に `var/run/` がjj/gitでignoreされることを要求します。opsのフォローアップです。
12. **`pass(1)` はGPL-2.0** — ユーザーのライセンスルールにより禁止。シークレット設計は代わりに `gopass`（MIT）を使用します。将来の依存関係にうっかり `pass` を入れないでください。
13. **freebsd-build-vmスキルはVM名とSSHポートについて古くなっています**（v1.2）。`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` のグローバルスキルはVMを `fb-vm-24`（実際：`<aarch64-builder>`）と呼び、hostfwdポート `2225`（実際：`2222`）を記載しています。スキル更新は本リポジトリ外の別PRです；現時点では§18が権威ある整合です。スキルを読む際は頭の中で置き換えてください。
14. **`.local` ホスト名はLAN限定です**（v1.2 — §18.5参照）。Tailscale経由でのみ<hypervisor-host>に到達するコーディネーターからは、D3のIRCフォールバック（`<irc-host-ip>:6697` 宛）は機能しません — 設計は緩やかに縮退します（HALTマーカー + スプール経路はファイルシステムローカル）が、LAN外ではエージェントは `fallback_status = 'no-route'` を予期すべきです。
15. **screenソケット喪失は既知の<aarch64-builder>ハザードです**（v1.2 — §18.4参照）。qemuは起動元のscreenセッションより長生きしえます；その場合、VMがssh:2222で到達可能でも `screen -r <aarch64-builder>` は失敗します。復旧は `pkill qemu` + `~/vms/run-fb-vm-24.sh` による再起動です。まずVM内ビルドが進行中でないことを確認してください。

## 15. 今後の作業

- §§11〜13が埋まった今、スプールを実際の（Tiny|Rump）BSDインスタンスへ移行 — プロトコルは構造上ポータブル。
- コーディネーターループごとにスプール + 仕様をコミット（`jj describe -m "..." && jj new`）。エージェント単位の分離は `jj workspace add ../smolBSD-<role>` で。
- コーディネーターバイナリの実装：
  - `bin/coord-tick.nu` — §12を逐語的に読むテーブル駆動ステートマシンインタープリター
  - `bin/coord-escalate.nu` — D3プロトコルのエントリーポイント
  - `bin/secret-materialize.nu` / `bin/secret-wipe.nu` — D1エンベロープのライフサイクル
  - `bin/spool-emit-control.nu` — 制御メッセージ（rotate-key、halt、resume）
  - `bin/spool-tail.nu` — TOMLプリティプリント付きの `mailx -f spool` 風ビューアー
  - `bin/spool-archive.nu` — Nメッセージ超過のスプールを `var/mail/spool.YYYY-MM-DD` へローテート
- クロスハーネス引き継ぎ：coordinator-Claude → builder-Codex でプロトコルが機能することを実証。
- AXファーストに準拠した `Manifest:` 発見エンドポイント。
- TrustZone統合（将来の展望；ユーザーのKnox背景 + BRAP L1決定を踏まえて）：返信は `[[claims]]` に加えて `[[attestations]]` ブロックを運べる。そこでのアテステーションは、ビルドVMが生成するTA署名付きクォート。仕様v2の候補。

## 16. セルフレビューチェックリスト（v1.2）

- [x] どのセクションにも「TBD」なし — §§11/12/13は完全に統合；§17は完全に仕様化；§18（運用ノート）はv1.2で追加
- [x] セクション間の内部整合性 — §4.1スキーマは§17に従い新しい `tools_required` フィールドを含む；§8役割テーブルに必要ツール列あり；§11/§12の相互参照（D1+D2のフィンガープリント不一致オーバーライド）；§12/§13の相互参照（ESCALATE → HALTプロトコル）；§13/§18.5の相互参照（LAN外ではIRCフォールバックは機能しない、設計どおり — ファイルシステムローカルのプライマリにフォールバック）
- [x] スコープ：1つのクローズドコントラクトを持つ単一基盤（mbox+TOML+spool）に集中 — 実装可能な状態
- [x] 曖昧さの解消：
  - mboxパスを明示（`var/mail/spool`）
  - RTKのサイドAとサイドBを区別
  - 信頼境界を明示（fleet-evalプローブ；コーディネーターは自己申告のみを決して信頼しない）
  - 能力/意図の分離（§17）— 読み取り専用と読み書き可能のサブエージェントタイプ
  - pass+probe-failedはリトライバジェット半分（§12）
  - blockedは2つのサブカテゴリー（アンブロッカーの有無）を持ち、遷移が異なる
  - <aarch64-builder> VMの識別子と到達性プリミティブ（§18）— VM名は `<aarch64-builder>`（`fb-vm-24` ではない）、SSHポートは2222（2225ではない）、virtfsパスは `/Users/studio/Users/studio/share/<aarch64-builder>`（二重プレフィックスのラッパーバグ、別途修正として文書化）
- [x] ライセンスフロアを検証済み：openssl Apache-2.0、Ergo MIT、Nushell MIT、mbox = 素のRFC822（ライブラリなし）、gopass MIT、ssh-agent BSD-2+ISC、RTK Apache-2.0。GPL/LGPL/AGPLなし。
- [x] 設計間の合成を明示：D1↔D2（フィンガープリント不一致パス）、D2↔D3（エスカレーション引き継ぎ）、D1↔D3（HALTマーカーはD1からのX-Halt-Reasonを受け入れる）、§18.5↔§13（LAN外のIRCフォールバックはログ記録付きno-routeに縮退、プライマリ経路は影響なし）
- [x] 前方参照を明示：§17の能力チェックは機械的であり、判断ではない；§18の整合は上流スキルが更新されるまで機械的な参照（判断なし）
- [x] ドリフトの表面化と整合（v1.2）：freebsd-build-vmスキルはVM名 + SSHポートについて古い；§18 + 注意事項§14.13がツリー内の権威ある整合；スキルは別途の更新PRが必要
