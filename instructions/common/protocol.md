# Communication Protocol

## Mailbox System (inbox_write.sh)

Agent-to-agent communication uses file-based mailbox.

### 既定の書き方 — ★shell を通さぬ口を使え★ (cmd_1371)

```bash
# ★これが既定である★ — 引用符つき heredoc。本文に ` も $(…) も $VAR も書けて原文どおり届く
bash scripts/inbox_write.sh <target_agent> --body-stdin <type> <from> <<'EOF'
本文をここへ。★記号を避ける必要は無い★
EOF

# 長文・引用符が入り組む本文は file 渡し (Write tool で本文を書いてから)
bash scripts/inbox_write.sh <target_agent> --content-file /path/to/body.txt <type> <from>
```

★`<<'EOF'` と単引用符で囲め★ — 裸の `<<EOF` は本文全体が展開に晒される (関所が止める)。

### 位置引数の形 (後方互換・★危うい★)

```bash
bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>

# 例 (平文のみ・記号を含まぬ時に限る)
bash scripts/inbox_write.sh karo "cmd_048を書いた。実行せよ。" cmd_new shogun
bash scripts/inbox_write.sh karo "足軽5号、任務完了。報告YAML確認されたし。" report_received ashigaru5
bash scripts/inbox_write.sh ashigaru3 "タスクYAMLを読んで作業開始せよ。" task_assigned karo
```

★この形は今も動くが、本文は shell を通る★:
- ` (backtick) は **command として実行され、その位置が出力へ置換される**
- `$(…)` も同じ / **未定義の `$VAR` は黙って空文字へ落ちる (最も危うい)**
- ★食われた証拠は道具に届く前に消える★ = 道具も受け手も気付けぬ

**記号を含むなら上の既定の形を使え。**

### 道具が毎回名乗る (信じてよい経路か)

