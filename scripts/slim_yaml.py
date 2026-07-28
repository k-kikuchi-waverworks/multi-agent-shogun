#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For Karo: Archives completed task/report files and finished command queue entries.
- For all agents: Archives read: true messages from inbox files.
"""

import os
import re
import sys
import time
from datetime import date, datetime, timedelta
from pathlib import Path

import yaml

# ★canonical = 「常駐の持ち場」= 終端に達しても file を消さず idle stub へ戻す相手★。
# 非 canonical は終端で ★file ごと archive へ移される★ (= 次の /clear 復帰で読む物が無い)。
#
# ★cmd_1395/1397 (2026-07-27): gunshi1/gunshi2 の追随漏れを是正★
#   cmd_652 (2026-05-16) で軍師が 2 人体制 (gunshi1/gunshi2) になった時、此の表が追随しておらなんだ。
#   ★実害は仮定ではない (写しの盤面で実走して確かめた)★:
#     ・queue/tasks/gunshi2.yaml は status=done で現に在り ⇒ 次の家老 cycle で ★file ごと消えておった★
#     ・壊れた gunshi1_report.yaml は load_yaml が {} を返し「非 active」と判じられ ★archive へ攫われた★
#       (壊れる頻度も此の二人が 1 位 28 件・2 位 27 件 = 最も落ちる者が最も守られておらなんだ)
#   ★gunshi_a / gunshi_b は加えぬ★= 旧 2 人体制の deprecated alias であり status='archived' (非終端) ゆえ
#     slim_tasks は元より触れぬ。canonical へ入れれば ★居らぬ pane の idle stub を毎 cycle 立て直す★ =
#     退場した者を帳簿の上で蘇らせる形になる。
#   ★karo.yaml は本任の scope 外ゆえ触れておらぬ★= 但し同じ形の危うさが在る (非 canonical ゆえ
#     status が done になった日に file ごと消える)。今は status='archived' で当たっておらぬ。家老へ具申済。
#   ★karo を加えた (家老の裁 2026-07-27 01:41)★= ★家老の task file が「done になった日に file ごと
#     消える」形は、家老の state が消える形である★。家老は /clear 復帰時に queue/ から state を建て直す
#     立場ゆえ、己の task file が消えるのが最も痛い。★而も家老は毎 cycle 己の手で此の道具を撃っておる★。
#   ★ashigaru7 / ashigaru8 は【既に canonical に居る】= 上の range(1, 9) が拾っておる★。
#     ⇒ ★家老が gunshi_a/b・ashigaru7 に当てた理屈 (実在せぬ agent の stub を立てるな) を通すなら、
#       此の二人は canonical から【外す】側である★ (ashigaru7 は pane 廃止済・★ashigaru8 は task file
#       すら存在せぬ★)。★但し之は「加えるな」でなく「外せ」であり、家老は外せとは命じておらぬゆえ
#       触れておらぬ★ = 具申に留める (挙動を変える判断は道具の持ち主が下すべきゆえ)。
CANONICAL_TASKS = {f'ashigaru{i}' for i in range(1, 9)} | {'gunshi', 'gunshi1', 'gunshi2', 'karo'}
CANONICAL_REPORTS = ({f'ashigaru{i}_report' for i in range(1, 9)}
                     | {'gunshi_report', 'gunshi1_report', 'gunshi2_report'})
IDLE_STUB = {'task': {'status': 'idle'}}
TOP_LEVEL_IDLE_STUB = {'status': 'idle'}
# ★status の語彙は【ファイル種別ごとに別】である (cmd_1463)★
# 正本 = instructions/common/task_flow.md の「Status is defined per YAML file type」の項。
# 台帳の 8 値は instructions/karo.md の「slim entry schema v2」の項と、
#   scripts/cmd_id_alloc.sh の --status を検める case 文が綴りまで同一。
#   探し方 = grep -n "pending|in_progress|deferred|done|superseded|archived|dispatched|cancelled" scripts/cmd_id_alloc.sh
# 台帳の終端の別は instructions/common/task_flow.md の「Archive Rule」の項と、
#   instructions/karo.md の「剪定対象 = 終端 status」の行。
# ★行番号で指さぬ★ = 正本が1行 動いた瞬間に別の行を指すゆえ (条F の末尾)。
#   現に 2026-07-28 の時点で、此の註が書いておった cmd_id_alloc.sh:238 は
#   8 値の行ではなく die の行を指しておった (軍師一号が検分で見つけた)。
#
# ★2026-07-28 まで、此の道具は【1 組の語彙を 3 種の file へ当てておった】★:
#   旧 TERMINAL = {done, cancelled, paused} / 旧 ACTIVE = {pending, in_progress, blocked}
#   ・paused と blocked は台帳の 8 値に無い (paused は文書から消えた後も機械に残っておった)
#   ・superseded / archived / dispatched / deferred は 8 値に在るのに機械が知らず、
#     ★正本どおりに書かれた entry を機械が "non-canonical" と刷った★ (実測 105 件・2026-07-28 08:0x)
#   ・害の向きは 2 つ = ①終端 (superseded/archived) が剪定されず積む
#     ②同じ集合が active の計算にも使われ、終端 cmd を「まだ active」と数える
#     (= その cmd の報告が slim_reports の剪定から外れ続ける)
#
# ★分けねばならぬ理由 (此処が本件の芯)★= 台帳の 8 値をそのまま task file へ当てると
#   status='archived' の task file (karo.yaml / ashigaru7.yaml / gunshi_a.yaml / gunshi_b.yaml) が
#   ★終端と読まれて file ごと archive へ移る★。下の CANONICAL_TASKS の註が「archived ゆえ当たっておらぬ」と
#   書いておるのは其の事であり、語彙を 1 組のまま直せば ★家老の task file が消える★。
CMD_TERMINAL_STATUSES = {'done', 'superseded', 'cancelled', 'archived'}
CMD_ACTIVE_STATUSES = {'pending', 'in_progress', 'deferred', 'dispatched'}
# 足軽 task file。正本 = instructions/common/task_flow.md の
# 「タスクファイルの終端 / 非終端」の表 (cmd_1463 で明文化)。
# idle は task_id: null の置き札のみ許される値。
# ★archived を終端へ入れるな★= 現に karo.yaml / ashigaru7.yaml / gunshi_a.yaml /
#   gunshi_b.yaml の 4 本が archived で在り、終端にすると 4 本ともファイルごと
#   archive へ移って家老の状態が消える。archived は「退いた持ち場の記録」である。
TASK_TERMINAL_STATUSES = {'done', 'failed', 'cancelled'}
TASK_ACTIVE_STATUSES = {'idle', 'assigned', 'blocked', 'in_progress',
                        'pending_blocked', 'archived'}
# ntfy_inbox の語彙。正本 = instructions/common/task_flow.md の
#   「`queue/ntfy_inbox.yaml`: `pending`, `processed`」の行。
#   ★行番号で指さぬ★ = 行が動いた瞬間に別の物を指すゆえ (条F。同じ罠を上の註でも踏んだ)。
NTFY_TERMINAL_STATUSES = {'processed'}
INVENTORY_AGE_SECONDS = 30 * 86400
# 掃除を見送る冷却期間 (cmd_1467)。
# 2026-07-28 08:09:28 に掃除を撃った時、その瞬間 status: done だった足軽2名の帳面が
# 中身2行まで削られた。done は「もう要らない」ではなく「次の指示を待っている」状態で、
# 掃除はその区別を持っていなかった。控え94本を測ると、6回に1回 (17.0%) は
# 足軽が5分以内に書いた帳面を消していた。
#
# そこで「最後に書かれてから一定の時間が経っていない帳面は見送る」を入れる。
# 刻が読めない時も見送る = 消してよいと言い切れない物を消さない。
#
# ★2時間より長くしてはいけない★
# 見送りは「後で掃除する」ではない。閾値を越える頃には次の指示で上書きされて
# もう終端ではなくなるので、長くすると掃除が二度と当たらなくなる。
# gunshi1 / gunshi2 / karo は一度も掃除が当たっておらず、gunshi2 の帳面がいちばん大きい。
# その大きさで session の開始が読み切れなかった実例が在る (2026-07-28 08:0x)。
# ★byte 数を焼かぬ★ = 帳面は書かれるたび育つゆえ (CLAUDE.md 条F の族)。
#   現に 08:0x の 123,085 byte は、同日 13:04 に測ると 133,915 byte であった。
#   今の大きさを知りたければ `ls -l queue/tasks/*.yaml` を撃て。
# 2時間は、今朝の2件 (24.5分・39.5分) を覆えて、かつ見送りが多くなりすぎない線である。
TASK_SLIM_COOLDOWN_SECONDS = 2 * 3600

# ここから下 = 報告 (queue/reports/*.yaml) の古い節を移す仕組み (cmd_1467)。
#
# なぜ要るか。CANONICAL_REPORTS に名が載っている報告は、上の除外表で掃除が
# 打ち切られる。表そのものは正しく、外すと「終端で file ごと消えて次の /clear 復帰で
# 読む物が無い」という既知の事故を作り直す。
# しかし外れた結果、育っている9本が9本とも一度も畳まれず、読む口の上限
# (25,000 token) を越えた。越えると、開いた者は全文を読めない。
#
# そこで「file を攫うか」ではなく「節を攫うか」へ替える。file は残し、中の古い節だけを
# queue/archive/reports/ へ移す。file が消えないので上の事故は起きない。
#
# ★本文を字のまま切り出す。yaml で読み書きし直さない★
# 読み書きし直すと註と block scalar が書き換わる。実測 (2026-07-28 17:2x) =
# ashigaru3_report.yaml で註 38 行が消え、block scalar 226 箇所が別の綴りになった。
# 「古い節だけ移す」はずが、残す側の中身まで変わる。ゆえに行を切る形にし、
# 切った後に「残った中身が元と同じか」を機械で検めてから書く。
#
# ★迷ったら移さない★ = 刻が読めない節・今 動いている cmd を名指す節・
# 検めが合わない file は、そのまま残す。
REPORT_SECTION_KEEP_DAYS = 1
# 節の名や中身に焼かれた刻。20260728_0729 / 20260728 / 2026-07-28 の3綴りを見る。
SECTION_DATE_RE = re.compile(r'(20\d{2})[-_]?(\d{2})[-_]?(\d{2})')
# 節の中から刻を探す時に見る欄。1段だけ潜る。
SECTION_DATE_KEYS = ('timestamp', 'updated_at', 'time', 'date', 'ts')


def load_yaml(filepath):
    """Safely load YAML file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        print(f"Error parsing {filepath}: {e}", file=sys.stderr)
        return {}


