#!/usr/bin/env bash
#
# dashboard_archive.sh — 殿の頁 (dashboard.md) の、印より下を控えへ移す (cmd_1470)
#
# 何のためか:
#   dashboard.md は 897KB (2026-07-28T18:11 実測) に育ち、読み取り道具の上限 256KB を
#   超えた。家老は己の頁を一度に読めない。読めないので畳めず、畳めないので更新が遅れ、
#   遅れると番人に /clear を撃たれる。2026-07-28 17:42 に現に起きた。
#
# 何を機械にさせないか:
#   ★何処で切るかは機械が決めない。★ 家老が頁の中へ印を 1 行 置き、この道具は
#   その行より下だけを移す。刻でも綴り (🚨 等) でも判じない。理由は実測してある =
#   頁が己で「過去ログ」と名乗っている 1,919 行の中に 🚨 が 48 行・殿の手番が 25 行
#   在る。綴りで止めれば 1 バイトも移せず、止めなければ生きた物を移す。どちらへ倒しても
#   機械だけでは決まらない (plans/cmd_1470_dashboard_diet.md §6)。
#
# 印:
#   KARO_CUT_HERE を含む HTML の註 (<!-- ... -->) を 1 行。家老が置く。
#   ★印の行より上は 1 バイトも触らない。★ 書いた後に機械が己で検め、1 バイトでも
#   違えば控えから戻す。
#   ★印の行そのものは移す側に入る (消費する)。★ 残すと次の走行が同じ所で空撃ちを
#   繰り返すためである。次に畳む時は、家老が新しい印を置く。
#
# この道具がしないこと (覆っていない範囲・条G):
#   ・踏む回数を減らさない。★頁が縮むのは「家老が印を 1 行 置いた時」だけである。★
#     置かれない間に増えるのは、気づける確率だけである (条H)。
#   ・移した物を消さない。だが移した先 (archive/) は git の追跡下に無く、
#     `git clean -xd` 一手で消える側に在る。控えは scripts/queue_backup.sh が
#     30 分ごとに木の外へ取っている (cmd_1466・足軽一号)。★この道具はそれに依っている。★
#   ・切った中身が正しいかを判じない。判じるのは印を置いた家老である。
#
# 撃ち方:
#   dashboard_archive.sh              何をするかだけ刷る (既定。1 バイトも書かない)
#   dashboard_archive.sh --apply      現に移す
#   dashboard_archive.sh --canary     探し方が生きている証を立てる (陽性と陰性の両方)
#   dashboard_archive.sh --file PATH  対象を差し替える (試験用)
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 素の道具を名指しで呼ぶ。対話の pane では grep が shell 関数に差し替わっており
# (中身は ugrep --ignore-files)、.gitignore で無視される file を黙って走査から外す。
# dashboard.md は現に無視の対象である。
GREP=/usr/bin/grep
STAT=/usr/bin/stat
WC=/usr/bin/wc
HEAD=/usr/bin/head
TAIL=/usr/bin/tail
CP=/usr/bin/cp
TOUCH=/usr/bin/touch
DATE=/bin/date
SHASUM=/usr/bin/sha256sum
MKTEMP=/usr/bin/mktemp
FLOCK=/usr/bin/flock

MARKER='KARO_CUT_HERE'
MIN_HEAD_LINES="${DASHBOARD_ARCHIVE_MIN_HEAD:-50}"   # 印がこれより上に在れば、頁を丸ごと移す事故と見て止める

DASH="$REPO/dashboard.md"
ARCHIVE_DIR="$REPO/archive"
APPLY=0
MODE=run

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        APPLY=1 ;;
    --dry-run)      APPLY=0 ;;
    --canary)       MODE=canary ;;
    # 既定の対象がどこを指しているかだけを刷って、すぐ畢わる。
    # ★書く道の手前で畢わる。★ 試験がこの口を使えば、道具のどこが壊れていても
    # 現物の dashboard.md へは届かない (2026-07-28 18:17 に現に踏んだ形の手当て)。
    --show-target)  MODE=show ;;
    --file)         DASH="$2"; shift ;;
    --archive-dir)  ARCHIVE_DIR="$2"; shift ;;
    -h|--help)      $GREP -E '^#' "${BASH_SOURCE[0]}" | $HEAD -45; exit 0 ;;
    *)              printf 'dashboard_archive: 知らぬ引数 %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '[dashboard_archive] %s\n' "$*"; }
