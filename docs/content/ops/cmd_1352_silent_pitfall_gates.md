# 沈黙する落とし穴 gate (cmd_1352)

**消す前に読め (Chesterton's Fence)**: この gate 群は 2026-07-25 夜に【独立に3件】起きた
「赤くならない事故」を機械で塞ぐために在る。gate が邪魔に見えるなら、それはこの3件を
知らぬからである。消す判断は必ずこの3実例を読んでから行え。

## なぜ在るか — 2026-07-25 夜の実例3件 (すべて沈黙した)

1. **cmd_1349 (足軽一号)** — `.gitignore:34` の `models/` が vendoring 本体 (+575行) を
   `git add` から**警告なしに**弾いた。commit は成功したように見え、fresh clone で初めて
   欠損が露見する構図 (最悪の遅延露見)。件数 gate が**偶然**捕まえた。→ **gate-1** の由来。
2. **cmd_1330 W0-2 (足軽五号)** — G2 を二段化した際、G2 を守っていた背骨 test を撃ち直さず、
   実機で 8002 が上がると細工が素通り。「gate 全 PASS = 何も守らぬ test」になっていた。
   一度赤を確認した変異でも、仕様変更後に**誰にも知られず**無効化される。→ **gate-2** の由来。
3. **cmd_1350 (足軽五号)** — 評価 harness の module 登録順が実機と逆で、全測定値が歪み
   家老の裁定まで誤らせた。設定・順序の**出所が二重**にあると実体とずれても誰も気付かぬ。
   → 本 gate 群の設計原則「出所を1つに」(manifest / 台帳とも正本は1 file) の由来。

共通点: どれも**赤くならなかった**。3件とも発見は偶然に近い (件数 gate / 別 test の赤 / 自己検分)。
人の注意力に戻せば4件目が必ず来る — ゆえに機械 gate にした。

## 何が居るか

| 部品 | 役割 |
|---|---|
| `scripts/gate_artifact_capture.sh` | **gate-1**: manifest 宣言 vs git 実体の突合。ignore に黙って弾かれた file を**弾いた規則の行番号つき**で名指し。件数 gate (`min=N`) 含む |
| `config/artifact_manifests/*.manifest` | gate-1 の宣言置き場 (1 task 1 file・累積で守る) |
| `scripts/gate_mutation_replay.py` | **gate-2**: 変異台帳の全件再走。「赤くなるべき変異」が緑のままなら名指しで FAIL。baseline 赤・mutate 空振りは UNDETERMINED |
| `config/mutation_registry.yaml` | 変異の台帳 (**出所はこの1 file のみ**)。変異試験を新設したらここへ登録 |
| `scripts/gate_precommit.sh` | commit 時の関所本体 (gate-1 全件 + gate-2 sanity。正本はここ・hook は shim) |
| `scripts/install_gate_hooks.sh` | pre-commit shim 据付 (冪等・既存 hook は退避チェーン) |
| `scripts/gate_nightly.sh` | cron backstop (毎朝 06:30 フル再走・非 PASS を家老 inbox へ警告) |

## どこで回るか (人が思い出して回す形にはしていない)

- **commit 時** (pre-commit hook): gate-1 全 manifest + gate-2 sanity。数百 ms。
  FAIL は commit を**止める**。UNDETERMINED は**大声で警告して通す**
  (全 agent が commit する repo ゆえ、一過性の未判定で全軍を塞がぬ — cmd_1342 zip 関所と同じ流儀)。
- **毎朝 06:30** (cron `silent_pitfall_gates_cmd1352`): 両 gate フル (gate-2 は変異を実走)。
  非 PASS は家老 inbox へ warning (是正手順つき)。hook 消失・commit の無い日の drift もここが拾う。
- 手動再走はいつでも可:
  `bash scripts/gate_artifact_capture.sh --all` / `python3 scripts/gate_mutation_replay.py`

## 三値の掟 (cmd_1342 Phase1d の流儀)

exit 0 = PASS / 1 = FAIL / 2 = UNDETERMINED。**0件・未判定は緑ではない**。
manifest 0件・台帳 0件・baseline 赤・mutate 空振り (sed の当たり損ね) はすべて UNDETERMINED。

## 赤くなった時の処方

- `[IGNORED] path ← .gitignore:N` … (a) `.gitignore` へ否定規則 `!path` を足す か
  (b) `git add -f path`。直後に `--all` を再走して緑を確認。
- `[UNTRACKED]/[MISSING]/[COUNT]` … 成果物の実在と `git add` を確かめよ。
- gate-2 の `★NG★ MUT-…` … 名指しされた変異の test を仕様変更へ追随させ、
  **再び赤くなることを確認**して台帳を維持。変異が正当に不要なら
  **理由を commit log に書いて**台帳から外せ (黙って外すな)。

## 逃がし口 (隠さぬ・使ったら理由を残せ)

`SHOGUN_GATE_SKIP=1 git commit ...` — 理由を commit message へ。

## 使い方 (新しい task で成果物を守るには)

1. `config/artifact_manifests/cmd_XXXX_<name>.manifest` に成果物を宣言 (dir は `dir/ min=N`)。
2. 変異試験で赤を確認したら `config/mutation_registry.yaml` へ登録。
3. commit すれば以後は hook + cron が自動で見張る。