def save_yaml(filepath, data):
    """Safely save YAML file."""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        return True
    except Exception as e:
        print(f"Error writing {filepath}: {e}", file=sys.stderr)
        return False


def get_timestamp():
    """Generate archive filename timestamp."""
    return datetime.now().strftime('%Y%m%d%H%M%S')


def get_queue_dir():
    override = os.environ.get('SHOGUN_QUEUE_DIR')
    if override:
        return Path(override).resolve()
    return Path(__file__).resolve().parent.parent / 'queue'


def get_item_status(item):
    """Return status from current top-level YAML or legacy task.status YAML."""
    if not isinstance(item, dict):
        return ''
    if item.get('status') is not None:
        return str(item.get('status'))
    task = item.get('task')
    if isinstance(task, dict) and task.get('status') is not None:
        return str(task.get('status'))
    return ''


def uses_legacy_task_status(data):
    return isinstance(data, dict) and isinstance(data.get('task'), dict) and 'status' in data['task'] and 'status' not in data


def get_item_field(item, key):
    """タスク YAML から項目を1つ読む。2つの書式の両方に対応する。

    書式は2つある。現行はキーがトップレベルに並ぶ形、旧い方は task: の下に
    入れ子になる形。get_item_status と同じ読み方をそろえてある。status だけ
    両対応で他の項目は片方しか読まない、という食い違いを防ぐため。
    """
    if not isinstance(item, dict):
        return None
    if item.get(key) is not None:
        return item.get(key)
    task = item.get('task')
    if isinstance(task, dict):
        return task.get(key)
    return None


