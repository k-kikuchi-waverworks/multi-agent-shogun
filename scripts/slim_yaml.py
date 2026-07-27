#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For Karo: Archives completed task/report files and finished command queue entries.
- For all agents: Archives read: true messages from inbox files.
"""

import os
import sys
import time
from datetime import datetime
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
# ntfy_inbox (task_flow.md:18)。
NTFY_TERMINAL_STATUSES = {'processed'}
INVENTORY_AGE_SECONDS = 30 * 86400


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


def idle_stub_for(stem, data):
    if uses_legacy_task_status(data):
        return IDLE_STUB
    stub = dict(TOP_LEVEL_IDLE_STUB)
    if stem in CANONICAL_TASKS:
        stub['worker_id'] = stem
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

            archive_path = archive_dir / f'{stem}_{timestamp}.yaml'
            if not archive_taskspec(filepath, archive_path, data, dry_run=dry_run):
                return False

            if dry_run:
                print(f"[DRY-RUN] would overwrite: {filepath} with {idle_stub_for(stem, data)}")
                continue

            if not save_yaml(filepath, idle_stub_for(stem, data)):
                return False
            continue

        if status not in TASK_TERMINAL_STATUSES:
            if status not in TASK_ACTIVE_STATUSES:
                print_inventory(f"task file {filepath.name} has non-canonical status '{status}'")
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
