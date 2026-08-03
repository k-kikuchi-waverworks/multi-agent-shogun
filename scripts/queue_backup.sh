#!/usr/bin/env bash
# queue/ と、同じ一手で消える殿の頁を repo の木の外へ控える (cmd_1466)
#
# ■ 何を控えるか (実測 2026-07-28T18:1x)
#   queue/         913 本 / 21.79 MiB   台帳・task YAML・報告・queue/archive
#   dashboard.md   897,623 byte         殿の頁。queue/dashboard.md は此処を指す symlink で、
#                                       link と指す先が同じ一手で消える
#   archive/       14 本 / 2.85 MiB     四号が cmd_1470 で殿の頁の古い節を攫う先
#
# ■ 何を守るか
#   `git clean -xd` を一手 撃つと queue/ が丸ごと消える。queue/ 配下は 1 本も git の
#   追跡下に無いためである (実測 2026-07-28T17:57 = `git ls-files queue` が 0 本)。
#   同じ一手で消える物 = 台帳 shogun_to_karo.yaml / 全エージェントの task YAML と報告 /
#   queue/archive / 番号の払い出しの記録。
#
# ■ この守りが「しないこと」(覆っていない範囲)
#   消えるのを止めない。消えた後に戻せるようにするだけである。
#   ゆえに失う分は「最後に控えを取ってから今まで」に限られる。0 にはならない。
#   止める側の案 (queue/ を追跡下へ入れる) は撃った上で採らなかった。理由は
#   plans/cmd_1466_queue_wipe_guard.md に書いた。
#
# ■ 控えの置き場を木の外にした理由
#   守りの避難先が、守るべき事故の射程の中に在ってはならない。
#   置き場 = $XDG_DATA_HOME/multi-agent-shogun/queue_backup (既定 ~/.local/share/…)。
#   repo は /mnt/c (Windows 側)、置き場は WSL 側の別 file system である。
#
# ■ 素の binary を絶対 path で呼ぶ理由
#   対話 pane の grep は shell 関数 (ugrep --ignore-files) へ差し替わっている場合がある。
#   この repo の .gitignore は `*` の白名簿なので、数えたい未追跡ファイルが走査から落ちる。
#   ここでは /usr/bin/ 配下の素の道具だけを使う。
#
# 使い方:
#   queue_backup.sh              控えを 1 本 取り、古い物を保持本数まで減らす
#   queue_backup.sh --verify     最新の控えから現に戻せるかを撃つ (queue/ へは書かない)
#   queue_backup.sh --canary     探し方が生きている証を立てる (陽性と陰性の両方)
#   queue_backup.sh --list       今 在る控えと、いつ消えるかを刷る
#   queue_backup.sh --dry-run    何をするかだけ刷って、1 バイトも書かない
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# 置き場は D: にする (cmd_1466・家老の命 18:24)。
#   理由 = WSL の / の実体は C:\Users\...\wsl\{…}\ext4.vhdx で、repo と同じ物理 disk の上に在る。
#   木の外ではあるが別の disk ではないので、C: が飛べば控えも一緒に消える。
#   D: は別の物理 disk で、現に mount されており書ける (実測 18:25 = 空き 1.1T / 1.9T 中 44% 使用)。
BACKUP_DIR="${QUEUE_BACKUP_DIR:-/mnt/d/backup/multi-agent-shogun/queue_backup}"
# 移す前の置き場。古い控えは消さずに此処へ残す
LEGACY_BACKUP_DIR="$DATA_HOME/multi-agent-shogun/queue_backup"
# 保持本数。30 分ごとに取るなら 48 本 = 約 24 時間 前まで戻せる
KEEP="${QUEUE_BACKUP_KEEP:-48}"

# plans/ の写し先 (cmd_1588・2026-08-02 殿の裁「含めていいよ」)。
#
# ■ なぜ tar へ同梱せず、別に鏡を置くか
#   plans/ は 3,983 本 / 375 MB あり、tar.gz にすると 188 MB・14 秒 掛かる。
#   30 分ごとに 48 本 保つと、ほぼ同じ中身の 188 MB が 48 本 = 約 9 GB になる。
#   rsync の差分なら 2 回目以降は 4 秒・数 KB で済む (実測 2026-08-02 20:08)。
#   queue/ の控えは「git clean -xd で消える」に備える物で、速さが値打ちである。
#   そこへ 14 秒を足すのは割に合わない。
#
# ■ なぜ --delete を付けないか
#   元から消えた稿を、鏡からも消してしまう。控えとしては逆である。
#   ゆえに足すだけにする。鏡は元より増えることはあっても減らない。
#
# ■ なぜ git へ入れないか
#   CLAUDE.md が plans/ の commit を禁じている (OSS 本家へ出るため)。控えは D: 側だけで取る。
PLANS_MIRROR="${PLANS_MIRROR_DIR:-/mnt/d/backup/multi-agent-shogun/plans}"
RSYNC=/usr/bin/rsync