def timestamp_to_iso(stamp):
    """アーカイブのファイル名に使う14桁を、人が読める日時へ直す。

    ファイル名に使うのと同じ文字列から作る。別々に now() を呼ぶと、
    ファイル名の日時と中に書く日時が1秒ずれる日が来る。
    """
    try:
        return datetime.strptime(str(stamp), '%Y%m%d%H%M%S').isoformat(timespec='seconds')
    except ValueError:
        return None


def idle_stub_for(stem, data, archive_name=None, archived_at=None):
    """終わったタスク YAML を、待機状態を示す短いファイルに置き換える。

    この短いファイルを空にしない (cmd_1467)。

    2026-07-28 08:09:28 に家老がこのスクリプトを実行した時、ちょうど status: done
    だった足軽2名 (一号・六号) のタスク YAML が、中身2行だけのファイルになった。
    スクリプトは仕様どおりに動いており、誤ったのは作業中に実行した側である。

    問題の中心は「仕事を終えた直後の人ほど記録が消える」ことである。done は
    「もう要らない」ではなく「次の指示を待っている」状態なのに、この片付け処理は
    その区別を持っていない。

    そこで待機ファイルに4つ残す。status を idle にすること自体は変えない
    (タスクは実際に終わっており、次を待つ状態は idle が正しい)。残すのは
    「誰が」「何を終えて」「全文はどこにあり」「いつ時点の写しか」である。

      last_task_id     直前に終えたタスクの ID
      last_parent_cmd  その親の cmd 番号
      archived_from    全文を保存したアーカイブのファイル名
      archived_at      そのアーカイブを取った日時

    archived_from と archived_at は、足軽六号が指摘した点への答えである。
    指摘は「復元する時は、いつ時点のアーカイブから復元したかを1行書くこと。
    消えたタスク YAML から復元すると、消えた後にやった仕事が見えない」。
    アーカイブの日時が待機ファイルに書いてあれば、その日時より後の report や
    commit を調べるだけで「写しに入っていない仕事」が機械的に分かる。六号は
    git log を見て偶然気づいたが、気づかなければ同じ作業を二度やっていた。

    アーカイブ側には書き足さない。アーカイブは rename で元のファイルがそのまま
    入るので、コメントも原文のまま残る。これは記録そのものなので、後から書き
    足して変えない。参照先は今も使われている側のファイルに書く。読む人が最初に
    開くのはそちらだからである。

    元から task_id を持たないタスク YAML では、その項目を足さない。無い項目を
    空文字で埋めると、「項目はあるが空」と「元から無い」が見分けられなくなる。
    """
    carried = {}
    last_task_id = get_item_field(data, 'task_id')
    last_parent_cmd = get_item_field(data, 'parent_cmd')
    if last_task_id is not None:
        carried['last_task_id'] = last_task_id
    if last_parent_cmd is not None:
        carried['last_parent_cmd'] = last_parent_cmd
    if archive_name:
        carried['archived_from'] = archive_name
    if archived_at:
        carried['archived_at'] = archived_at

    if uses_legacy_task_status(data):
        inner = dict(IDLE_STUB['task'])
        inner.update(carried)
        return {'task': inner}

    stub = dict(TOP_LEVEL_IDLE_STUB)
    if stem in CANONICAL_TASKS:
        stub['worker_id'] = stem
    stub.update(carried)
    return stub


def is_old_timestamp(value, now=None, age_seconds=INVENTORY_AGE_SECONDS):
    if not value:
        return False
    now = now or datetime.now().astimezone()
    text = str(value)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return False
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return (now - parsed).total_seconds() >= age_seconds


def print_inventory(message):
    print(f"[INVENTORY] {message}", file=sys.stderr)


def print_hold(message):
    """掃除を見送った物を名乗る。

    黙って見送ると「消えなかった」と「そもそも見ていない」が同じ顔になる。
    2026-07-28 の事故に気づけたのは、家老が別件で python を落としたからで偶然であった。
    """
    print(f"[HOLD] {message}")


def get_task_slim_cooldown_seconds():
    """冷却期間 (秒) を返す。試験と運用で差し替えられるよう環境変数も見る。"""
    raw = os.environ.get('SHOGUN_TASK_SLIM_COOLDOWN_SECONDS')
    if raw is None or raw == '':
        return TASK_SLIM_COOLDOWN_SECONDS
    try:
        return max(0, int(raw))
    except ValueError:
        print_inventory(
            f"SHOGUN_TASK_SLIM_COOLDOWN_SECONDS が数として読めない ('{raw}')。"
            f"既定の {TASK_SLIM_COOLDOWN_SECONDS} 秒を使う"
        )
        return TASK_SLIM_COOLDOWN_SECONDS


def task_slim_hold_reason(filepath, cooldown_seconds, now=None):
    """掃除を見送るなら理由の文、掃除してよいなら None を返す。

    判定はファイルの最終書込で行う。タスク YAML は updated_at をほとんど持たず
    (控え94本のうち読めたのは2本だけ)、全部に在る刻がこれしかないためである。

    ★刻が読めない時は見送る側へ倒す。★
    """
    if cooldown_seconds <= 0:
        return None
    try:
        mtime = filepath.stat().st_mtime
    except OSError as exc:
        return f"最終書込の刻が読めない ({exc.__class__.__name__}) ため見送る"
    current = datetime.now().timestamp() if now is None else now
    age = current - mtime
    if age < cooldown_seconds:
        return (f"最後に書かれてから {age / 60:.1f} 分 しか経っていない "
                f"(冷却 {cooldown_seconds / 60:.0f} 分)")
    return None


def get_active_cmd_ids():
    """Return command IDs in shogun_to_karo that are not terminal."""
    queue_dir = get_queue_dir()
    shogun_file = queue_dir / 'shogun_to_karo.yaml'
    data = load_yaml(shogun_file)

    key = 'commands' if 'commands' in data else 'queue'
    commands = data.get(key, []) if isinstance(data, dict) else []
    if not isinstance(commands, list):
        return set()

    active = set()
    for cmd in commands:
        if not isinstance(cmd, dict):
            continue
        if cmd.get('id') is None:
            continue
        if get_item_status(cmd) in CMD_TERMINAL_STATUSES:
            continue
        active.add(cmd.get('id'))
    return active


