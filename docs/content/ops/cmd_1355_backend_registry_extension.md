# cmd_1355: backend 台帳延長 — 「守り手を守る台帳」

> ★検査そのものが台帳の外に在れば、その検査は黙って殺せる★ — 軍師一号の名指し
> (2026-07-26 束ねQC ③) への機械的な答え。

## なぜ在るか (実例を引く — これが分からねば次の者が消す)

2026-07-26 未明の「沈黙」8+1件のうち、**③ harness module 順が実機と逆** (cmd_1350・恋の
測定を誤らせ家老の裁定まで誤らせた) と **⑨ 世代 filter 地雷** (arm B の嘘の勝利) を
護っておるのは backend 側の検査 2 本である:

- **順序検査** (`backend` 9396d95): `tests/unit/test_cmd_1350_module_order.py` +
  `tests/harness/live_form.py` の AST 導出 (実機 bootstrap を読む・写経定数を置かぬ)
- **gate X** (`backend` cb873e9): `tests/harness/arm_compare.py: gate_generation_filter`
  (世代 filter が turn を黙って落としたら blocking)

だがこの 2 本は **どの変異台帳にも載っておらなんだ** = 仕様変更で牙が折れても
(cmd_1330 W0-2 G2 事故の型 = 「gate 全 PASS = 何も守らぬ test」) 誰も気付けぬ。
**守り手を守る層が無かった**。

## 何を作ったか

1. **backend 側台帳** `backend/config/mutation_registry.yaml` — entry 5 本
   (MUT-1350-M1〜M4 = 9396d95 で一度赤を実証した変異の恒久化 / MUT-1350-X = gate X の骨抜き検分)。
   台帳は **検査と同じ repo を旅する** (fresh clone に契約が付いて来る)。
2. **runner 拡張** (`scripts/gate_mutation_replay.py` — cmd_1352/1352b の道具の延長):
   - **D3 検出規則**: pytest 型変異test (`def test_` と変異 keyword の共起・`.py` のみ)。
     backend の変異test は bats でも `--selftest` 宣言でもないゆえ既存 D1/D2 の網に
     掛からず、**backend を見ても常に 0 件 = 延長全体が真空**になるため。
   - **台帳側 `coverage_positive_control:` key**: runner 自身を持たぬ repo でも
     陽性対照が立つ (backend では `tests/unit/test_cmd_1350_module_order.py`)。
   - baseline 赤の UNDETERMINED 理由に**失敗出力の尻尾を添付** (repo 跨ぎでは
     「venv 不在」「rubric 不在」等の空振り理由が exit code だけでは家老に辿れぬ)。
3. **配線** (`scripts/gate_nightly.sh` — 毎朝 06:30 の既存 cron に相乗り・crontab 非接触):
   backend 台帳の全件再走 + `--coverage`。非 PASS は既存の家老 inbox 警告経路へ相乗り。
4. **環境解決の単一口** `backend/tests/harness/gate2_env.sh`: venv への道はここ 1 file
   (設定の出所を1つに)。**見つからねば大声で非0 = UNDETERMINED へ倒す。黙る fallback は無い**。

## 誤検知の実測 (D3 導入時・2026-07-26)

| repo | D3 候補 | 内訳 |
|------|---------|------|
| backend | 7 件 | 2 件 = 本任で登録 (REGISTERED) / 5 件 = 他者所有 → **理由つき waiver + 所有者へ申し送り** |
| multi-agent-shogun | 0 件 | 既存運用への誤検知増 = ゼロ |

waiver は毎朝 `[WAIVED]` として可視表示される (黙って消える道は無い)。
他人の test に mutate を書くのは**所有者の手番** — 台帳の掟。

## 「登録が飾りでない」ことの実測 (2026-07-26)

path だけ載せた飾り entry でも REGISTERED になりうる (cmd_1352b caveat C2)。ゆえに:

- **正常系**: 5 entry 全て baseline 緑 → 変異 → 赤 + **red_needle 名指し**確認 = PASS (3.8 秒)。
- **G2 型 kill 演習** (demo A): gate X の変異試験の assert の牙を demo repo で抜く →
  台帳が **MUT-1350-X を名指しで FAIL**「★変異後も緑 = この変異は静かに無効化された★」。
- **検査器 kill 演習** (demo B): `module_order_mismatch` を常時 None へ →
  M1〜M4 が **UNDETERMINED (baseline 赤 + 理由の尻尾つき)**・exit 2 = 鳴る。
  **未判定は緑ではない**。

## repo 跨ぎの空振り → 全て「鳴る側」に倒れる (実測表)

| 空振りの型 | 挙動 |
|-----------|------|
| backend 台帳が見えぬ (submodule 未init / path 違い / disk 喪失) | gate_nightly が rc=2 UNDETERMINED + 家老警告 |
| backend .venv 不在 (fresh clone 相当) | gate2_env.sh が exit 3 + 大声 → baseline 赤 → UNDETERMINED (理由の尻尾に「venv が居らぬ」) |
| rubric 正本不在 (app repo 側 `eval/rubric/conv_v2.yaml`) | MUT-1350-X の test が exit 3 + 大声 → UNDETERMINED |
| cron 素 PATH | python3 は /usr/bin・venv は絶対 path ゆえ影響なし (E2E 実測済) |
| mutate の当たり損ね (arm_compare 改修が続く等) | 空振り検知 → UNDETERMINED「pattern の当たり損ね。mutate を直せ」= **台帳の追随が要る音** |

## 限界 (正直に)

- gate-2 は **worktree を読む** (mutation は現行 code へ当てる設計)。commit 漏れの検分は
  gate-1 (--committed) の領分であり、backend には gate-1 は未延長。
- D3 は keyword **共起**ゆえ、「変異」に言及するだけの pytest file も拾いうる
  (裁きは waiver で可視に行う)。untracked の変異test は見えぬ (git ls-files 起点)。
- MUT-1350-X の対象 `arm_compare.py` は改修が続く file — mutate 空振り = UNDETERMINED が
  鳴ったら台帳を追随させよ (黙って外すな)。

## 手動再走

```bash
# backend 台帳の全件再走 + 登録検知 (cwd = multi-agent-shogun)
python3 scripts/gate_mutation_replay.py \
  --registry ~/aituber-project/backend/config/mutation_registry.yaml \
  --repo-root ~/aituber-project/backend
python3 scripts/gate_mutation_replay.py --coverage \
  --registry ~/aituber-project/backend/config/mutation_registry.yaml \
  --repo-root ~/aituber-project/backend
```

## 原理 (cmd_1352 docs の 4 原理を本延長がどう継ぐか)

- (i) commit済blob を正とする — gate-1 の領分 (backend 未延長・上記「限界」)。
- (ii) 操作でなく状態の変化を証拠に — mutate 空振り検知・gate2_env の「黙る fallback 無し」。
- (iii) 赤の理由が変異を名指しするか — 全 entry に red_needle (実測値のみ)。
- (iv) 渡す前に食われる経路を疑え — rubric は scratch へ staging して読ませる
  (conv_metrics が APP_ROOT を見る = scratch の外を暗黙に読む経路を、明示の staging に変えた)。