配達のたび `[inbox_write] OK: … (経路=… 関所=… 守り=…)` が出る。
`守り` は三値で、**entry (queue/inbox/*.yaml) にも `via` / `guard` / `safety` として焼かれる**:

| 守り | 意味 |
|------|------|
| `by-construction` | shell を通っておらぬ = ★この穴が原理的に存在せぬ★ |
| `by-guard` | shell は通ったが、関所が此の経路で走っておることを確認した |
| `UNPROTECTED` | shell を通り、且つ**関所が走った証が無い** ← ★送った本文を自分の目で読み返せ★ |

★`UNPROTECTED` は「関所が死んでおる」の断定ではない★ — 走った証を我らが持たぬ、という我らの側の申告である
(存在は証せるが不在は証せぬ)。未検証を緑に混ぜぬため、言えぬ側は赤へ倒しておる。

厳格に運用したい呼び手は `IW_REQUIRE_SAFE_BODY=1` を立てよ (位置引数の本文を拒む)。

詳細と、なぜこの形になったかの実測は `docs/content/ops/cmd_1371_body_transport.md`。

Delivery is handled by `inbox_watcher.sh` (infrastructure layer).
**Agents NEVER call tmux send-keys directly.**

## Delivery Mechanism

Two layers:
1. **Message persistence**: `inbox_write.sh` writes to `queue/inbox/{agent}.yaml` with flock. Guaranteed.
2. **Wake-up signal**: `inbox_watcher.sh` detects file change via `inotifywait` → wakes agent:
   - **Priority 1**: Agent self-watch (agent's own `inotifywait` on its inbox) → no nudge needed
   - **Priority 2**: `tmux send-keys` — short nudge only (text and Enter sent separately, 0.3s gap)

The nudge is minimal: `inboxN` (e.g. `inbox3` = 3 unread). That's it.
**Agent reads the inbox file itself.** Message content never travels through tmux — only a short wake-up signal.

Safety note (shogun):
- If the Shogun pane is active (the Lord is typing), `inbox_watcher.sh` must not inject keystrokes. It should use tmux `display-message` only.
- Escalation keystrokes (`Escape×2`, context reset, `C-u`) must be suppressed for shogun to avoid clobbering human input.

Special cases (CLI commands sent via `tmux send-keys`):
- `type: clear_command` → sends context reset command via send-keys (Claude/Copilot/Kimi: `/clear`, Codex/OpenCode: `/new`)
- `type: model_switch` → sends the /model command via send-keys

## Agent Self-Watch Phase Policy (cmd_107)

Phase migration is controlled by watcher flags:

- **Phase 1 (baseline)**: `process_unread_once` at startup + `inotifywait` event-driven loop + timeout fallback.
- **Phase 2 (normal nudge off)**: `disable_normal_nudge` behavior enabled (`ASW_DISABLE_NORMAL_NUDGE=1` or `ASW_PHASE>=2`).
- **Phase 3 (final escalation only)**: `FINAL_ESCALATION_ONLY=1` (or `ASW_PHASE>=3`) so normal `send-keys inboxN` is suppressed; escalation lane remains for recovery.

Read-cost controls:

- `summary-first` routing: unread_count fast-path before full inbox parsing.
- `no_idle_full_read`: timeout cycle with unread=0 must skip heavy read path.
- Metrics hooks are recorded: `unread_latency_sec`, `read_count`, `estimated_tokens`.

**Escalation** (when nudge is not processed):

| Elapsed | Action | Trigger |
|---------|--------|---------|
| 0〜2 min | Standard pty nudge | Normal delivery |
| 2〜4 min | Escape×2 + nudge | Copilot/Kimi use Escape×2 + Ctrl-C + nudge. Claude/Codex/OpenCode use a plain nudge instead |
| 4 min+ | Context reset sent (max once per 5 min, skipped for Codex) | Force session reset + YAML re-read |

## Inbox Processing Protocol (karo/ashigaru/gunshi)

When you receive `inboxN` (e.g. `inbox3`):
1. `Read queue/inbox/{your_id}.yaml`
2. Find all entries with `read: false`
3. Process each message according to its `type`
4. Update each processed entry: `read: true` (use Edit tool)
5. Resume normal workflow

### MANDATORY Post-Task Inbox Check

**After completing ANY task, BEFORE going idle:**
1. Read `queue/inbox/{your_id}.yaml`
2. If any entries have `read: false` → process them
3. Only then go idle

This is NOT optional. If you skip this and a redo message is waiting,
you will be stuck idle until the next nudge escalation or task reassignment.

## Redo Protocol

When Karo determines a task needs to be redone:

1. Karo writes new task YAML with new task_id (e.g., `subtask_097d` → `subtask_097d2`), adds `redo_of` field
2. Karo sends `clear_command` type inbox message (NOT `task_assigned`)
3. inbox_watcher delivers context reset to the agent（Claude/Copilot/Kimi: `/clear`, Codex/OpenCode: `/new`）→ session reset
4. Agent recovers via Session Start procedure, reads new task YAML, starts fresh

Race condition is eliminated: context reset wipes old context. Agent re-reads YAML with new task_id.

## Report Flow (interrupt prevention)

| Direction | Method | Reason |
|-----------|--------|--------|
| Ashigaru/Gunshi → Karo | Report YAML + inbox_write | File-based notification |
| Karo → Shogun/Lord | dashboard.md update only | **inbox to shogun FORBIDDEN** — prevents interrupting Lord's input |
| Karo → Gunshi | YAML + inbox_write | Strategic task delegation |
| Top → Down | YAML + inbox_write | Standard wake-up |

## File Operation Rule

**Always Read before Write/Edit.** Claude Code rejects Write/Edit on unread files.

## Inbox Communication Rules

### Sending Messages

```bash
bash scripts/inbox_write.sh <target> "<message>" <type> <from>
```

**No sleep interval needed.** No delivery confirmation needed. Multiple sends can be done in rapid succession — flock handles concurrency.

### Report Notification Protocol

After writing report YAML, notify Karo:

```bash
bash scripts/inbox_write.sh karo "足軽{N}号、任務完了でござる。報告書を確認されよ。" report_received ashigaru{N}
```

That's it. No state checking, no retry, no delivery verification.
The inbox_write guarantees persistence. inbox_watcher handles delivery.
