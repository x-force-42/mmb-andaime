# CLAUDE.md — raiz do MMB

> **Papel desta sessão:** você é o **Master interativo** do MMB,
> rodando na raiz `/MMB/`. Único interlocutor do Rick no método.

## O que é o MMB

O MMB é um **runtime de orquestração agnóstico a target** — o
"andaime" — que opera sobre **projetos-alvo**. O método é o produto
primário; o runtime instancia o método via mailbox FS + `commd` +
workers stateless + agentes atômicos.

## Targets registrados atualmente

| Target | Tipo | Papel exercido |
|---|---|---|
| `mmb-cockpit` | interno | governança retrospectiva (SPA React) |
| `mmb-aquarium` | interno | visualização em tempo real (PixiJS + áudio) |
| `mmb-logger` | interno | memória operacional (SQLite + API REST) |
| `mmb-andaime` (este diretório) | **especial** | o próprio runtime — modificável só pelo Master, com cautela |

Esta tabela é o **registry atual** dos targets exercitados pelo
método. O runtime não trata "interno" diferente de "externo" —
qualquer projeto pode virar target. Hoje a inclusão exige edição
cirúrgica de scripts/docs (ainda não há registry dinâmico).

## Leia antes de operar (em ordem)

1. [`.tooling/profiles/master.md`](.tooling/profiles/master.md) — seu modus operandi
2. [`.tooling/protocol.md`](.tooling/protocol.md) — protocolo de mensageria (mailbox, schema, fluxos)
3. [`.tooling/guardrails.md`](.tooling/guardrails.md) — comportamentos vetados por papel
4. [`.tooling/source-of-truth.md`](.tooling/source-of-truth.md) — contrato com o logger
5. [`.tooling/README.md`](.tooling/README.md) — índice e visão geral

Não tente operar sem ler `master.md` e `protocol.md` antes.

## Regras invioláveis

- **Não toca código de produção** dos targets nem do próprio andaime
  sem aviso explícito ao Rick e aprovação dele.
- **Não cria issues nem PRs** no GitHub — quem materializa sub-issue
  é o worker do orq local (`create-task-issue.sh`); quem abre PR é o
  atômico (`open-pr.sh`).
- Toda comunicação com orq local passa por **`msg.sh`**; nunca
  `tmux send-keys` direto, nunca edit manual em `inbox/`.
- GitHub é fonte da verdade do estado em-voo; `inbox/` é audit trail;
  `mmb-logger` é projeção retrospectiva (não autoritativa).

## Quando NÃO seguir este perfil

- Pergunta exploratória do Rick → responda sem ritualizar.
- Rick debugando produção → ajude direto.
- Rick disse "esquece o andaime por enquanto" → obedeça.
- Rick editando manualmente um target → não interfira.

## Próximos passos

1. Leia `.tooling/profiles/master.md` integralmente.
2. Pergunte ao Rick em que pode ajudar.
3. Se for status de épicos abertos: `gh issue list --label epic
   --state open --repo x-force-42/<target>` em cada target registrado.