def inventory_commands(commands):
    unknown = []
    old_active = []
    for cmd in commands:
        if not isinstance(cmd, dict):
            continue
        status = get_item_status(cmd) or 'unknown'
        cmd_id = cmd.get('id', '<missing-id>')
        if status not in CMD_TERMINAL_STATUSES and status not in CMD_ACTIVE_STATUSES:
            unknown.append(f"{cmd_id}:{status}")
        if status in CMD_ACTIVE_STATUSES and is_old_timestamp(cmd.get('timestamp')):
            old_active.append(f"{cmd_id}:{status}:{cmd.get('timestamp')}")

    if unknown:
        print_inventory("non-canonical command status: " + ", ".join(unknown))
    if old_active:
        print_inventory("old non-terminal commands kept for human review: " + ", ".join(old_active))


def inventory_ntfy_inbox(dry_run=False):
    """Report old ntfy entries without deleting or changing them."""
    queue_dir = get_queue_dir()
    ntfy_file = queue_dir / 'ntfy_inbox.yaml'
    if not ntfy_file.exists():
        return True

    data = load_yaml(ntfy_file)
    entries = data.get('inbox', []) if isinstance(data, dict) else []
    if not isinstance(entries, list):
        print("Error: ntfy inbox is not a list", file=sys.stderr)
        return False

    old_pending = []
    old_terminal = []
    for item in entries:
        if not isinstance(item, dict):
            continue
        status = get_item_status(item) or 'unknown'
        item_id = item.get('id', '<missing-id>')
        if is_old_timestamp(item.get('timestamp')):
            if status in NTFY_TERMINAL_STATUSES:
                old_terminal.append(f"{item_id}:{status}")
            else:
                old_pending.append(f"{item_id}:{status}")

    prefix = "[DRY-RUN] " if dry_run else ""
    if old_pending:
        print_inventory(prefix + "old ntfy pending/non-terminal entries kept: " + ", ".join(old_pending))
    if old_terminal:
        print_inventory(prefix + "old ntfy terminal entries available for explicit cleanup: " + ", ".join(old_terminal))
    return True


def ensure_parent_dir(path):
    path.parent.mkdir(parents=True, exist_ok=True)


def archive_taskspec(filepath, archive_path, data, dry_run=False):
    if dry_run:
        print(f"[DRY-RUN] would archive: {filepath}")
        print(f"[DRY-RUN] would write: {archive_path}")
        return True

    ensure_parent_dir(archive_path)
    if not save_yaml(archive_path, data):
        return False

    if filepath.name in archive_path.name:
        return True
    return filepath.rename(archive_path)


def slim_tasks(dry_run=False):
    queue_dir = get_queue_dir()
    tasks_dir = queue_dir / 'tasks'
    archive_dir = queue_dir / 'archive' / 'tasks'

    if not tasks_dir.exists():
        return True

    timestamp = get_timestamp()
    cooldown = get_task_slim_cooldown_seconds()
    held = 0
    for filepath in sorted(tasks_dir.glob('*.yaml')):
        data = load_yaml(filepath)
        if not isinstance(data, dict):
            continue

        status = get_item_status(data)
        if not status:
            continue

        stem = filepath.stem
        if stem in CANONICAL_TASKS:
            if status not in TASK_TERMINAL_STATUSES:
                if status not in TASK_ACTIVE_STATUSES:
                    print_inventory(f"canonical task {filepath.name} has non-canonical status '{status}'")
                continue

            hold = task_slim_hold_reason(filepath, cooldown)
            if hold:
                print_hold(f"{filepath.name} を見送る: {hold}")
                held += 1
                continue

            archive_path = archive_dir / f'{stem}_{timestamp}.yaml'
            if not archive_taskspec(filepath, archive_path, data, dry_run=dry_run):
                return False

            # 待機ファイルにアーカイブの参照先を書く。ファイル名と日時は
            # 同じ timestamp から作る (cmd_1467)。
            stub = idle_stub_for(stem, data,
                                 archive_name=archive_path.name,
                                 archived_at=timestamp_to_iso(timestamp))

            if dry_run:
                print(f"[DRY-RUN] would overwrite: {filepath} with {stub}")
                continue

            if not save_yaml(filepath, stub):
                return False
            continue

        if status not in TASK_TERMINAL_STATUSES:
            if status not in TASK_ACTIVE_STATUSES:
                print_inventory(f"task file {filepath.name} has non-canonical status '{status}'")
            continue

        hold = task_slim_hold_reason(filepath, cooldown)
        if hold:
            print_hold(f"{filepath.name} を見送る: {hold}")
            held += 1
            continue

        archive_path = archive_dir / filepath.name
        if archive_path.exists():
            archive_path = archive_dir / f'{filepath.stem}_{timestamp}{filepath.suffix}'

        if dry_run:
            print(f"[DRY-RUN] would archive: {filepath}")
            print(f"[DRY-RUN] would move to: {archive_path}")
            continue

        ensure_parent_dir(archive_path)
        filepath.rename(archive_path)

    if held:
        print_hold(f"合わせて {held} 本 見送った (冷却 {cooldown / 60:.0f} 分)")
    return True


def get_report_section_keep_days():
    """節を手元に残す日数を返す。試験と運用で差し替えられるよう環境変数も見る。"""
    raw = os.environ.get('SHOGUN_REPORT_SECTION_KEEP_DAYS')
    if raw is None or raw == '':
        return REPORT_SECTION_KEEP_DAYS
    try:
        return max(0, int(raw))
    except ValueError:
        print_inventory(
            f"SHOGUN_REPORT_SECTION_KEEP_DAYS が数として読めない ('{raw}')。"
            f"既定の {REPORT_SECTION_KEEP_DAYS} 日を使う"
        )
        return REPORT_SECTION_KEEP_DAYS


def section_date_from_text(value):
    """字の中から日付を1つ拾う。読めなければ None。"""
    match = SECTION_DATE_RE.search(str(value))
    if not match:
        return None
    try:
        return date(int(match.group(1)), int(match.group(2)), int(match.group(3)))
    except ValueError:
        return None


def section_date(name, value):
    """節の刻を返す。読めなければ None。

    刻は2通りで引く。①節の名に焼かれた刻 ②節の中の timestamp 欄 (1段だけ潜る)。
    どちらも読めなければ None を返し、呼ぶ側は ★移さない側へ倒す★。
    """
    found = section_date_from_text(name)
    if found is not None:
        return found
    if isinstance(value, dict):
        for key in SECTION_DATE_KEYS:
            raw = value.get(key)
            if isinstance(raw, datetime):
                return raw.date()
            if isinstance(raw, date):
                return raw
            if raw is not None:
                found = section_date_from_text(raw)
                if found is not None:
                    return found
    return None