die()  { printf '[dashboard_archive] ✗ %s\n' "$*" >&2; exit "${2:-2}"; }

now()      { $DATE '+%Y-%m-%d %H:%M:%S'; }
sha_of()   { $SHASUM "$1" | /usr/bin/cut -d' ' -f1; }
bytes_of() { $STAT -c '%s' "$1"; }

# ── 探し方が生きている証 (陽性と陰性の両方を撃つ) ──────────────────────
canary() {
  local rc=0 f="$DASH"
  say "canary — 探し方が生きているかを撃つ (対象 = $f)"
  [ -f "$f" ] || die "対象が無い: $f" 2

  # 陽性: 必ず 1 件 当たる綴り。0 なら走査そのものが死んでいる。
  local hit; hit=$($GREP -c '^# 🏯' "$f" || true)
  printf '  陽性 (必ず当たる綴り "^# 🏯")      : %s 件 (期待 1 件以上)\n' "$hit"
  [ "$hit" -ge 1 ] || { printf '  ⇒ 赤: 走査が死んでいる公算\n'; rc=1; }

  # 陰性: 決して当たらない綴り。当たれば探し方が広すぎる。
  local miss; miss=$($GREP -c 'ZZZ_NEVER_PRESENT_ZZZ' "$f" || true)
  printf '  陰性 (決して当たらぬ綴り)          : %s 件 (期待 0 件)\n' "$miss"
  [ "$miss" -eq 0 ] || { printf '  ⇒ 赤: 探し方が広すぎる\n'; rc=1; }

  local n; n=$($GREP -c "$MARKER" "$f" || true)
  printf '  印 (%s) の本数              : %s 件\n' "$MARKER" "$n"
  printf '  大きさ                             : %s byte / %s 行\n' "$(bytes_of "$f")" "$($WC -l < "$f")"
  printf '  採取の刻                           : %s\n' "$(now)"
  return $rc
}

if [ "$MODE" = show ]; then
  printf '対象   = %s\n' "$DASH"
  printf '控え先 = %s\n' "$ARCHIVE_DIR"
  printf '印     = %s\n' "$MARKER"
  exit 0
fi

[ "$MODE" = canary ] && { canary; exit $?; }

# ── 走る ────────────────────────────────────────────────────────────
[ -f "$DASH" ] || die "対象が無い: $DASH" 2
[ -r "$DASH" ] || die "対象が読めぬ: $DASH" 2

# 家老が同時に頁を書く形が在る。控えの間に書かれると、書かれた分を落とす。
LOCK="${TMPDIR:-/tmp}/dashboard_archive.lock"
exec 9>"$LOCK" 2>/dev/null || true
if [ -e /proc/self/fd/9 ]; then
  $FLOCK -w 30 9 || die "他の走行が掛かっている (30 秒 待った)" 2
fi

TOTAL_LINES=$($WC -l < "$DASH")
TOTAL_BYTES=$(bytes_of "$DASH")
SHA_BEFORE=$(sha_of "$DASH")
STAMP=$(now)

say "採取の刻 = $STAMP"
say "対象 = $DASH ($TOTAL_BYTES byte / $TOTAL_LINES 行)"

# ── 守り 1: 印が無ければ 1 バイトも移さない ──────────────────────────
# ★「印が無い」を黙って緑にしない。★ 見る物が 0 本の時に、そう名乗る。
MARK_COUNT=$($GREP -c "$MARKER" "$DASH" || true)
if [ "$MARK_COUNT" -eq 0 ]; then
  say "印 ($MARKER) が無い ⇒ ★1 バイトも移さぬ★"
  say "  頁を畳むには、家老が切りたい所へ次の 1 行を置く:"
  say "  <!-- $MARKER  置いた者=karo  刻=$($DATE '+%Y-%m-%dT%H:%M') -->"
  # 100KB は既に在る目安 (scripts/context_cleanup_diagnose.sh) をそのまま使う。新しい数を作らない。
  if [ "$TOTAL_BYTES" -gt 102400 ]; then
    say "  なお頁は $TOTAL_BYTES byte で、既存の目安 100KB (102400 byte) を超えている"
  fi
  exit 0
fi

