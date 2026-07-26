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
- **(v) 選別・除外の仕組みは【何を落としたか】を必ず数えさせよ。**
  実例: 評価 harness の世代フィルタが、見出しごと書き換えた比較腕の**全 turn を「旧世代」として
  静かに除外**し、「その腕は違反 0 件」という**嘘の勝利**を作りうると判った
  (2026-07-26 未明・**9件目の沈黙**。足軽五号が gate X を新設して塞いだ)。
  除外は**成功と区別がつかぬ形で数字を良くする**ゆえ、
  **除外件数を実測して 1 件でも在れば落とす**のが処方 (0 件を黙って通すのではなく、
  **0 件であることを毎回示させる**)。

### 沈黙の件数 — 正本はどこか

**件数は prose の中で各自が数えるな** (実例: 五号が本件を「8件目」と書き、8 は既に上記 (iv) で
埋まっておった)。**正本 = `dashboard.md` の台帳 (2026-07-25 00:42 節「本日の学び」) と本節**。
新しい沈黙を数える者は**先に台帳を読み、次の番号を採れ**。

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
  行内に `変異|わざと壊|壊して赤|壊せば落ち|mutation` (大小無視)。照合前に**強調の装飾記号**
  (`★☆◆■●▲【】《》｜` 等) を落とす (cmd_1370)。
  負規則: `(without|no|not)\s+mutation` に当たる行は除く (データ変異の意の英語を誤検知せぬ)。
- **D2**: selftest 宣言 (`--selftest` / `def selftest` / `selftest()`) と変異 keyword の
  **同一 file 内共起** (selftest に変異試験を内蔵する本 repo の流儀を捕まえる)。
- **D3** (cmd_1355 で追加): pytest 型 test 定義 (`def test_`) と変異 keyword の共起
  (.py のみ)。backend の `test_cmd_1350_*` 等は bats でも selftest 宣言でもないゆえ
  D1/D2 の網に掛からなかった — 実測 2026-07-26: この規則で backend 7 件 / shogun 0 件
  (既存運用の誤検知増ゼロ)。

**限界 (正直に)**: prose (*.md) と YAML は対象外 (実行可能な test のみ)・untracked の
変異testは見えぬ (commit されて初めて守れる)・内容は worktree を読む。
規則を変える時は誤検知率を再実測せよ。
**そして最大の限界 = 綴りに依ること**: D1/D2/D3 はいずれも「書き手が変異について**書いた**か」を
見ておるにすぎず、**その file が変異試験であるか**を見てはおらぬ。本 repo 群の様式では
**変異の実体は台帳側の `mutate:` (sed 等) に在り、test 本体は普通の test** ゆえ、
test 本体に構造的な印は**原理的に存在せぬ**。この限界を数字で言わせるのが下の**視野計**である。

### 視野計 — 検知規則の recall を台帳で測る (cmd_1370)

**なぜ在るか (実測)**: cmd_1366 の変異test は「`★変異★= …を戻せば ★本 test は赤★`」と
装飾つきで書かれており、旧 keyword (語句固定) の該当が **0 件** = **候補にすら挙がらなかった**
(軍師一号 R5)。つまり毎朝の `PASS: 候補 9 件すべて登録済` は**候補に挙がった物だけ**を数えており、
**候補に挙がらなかった牙は最初から分母の外**に在った。

**測り方**: 台帳が `paths`/`test`/`mutate` で名指しする追跡下 file のうち **test 本体の印**
(`def test_` / `@test` / selftest 宣言) を持つものは、**定義により変異試験**である
(綴りに一切依らぬ独立の証拠)。これを分母に、D1/D2/D3 が候補に挙げた数を分子として
毎朝印字し、見えておらぬ file を `注 [RULE-BLIND]` で**名指す**。PASS 行にも視野を刻む
(「候補すべて登録済」を**全部検査した**と読ませぬための限定)。

**実測 (2026-07-26 cmd_1370 是正後)**: shogun = 台帳既知 11 件中 **見える 7・盲 4**、
backend = 台帳既知 11 件中 **見える 7・盲 4** (是正前は 5)。**盲の 8 件は変異語彙を1語も
持たぬ** = keyword をいくら足しても届かぬ族である。

**verdict への効き方 (permanent-red を作らぬ)**:

- 盲そのものは **FAIL にせぬ** (印字して数えるのみ)。台帳が在る以上その file は守られており、
  かつ「規則には永久に見えぬ」ゆえ赤にすれば**毎朝赤くなり無視されて死ぬ**
  (家老の掟「登録したが永久に UNDETERMINED は免除より悪い」)。
- **UNDETERMINED になるのは1つだけ** = 台帳が名指す**対照以外**の変異試験を規則が
  **1件も見えておらぬ**時。陽性対照は必ず当たる fixture ゆえ規則の生存を証明せぬ —
  従来の「対照1件の検分」より広い牙である。
- 台帳が対照以外の test 本体を名指さぬ時は「**視野は測れておらぬ**」と明言する
  (分母0を「全部見えておる」と読ませぬ — cmd_1364 の流儀)。

**視野計の限界 (正直に)**: 物差しは**台帳**ゆえ、**未登録かつ綴りでも見えぬ** file は
視野計にも映らぬ (残余)。視野計が塞ぐのは「盲であることが**画面から見えぬ**」であって、
「盲そのもの」ではない。