def _is_doc_separator(line):
    # ★行末の CR まで落とす★ = この repo には CRLF の file が現に混じっており、
    # '\n' だけを落とすと '---\r' が残って document の境目を見落とす。
    # 見落とすと節の割り方が読み取りと合わなくなり、file ごと見送りになる
    # (黙って切る形にはならないが、掃除が永久に当たらなくなる)。
    stripped = line.rstrip('\r\n')
    return stripped == '---' or stripped.startswith('--- ')


def _split_documents(lines):
    """行の列を document ごとに割る。返す物 = [(開始行, 終了行)]。終了行は含まない。

    中身が註と空行しかない塊は落とす。yaml もそこを document と数えないため。
    """
    bounds = []
    prev = 0
    for i, line in enumerate(lines):
        if _is_doc_separator(line):
            bounds.append((prev, i))
            prev = i + 1
    bounds.append((prev, len(lines)))
    return [(a, b) for (a, b) in bounds
            if any(l.strip() and not l.lstrip().startswith('#') for l in lines[a:b])]


def _section_ranges(lines, start, end, indent):
    """[start, end) の中で、指定の字下げに並ぶ節の行範囲を返す。

    返す物 = [(節の名, 開始行, 終了行)]。終了行は含まない。
    節の直前に続く註の行は、その節に含める (節だけ移して註を置き去りにしないため)。
    ただし ★最初の節には含めない★ = そこに在るのは file 全体の見出しであるため。

    ここで拾った名は、呼ぶ側が yaml の読み取りと突き合わせる。合わなければ file ごと
    見送る。ゆえにこの綴りの取りこぼしは、黙って中身を切る形にはならない。
    """
    heads = []
    for i in range(start, end):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if len(line) - len(line.lstrip(' ')) != indent:
            continue
        match = re.match(r"([^:#]+):(\s|$)", line[indent:])
        if not match:
            continue
        heads.append((i, match.group(1).strip().strip('\'"')))

    ranges = []
    for order, (line_no, name) in enumerate(heads):
        begin = line_no
        if order > 0:
            while begin > start and lines[begin - 1].lstrip().startswith('#'):
                begin -= 1
        ranges.append([name, begin, end])
    for order in range(len(ranges) - 1):
        ranges[order][2] = ranges[order + 1][1]
    return [tuple(r) for r in ranges]


def _container_block(lines, start, end, key):
    """字下げ 0 に並ぶ `key:` の塊が、何行目から何行目までかを返す。無ければ None。

    これが要るのは、同じ document に入れ物が2つ並ぶ形が現に在るためである。
    実例 = queue/reports/ashigaru5_report.yaml の doc0 は `report:` と
    `previous_report:` を持つ。document 全体から字下げ 2 の行を拾うと、
    両方の節が1つの入れ物の物として混ざる。
    """
    head = None
    for i in range(start, end):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if line.startswith(' '):
            continue
        match = re.match(r"([^:#]+):(\s|$)", line)
        if not match:
            continue
        if head is None:
            if match.group(1).strip().strip('\'"') == key:
                head = i
        else:
            return head + 1, i
    return None if head is None else (head + 1, end)


def _report_container(doc):
    """document の中で、節が並んでいる所を返す。

    返す物 = (節の入れ物, 字下げ)。読み取り道具 plans/cmd_1467_report_shape_scan.py と
    同じ見分け方をそろえてある。片方だけ直すと数が合わなくなるため。
    """
    if not isinstance(doc, dict):
        return None, 0
    inner = doc.get('report')
    if isinstance(inner, dict) and len(inner) > 3:
        return inner, 2
    return doc, 0


def _container_of(doc, indent):
    """字下げが分かっている時に入れ物を取り出す。

    ★節を抜いた後の document へ _report_container を当ててはいけない★ =
    あちらは「report: の下が3個より多いか」で見分けるので、節を抜いて数が減ると
    見分けが裏返り、入れ物ごと別の物を指す。元の file で決めた字下げを持ち回す。
    """
    if not isinstance(doc, dict):
        return None
    return doc.get('report') if indent else doc


def _archive_sections(docs):
    """控えに入っている節を集める。

    控えはこの道具が書いた物なので形が分かっている。字下げ 2 で書いた塊は
    `report:` 1つだけを持つ document になる。それ以外は節がそのまま並ぶ。
    """
    found = {}
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        inner = doc.get('report')
        if list(doc.keys()) == ['report'] and isinstance(inner, dict):
            found.update(inner)
        else:
            found.update(doc)
    return found