# ── 守り 2: 印が 2 本以上なら、どちらで切るか機械には決められない ──────
if [ "$MARK_COUNT" -ge 2 ]; then
  say "印が $MARK_COUNT 本 在る ⇒ ★止まる。1 バイトも移さぬ★"
  say "  どちらで切るかは機械には決められない。家老が 1 本に減らすこと。"
  $GREP -n "$MARKER" "$DASH" | /usr/bin/sed 's/^/    /'
  exit 3
fi

MARK_LINE=$($GREP -n "$MARKER" "$DASH" | $HEAD -1 | /usr/bin/cut -d: -f1)

# ── 守り 3: 印が頁の頭に在れば、頁を丸ごと移す事故と見て止める ─────────
if [ "$MARK_LINE" -le "$MIN_HEAD_LINES" ]; then
  say "印が $MARK_LINE 行目 (頭から $MIN_HEAD_LINES 行以内) ⇒ ★止まる。1 バイトも移さぬ★"
  say "  頁を丸ごと移す形に見える。意図した物なら、印を下げるか閾値を明示すること。"
  exit 4
fi

KEEP_LINES=$((MARK_LINE - 1))          # 印より上 = ここは 1 バイトも触らない
CUT_LINES=$((TOTAL_LINES - KEEP_LINES)) # 印の行を含めて、これより下を移す

