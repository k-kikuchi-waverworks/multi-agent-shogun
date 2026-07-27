# instructions/retired/ — 退役した役割定義（cmd_1451・2026-07-28）

**ここにある `*_role.md` は、もう誰も読みません。編集しないでください。**

## 何が起きたか

役割の指示書には正本が二本ありました。

| 読む者 | 読んでいた file |
|---|---|
| Claude | `instructions/{role}.md` |
| Codex / Copilot / Kimi / OpenCode / Cursor / Antigravity | `instructions/generated/*` = **`instructions/roles/{role}_role.md` から作られた物** |

build（`scripts/build_instructions.sh`）は `instructions/{role}.md` から YAML 頭書だけを取り、
本文は `roles/{role}_role.md` から取っていました。**ゆえに正本の本文は、Claude 以外へ一行も届きませんでした。**

正本にしか無い行の割合は shogun 56% / **karo 84%** / ashigaru 39% / gunshi 71% でした。
逆に roles にしか無い行は 190 行あり、うち 81 行は**今も生きている規**でした
（最も重いのは Critical Thinking 5 段。`shogun.md` が「軍師へ回して 5 段の検分を受けよ」と
指しているのに、指された中身がどこにも無い状態でした）。

## どう畳んだか

`instructions/{role}.md` を単一の正本とし、build がその全文を読む形へ替えました（cmd_1451 案B）。
190 行は 甲81（正本へ合流）/ 乙30（両者が食い違い・家老が一つずつ裁定）/ 丙79（退役）に分けてあります。

## 何ゆえ消さずに残すか

**丙 79 行の現物を、git 履歴を掘らずに読める形で残すためです。**
分けた理由の表は `plans/cmd_1451_dual_canon.md` §11 にありますが、`plans/` は git 管理外です。
現物がここに在れば、後の者が「本当に捨ててよい行だったか」を自分の目で検め直せます。

## 触ってよい file はどれか

- 役割の規を直す → **`instructions/{role}.md`**（正本）を直し、`bash scripts/build_instructions.sh` を撃つ
- 全 role 共通の規を直す → `instructions/common/*.md`
- CLI 固有の記述を直す → `instructions/cli_specific/*_tools.md`
- `instructions/generated/*` は生成物。**直接 編集しない**（F006）
