# cmd_1339 incident — watcher pane 割当のズレによる交差配達（軍師一号 × 足軽六号）

- 発生: 2026-07-25 18:19 頃（検知 18:48 / 是正完了 18:56）
- 検知者: 軍師一号（自ら食い違いを申告）+ inbox_watcher stall_alert + 家老の pane 実査
- 影響: 軍師一号・足軽六号の **session context 喪失**（成果物・YAML・commit は無傷）
- 記録者: 家老

---

## 1. 何が起きたか

`inbox_watcher` の pane 割当が実 pane 配置とずれており、**軍師一号（pane 0.6）と足軽六号（pane 0.7）へ交差配達**されていた。

| | 実態（`@agent_id`） | watcher の割当（事故時） |
|---|---|---|
| pane 0.6 | **gunshi1** | `ashigaru6 → agents.6` ❌ |
| pane 0.7 | **ashigaru6** | `gunshi1 → agents.7` ❌ |
| pane 0.8 | gunshi2 | `gunshi2 → agents.8` ✓ |

`@agent_id` は tmux pane option であり、**SessionStart hook がこれを読んで各 CLI session に「貴殿は誰か」を告げる**。つまり `@agent_id` が自己識別の正本である。watcher だけが別の前提で動いていた。

## 2. 真因

`scripts/watcher_supervisor.sh` の `ashigaru_pane()` が

```
命名規約: ashigaru{N} → multiagent:agents.{N}
```

を **hardcode** しており、実 pane 配置がこの規約から外れた時に**誰も検知できない**構造だった。
gunshi 系は `config/settings.yaml` の `pane:` field を参照していたが、そこにも `gunshi1: multiagent:agents.7` と**実体と異なる値**が書かれていた（実体は agents.6）。

## 3. なぜ長時間気付けなかったか（ここが本質）

- **plain nudge（`inboxN`）は軽症**。CLAUDE.md の設計どおり「メッセージ本体は tmux を通らず、各 agent は自分の inbox file を読む」ゆえ、**間違った pane を起こしても、起きた agent は自分の inbox を読むだけ**で終わる。
  ⇒ 足軽六号の報告は 17:49 / 18:17 と正常に届いており、**表面上は健全に見えていた**。
- **`clear_command` は致命的**。`/clear` + 指示文を **pane へ直接送る**ため、
  **別 agent の session を吹き飛ばし、他人の task 指示を渡す**。

| 時刻 | 送信（家老の意図） | 実際の着弾 | 結果 |
|---|---|---|---|
| 18:19 | gunshi1 へ cmd_1330 patch（clear_command） | pane 0.7 = **ashigaru6** | ash6 の session が消え白紙で待機 |
| 18:20 | ashigaru6 へ cmd_1337（clear_command） | pane 0.6 = **gunshi1** | gunshi1 の session が消え、他人の task 指示を受領 |

## 4. 事故を止めたもの

軍師一号が

> 「hook は gunshi1 と申すが、指示文は ashigaru6 のタスクを指しておる — この食い違いこそ CLAUDE.md が警告する役割誤認事故の入口ゆえ、tmux で確定させる」

と**自ら食い違いを検知し、tmux で自己識別を確定させた**。
⇒ **CLAUDE.md Session Start の「Step 1 自己識別を最優先」規律が、実際の事故を止めた**。被害は context 喪失のみに留まり、**他 agent の task を実行してしまう二次事故は発生しなかった**。

## 5. 家老の是正（18:52–18:56）

交通整理（全エージェント操作権限の一元管理）ゆえ家老が直接実行した。CLAUDE.md Test Rules 4 の例外条件に該当し、理由を本 incident と台帳 evidence に明記する。

1. `scripts/watcher_supervisor.sh` に **`resolve_pane_by_agent_id()`** を新設し、**`@agent_id` を pane 解決の第一正本**とした。見つからねば従来の命名規約 / `settings.yaml` へ fallback（**回帰非破壊**）。
2. 誤 pane の watcher を停止し、正しい pane で再起動（`gunshi1 → 0.6` / `ashigaru6 → 0.7`）。
3. supervisor 再起動時に**全 agent の watcher が二重起動**したため 10 体を停止し**各 1 体へ整理**（`pgrep` dedup がこの環境で滑る瞬間があった）。
4. `config/settings.yaml` の `gunshi1.pane` を `agents.7` → `agents.6` へ是正。
5. 両者へ「**非は infra にあり貴殿にはない**」と伝え、**task YAML を唯一の正**として再開させた。

## 6. 残課題（cmd_1339 として起票・足軽/軍師へ委任予定）

1. ★**watcher の pane 割当が `@agent_id` と食い違った時に自動検知して警告する層**★
   — 今回は**事故が起きるまで誰も気付けなかった**。検知が無いことが本質である。
2. supervisor の重複起動防止（`pgrep` dedup が滑る条件の特定と、より確実な単一化）。
3. 出陣（`shutsujin`）時に pane 割当と `@agent_id` を突合する gate。

## 7. 教訓

- **「動いているように見える」は健全の証明ではない**。plain nudge が機能していたため、致命的な誤配線が隠れていた。**軽症の経路が重症の経路を覆い隠す**型の障害である。
- **自己識別規律は飾りではない**。役割誤認防止の Step 1 が、実際に二次事故を防いだ。
- **hardcode された命名規約は、実態がずれた瞬間に沈黙して壊れる**。正本（`@agent_id`）から導出する形へ寄せるのが筋。
