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

## 4つの原理 (gate を書く者・直す者へ)

同夜〜翌未明の実事故から蒸留した原理。gate 群の設計判断はすべてここへ帰着する:

- **(i) 成果物は【作業ツリーでなく commit 済 blob】を正として検める。**
  作業ツリーで自分を検めると「自分で書いた嘘を自分で信じる」循環が起きる。
  軍師二号の cmd_1349 束ねQC (`git archive` で commit 済 blob だけを別 tree へ展開して突合)
  の流儀。gate-1 `--committed` の由来。
- **(ii) 操作を撃ったことでなく【状態が変わったこと】を成功の証拠とする。**
  実例: 足軽五号が `docker rm -f vllm-8002` を撃ったが実 container 名は `vllm-main` で
  **黙って何もせず exit 0** (2026-07-25 夜・7件目の沈黙)。exit 0 は「何もしなかった」とも
  両立する。gate-2 の mutate 空振り検知 (tree digest 前後比較) はこの原理の実装。
- **(iii) 変異は【赤くなったか】でなく【赤の理由が変異を名指ししておるか】で検める。**
  実例: 行の移動型変異は diff で ± 同一文字列に見え目視で実効が判らぬ (五号の harness
  module 順事故)。「別の理由で偶然赤い」を「変異が効いた」と誤認するのは沈黙の裏返しの
  偽陽性。台帳の `red_needle` field の由来 (値は**実測した失敗出力**から取れ)。
- **(iv) 「渡す前に食われる」経路を疑え。**
  実例: 家老が inbox 本文に backtick を書き、shell が inbox_write.sh へ渡す**前に**中身を
  コマンドとして実行した (2026-07-26 未明・8件目の沈黙。意図せず `docker rm -f` を実発射)。
  道具が安全でも、道具へ渡すまでの経路 (shell 展開・引用の入れ子) が黙って中身を変えうる。
  gate が「何を検めるか」を決める時、**検める対象が検める前に既に変わっておらぬか**を一度考えよ。

## 何が居るか

| 部品 | 役割 |
|---|---|
| `scripts/gate_artifact_capture.sh` | **gate-1**: manifest 宣言 vs git 実体の突合。ignore に黙って弾かれた file を**弾いた規則の行番号つき**で名指し。件数 gate (`min=N`) 含む。`--committed` で **HEAD blob を正** (fresh clone が受け取る中身・作業ツリーを信ぜぬ = 軍師二号が cmd_1349 QC で示した流儀。manifest 自体も HEAD から読む = 自分で自分を検める循環を断つ) |
| `config/artifact_manifests/*.manifest` | gate-1 の宣言置き場 (1 task 1 file・累積で守る) |
| `scripts/gate_mutation_replay.py` | **gate-2**: 変異台帳の全件再走。「赤くなるべき変異」が緑のままなら名指しで FAIL。baseline 赤・mutate 空振りは UNDETERMINED |
| `config/mutation_registry.yaml` | 変異の台帳 (**出所はこの1 file のみ**)。変異試験を新設したらここへ登録。`red_needle` (任意) で赤の名指しまで契約化。`coverage_waivers` = 登録検知の免除簿 (理由必須) |
| `gate_mutation_replay.py --coverage` | **gate-2 付帯 (cmd_1352b)**: 台帳登録検知。「変異testらしき file が台帳に無い」を名指しで警告 (下記専用節) |
| `scripts/gate_precommit.sh` | commit 時の関所本体 (gate-1 全件 + gate-2 sanity。正本はここ・hook は shim) |
| `scripts/install_gate_hooks.sh` | pre-commit shim 据付 (冪等・既存 hook は退避チェーン) |
| `scripts/gate_nightly.sh` | cron backstop (毎朝 06:30 フル再走・非 PASS を家老 inbox へ警告) |

## どこで回るか (人が思い出して回す形にはしていない)

- **commit 時** (pre-commit hook): gate-1 全 manifest (index 視点=いま commit しようとする中身) + gate-2 sanity。数百 ms。
  FAIL は commit を**止める**。UNDETERMINED は**大声で警告して通す**
  (全 agent が commit する repo ゆえ、一過性の未判定で全軍を塞がぬ — cmd_1342 zip 関所と同じ流儀)。
- **毎朝 06:30** (cron `silent_pitfall_gates_cmd1352`): 両 gate フル (gate-1 は `--committed` で
  fresh clone 視点・gate-2 は変異を実走)。非 PASS は家老 inbox へ warning (是正手順つき)。
  hook 消失 (shim marker の grep)・commit の無い日の drift もここが拾う。
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

## 境界: gate-1 が証明する範囲と、しない範囲 (依存解決の再現性)

軍師二号の cmd_1349 束ねQC が引いた線をここに固定する (設計上の宣言・実装は範囲外):

- gate-1 が**証明する**もの: 「repo の中身が**完全** (宣言された成果物が fresh clone に渡る) かつ
  **忠実** (`--committed` なら HEAD blob そのもの)」であること。
