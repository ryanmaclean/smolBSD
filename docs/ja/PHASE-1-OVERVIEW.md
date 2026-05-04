# smolBSD — フェーズ I：概要

> **自動翻訳** — 以下のソースドキュメントを要約・合成したものです：
> - `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md`
> - `plans/tinyos/PHASE-1-ARCH-DECISION.md`

---

## 1. ミッション

smolBSD は、FreeBSD 15 の最小安定 VM を構築することを目指します。この VM は
無人でログインプロンプトまで起動し、`sh`、`vi`/`ed`、`rc.d`、`pkg` を実行
でき、UFS を使用し、ディスク上で 512 MiB 以内に収まります。目標値として、
qcow2 アーティファクトを 128 MiB 未満とすることを目指します。

フェーズ I では同一の FreeBSD 公式ツール `release/Makefile.vm` を用いて、
aarch64（優先ブランチ）と amd64（後続ブランチ）の 2 つのアーキテクチャ
バリアントを生成します。

---

## 2. アーキテクチャ決定：aarch64 優先、両ブランチ

決定の根拠は `PHASE-1-ARCH-DECISION.md`（選択肢 C）に記載されています。

**主な理由 — HVF の非対称性。** ビルドホスト `minim4-24`（Apple Silicon）では、
ハードウェアアクセラレータ HVF はネイティブ ISA（aarch64）のみを高速化します。
aarch64 ゲストは HVF 下で 10〜30 秒で起動し、≤ 30 秒という合格基準を容易に
クリアします。amd64 ゲストは同じホスト上で TCG（ソフトウェアエミュレーション）
に落ちるため、60〜180 秒かかり、同じ基準に失敗します。自らのビルドホストで
合格基準を通過できないイメージを構築することは許容できません。

**補足理由。** 既存のフリート全体が aarch64 です（fbrpi ノード、Pi 5、RK3588、
fbuild VM）。各種ツールチェーン（`freebsd-build-vm`、`zig-cc`、`freebsd-pi`）も
すべて aarch64 向けです。amd64 イメージをこのフリートに単独で置くと、デバッグ
コストを共有する他の消費者がいない「孤立アーキテクチャ」になります。

**amd64 ブランチは廃棄しません。** fbuild 内で `TARGET=amd64 TARGET_ARCH=amd64`
を用いたクロスコンパイルで構築し、KVM 対応の x86 ホスト（Vultr インスタンスまたは
フリートの Linux x86 機）でテストします。既存の計画をそのまま再利用します。

---

## 3. パッケージ選択とサイズバジェット

両バリアントはまったく同一のパッケージセットを共有します（pkgbase のパッケージ名は
ISA に依存しません）。

**最小ベース**（`release/tools/oci-image-runtime.conf` より）：
`FreeBSD-runtime`、`FreeBSD-rc`、`FreeBSD-fetch`、`FreeBSD-certctl`、
`FreeBSD-kerberos-lib`、`FreeBSD-libarchive`、`FreeBSD-libexecinfo`、
`FreeBSD-libucl`、`FreeBSD-pkg-bootstrap`、`FreeBSD-mtree`。

**smolBSD 固有の追加**：`FreeBSD-kernel-generic`（カスタムコンパイルした SMOLBSD
カーネルで置き換え）、`FreeBSD-utilities`、`FreeBSD-clibs`、
`FreeBSD-openssl-lib`、`FreeBSD-ee`。

**明示的な除外**（`vm_extra_filter_base_packages()` 経由）：
すべての `-dbg`、`-lib32`、`FreeBSD-tests*`、`FreeBSD-lldb*`、
`FreeBSD-devel*`、`FreeBSD-src*` パッケージ。

**レイヤー別サイズバジェット：**

| レイヤー | バジェット |
|----------|-----------|
| カーネルバイナリ（`/boot/kernel/kernel`、-dbg なし） | 19〜20 MiB |
| カーネルモジュール（`/boot/kernel/*.ko`、最小セット） | 7〜8 MiB |
| ベースユーザーランド（`FreeBSD-runtime` + `FreeBSD-clibs`） | 35 MiB |
| ユーティリティ（`FreeBSD-utilities`） | 48 MiB |
| rc.d フレームワーク（`FreeBSD-rc`） | 3 MiB |
| pkg ランタイム（libarchive + openssl-lib + libucl + fetch + pkg-bootstrap） | 18 MiB |
| 補助パッケージ（certctl、kerberos-lib、libexecinfo、mtree、ee） | 6 MiB |
| `/boot` ローダー + EFI ファイル | 5 MiB |
| `/etc` デフォルト + `/var` スケルトン + `/tmp` | 2 MiB |
| **ディスク上の合計** | **約 143〜145 MiB** |
| **qcow2 アーティファクト**（スパース割り当て後） | **約 128 MiB** |
| **絶対上限** | **512 MiB** |

---

## 4. 合格基準 — 5 つの計測遺物

各バリアントはフェーズ I 完了前に以下の 5 つの計測をすべてパスする必要があります：

1. **ビルド成功率** — qcow2 ファイルが存在し、`qemu-img info` が想定フィールドを返すこと。
2. **準備完了までの時間** — VM が `login:` プロンプトを ≤ 30 秒で表示すること
   （aarch64 は HVF、amd64 は KVM 対応の x86 ホスト使用）。
3. **ピーク時メモリ** — ホスト RSS < 300 MiB、256 MiB VM 内の空きメモリ ≥ 150 MiB。
4. **アイドル時メモリ** — 同じ閾値を t+60 秒時点で計測。
5. **アーティファクトサイズ** — `actual-size` < 134,217,728 バイト（128 MiB 目標値）、
   かつ < 536,870,912 バイト（512 MiB ハード上限）。
6. **クラッシュ回復時間** — `kill -9` 後に VM を再起動し、≤ 60 秒以内に SSH が
   利用可能になること（UFS soft-updates の fsck パス）。

---

## 5. 現在のステータス

- **フェーズ I aarch64**：設計完了（`PHASE-1-AARCH64-TINY-BASELINE.md` のステータス
  `design-complete`）。fbuild 内でクロスコンパイルなしのネイティブビルド。`minim4-24`
  上で HVF を用いてテスト。このブランチが優先されます。
- **フェーズ I amd64**：設計完了（`PHASE-1-FORGE-TINY-BASELINE.md` のステータス
  `design-complete`）。fbuild から `TARGET=amd64 TARGET_ARCH=amd64` でクロスコンパイル。
  KVM 対応 x86 テストホストを待機中。

両ドキュメントとも、まだいかなるビルドコマンドも実行されていません。
現在は設計段階のみです。

---

*このサマリーは 2026-05-04 に smolBSD フェーズ I 計画ドキュメントから作成されました。*