def slim_report_sections(filepath, archive_dir, timestamp, active_cmd_ids, dry_run=False):
    """報告 file は残したまま、中の古い節だけを控えへ移す。移した節の数を返す。

    ★本文を字のまま切り出す★ = yaml で読み書きし直すと註と block scalar が
    書き換わり、残す側の中身まで変わるため (この関数の上の註に実測が在る)。

    ★切った後に検めてから書く★ = 残った中身が元と1つも違わないこと、控えへ移した
    中身が元と同じことを、書く前に yaml で読み直して確かめる。合わなければ1行も書かない。
    scripts/inbox_write.sh の overflow が「捨てる前に読み戻して数を数える」形と同じ。

    ★移さないのは★ 刻が読めない節 / 今 動いている cmd を名指す節 / 器の最後の1節。
    """
    try:
        # ★newline='' で読む★ = 既定の読み方は CRLF を黙って LF へ直す。直したまま
        # 書き戻すと、古い節を移すだけのはずが file 全体の行末が入れ替わる。
        # この repo には CRLF の file が現に混じっており、実測で 7 行すべてが
        # LF へ化けた (2026-07-28 17:4x)。
        with open(filepath, encoding='utf-8', newline='') as handle:
            text = handle.read()
        stat = filepath.stat()
    except OSError as exc:
        print_hold(f"{filepath.name} を見送る: 読めない ({exc.__class__.__name__})")
        return 0
    if not text.strip():
        return 0

    try:
        docs = list(yaml.safe_load_all(text))
    except yaml.YAMLError as exc:
        print_hold(f"{filepath.name} を見送る: yaml として読めない ({exc.__class__.__name__})")
        return 0

    lines = text.splitlines(keepends=True)
    bounds = _split_documents(lines)
    if len(bounds) != len(docs):
        print_hold(f"{filepath.name} を見送る: document の数が読み取りと合わない "
                   f"(行から {len(bounds)} / yaml から {len(docs)})")
        return 0

    cutoff = date.today() - timedelta(days=max(0, get_report_section_keep_days() - 1))
    plan = []          # (doc の番号, 節の名, 開始行, 終了行, 字下げ)
    containers = []    # (doc の番号, 入れ物, 字下げ, その doc の節の列)
    held_no_date = 0   # 刻が読めなくて見送った節
    held_active = 0    # 今 動いている cmd を名指していて見送った節

    for index, ((begin, end), doc) in enumerate(zip(bounds, docs)):
        target, indent = _report_container(doc)
        if not isinstance(target, dict) or not target:
            continue
        if indent:
            block = _container_block(lines, begin, end, 'report')
            if block is None:
                print_hold(f"{filepath.name} を見送る: report: の行が見つからない (doc {index})")
                return 0
            scan_begin, scan_end = block
        else:
            scan_begin, scan_end = begin, end
        ranges = _section_ranges(lines, scan_begin, scan_end, indent)
        found = [name for name, _s, _e in ranges]
        if len(found) != len(set(found)):
            dup = sorted({n for n in found if found.count(n) > 1})
            print_hold(f"{filepath.name} を見送る: 同じ節名が二度 在る {dup} (doc {index})。"
                       f"後勝ちで先の記録が黙って消える形ゆえ、触らない")
            return 0
        if found != [str(k) for k in target.keys()]:
            print_hold(f"{filepath.name} を見送る: 節の割り方が読み取りと合わない "
                       f"(doc {index}: 行から {len(found)} / yaml から {len(target)})")
            return 0
        containers.append((index, target, indent, ranges))

        movable = []
        for name, sec_begin, sec_end in ranges:
            when = section_date(name, target.get(name))
            if when is None:
                held_no_date += 1
                continue
            if when >= cutoff:
                continue
            body = ''.join(lines[sec_begin:sec_end])
            hit = next((cmd for cmd in active_cmd_ids if cmd and cmd in body), None)
            if hit:
                held_active += 1
                continue
            movable.append((name, sec_begin, sec_end))
        # 器を空にしない。空にすると節の入れ物そのものが消え、形が変わる。
        if movable and len(movable) == len(ranges):
            stayed = movable.pop()
            print_hold(f"{filepath.name} の {stayed[0]} を残す: 器を空にしないため")
        for name, sec_begin, sec_end in movable:
            plan.append((index, name, sec_begin, sec_end, indent))

    # 見送った物を名乗る。黙って見送ると「移す物が無かった」と「見たが移さなかった」が
    # 同じ顔になる (cmd_1467 で帳面の側に入れたのと同じ理由)。
    if held_no_date or held_active:
        print_hold(f"{filepath.name} の {held_no_date + held_active} 節 を見送った "
                   f"(刻が読めない {held_no_date} / 今 動いている cmd を名指す {held_active})")

    if not plan:
        return 0

    moved_names = {}
    for index, name, _b, _e, _i in plan:
        moved_names.setdefault(index, set()).add(name)

    drop = set()
    for _index, _name, sec_begin, sec_end, _indent in plan:
        drop.update(range(sec_begin, sec_end))
    new_text = ''.join(l for i, l in enumerate(lines) if i not in drop)

    archive_parts = []
    for index, target, indent, _ranges in containers:
        rows = [row for row in plan if row[0] == index]
        if not rows:
            continue
        chunk = []
        if indent:
            chunk.append('report:\n')
        for _i, _name, sec_begin, sec_end, _ind in rows:
            chunk.append(''.join(lines[sec_begin:sec_end]))
        archive_parts.append((index, ''.join(chunk)))

    # 控えに足す行の行末は、元の file にそろえる (混ぜない)。
    newline = '\r\n' if '\r\n' in text else '\n'
    archived_at = timestamp_to_iso(timestamp) or timestamp
    header = [
        f"# {filepath.name} から古い節を移した控え (cmd_1467)",
        f"# 元 = {filepath.name} / 移した刻 = {archived_at} / 節 {len(plan)} 個",
        "# 元の file は残っている。ここに在るのは、そこから出した古い節だけである。",
        "# ★ここは queue/ の下ゆえ git 管理外である。git clean -xd で親ごと消える。★",
        "#   移す前も後も消える。この仕組みは「読めるようにする」ためで、",
        "#   「失わないようにする」ためではない。",
    ]
    body = []
    for order, (index, chunk) in enumerate(archive_parts):
        if order:
            body.append('---' + newline)
        body.append(f"# 元の document {index}" + newline)
        body.append(chunk)
    archive_text = newline.join(header) + newline + ''.join(body)

    if not _report_cut_is_faithful(filepath, new_text, archive_text, docs,
                                   containers, moved_names):
        return 0

    archive_path = archive_dir / f'{filepath.stem}_{timestamp}{filepath.suffix}'
    serial = 1
    while archive_path.exists():
        archive_path = archive_dir / f'{filepath.stem}_{timestamp}_{serial}{filepath.suffix}'
        serial += 1

    moved_bytes = len(''.join(''.join(lines[b:e]) for _i, _n, b, e, _d in plan).encode('utf-8'))
    if dry_run:
        print(f"[DRY-RUN] would move {len(plan)} sections ({moved_bytes:,} byte) "
              f"from {filepath.name} to {archive_path.name}")
        return len(plan)

    ensure_parent_dir(archive_path)
    try:
        with open(archive_path, 'w', encoding='utf-8', newline='') as handle:
            handle.write(archive_text)
        # 書けたつもりを許さない。控えを読み戻して節の数を数え、合わなければ捨てる。
        with open(archive_path, encoding='utf-8', newline='') as handle:
            back = list(yaml.safe_load_all(handle.read()))
        saved = len(_archive_sections(back))
        if saved != len(plan):
            raise RuntimeError(f"控えを読み戻したら節の数が合わない "
                               f"(控え {saved} / 移すはず {len(plan)})")
    except Exception as exc:
        print_hold(f"{filepath.name} を見送る: 控えが書けない ({exc})")
        try:
            if archive_path.exists():
                archive_path.unlink()
        except OSError:
            pass
        return 0

    try:
        with open(filepath, 'w', encoding='utf-8', newline='') as handle:
            handle.write(new_text)
    except OSError as exc:
        print(f"Error writing {filepath}: {exc}", file=sys.stderr)
        return 0

    # 最終書込の刻を元に戻す。掃除は「その agent が働いた刻」ではないため。
    # 戻さないと、番人 (scripts/idle_revive_scan.py) が報告の刻を見て
    # 「今さっき働いた」と読む。止まっている者を止まっていないと読む向きで、
    # これは安全側ではない (cmd_1467・軍師一号の指摘)。
    try:
        os.utime(filepath, (stat.st_atime, stat.st_mtime))
    except OSError as exc:
        print_inventory(f"{filepath.name} の最終書込の刻を戻せなかった ({exc.__class__.__name__})")

    print(f"[SLIM] {filepath.name}: 古い節 {len(plan)} 個 ({moved_bytes:,} byte) を "
          f"{archive_path.name} へ移した", file=sys.stderr)
    return len(plan)