TMPDIR_RUN=$($MKTEMP -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT
HEAD_PART="$TMPDIR_RUN/head"
CUT_PART="$TMPDIR_RUN/cut"
NEW_PART="$TMPDIR_RUN/new"

$HEAD -n "$KEEP_LINES" "$DASH" > "$HEAD_PART"
$TAIL -n +"$MARK_LINE" "$DASH" > "$CUT_PART"

KEEP_BYTES=$(bytes_of "$HEAD_PART")
CUT_BYTES=$(bytes_of "$CUT_PART")
SHA_HEAD_BEFORE=$(sha_of "$HEAD_PART")

# ── 守り 4: 移す中身が空 (印より下が空白だけ) なら、何もしない ────────
if [ "$($GREP -c '[^[:space:]]' "$CUT_PART" || true)" -le 1 ]; then
  say "印より下に、移す中身が無い ⇒ ★1 バイトも移さぬ★"
  exit 0
fi

ARCHIVE_FILE="$ARCHIVE_DIR/dashboard_archive_$($DATE '+%Y%m%d').md"
BACKUP_FILE="$ARCHIVE_DIR/dashboard_backup_$($DATE '+%Y%m%d_%H%M%S').md"

# 移した後に頁へ残す 1 行。指し先は綴りで書く (行番号を焼かない)。
POINTER="> 📦 これより古い記録は \`archive/$(/usr/bin/basename "$ARCHIVE_FILE")\` に在ります (移した刻 = $STAMP)"

# 印より下に 🚨 の見出しが幾つ在るかは、止める理由にしない (§6 で測った)。
# ★だが黙って移さない。★ 幾つ移すかを必ず名乗る。
CUT_ALERT=$($GREP -c '^#\{1,4\} .*🚨' "$CUT_PART" || true)
CUT_HEADS=$($GREP -c '^#\{1,4\} ' "$CUT_PART" || true)

say "印 = $MARK_LINE 行目"
say "  残る (印より上) : $KEEP_LINES 行 / $KEEP_BYTES byte  ← ★1 バイトも触らぬ★"
say "  移す (印より下) : $CUT_LINES 行 / $CUT_BYTES byte"
say "  移す中の見出し  : $CUT_HEADS 本 (うち 🚨 を含む見出し $CUT_ALERT 本)"
say "  移す先          : $ARCHIVE_FILE"
if [ -f "$ARCHIVE_FILE" ]; then
  say "  移す先は既に在る ($(bytes_of "$ARCHIVE_FILE") byte) ⇒ ★追記する。上書きしない★"
fi
say "  控え            : $BACKUP_FILE"

if [ "$APPLY" -eq 0 ]; then
  say "★空撃ちである。1 バイトも書いていない。★ 現に移すには --apply を付けよ"
  exit 0
fi

# ── ここから現に書く ────────────────────────────────────────────────
mkdir -p "$ARCHIVE_DIR" || die "控えの置き場を作れぬ: $ARCHIVE_DIR" 2

# 控えを先に取る。戻せる形にしてから撃つ。-p で最終書込の刻も写す (後で戻すのに使う)。
$CP -p "$DASH" "$BACKUP_FILE" || die "控えを取れぬ" 2
[ "$(bytes_of "$BACKUP_FILE")" -eq "$TOTAL_BYTES" ] || die "控えの大きさが元と違う。1 バイトも書かぬ" 8

# ── 守り 5: 控えを取る間に家老が書いていないか ────────────────────────
if [ "$(sha_of "$DASH")" != "$SHA_BEFORE" ]; then
  say "控えを取る間に頁が書き替わった ⇒ ★止まる。1 バイトも移さぬ★"
  rm -f "$BACKUP_FILE"
  exit 5
fi

ARCHIVE_BEFORE=0
[ -f "$ARCHIVE_FILE" ] && ARCHIVE_BEFORE=$(bytes_of "$ARCHIVE_FILE")

# 控えへ追記する。★追記のみ。既存の控えを消す道は持たせない。★
{
  printf '\n\n<!-- ===== %s に dashboard.md から移した (%s 行 / %s byte) ===== -->\n' \
         "$STAMP" "$CUT_LINES" "$CUT_BYTES"
  /usr/bin/cat "$CUT_PART"
} >> "$ARCHIVE_FILE" || die "控えへ追記できぬ。頁へは 1 バイトも書いていない" 7

ARCHIVE_AFTER=$(bytes_of "$ARCHIVE_FILE")
if [ "$ARCHIVE_AFTER" -lt "$((ARCHIVE_BEFORE + CUT_BYTES))" ]; then
  die "控えへ移した量が足りぬ ($ARCHIVE_BEFORE → $ARCHIVE_AFTER)。頁へは 1 バイトも書いていない" 7
fi

# 新しい頁を組む。印より上 + 指し先の 1 行。
{ /usr/bin/cat "$HEAD_PART"; printf '%s\n' "$POINTER"; } > "$NEW_PART"

# 書く前に、組んだ物の頭が元と 1 バイトも違わないかを検める。
if [ "$(sha_of <($HEAD -n "$KEEP_LINES" "$NEW_PART"))" != "$SHA_HEAD_BEFORE" ]; then
  die "組んだ頁の頭が元と違う。頁へは 1 バイトも書いていない" 6
fi

# ★書き替えは in-place で行う (inode を替えない)。★
# mv で置き換えると、既に開いている inotifywait の見張りが古い inode に残り、
# 家老の次の更新が将軍に届かなくなる。scripts/stop_hook_inbox.sh は将軍の pane で
# dashboard.md を close_write で見張っている。
if ! /usr/bin/cat "$NEW_PART" > "$DASH"; then
  $CP -p "$BACKUP_FILE" "$DASH"
  die "頁を書けなんだ。控えから戻した" 6
fi

# ── 書いた後に、己で検める ──────────────────────────────────────────
FAIL=""
[ "$(sha_of <($HEAD -n "$KEEP_LINES" "$DASH"))" = "$SHA_HEAD_BEFORE" ] || FAIL="印より上が変わった"
[ "$($WC -l < "$DASH")" -eq "$((KEEP_LINES + 1))" ]                    || FAIL="${FAIL:-行数が合わぬ}"
if [ -n "$FAIL" ]; then
  $CP -p "$BACKUP_FILE" "$DASH"
  die "検めに落ちた ($FAIL)。控えから戻した。控えは $BACKUP_FILE に残す" 6
fi

# 最終書込の刻を元へ戻す。戻さないと番人 (scripts/idle_revive_scan.py) が
# dashboard.md の mtime を見て「家老が今さっき働いた」と読む。止まっている家老を
# 止まっていないと読む向きで、これは安全側ではない (cmd_1467・軍師一号の指摘)。
# 足軽三号が同じ手を scripts/slim_yaml.py で先に据えており、それを写した。
$TOUCH -r "$BACKUP_FILE" "$DASH" || say "⚠ 最終書込の刻を戻せなかった (番人の目が 20 分 曇る)"

NEW_BYTES=$(bytes_of "$DASH")
say "★移した★ $CUT_LINES 行 / $CUT_BYTES byte → $ARCHIVE_FILE"
say "  頁 : $TOTAL_BYTES → $NEW_BYTES byte (減 $((TOTAL_BYTES - NEW_BYTES)))"
say "  控え: $BACKUP_FILE ($TOTAL_BYTES byte・★消していない★)"
say "  最終書込の刻 = $($STAT -c '%y' "$DASH") (元へ戻した)"
exit 0
