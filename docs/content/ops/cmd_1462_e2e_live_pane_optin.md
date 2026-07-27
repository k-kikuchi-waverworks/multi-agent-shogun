# E2E テストのうち、稼働中の agent を止めるものについて

対象: `tests/e2e/e2e_bloom_routing.bats` の TC-BLOOM-004 と TC-BLOOM-005
起票: cmd_1462（2026-07-28・足軽四号が調査、家老が裁可）

## いちばん大事なこと

**`bats tests/e2e/` を何気なく実行すると、稼働中の agent の作業が止まります。**

`e2e_bloom_routing.bats` の 2 本は、実際の tmux pane へキー入力を送ります。

- `ashigaru4` / `ashigaru5` の pane へ `echo 'Working...'; sleep 30` を打ち込む
- テストの終わりに、その pane へ Ctrl-C を送る

手元の一時ディレクトリではありません。**今 動いている agent の pane** です。

2026-07-28 に cmd_1462 で対策を入れました。今はこの 2 本は
**明示的に opt-in した時だけ**走ります。

## 走らせ方

```bash
E2E_BLOOM_ALLOW_LIVE_PANES=1 bats tests/e2e/e2e_bloom_routing.bats
```

**走らせてよいのは、全 agent がアイドルで、止めてよいと分かっている時だけです。**

値は `1` のときだけ通ります。`0` / 空 / `yes` / 未設定はすべて止まります（実測で確認）。

## opt-in しないとどうなるか

SKIP ではなく**不合格**になります。画面には次のように出ます。

```
このテストは走っていません。合格ではありません。

  理由: 稼働中の agent の pane へ実際にキー入力を送るため、既定では走らせない。
  何が起きるか: ashigaru4/5 の pane へ "sleep 30" を打ち込み、終了時に Ctrl-C を送る。
                その間、その agent の作業は止まる。

  走らせるには: E2E_BLOOM_ALLOW_LIVE_PANES=1 bats tests/e2e/e2e_bloom_routing.bats
  走らせてよいのは、全 agent がアイドルで、止めてよいと分かっている時だけ。

  今 守られていないもの: ビジー時の Bloom ルーティング
    ・ashigaru4 がビジーの時、L5 タスクが ashigaru5 へ回るか (TC-BLOOM-004)
    ・Sonnet 足軽が全員ビジーの時、Codex へ降格せず QUEUE になるか (TC-BLOOM-005)
```

### なぜ SKIP にしないのか

この repo では **SKIP は FAIL と同じ扱い**です（CLAUDE.md「Test Rules」）。

SKIP は TAP では `ok` として出力されます。つまり数だけ数えると合格に見えます。
「走っていないのに合格」は、2026-07-28 に全軍で追いかけていた問題そのものです。

不合格にしたうえで、**何が守られていないか**を文面に書きました。
読んだ人が「では今 何が確かめられていないのか」を判断できる形にするためです。

## opt-in が要らないテスト

同じファイルの TC-BLOOM-001 / 002 / 003 / 006 は opt-in を要りません。

`get_recommended_model` と `find_agent_for_model` を呼ぶだけで、pane へ書き込みません。
`lib/` の中に `send-keys` が 1 件も無いことを確認済みです。

## 対策を入れる前に測ったこと

| 測ったこと | 結果 |
|---|---|
| pane が在る環境で 004/005 は skip されるか | **されない。そのまま実行される** |
| 対策後、opt-in なしで pane へ何か送られるか | **送られない**（`ashigaru5` の `history_size` が 107 のまま） |
| 門は `1` 以外で通るか | 通らない（未設定 / `0` / 空 / `yes` すべて rc=1） |

## まだ直っていないこと

**TC-BLOOM-001 / 002 / 003 / 006 は、現在 4 本とも不合格です。**
cmd_1462 の変更より前（HEAD の版）でも同じく 4 本とも不合格でした。
**この対策が壊したものではありません。**

原因は、テストが前提にしている布陣が今は存在しないことです。

- テストの前提（ファイル頭書）: `ashigaru1-3=codex/spark, ashigaru4-5=claude/sonnet, ashigaru6-7=claude/opus`
- 今の `config/settings.yaml`: **足軽は全員 `claude-opus-5`**

併せて、`get_recommended_model` は L1 / L3 / L5 / L6 のいずれでも
**空を返しながら rc=0** になります。呼んだ側から見ると「成功したが何も言わない」形です。

この 2 点は cmd_1462 の範囲外なので直していません。別途 裁可を仰いでいます。

## 同じ形が他に無いか（全数を数えました）

母数 = `tests/` 配下の `.bats` / `.sh` / `.bash` **88 本**（第三者の `test_helper/` を除く）。
`find` で数えています（この pane の `grep` は関数で、追跡外のファイルを落とすため）。

`send-keys` を含む行は多数ありますが、**そのほとんどは mock のログに対する `grep`** です
（「送られたか」を確かめる側であって、送る側ではありません）。
実際に `tmux send-keys` を**実行する**箇所だけを選り分けると、次のとおりです。

| 場所 | 宛先 | 危険か |
|---|---|---|
| `e2e/e2e_bloom_routing.bats:157,205,206,207` | `@agent_id` から引いた**稼働中の pane** | **危険。今回 opt-in を付けた** |
| `unit/test_pane_cli_liveness.bats:88,97,104,119,203` | `pcl_$$_${BATS_TEST_NUMBER}` = テストが自分で作る session | 安全（teardown で kill する） |
| `e2e/helpers/setup.bash:85` | `${E2E_SESSION_PREFIX}_$$` = E2E 専用 session | 安全 |
| `e2e/helpers/tmux_helpers.bash:9,11` | 呼び手が渡す（上の E2E 専用 session） | 安全 |
| `unit/test_send_wakeup.bats:690,713` | `tmux` 自体が mock 済み（:121 で関数定義） | 安全 |

**つまり、稼働中の agent へ書き込むのは `e2e_bloom_routing.bats` の 2 本だけです。**
`lib/` の中に `send-keys` は 0 件です。

**新しく E2E を書く人へ**: 実 pane を触る必要が出たら、同じ形の opt-in を付けてください。
自分で session を作って自分で消す形（`test_pane_cli_liveness.bats` が手本）にできるなら、
そちらの方が安全です。