def _report_cut_is_faithful(filepath, new_text, archive_text, docs, containers, moved_names):
    """切った後の本文と控えが、元と食い違っていないかを検める。

    見るのは3つ。①残った本文が yaml として読め、document の数が変わっていないか
    ②残った節の名と中身が元と1つも違わないか ③控えへ移した節の中身が元と同じか。
    1つでも合わなければ False を返し、呼ぶ側は1行も書かない。
    """
    try:
        after = list(yaml.safe_load_all(new_text))
    except yaml.YAMLError as exc:
        print_hold(f"{filepath.name} を見送る: 切った後が yaml として読めない "
                   f"({exc.__class__.__name__})")
        return False
    if len(after) != len(docs):
        print_hold(f"{filepath.name} を見送る: 切ると document の数が変わる "
                   f"({len(docs)} → {len(after)})")
        return False

    try:
        archived = list(yaml.safe_load_all(archive_text))
    except yaml.YAMLError as exc:
        print_hold(f"{filepath.name} を見送る: 控えが yaml として読めない "
                   f"({exc.__class__.__name__})")
        return False
    archived_sections = _archive_sections(archived)

    for index, target, indent, _ranges in containers:
        moved = moved_names.get(index, set())
        after_container = _container_of(after[index], indent)
        if not isinstance(after_container, dict):
            print_hold(f"{filepath.name} を見送る: 切ると節の入れ物が消える (doc {index})")
            return False
        expected = [str(k) for k in target.keys() if str(k) not in moved]
        if [str(k) for k in after_container.keys()] != expected:
            print_hold(f"{filepath.name} を見送る: 残る節の顔ぶれが変わる (doc {index})")
            return False
        for key in after_container:
            if after_container[key] != target.get(key):
                print_hold(f"{filepath.name} を見送る: 残した節 '{key}' の中身が変わる "
                           f"(doc {index})")
                return False
        for name in moved:
            if name not in archived_sections:
                print_hold(f"{filepath.name} を見送る: 移した節 '{name}' が控えに無い")
                return False
            if archived_sections[name] != target.get(name):
                print_hold(f"{filepath.name} を見送る: 移した節 '{name}' の中身が変わる")
                return False
    return True


def slim_reports(dry_run=False):
    queue_dir = get_queue_dir()
    reports_dir = queue_dir / 'reports'
    archive_dir = queue_dir / 'archive' / 'reports'

    if not reports_dir.exists():
        return True

    active_cmd_ids = get_active_cmd_ids()
    timestamp = get_timestamp()

    for filepath in sorted(reports_dir.glob('*.yaml')):
        if filepath.stem in CANONICAL_REPORTS:
            # 除外表に載っている報告は file ごと攫わない (攫うと次の /clear 復帰で
            # 読む物が無くなる)。代わりに file は残し、中の古い節だけを控えへ移す。
            slim_report_sections(filepath, archive_dir, timestamp,
                                 active_cmd_ids, dry_run=dry_run)
            continue

        data = load_yaml(filepath)
        parent_cmd = data.get('parent_cmd') if isinstance(data, dict) else None
        is_active = parent_cmd in active_cmd_ids
        is_stale = (time.time() - filepath.stat().st_mtime) >= 86400

        if not is_stale:
            continue
        if is_active:
            continue

        archive_path = archive_dir / filepath.name
        if archive_path.exists():
            archive_path = archive_dir / f'{filepath.stem}_{timestamp}{filepath.suffix}'

        if dry_run:
            print(f"[DRY-RUN] would archive: {filepath}")
            print(f"[DRY-RUN] would move to: {archive_path}")
            continue

        ensure_parent_dir(archive_path)
        filepath.rename(archive_path)

    return True


def slim_inbox(agent_id, dry_run=False):
    """Archive read: true messages from inbox file."""
    queue_dir = get_queue_dir()
    archive_dir = queue_dir / 'archive'
    inbox_file = queue_dir / 'inbox' / f'{agent_id}.yaml'

    if not inbox_file.exists():
        # Inbox doesn't exist yet - that's fine
        return True

    data = load_yaml(inbox_file)
    if not data or 'messages' not in data:
        return True

    messages = data.get('messages', [])
    if messages is None:
        # `messages:` with no value (empty inbox) parses as None
        messages = []
    if not isinstance(messages, list):
        print("Error: messages is not a list", file=sys.stderr)
        return False

    # Separate unread and archived messages
    unread = []
    archived = []

    for msg in messages:
        is_read = msg.get('read', False)
        if is_read:
            archived.append(msg)
        else:
            unread.append(msg)

    # If nothing to archive, return success without writing
    if not archived:
        return True

    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'inbox_{agent_id}_{archive_timestamp}.yaml'

    if dry_run:
        print(f"[DRY-RUN] would archive: {inbox_file}")
        print(f"[DRY-RUN] would move to: {archive_file}")
        return True

    # Write archived messages to timestamped file
    archive_data = {'messages': archived}
    if not save_yaml(archive_file, archive_data):
        return False

    # Update main file with unread messages only
    data['messages'] = unread
    if not save_yaml(inbox_file, data):
        print(f"Error: Failed to update {inbox_file}, but archive was created", file=sys.stderr)
        return False

    if archived:
        print(f"Archived {len(archived)} messages from {agent_id} to {archive_file.name}", file=sys.stderr)
    return True