TAR=/usr/bin/tar
FIND=/usr/bin/find
GREP=/usr/bin/grep
STAT=/usr/bin/stat
AWK=/usr/bin/awk
SORT=/usr/bin/sort
READLINK=/usr/bin/readlink

die() { printf 'queue_backup: %s\n' "$*" >&2; exit 2; }

# 置き場が /mnt/<英字1文字>/ の下に在る時、その drive が現に mount されているかを確かめる。
#
# なぜ「dir が在るか」では足りないか:
#   D: が mount されていなくても /mnt/d という空の dir は残る。そこへ書くと、
#   ★書けたつもりで、実は WSL の root (= C: の中の vhdx) へ落ちている★形になる。
#   控えを C: から D: へ逃がした意味が、黙って消える。ゆえに mount そのものを見る。
#
# 見えなければ落とす。既定の置き場へ勝手に戻さない (黙って戻すと、上の形をこの script が自分で作る)。
require_mount() {
  local dir="$1"
  case "$dir" in
    /mnt/?/*|/mnt/?) : ;;
    *) return 0 ;;   # /mnt/ の下でなければ、この検めの対象外 (砂場での試験など)
  esac
  local root; root="$(printf '%s' "$dir" | /usr/bin/cut -d/ -f1-3)"   # /mnt/d
  if ! $GREP -qE " ${root} " /proc/mounts; then
    printf 'queue_backup: ★%s が mount されていない★\n' "$root" >&2
    printf '  控え先 = %s\n' "$dir" >&2
    printf '  ここへ書くと、書けたつもりで WSL の root (C: の中の vhdx) へ落ちる。\n' >&2
    printf '  ゆえに落とす。既定の置き場へは勝手に戻さない。\n' >&2
    printf '  mount を戻すか、QUEUE_BACKUP_DIR で置き場を名指しで替えよ。\n' >&2
    exit 3
  fi
}

now() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# queue/inbox は木の外を指す symlink である。link そのものは git clean で消えるが
# 指す先は消えない。とはいえ同じ資産ゆえ、控えには指す先の中身も一緒に入れる。
inbox_target() {
  [ -L "$REPO/queue/inbox" ] || return 1
  local t; t="$($READLINK -f "$REPO/queue/inbox" 2>/dev/null)"
  [ -n "$t" ] && [ -d "$t" ] && printf '%s' "$t"
}

# queue/ の他に、同じ一手で消えて、かつ小さい物を一緒に控える。
# dashboard.md は queue/dashboard.md が指す先で、link だけ控えても中身が残らない。
# archive/ は四号が cmd_1470 で殿の頁の古い節を攫う先である (家老 18:11 の便)。
EXTRA_PATHS=(dashboard.md archive)

existing_extras() {
  local p
  for p in "${EXTRA_PATHS[@]}"; do
    [ -e "$REPO/$p" ] && printf '%s\n' "$p"
  done
}

newest_archive() {
  $FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f 2>/dev/null \
    | $SORT | /usr/bin/tail -1
}

# 控えの中の file 本数 (dir の行は除く)。0 なら「中身が無い」と名指せる
archive_count() {
  $TAR -tzf "$1" 2>/dev/null | $GREP -vc '/$'
}

cmd_list() {
  printf '採取刻   = %s\n' "$(now)"
  printf '置き場   = %s\n' "$BACKUP_DIR"
  printf '保持本数 = %s 本\n' "$KEEP"
  # 移す前の置き場に残っている分も刷る。消していないことが目で分かるようにする
  if [ -d "$LEGACY_BACKUP_DIR" ] && [ "$LEGACY_BACKUP_DIR" != "$BACKUP_DIR" ]; then
    printf '移す前の置き場 (%s) に残っている控え = %s 本 (消していない)\n' \
      "$LEGACY_BACKUP_DIR" \
      "$($FIND "$LEGACY_BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f 2>/dev/null | $GREP -c .)"
  fi
  local n; n=$($FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f 2>/dev/null | $GREP -c .)
  printf '今 在る  = %s 本\n' "$n"
  if [ "$n" -eq 0 ]; then
    printf '⚠ 控えが 1 本も無い。今 queue/ が消えたら戻せない\n'
    return 1
  fi
  printf '\n古い順:\n'
  $FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f -printf '%TY-%Tm-%Td %TH:%TM  %10s byte  %f\n' \
    2>/dev/null | $SORT
  printf '\nいつ消えるか: %s 本を超えると、古い順にこの script 自身が消す。\n' "$KEEP"
  printf '  ⇒ 最も古い控えは、控えを取る間隔 × %s だけ前までしか遡れない。\n' "$KEEP"
  local oldest; oldest=$($FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f 2>/dev/null | $SORT | /usr/bin/head -1)
  [ -n "$oldest" ] && printf '  現に今 最も古い控え = %s\n' "$(basename "$oldest")"
  return 0
}

cmd_canary() {
  local rc=0
  printf '採取刻 = %s\n\n' "$(now)"
  printf '=== 陽性 — 探し方が現に当たる証 ===\n'

  local live_files; live_files=$($FIND "$REPO/queue" -type f 2>/dev/null | $GREP -c .)
  printf '  queue/ の file 本数            : %s (期待 1 本以上)\n' "$live_files"
  [ "$live_files" -ge 1 ] || { printf '  ⇒ 赤: queue/ が 1 本も見えない。走査が死んでいる公算\n'; rc=1; }

  local ledger="$REPO/queue/shogun_to_karo.yaml"
  printf '  台帳が現に在るか              : %s (期待 在り)\n' "$([ -f "$ledger" ] && echo 在り || echo 無し)"
  [ -f "$ledger" ] || { printf '  ⇒ 赤: 台帳が見えない\n'; rc=1; }

  # 追跡下が 0 本であること自体が、この守りが要る理由である
  local tracked; tracked=$(cd "$REPO" && git ls-files queue 2>/dev/null | $GREP -c .)
  printf '  queue/ で git の追跡下の本数  : %s (0 なら git clean -xd で丸ごと消える側)\n' "$tracked"

  # queue/ の外だが同じ一手で消える物。追跡下に無ければ控える要が在る
  local p
  for p in "${EXTRA_PATHS[@]}"; do
    if [ -e "$REPO/$p" ]; then
      printf '  %-13s : 在り / 追跡下 %s 本 (0 なら控える要が在る)\n' "$p" \
        "$(cd "$REPO" && git ls-files "$p" 2>/dev/null | $GREP -c .)"
    else
      printf '  %-13s : 無し (控えの対象から自動で外れる)\n' "$p"
    fi
  done

  printf '\n=== 陰性 — 在らぬ物が現に出ない証 ===\n'
  local ghost; ghost=$($FIND "$REPO/queue" -name 'no_such_file_zzz_canary' -type f 2>/dev/null | $GREP -c .)
  printf '  在らぬ名で探した本数          : %s (期待 0)\n' "$ghost"
  [ "$ghost" -eq 0 ] || { printf '  ⇒ 赤: 在らぬ物が出た。走査の当て方が誤っている\n'; rc=1; }

  local ghost_arch; ghost_arch=$($FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_no_such_zzz.tar.gz' -type f 2>/dev/null | $GREP -c .)
  printf '  在らぬ控えを探した本数        : %s (期待 0)\n' "$ghost_arch"
  [ "$ghost_arch" -eq 0 ] || rc=1

  printf '\n判定: %s\n' "$([ "$rc" -eq 0 ] && echo 緑 || echo 赤)"
  return $rc
}

cmd_backup() {
  local dry="${1:-}"
  [ -d "$REPO/queue" ] || die "queue/ が無い: $REPO/queue"

  local stamp; stamp=$(date '+%Y%m%d_%H%M%S')
  local out="$BACKUP_DIR/queue_${stamp}.tar.gz"
  local tgt; tgt="$(inbox_target || true)"
  local extras; mapfile -t extras < <(existing_extras)

  printf '採取刻 = %s\n' "$(now)"
  printf '控え先 = %s\n' "$out"
  printf '同梱   = queue/ %s\n' "$(printf '%s ' "${extras[@]:-}")"
  if [ -n "$tgt" ]; then
    printf '         と、queue/inbox が指す先 %s\n' "$tgt"
  else
    printf '         ★queue/inbox の symlink が辿れなかった。便の中身は控えに入っていない★\n'
  fi

  # 置き場の drive が現に mount されているかを、書く前に見る
  require_mount "$BACKUP_DIR"

  printf 'plans の鏡 = %s (足すだけ・消さない)\n' "$PLANS_MIRROR"

  if [ "$dry" = "--dry-run" ]; then
    printf '乾式ゆえ 1 バイトも書かない\n'
    return 0
  fi

  mkdir -p "$BACKUP_DIR" || die "置き場を作れない: $BACKUP_DIR"

  # symlink は辿らず link のまま入れる (-h を付けない)。
  # 台帳は数分おきに書き替わるので、読んでいる最中に変わることがある。
  # tar はそれを警告 (rc=1) にする。中身が壊れるわけではないので、警告は名乗った上で通す。
  local rc
  if [ -n "$tgt" ]; then
    $TAR -czf "$out" \
      --warning=no-file-changed \
      -C "$REPO" queue "${extras[@]}" \
      -C "$(dirname "$tgt")" "$(basename "$tgt")"
    rc=$?
  else
    $TAR -czf "$out" --warning=no-file-changed -C "$REPO" queue "${extras[@]}"
    rc=$?
  fi

  if [ "$rc" -ge 2 ]; then
    rm -f "$out"
    die "tar が落ちた (rc=$rc)。壊れた控えは置かずに消した"
  fi
  [ "$rc" -eq 1 ] && printf '註: 読んでいる最中に書き替わった file が在る (tar rc=1)。控えは作れている\n'

  [ -f "$out" ] || die "控えが出来ていない: $out"

  # 控えが空でないことを、その場で数えて確かめる。
  # 「取れた」と「中身が入っている」は別である。
  local n; n=$(archive_count "$out")
  local live; live=$($FIND "$REPO/queue" -type f 2>/dev/null | $GREP -c .)
  printf '控えの中の file : %s 本\n' "$n"
  printf 'queue/ の生     : %s 本 (symlink は別に %s 本)\n' "$live" \
    "$($FIND "$REPO/queue" -type l 2>/dev/null | $GREP -c .)"
  printf '大きさ          : %s MiB\n' "$($STAT -c %s "$out" | $AWK '{printf "%.2f", $1/1048576}')"
  if [ "$n" -lt "$live" ]; then
    printf '⚠ 控えの本数が生より少ない。取りこぼしている公算\n'
  fi
  if [ "$n" -eq 0 ]; then
    rm -f "$out"
    die "控えの中が空だった。置かずに消した"
  fi

  # 保持本数まで減らす。何を消したかを黙って済ませない
  local all; all=$($FIND "$BACKUP_DIR" -maxdepth 1 -name 'queue_*.tar.gz' -type f 2>/dev/null | $SORT)
  local total; total=$(printf '%s\n' "$all" | $GREP -c .)
  if [ "$total" -gt "$KEEP" ]; then
    local drop=$((total - KEEP))
    printf '保持 %s 本を超えた (今 %s 本)。古い順に %s 本 消す:\n' "$KEEP" "$total" "$drop"
    printf '%s\n' "$all" | /usr/bin/head -n "$drop" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '  消す: %s\n' "$(basename "$f")"
      rm -f "$f"
    done
  else
    printf '保持 %s 本以内 (今 %s 本)。消す物は無い\n' "$KEEP" "$total"
  fi

  # plans/ の鏡を更新する。ここで落ちても queue/ の控えは既に出来ているので、
  # 全体を落とさず、落ちたことだけ名乗って先へ進む。
  mirror_plans

  # ★ここが最後である。ここより後に処理を足さないこと★ (cmd_1465 の丙)
  #   走り畢えた刻を 1 行 残す。log の更新時刻は途中で死んでも動くので証にならない。
  #   軍師二号が「落ちた時に気付く口が log だけ」と名指した所を、これで塞ぐ。
  #   書く場所は $QUEUE_STAMP_DIR で差し替えられる (試験が本番の証を汚さないため)。
  write_end_stamp
  return 0
}

# plans/ を D: へ写す。足すだけで、鏡からは 1 バイトも消さない。
#
# この鏡が守る物 = 殿へお出しした数の裏付けである。
#   155日/190本/25MiB・813件中790件・pool 243/257・段Aの640本 — どれも根拠は plans/ の中にしか無い。
#   plans/ は git の追跡外 (CLAUDE.md が commit を禁じている)・queue_backup の tar にも入っておらず、
#   2026-08-02 まで C: 一枚の上にしか存在しなかった。
mirror_plans() {
  local src="$REPO/plans"
  if [ ! -d "$src" ]; then
    printf 'plans/ が無いので鏡は更新しない\n'
    return 0
  fi
  if [ ! -x "$RSYNC" ]; then
    printf '⚠ rsync が無く plans/ の鏡を更新できない (%s)\n' "$RSYNC" >&2
    return 0
  fi
  # 置き場の drive が現に mount されているかを、書く前に見る。
  # ここを飛ばすと、D: が落ちている時に WSL の root (= C: の中の vhdx) へ静かに落ちる。
  require_mount "$PLANS_MIRROR"
  mkdir -p "$PLANS_MIRROR" || { printf '⚠ 鏡の置き場を作れない: %s\n' "$PLANS_MIRROR" >&2; return 0; }

  local out
  out="$($RSYNC -a --stats "$src/" "$PLANS_MIRROR/" 2>&1)"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '⚠ plans/ の鏡の更新が落ちた (rsync rc=%s)。queue/ の控えは出来ている\n' "$rc" >&2
    return 0
  fi
  # 「写した」と「現に在る」は別なので、両側を数えて並べる
  local n_src n_dst
  n_src=$($FIND "$src" -type f 2>/dev/null | $GREP -c .)
  n_dst=$($FIND "$PLANS_MIRROR" -type f 2>/dev/null | $GREP -c .)
  printf 'plans の鏡    : %s (元 %s 本 / 鏡 %s 本・今回 %s 本 写した)\n' \
    "$PLANS_MIRROR" "$n_src" "$n_dst" \
    "$(printf '%s' "$out" | $AWK -F': *' '/Number of regular files transferred/{print $2}')"
  if [ "$n_dst" -lt "$n_src" ]; then
    printf '⚠ 鏡の本数が元より少ない。写し切れていない公算\n'
  fi
  return 0
}

# 終わりの証を 1 行 書く。書き手と読み手の形を 1 箇所に寄せるため、
# 名前の付け方は scheduled_liveness_check.py に持たせてある (この script は呼ぶだけ)。
write_end_stamp() {
  local py stamp_args=()
  py="$([ -x "$REPO/.venv/bin/python3" ] && echo "$REPO/.venv/bin/python3" \
        || command -v python3 || true)"
  if [ -z "$py" ]; then
    printf '⚠ python3 が無く、終わりの証を書けなかった。次の見張りで「証を持たない」と鳴る\n' >&2
    return 0
  fi
  [ -n "${QUEUE_STAMP_DIR:-}" ] && stamp_args=(--logs-dir "$QUEUE_STAMP_DIR")
  if ! "$py" "$REPO/scripts/scheduled_liveness_check.py" \
        --stamp queue_backup "${stamp_args[@]}"; then
    # 書けなかったことを黙らせない (次の走行で「証が無い」と鳴った時、
    # 何ゆえ無いのかを辿る手掛かりがここに残る)
    printf '⚠ 終わりの証を書けなかった。次の見張りで「証を持たない」と鳴る\n' >&2
  fi
  return 0
}

cmd_verify() {
  printf '採取刻 = %s\n' "$(now)"
  local arch; arch="$(newest_archive)"
  if [ -z "$arch" ]; then
    printf '⚠ 控えが 1 本も無い。「戻せる」と言えない\n'
    return 1
  fi
  printf '検める控え = %s\n' "$arch"

  local n; n=$(archive_count "$arch")
  printf '控えの中の file = %s 本\n' "$n"
  if [ "$n" -eq 0 ]; then
    printf '⚠ 赤: 控えの中が空である。在るだけで、戻せない\n'
    return 1
  fi

  # 現に戻してみる。戻す先は捨てる場所で、queue/ へは 1 バイトも書かない
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/queue_verify_XXXXXX")" || die "作業場を作れない"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  if ! $TAR -xzf "$arch" -C "$work" 2>/dev/null; then
    printf '⚠ 赤: 控えを開けない\n'
    return 1
  fi

  local restored; restored=$($FIND "$work/queue" -type f 2>/dev/null | $GREP -c .)
  printf '現に戻した file = %s 本\n' "$restored"
  if [ "$restored" -eq 0 ]; then
    printf '⚠ 赤: 開けたが queue/ が 1 本も出てこない\n'
    return 1
  fi

  # 1 本 取り出して、今の正本と中身が一致するかを見る。
  # 「戻せる」と「戻して正しい」は別である (条A)。
  local rc=0
  local probe="queue/cmd_owner_record.yaml"
  [ -f "$REPO/$probe" ] || probe="queue/shogun_to_karo.yaml"
  if [ -f "$work/$probe" ] && [ -f "$REPO/$probe" ]; then
    if /usr/bin/cmp -s "$work/$probe" "$REPO/$probe"; then
      printf '突き合わせ: %s は今の正本と一致\n' "$probe"
    else
      printf '突き合わせ: %s は今の正本と違う (控えを取った後に書き替わった分。控えの刻を見よ)\n' "$probe"
    fi
  else
    printf '⚠ 赤: 突き合わせる %s が控えの中に無い\n' "$probe"
    rc=1
  fi

  # 台帳が控えの中に在り、中身を持つこと
  if [ -s "$work/queue/shogun_to_karo.yaml" ]; then
    printf '台帳      : 控えの中に在り、%s byte\n' "$($STAT -c %s "$work/queue/shogun_to_karo.yaml")"
  else
    printf '⚠ 赤: 台帳が控えの中に無いか、空である\n'
    rc=1
  fi

  # queue/ の外だが同じ一手で消える物も、中身を持って入っていること。
  # dashboard.md は queue/dashboard.md が指す先で、link だけでは中身が残らない。
  local p
  for p in $(existing_extras); do
    if [ -e "$work/$p" ]; then
      if [ -f "$work/$p" ] && [ ! -s "$work/$p" ]; then
        printf '⚠ 赤: %s が控えの中で空である\n' "$p"; rc=1
      elif [ -L "$work/$p" ]; then
        printf '⚠ 赤: %s が控えの中で symlink のままである (中身が入っていない)\n' "$p"; rc=1
      else
        printf '%-9s : 控えの中に在り、中身を持つ\n' "$p"
      fi
    else
      printf '⚠ 赤: %s が控えの中に無い\n' "$p"; rc=1
    fi
  done

  # plans/ の鏡も「在る」でなく「現に戻せる」で見る。
  # tar と違い鏡は開く手間が無いので、本数を並べて 1 本 中身を突き合わせる。
  printf '\n--- plans の鏡 ---\n'
  if [ ! -d "$PLANS_MIRROR" ]; then
    printf '⚠ 赤: 鏡が無い: %s\n' "$PLANS_MIRROR"; rc=1
  else
    local ps pd
    ps=$($FIND "$REPO/plans" -type f 2>/dev/null | $GREP -c .)
    pd=$($FIND "$PLANS_MIRROR" -type f 2>/dev/null | $GREP -c .)
    printf '元 %s 本 / 鏡 %s 本\n' "$ps" "$pd"
    [ "$pd" -ge "$ps" ] || { printf '⚠ 赤: 鏡の方が少ない。写し切れていない\n'; rc=1; }

    # 1 本 取り出して中身を突き合わせる。最も新しい物を選ぶ
    # (最後に写した分が届いているかが、いちばん知りたい所ゆえ)。
    local newest rel
    newest=$($FIND "$REPO/plans" -type f -printf '%T@ %p\n' 2>/dev/null | $SORT -rn | /usr/bin/head -1 | /usr/bin/cut -d' ' -f2-)
    if [ -n "$newest" ]; then
      rel="${newest#"$REPO/plans/"}"
      if [ -f "$PLANS_MIRROR/$rel" ] && /usr/bin/cmp -s "$newest" "$PLANS_MIRROR/$rel"; then
        printf '突き合わせ: %s は鏡と一致\n' "$rel"
      elif [ -f "$PLANS_MIRROR/$rel" ]; then
        printf '突き合わせ: %s は鏡と違う (写した後に書き替わった分。鏡の刻を見よ)\n' "$rel"
      else
        printf '⚠ 赤: 最も新しい %s が鏡に無い\n' "$rel"; rc=1
      fi
    fi
  fi

  printf '\n判定: %s\n' "$([ "$rc" -eq 0 ] && echo '緑 = 今 現に戻せる' || echo '赤 = 戻せない')"
  printf 'この判定が答えないこと: 控えを取った刻より後の書き替えは、この控えに入っていない\n'
  return $rc
}

case "${1:-}" in
  --verify)  cmd_verify ;;
  --canary)  cmd_canary ;;
  --list)    cmd_list ;;
  --dry-run) cmd_backup --dry-run ;;
  "")        cmd_backup ;;
  *)         die "知らない引数: $1" ;;
esac