- gate-1 が**証明しない**もの: 「その中身から**依存解決が今日も成功する**」こと。
  pip/uv の resolver 挙動・PyPI 上流の生存・transitive 依存の版ずれは repo の外の世界であり、
  manifest 突合では**原理的に**捕まえられない。
- ゆえに残余リスクは**依存解決側に集中**する。処方は (a) freeze を text list でなく
  `pip install -r` 可能な **lockfile として機械強制**すること (cmd_1349 A-O2)、
  (b) 「復元が今日も通る」の唯一の証明は **restore の実走リハーサル**であり、
  gate の緑をその代替にしないこと。restore 実走は重い (venv 構築) ゆえ gate には載せず、
  runbook 側の定期演習 (人ではなく cmd 起票で駆動) に置く。

## 台帳登録検知 (gate-2 付帯・cmd_1352b)

**なぜ在るか**: 変異試験を書いて赤を確認しても、**台帳へ登録せねば** gate-2 は守れない
(caveat C4)。家老裁定 =「登録の強制はせぬ (強制は形骸化を生む)。**検知して警告せよ**」
(cmd_1336 の detect→warn 流儀)。初回実走が実際に **cmd_1339 の未登録変異test 2件**
(`test_idle_revive_quorum.bats` の T-QRM-003 / `test_supervisor_legacy_once.bats` の
T-LEG-004 — quorum gate と warn-once 契約を守る現役の牙) を名指しし、MUT-1339-001/002
として登録させた。検知が無ければこの2本は次の仕様変更で静かに無効化されえた。

**何を変異testと見なすか (検出規則の定義・正本は `gate_mutation_replay.py` 冒頭の定数)**:
git 追跡下 (`git ls-files`) かつ拡張子 `.sh` `.bash` `.py` `.bats` の file で、

- **D1**: `@test` を含む行が変異を名指しする —
  行内に `変異試験|変異を当て|わざと壊|壊して赤|壊せば落ち|mutation` (大小無視)。
  負規則: `(without|no|not)\s+mutation` に当たる行は除く (データ変異の意の英語を誤検知せぬ)。
- **D2**: selftest 宣言 (`--selftest` / `def selftest` / `selftest()`) と変異 keyword の
  **同一 file 内共起** (selftest に変異試験を内蔵する本 repo の流儀を捕まえる)。

**限界 (正直に)**: prose (*.md) と YAML は対象外 (実行可能な test のみ)・untracked の
変異testは見えぬ (commit されて初めて守れる)・内容は worktree を読む・pytest 流の
mutation test (上記 marker を持たぬもの) は届かぬ。規則を変える時は誤検知率を再実測せよ。

**誤検知の実測 (2026-07-26)**: 素朴な keyword 全文一致では 8 file 中 4 件が誤検知 (50% —
言及のみの `gate_nightly.sh`/`gate_precommit.sh`/`idle_revive_scan.py`、データ変異の意の
`test_branch_policy_scripts.bats`)。D1/D2 へ絞った結果 = **候補 4 件・誤検知 0 件**。
「常に赤い検知は無視されて死ぬ」ゆえ、誤検知が出るようになったら規則を絞るか
`coverage_waivers` へ**理由つきで**免除せよ (免除は毎朝 [WAIVED] として可視・黙って消える道は無い)。

**三値と対照**: 陽性対照 = `scripts/gate_mutation_replay.py` 自身 (selftest T2 =
変異試験を永続内蔵)。これが検出されねば**検出規則の牙が折れておる**として UNDETERMINED
(0件検出もここへ畳む = 真空 PASS 禁)。理由なし waiver も UNDETERMINED (曖昧な免除は免除でない)。

**どこで回るか**: gate_nightly (cron 毎朝 06:30) のみ。pre-commit には載せぬ — 理由:
(a) これは**警告層**であり block 層でない (他 agent の未登録 test で全軍の commit を塞ぐのは
検知層の越権)、(b) 警告は既存の gate_nightly → 家老 inbox 経路へ**相乗り** (新経路を作らぬ・
家老裁定)。FAIL の意味は「家老へ警告」= 登録するか免除するかの判断は人 (家老/所有者) に残る。

**他 agent の変異testを見つけた時**: 勝手に登録するな (他人の test へ mutate を書くのは
所有者の手番)。`coverage_waivers` へ理由つきで置き、所有者へ登録を申し送れ。

## 逃がし口 (隠さぬ・使ったら理由を残せ)

`SHOGUN_GATE_SKIP=1 git commit ...` — 理由を commit message へ。

## 使い方 (新しい task で成果物を守るには)

1. `config/artifact_manifests/cmd_XXXX_<name>.manifest` に成果物を宣言 (dir は `dir/ min=N`)。
2. 変異試験で赤を確認したら `config/mutation_registry.yaml` へ登録。`red_needle` には
   **実測した失敗出力**の名指し文字列を書く (推測で書くと偽 FAIL で信頼を失う)。
3. commit すれば以後は hook + cron が自動で見張る。登録を忘れても翌朝の台帳登録検知が
   名指しで警告する (が、警告される前に登録するのが筋である)。
