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
BACKUP_DIR="${QUEUE_BACKUP_DIR:-$DATA_HOME/multi-agent-shogun/queue_backup}"
# 保持本数。30 分ごとに取るなら 48 本 = 約 24 時間 前まで戻せる
KEEP="${QUEUE_BACKUP_KEEP:-48}"

TAR=/usr/bin/tar
FIND=/usr/bin/find
GREP=/usr/bin/grep
STAT=/usr/bin/stat
AWK=/usr/bin/awk
SORT=/usr/bin/sort
READLINK=/usr/bin/readlink

die() { printf 'queue_backup: %s\n' "$*" >&2; exit 2; }

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