**誤検知の実測 (2026-07-26)**: 素朴な keyword 全文一致では 8 file 中 4 件が誤検知 (50% —
言及のみの `gate_nightly.sh`/`gate_precommit.sh`/`idle_revive_scan.py`、データ変異の意の
`test_branch_policy_scripts.bats`)。D1/D2 へ絞った結果 = **候補 4 件・誤検知 0 件**。
**cmd_1370 の綴り一般化でも誤検知は増やしておらぬ (実測)**: 日本語側のみ一般形「変異」へ
広げ、**英語側は `mutation` のまま広げなかった** — `mutat` まで広げると
`does not mutate` / `mutate 可能な stub` 等の**データ変異の意**を拾い、backend で誤検知が
**2 件**増えることを実測したゆえ (誤検知は検知を殺す)。一般化後の候補は
shogun 7 件 (増減なし) / backend 12 件 (+3・いずれも実物の変異試験を目視確認)。
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

## harness 内 SKIP=FAIL (gate-2 付帯2・2026-07-26 四号の申し送り)

**なぜ在るか — 実例 (2026-07-26 朝・足軽四号)**: 四号の STT 署名 canary は、変異を撃っても
最初【緑】であった。機序 = gate-2 の scratch は entry の `paths` だけの repo コピーであり、
**corpus は .gitignore ゆえ付いて来ぬ → 番人が skip → skip は緑に見える** =
**【見張っておらぬ番人が「異常なし」と報告する形】**。四号は STT_CORPUS_WATCH_DB の口を
開けて撃ち直し、赤を実測した。四号の申し送り (家老が採り、台帳所有者が受けた) =
**「SKIP=FAIL の掟 (CLAUDE.md Test Rules 1) は変異試験の harness 内でも成り立つ。
scratch で skip する番人は、台帳に載っていても何も守っておらぬ」**。

**何を検るか (正本 = `gate_mutation_replay.py` の `_SKIP_EVIDENCE`)**: baseline と変異後の
**両方**の test 出力から、skip の機械痕跡を拾い **UNDETERMINED** に畳む (skip は緑でも
赤でもない):

- TAP/bats の `ok N … # skip` — skip した test は ok の顔をする (緑の顔をした不在)
- TAP 空計画 `1..0` — `bats --filter` の空振り (test 名の rename 等) は 1 本も走らずに
  exit 0 する
- pytest 要約の `N skipped` (N≥1)

変異後出力の skip も判定を汚す扱いとする — skip した試験の混じった赤は「当てた変異の赤」の
保証にならぬ (red_needle の名指しと同じ理路)。

**全台帳の実測 (2026-07-26)**: 導入後の全件再走 = **shogun 台帳 23 件 + backend 台帳
30 件 = 53 entry すべて skip 痕跡なしで PASS**。四号の是正済 canary (backend 台帳の署名
watch) も新検分の下で健全 = 「coverage PASS が嘘」は現状ゼロと機械で確認した。

**限界 (正直に)**: bash selftest が内部 guard で**黙って何もせず exit 0** する無痕跡形は
拾えぬ — その全滅形は既存の「変異後も緑=FAIL」が捕まえる (baseline 緑 + 変異後緑)。残余は
【痕跡を出さぬ部分 skip】のみ (手動検分 2026-07-26: shogun 台帳の bash/python selftest 系
entry に該当なし)。五号の教訓の一般形と同根 =「操作を撃ったこと」を成功の証拠にするな —
skip 検知は「test が走ったこと」すら証拠にせず、**走らなかった痕跡**を探す側から塞ぐ。

**変異試験**: MUT-1352-006 (skip 検知を折る → selftest T19 が名指しで赤・実測済)。

## 幽霊 ID 検分 (gate-2 付帯3・四号 M9 型)

**なぜ在るか — 実例 (2026-07-26・足軽四号の自白)**: M9 は台帳に無いのに「実射で確認済」と
docstring に書いてあった — M6 で同じ抜けを一度やっており**二度目** = docstring の申告と
台帳の実在の食い違いは、人の注意力では二度破れた。

**何を検るか**: `--coverage` に相乗り。tracked な test file (COVERAGE_EXTS) 中の台帳 ID
**完全形言及** (`MUT-xxxx-nnn` / `MUT-xxxx-Mn` 形) を全数拾い、台帳に実在せぬものを
`[GHOST-ID]` として **file:行 で名指し** (FAIL = 家老へ警告・block せぬ)。

**実測 (2026-07-26)**: shogun ID言及 23 件・backend 13 件 — **幽霊ゼロ** (導入時点の
食い違いは無し)。

**限界 (正直に)**: 略記の申告 (「M9 は実射で確認済」) は拾えぬ — **完全形 ID で書く規律**と
セットで効く。照合先は各 repo 自身の台帳のみ (repo 跨ぎ言及は実測ゼロ・現れたら規則を再考)。

**変異試験**: MUT-1352-007 (ID 抽出を折る → selftest T21 が名指しで赤・実測済)。

## 逃がし口 (隠さぬ・使ったら理由を残せ)

`SHOGUN_GATE_SKIP=1 git commit ...` — 理由を commit message へ。

## 使い方 (新しい task で成果物を守るには)

1. `config/artifact_manifests/cmd_XXXX_<name>.manifest` に成果物を宣言 (dir は `dir/ min=N`)。
2. 変異試験で赤を確認したら `config/mutation_registry.yaml` へ登録。`red_needle` には
   **実測した失敗出力**の名指し文字列を書く (推測で書くと偽 FAIL で信頼を失う)。
3. commit すれば以後は hook + cron が自動で見張る。登録を忘れても翌朝の台帳登録検知が
   名指しで警告する (が、警告される前に登録するのが筋である)。