def has_close_evidence(cmd):
    """剪定の条件 = 正本 instructions/karo.md の「剪定 gate」の項 (cmd_1463 で実装)。

    正本の文 = 「終端 status かつ evidence 欄に close 根拠があること」を満たす entry のみ剪定可。
    探し方 = grep -n "close 根拠" instructions/karo.md
    (★行番号で指さぬ★ = 正本が1行 動いた瞬間に別の行を指すゆえ。条F の末尾)

    ★機械が見ておるのは【欄が空でないこと】だけである★ =
    書かれた文が本当に close の根拠になっておるかは、機械には判じられぬ。
    ゆえに此の関門が防ぐのは「evidence 欄が空のまま黙って archive へ移る」形であって、
    「中身の薄い evidence」ではない。★緑の射程を狭く名乗る (条6)★。
    """
    if not isinstance(cmd, dict):
        return False
    return bool(str(cmd.get('evidence') or '').strip())


def slim_shugun_to_karo(dry_run=False):
    """Archive done/cancelled commands from shogun_to_karo.yaml."""
    queue_dir = get_queue_dir()
    archive_dir = queue_dir / 'archive'
    shogun_file = queue_dir / 'shogun_to_karo.yaml'

    if not shogun_file.exists():
        print(f"Warning: {shogun_file} not found", file=sys.stderr)
        return True

    data = load_yaml(shogun_file)
    # Support both 'commands' and 'queue' keys for backwards compatibility
    key = 'commands' if isinstance(data, dict) and 'commands' in data else 'queue'
    if not data or key not in data:
        return True

    queue = data.get(key, [])
    if not isinstance(queue, list):
        print("Error: queue is not a list", file=sys.stderr)
        return False

    inventory_commands(queue)

    # Separate active and archived commands
    active = []
    archived = []
    held = []

    for cmd in queue:
        status = get_item_status(cmd) or 'unknown'
        if status not in CMD_TERMINAL_STATUSES:
            active.append(cmd)
            continue
        if has_close_evidence(cmd):
            archived.append(cmd)
        else:
            # 剪定の条件を満たさぬゆえ移さぬ。黙って残さず名指す (cmd_1463)。
            held.append(cmd)
            active.append(cmd)

    if held:
        ids = [str(cmd.get('id', '<missing-id>')) for cmd in held]
        print_inventory(
            f"terminal but evidence is empty: {len(held)} kept in the active file "
            f"(karo.md の「剪定 gate」の条件を満たさぬ。家老が evidence を埋めるまで移さぬ) — "
            + ", ".join(ids))

    # If nothing to archive, return success without writing
    if not archived:
        return True

    # Write archived commands to timestamped file
    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'shogun_to_karo_{archive_timestamp}.yaml'

    if dry_run:
        print(f"[DRY-RUN] would archive {len(archived)} commands from {shogun_file}")
        print(f"[DRY-RUN] would write: {archive_file}")
        return True

    archive_data = {key: archived}
    if not save_yaml(archive_file, archive_data):
        return False

    # Update main file with active commands only
    data[key] = active
    if not save_yaml(shogun_file, data):
        print(f"Error: Failed to update {shogun_file}, but archive was created", file=sys.stderr)
        return False

    print(f"Archived {len(archived)} commands to {archive_file.name}", file=sys.stderr)
    return True


def slim_all_inboxes(dry_run=False):
    queue_dir = get_queue_dir()
    inbox_dir = queue_dir / 'inbox'
    if not inbox_dir.exists():
        return True

    for filepath in sorted(inbox_dir.glob('*.yaml')):
        agent_id = filepath.stem
        if dry_run:
            print(f"[DRY-RUN] processing inbox file: {filepath}")
        if not slim_inbox(agent_id, dry_run=dry_run):
            return False
        if dry_run:
            print(f"[DRY-RUN] finished inbox file: {filepath}")

    return True


def migration(dry_run=False):
    queue_dir = get_queue_dir()
    legacy_archive_dir = queue_dir / 'reports' / 'archive'
    if not legacy_archive_dir.exists():
        return True

    target_dir = queue_dir / 'archive' / 'reports'
    candidates = sorted(legacy_archive_dir.glob('*.yaml'))
    if not candidates:
        if not dry_run:
            legacy_archive_dir.rmdir()
        return True

    if dry_run:
        print(f"[DRY-RUN] would migrate: {len(candidates)} files")
        return True

    target_dir.mkdir(parents=True, exist_ok=True)
    for path in candidates:
        dest = target_dir / path.name
        path.rename(dest)

    if not any(legacy_archive_dir.iterdir()):
        legacy_archive_dir.rmdir()

    return True


def parse_arguments():
    args = [arg for arg in sys.argv[1:] if arg != '--dry-run']
    dry_run = '--dry-run' in sys.argv[1:]
    if len(args) < 1:
        print("Usage: slim_yaml.py <agent_id> [--dry-run]", file=sys.stderr)
        sys.exit(1)

    return args[0], dry_run


def main():
    """Main entry point."""
    agent_id, dry_run = parse_arguments()

    archive_dir = get_queue_dir() / 'archive'
    if not dry_run:
        archive_dir.mkdir(parents=True, exist_ok=True)

    # Process shogun_to_karo if this is Karo
    if agent_id == 'karo':
        if not slim_shugun_to_karo(dry_run=dry_run):
            sys.exit(1)
        if not migration(dry_run):
            sys.exit(1)
        if not slim_tasks(dry_run):
            sys.exit(1)
        if not slim_reports(dry_run):
            sys.exit(1)
        if not slim_all_inboxes(dry_run):
            sys.exit(1)
        if not inventory_ntfy_inbox(dry_run=dry_run):
            sys.exit(1)

    # Process inbox for all agents
    if not slim_inbox(agent_id, dry_run):
        sys.exit(1)

    sys.exit(0)


if __name__ == '__main__':
    main()
