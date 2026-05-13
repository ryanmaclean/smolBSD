# フェーズ I — aarch64 最小ベースライン：FreeBSD 15 arm64 最小仮想マシン

- **フェーズ**：全4フェーズ中のフェーズI — 最小ベースラインの構築（aarch64ブランチ；REPLAN により主要ブランチ）
- **キャンペーン**：smolBSD — 小さな王国 vs ランプの要塞
- **ターゲット**：FreeBSD 15.0-RELEASE arm64、VM優先、ヘッドレス
- **作成者**：planner@smolbsd.local（task-0005）
- **日付**：2026-04-30
- **ステータス**：設計完了 — このファイルが承認されるまでビルドしないこと
- **REPLAN の決定**：`plans/tinyos/PHASE-1-ARCH-DECISION.md` — オプション C、aarch64 優先

---

## 1. ミッションステートメント

**≤ 30秒**（`minim4-24` 上の HVF 加速）でログインプロンプトまで無人起動し、sh、
vi/ed、rc.d、pkg を実行し、UFS を使用し、ディスク上で 512 MiB 以内に収まる
（目標値：qcow2 アーティファクト 128 MiB 未満）、最小かつ安定した
FreeBSD 15 arm64 QEMU VMを構築する。

**これはフェーズIの主要ブランチです。** Apple Silicon（`minim4-24`）上の
HVFアクセラレーターはネイティブISAのみ対応です：HVF下のaarch64ゲストは
ベアメタルに近い速度で動作しますが、amd64ゲストはTCG（ソフトウェアエミュレーション、
5〜10倍遅い）にフォールバックします。≤ 30秒のログイン到達という受け入れゲートは、
aarch64イメージを使用した場合のみビルドホスト上でクリアできます。amd64ブランチの
計時ゲートにはKVM対応のx86ホストが必要です。

このファイルはビルドコントラクトを定義します。ここではビルドコマンドを実行しません。

---

## 2. ビルドホストとビルドモード

### 2.1 ビルドホスト：`fbuild`（`minim4-24` 上のFreeBSD 15 aarch64）

fbuild VMはFreeBSD 15.0-RELEASE **aarch64** — ターゲットと同じISAです。
これは**クロスコンパイルが不要**であることを意味します：ビルドシステムは
エンドツーエンドでネイティブツールチェーンを使用します。

**fbuildの運用上の注意**（詳細は設計仕様の§18を参照）：

- スキルの正規名 `fb-vm-24` は古いです — 実際のVM名は `fbuild` です。
- SSHポート：`ssh -J minim4-24 -p 2222 builder@localhost`（スキルの古い2225ではない）。
- ホスト側のvirtfs共有：`/Users/studio/Users/studio/share/fbuild/`（プレフィックス重複バグ、別途文書化済み）。
- screenソケット消失の危険：`pgrep qemu` と `screen -ls` が乖離することがある。復旧方法は仕様の§18.4を参照。

### 2.2 ビルドモード：ネイティブ arm64 — クロスコンパイルなし

arm64ホストでarm64向けにビルドする場合、`TARGET` と `TARGET_ARCH` は省略するか
明示的に指定できます（どちらも同等です）：

```sh
# ネイティブビルド（推奨 — シンプルで障害モードが少ない）：
make -j4 -C /usr/src buildworld buildkernel KERNCONF=SMOLBSD

# または明示的なアーキテクチャ指定（arm64ホスト上では同一の結果）：
make -j4 -C /usr/src buildworld buildkernel \
    KERNCONF=SMOLBSD \
    TARGET=arm64 \
    TARGET_ARCH=aarch64
```

これに対し、amd64ブランチはarm64のfbuildホストから `TARGET=amd64 TARGET_ARCH=amd64`
を使ってクロスコンパイルする必要があります。ネイティブパスによりクロスツールチェーンの
ステップが不要になり、ビルド時間と障害モードが削減されます。
