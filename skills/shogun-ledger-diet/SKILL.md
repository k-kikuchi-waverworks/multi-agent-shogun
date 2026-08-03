---
name: shogun-ledger-diet
description: |
  台帳 (queue/shogun_to_karo.yaml) と inbox (queue/inbox/*.yaml) が膨らんだ時に、
  閉じた分だけを退避させて痩せさせる。★どれを閉じたとみなすかは必ず人に見せ、承認を得てから動く。★
  「台帳が重い」「台帳ダイエット」「台帳を痩せさせて」「inbox を畳んで」「ledger diet」で起動。
  Do NOT use for: cmd の状態を変えること・cmd を消すこと・目方を測って見せるだけの用途。
argument-hint: "[ledger | inbox | both]"
allowed-tools: Read, Bash, Grep
---

# 台帳と inbox のダイエット

## これは何か

台帳が 2万行まで膨らむと、家老が毎回それを読むだけで手が塞がる。
閉じた cmd を別の file へ移し、正本には生きている物だけを残す。inbox も同じ。

**移すだけである。1件も消さない。** 退避先に塊がそのまま残るので、貼り戻せば元に戻る。

## いつ使うか

- 殿または将軍が「台帳が重い」「畳んでくれ」と仰った時
- 台帳が 1万行を超え、家老が読むのに難儀している時

## ★この skill の芯 — 承認を待って止まる★

2026-08-03、将軍が手で畳んだ時に事故が起きた。
「閉じた物」の線を `pending` / `in_progress` 以外すべてに引いた結果、
**まだ生きている `deferred` 26本と `stopped_by_lord` 22本を巻き込んで退避させた。**
殿が「あれ？deferred 全部消えたんだけど」と仰って初めて分かった。

⇒ **機械に線を引かせない。案を出して人に見せ、承認を得てから動く。**
⇒ 速さのために step 3 を飛ばさないこと。飛ばせる作りにもなっていない
   (`apply.py` は承認の一文と控えの場所の両方が無いと1件も動かない)。

## 手順

### Step 1: 控えを取る。★取れなければ何もせず止まる★

`queue/` は git 管理外である。壊しても git では戻らない。**控えが唯一の戻し道である。**

控えは `queue/` の下の形をそのまま写す。**`apply.py` はこの形を前提に戻し先を決める。**
平らに写すと、inbox の控えが退避先を上書きして前の便りを消す。

```bash
BK="queue/archive/diet_backup_$(date +%Y%m%d_%H%M)"
mkdir -p "$BK/inbox" "$BK/archive"
cp queue/shogun_to_karo.yaml "$BK"/
cp queue/inbox/*.yaml "$BK/inbox"/
cp queue/archive/*.yaml "$BK/archive"/ 2>/dev/null        # 既にある台帳の退避先
for d in queue/archive/inbox_*; do                        # 既にある inbox の退避先
  [ -d "$d" ] && cp -r "$d" "$BK/archive"/
done
# 控えが現物と1バイトも違わないことを確かめる
md5sum queue/shogun_to_karo.yaml "$BK"/shogun_to_karo.yaml
echo "★次の2つを控えておくこと。Step 4 と Step 5 でそのまま打ち込む★"
echo "控え   = $BK"
echo "日付   = $(date +%Y%m%d)"
```

md5 が違う、または `cp` が落ちた場合は **ここで止まる。以後の step を撃たない。**

★**最後の2行が画面に出した文字列を、必ず書き留めること。**★
Step 4 と Step 5 は別々の bash 呼出である。**`$BK` も `$STAMP` も引き継がれず、空文字になる。**
空文字を渡すと `apply.py` は「控えの場所が空」と言って止まるので、事故にはならない。
だが手が止まる。**変数を使わず、画面に出た文字列を直に打ち込むこと。**

D: の控え (`/mnt/d/backup/multi-agent-shogun/queue_backup/`) は 30分ごとに取られている。
そちらも在るか併せて見ておくと、戻し道が2本になる。

### Step 2: 塊に切り、状態ごとの件数を出す

```bash
python3 skills/shogun-ledger-diet/scripts/scan.py
```

- 台帳を `- id:` で始まる塊に、inbox を `- content:` で始まる塊に切る
- 切って繋ぎ直すと元と1バイトも違わないことを、その場で確かめる。違えば `NG` を出して止まる
- **読むだけである。1文字も書かない**

### Step 3: ★案を示して止まる。承認を待つ★

Step 2 の出力をもとに、人へこう見せる。

```
■ 台帳 = 全 {N}本 / {M}行

  退避してよいか伺いたい分:
    cancelled     {n}本   (取り止めになった物)
    superseded    {n}本   (後の cmd に置き換わった物)
    done          {n}本   (畢わった物)

  残すつもりの分:
    pending       {n}本   ← 開いている
    in_progress   {n}本   ← 開いている
    deferred      {n}本   ← ★生きている。後回しなだけで閉じていない★
    stopped_by_lord {n}本 ← ★生きている。殿が止めておられるだけ★

  この線でよろしいでしょうか。残す物・退避する物の入れ替えがあれば仰ってください。
```

**ここで必ず止まる。** 次の3つを人から受け取るまで、1件も動かさない。

1. どの状態を退避するか
2. その状態のうち、名指しで残す cmd はあるか
3. inbox の既読を何件 残すか (既定 = 直近5件)

`deferred` と `stopped_by_lord` は **既定で残す側に置く。**
これを退避する時は、人が明示的にそう言った時だけである。

### Step 4: 承認された分だけ移す

**YAML として読み込んで組み直さないこと。** 書式やブロック記法が1文字でも変われば台帳が壊れる。
`apply.py` はテキストの塊のまま移す。

★`--backup` と `--stamp` には **Step 1 が画面に出した文字列を直に書く。**★
`"$BK"` や `"$STAMP"` と書かない。**別の bash 呼出なので空文字になる。**
下の例の `diet_backup_20260803_1810` と `20260803` の所が、その差し替える箇所である。

```bash
# 台帳
python3 skills/shogun-ledger-diet/scripts/apply.py \
  --target ledger \
  --approved "殿のご承認 2026-08-03 18:10 = cancelled と superseded のみ。deferred と stopped_by_lord は残す" \
  --backup queue/archive/diet_backup_20260803_1810 \
  --stamp 20260803 \
  --statuses cancelled,superseded \
  --keep-ids cmd_1246          # 状態が当たっても名指しで残す物 (無ければ省く)

# inbox
python3 skills/shogun-ledger-diet/scripts/apply.py \
  --target inbox \
  --approved "殿のご承認 = 既読の古い分のみ。未読は1件も移さない" \
  --backup queue/archive/diet_backup_20260803_1810 \
  --stamp 20260803 \
  --keep-read 5
```

`--approved` には **人が実際に言った内容**を書く。この一文は退避先の頭にも残り、後から誰の裁で移したか分かる。

`apply.py` が動かない場合 (どれも正しい振る舞いである):

| 出力 | 意味 |
|---|---|
| `控えの場所が空` | `$BK` と書いた。Step 1 が画面に出した文字列を直に打ち込む |
| `控えが揃っていない` | 控えに現物が無いか、控えが古い。Step 1 をやり直す |
| `承認の一文が空` | Step 3 に戻る |
| `pending は open である` | **open な cmd はこの skill では移せない。`--ids` で名指ししても移せない** |
| `退避する status も id も指定が無い` | 何を移すか決まっていない |

**`pending` / `in_progress` は、この skill では移せない。** `--statuses` でも `--ids` でも移せない。
開いている cmd を台帳から外すのは、この skill の役目ではない。まず cmd を閉じること。

### Step 5: 検算 — 合わなければ控えから戻す

`apply.py` が移した直後に自分で検算する。**1つでも合わなければ控えから戻し、非0で終わる。**

| 検める事 | 合わない時 |
|---|---|
| 残した数 + 移した数 = 元の数 | 戻す |
| id の集合が元と同じ | 戻す |
| 退避先に id の重複が増えていない | 戻す |
| `pending` / `in_progress` が全部 正本に在る | 戻す |
| 移した塊が退避先に**1文字も違わない形**で入っている | 戻す |
| 正本・退避先が両方 YAML として読める | 戻す |
| (inbox) **未読の数が減っていない** | 戻す |

戻ったら、人へ「合わなかったので元に戻した」と何が合わなかったかを伝える。**撃ち直さない。**

★inbox は file を1本ずつ順に移すので、途中で落ちた時に戻るのは**落ちたその1本だけ**である。★
それより前に済んだ file は移ったまま残る。便りが失われることはない (移った先に在る) が、
「全部 元に戻った」ではない。**画面に出た「残○/退避○」の行を見て、どこまで進んだかを人へ伝える。**
全部を元の姿へ戻したい時は、Step 1 で取った控えのディレクトリから手で戻すこと。

★`!!!!` の枠で **「戻せなかった。<path> は壊れたままである」** と出た時は、話が別である。★
その file は今も壊れている。**撃ち直さず、人へすぐ知らせ、手で戻すこと。**
戻し道は2本ある。控えのディレクトリと、D: の30分ごとの控えである。

人の目でも確かめる (`20260803` の所は Step 1 が出した日付に差し替える):

```bash
python3 skills/shogun-ledger-diet/scripts/scan.py                    # 残った内訳
python3 -c "import yaml;yaml.safe_load(open('queue/shogun_to_karo.yaml',encoding='utf-8'));print('台帳 読める')"
grep -c '^  read: false' queue/archive/inbox_20260803/*.yaml   # 0 でなければ未読が混ざっている = 戻す
```

### Step 6: 報せる

- 何本を残し、何本を移したか
- 退避先の path (貼り戻せば元に戻ると添える)
- 控えの path

## 戻し方

退避先の file から当該の塊 (`- id: cmd_XXXX` から次の `- id:` の直前まで) をそのまま切り取り、
正本の `commands:` の下へ貼る。**書き換えずに貼る。** 貼った後に必ず:

```bash
python3 -c "import yaml;yaml.safe_load(open('queue/shogun_to_karo.yaml',encoding='utf-8'));print('OK')"
```

全部 戻す時は控えのディレクトリから上書きする。控えは `queue/` の下と同じ形をしている。

```bash
BK=queue/archive/diet_backup_20260803_1810      # Step 1 が出した控えの path
cp "$BK"/shogun_to_karo.yaml queue/
cp "$BK"/inbox/*.yaml        queue/inbox/
cp -r "$BK"/archive/.        queue/archive/
```

## やらないこと

- **計器を作らない。** 殿の逐語 (2026-08-03) =「B:計器はいらないでしょう」。
  目方を測って見せるだけの機能・新しい監視・門・変異テストは作らない。
  `scan.py` が件数を出すのは **承認を得るために人へ見せるため**であって、常時 測るためではない。
- cmd の状態を書き換えない。移すだけである。
- cmd を消さない。
- 承認を待たずに動かない。
