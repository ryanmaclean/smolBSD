# Mailbox + JEC 引き継ぎプロトコル — 設計仕様 v1.2

- **日付**：2026-04-30
- **プロジェクト**：smolBSD
- **ステータス**：v1.2 — fb-vm-24/fbuild の整合、ポート2222、screenソケット問題、.local ネットワークコンテキストの注意事項
- **ライセンス**：BSD-2-Clause（プロジェクトデフォルト）
- **履歴**：v1（2026-04-30 13:30 — オープンセクション延期）；v1.1（2026-04-30 14:30 — エージェント返信収集・統合）；v1.2（2026-04-30 15:00 — fb-vm-24/fbuild整合、ポート2222、screenソケット問題、.localネットワークコンテキストの注意事項）

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
tools_required       = ["Read", "Write", "Edit", "Bash"]
tools_allowed        = ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
budget_tokens        = 80000
```
