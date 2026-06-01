# `.tooling/` — andaime cross-repo do MMB

Diretório de **orquestração e contrato** do ecossistema MMB. Vive
fora dos 3 repos de produto (`mmb-cockpit`, `mmb-aquarium`,
`mmb-logger`) e os coordena. Não tem código de produto; existe pra ser
usado, evoluído, e — quando o ponto de inflexão chegar — absorvido ou
desligado.

## Visão geral em 3 camadas

```
┌─────────────────────────────────────────────────────────────┐
│  RICK                                                        │
│  ↕ (conversa SÓ com Mestre)                                  │
│                                                              │
│  MASTER (sessão Claude interativa, /MMB/)                    │
│  - faz curadoria + briefings                                 │
│  - NÃO toca GitHub                                           │
│  - dispara briefings via msg.sh                              │
│  ↕ (mailbox em .tooling/inbox/<dest>/)                       │
│                                                              │
│  ORQS DE PROJETO (workers stateless via commd → claude -p)   │
│  - autônomos: criam sub-issue com `create-task-issue.sh`     │
│    (injeta âncora mmb-cycle-key) + spawnam atômico           │
│  - escalam dúvidas via msg.sh master question                │
│  ↓ (spawn-atomic.sh)                                         │
│                                                              │
│  ATÔMICOS (panes efêmeros nas tabs dos projetos)             │
│  - lêem issue como prompt direto                             │
│  - executam, commitam, abrem PR via open-pr.sh               │
│    (com Closes #N obrigatório derivado de $GH_SUBISSUE)      │
│  - pane fecha em 8s                                          │
│                                                              │
│  Rick → revisa PR → mergeia                                  │
│                                                              │
│  mmb-logger → reconcile observa artefatos + projeta em DB    │
└─────────────────────────────────────────────────────────────┘
```

**Rick interage SÓ com:** a tab master, e os PRs no GitHub. Tudo no
meio acontece via mailbox FS + commd + workers stateless.

## Contratos canônicos

Quatro documentos definem o método:

| Doc | Papel |
|---|---|
| [`ontology.md`](ontology.md) | Linguagem ubíqua: vocabulário canônico do domínio (um termo PT + um EN por conceito), conjuntos fechados e regras anti-homônimo. Os demais docs deferem a ele para a *escolha do nome*. |
| [`source-of-truth.md`](source-of-truth.md) | Contrato governando o que o `mmb-logger` projeta na DB. Define matriz de fontes canônicas, dois domínios (derivado vs humano), princípios operacionais, e plano em fases. |
| [`protocol.md`](protocol.md) | Especificação do protocolo de mailbox + commd → worker stateless. |
| [`guardrails.md`](guardrails.md) | Comportamentos vetados por papel (M*/L*/A* — Master/orq/Atômico). |

Os profiles em [`profiles/`](profiles/) detalham o modus operandi de
cada papel. A âncora `mmb-cycle-key` (specificada no source-of-truth)
é o que garante linkagem determinística briefing ↔ issue ↔ PR ↔
transcript no reconcile do logger.

## O que está aqui

```
.tooling/
├── README.md                       ← este arquivo
├── ontology.md                     ← linguagem ubíqua (vocabulário canônico)
├── source-of-truth.md              ← contrato do mmb-logger
├── protocol.md                     ← protocolo mailbox + commd
├── guardrails.md                   ← comportamentos vetados (M*/L*/A*)
├── config.sh                       ← knobs centrais (sourced pelos scripts)
├── profiles/
│   ├── master.md                   ← modus operandi do mestre
│   ├── project-orchestrator.md     ← modus operandi dos orqs
│   └── atomic-agent.md             ← protocolo dos atômicos
├── templates/
│   ├── master-briefing.md          ← briefing local (não vira issue)
│   ├── task-briefing.md            ← body de sub-issue (prompt do atômico)
│   └── pr-body.md                  ← body de PR (preenchido por open-pr.sh)
├── bin/
│   ├── commd.sh                    ← daemon: inotifywait → worker
│   ├── worker.sh                   ← worker stateless (claude -p) por msg
│   ├── msg.sh                      ← envia mensagem entre sessões
│   ├── agents.sh                   ← registry de agentes + heartbeats
│   ├── log.sh                      ← journal estruturado de incidentes
│   ├── create-task-issue.sh        ← gh issue create com âncora mmb-cycle-key
│   ├── open-pr.sh                  ← push + gh pr create (Closes #N obrigatório)
│   ├── spawn-atomic.sh             ← task-start + tmux split + claude
│   ├── task-start.sh               ← worktree + branch (default branch agnóstico)
│   ├── task-end.sh                 ← cleanup pós-merge (squash detection)
│   ├── task-abort.sh               ← cleanup pré-merge (descarta)
│   ├── check-deps.sh               ← verifica PRs de deps via gh
│   ├── review-cycle.sh             ← agrega journal por épico (anti-overengineering)
│   ├── up.sh                       ← sobe layout tmux com 4+ tabs
│   ├── smoke.sh                    ← testes de sanidade do método
│   ├── reset-all.sh                ← reset total do andaime
│   ├── aquario-bridge.py/sh        ← bridge de eventos → WebSocket
│   └── lib/
│       └── pr-body.sh              ← funções puras testáveis de body
├── tests/
│   └── test-pr-body.sh             ← testes shell do lib/pr-body.sh
├── inbox/                          ← mailbox por destinatário (runtime)
│   ├── master/
│   ├── cockpit/
│   ├── aquarium/
│   └── logger/
├── state/                          ← registry de agentes + heartbeats (runtime)
├── logs/                           ← logs de workers + journal (runtime)
└── intents/                        ← histórico local de briefings (gitignored)
    └── <YYYY-MM-DD>-<slug>/
        ├── master-briefing.md
        └── briefings/
            └── <repo>-<slug>.md    ← (se cross-repo)
```

## Protocolo de mensagens

Spec completo em [`protocol.md`](protocol.md). Resumo:

- Cada mensagem é um arquivo markdown em `inbox/<destinatário>/`.
- Nome: `YYYY-MM-DDTHH-MM-SSZ_<from>_<type>_<subject>.md`.
- Frontmatter padrão: `from`, `to`, `type`, `subject`, `thread`, `created`.
- Tipos: `briefing | question | answer | status | error`.
- `commd.sh` faz `inotifywait` em todos os `inbox/<dest>/` e dispara
  `worker.sh <dest> <arquivo>` quando aparece mensagem nova.
- O worker é `claude -p` (stateless) com o profile do papel injetado
  como `--append-system-prompt`. Lê a mensagem, processa, escreve
  resumo via stdout, e termina.

Helper único de envio: `msg.sh <to> <type> <subject> <body-file> [thread]`.

## Âncora `mmb-cycle-key`

O wrapper `create-task-issue.sh` prepende a cada body de issue:

```html
<!-- mmb-cycle-key: <epic_slug>/<project_short>/<briefing_created_ts>
     mmb-briefing-file: <basename do arquivo em inbox> -->
```

Isso garante que o `mmb-logger` consiga casar briefing ↔ issue
deterministicamente, sem inferência por regex em subject (era o
paradigma anterior, hoje morto). Spec completa em
[`source-of-truth.md`](source-of-truth.md).

## `config.sh` — knobs centrais

Sourced por `up.sh`, `spawn-atomic.sh`, `task-end.sh`, `open-pr.sh`,
`msg.sh`, `commd.sh`, `worker.sh`.

| Variável | Default | Pra quê |
|---|---|---|
| `MMB_MODE` | `normal` | `normal` (Opus + high) / `balanced` (Opus master, Sonnet workers) / `fast` (Haiku + low) |
| `MMB_MODEL_MASTER` | (depende do mode) | Override pontual do Mestre |
| `MMB_MODEL_PROJECT_ORCHESTRATOR` | (depende) | Override pontual dos orqs |
| `MMB_MODEL_ATOMIC` | (depende) | Override pontual dos atômicos |
| `MMB_SKIP_PERMS` | `true` | `--dangerously-skip-permissions` no spawn |
| `MMB_GH_OWNER` | `x-force-42` | Owner GitHub dos repos |
| `MMB_TMUX_SESSION` | `mmb` | Nome da sessão tmux |
| `MMB_TMUX_SPLIT` | `-v` | Split do atômico: `-v`, `-h`, `win` |
| `MMB_HEARTBEAT_TIMEOUT` | `600` | Timeout (s) pra considerar atômico zumbi |
| `MMB_WORKER_TIMEOUT` | `1200` | Timeout duro pra `claude -p` em worker.sh |
| `MMB_COMMD_POLL_INTERVAL` | `30` | Safety net pro inotifywait perder eventos |

Override por sessão:

```bash
MMB_MODE=fast .tooling/bin/up.sh
MMB_MODEL_ATOMIC=claude-sonnet-4-6 .tooling/bin/spawn-atomic.sh mmb-cockpit 1.1 4
```

## Fluxo completo (walk)

1. Rick → tab master: *"adicionar coluna `model` em CiclosTable do mmb-cockpit"*.
2. Master lê o repo read-only, produz briefing em
   `.tooling/intents/<date>-<slug>/master-briefing.md`, mostra na conversa.
3. Rick aprova.
4. Master: `msg.sh cockpit briefing model-column <briefing-path> model-column`.
5. `commd.sh` detecta arquivo em `inbox/cockpit/`, spawna
   `worker.sh cockpit <arquivo>` = `claude -p` com profile do orq.
6. Worker do orq cockpit lê inbox + briefing, decide criar issue, roda:
   ```bash
   .tooling/bin/create-task-issue.sh mmb-cockpit <briefing-path>
   ```
   (wrapper injeta âncora `mmb-cycle-key` no body antes de chamar
   `gh issue create`).
7. Worker do orq: `spawn-atomic.sh mmb-cockpit 1.1 <issue-number>`.
   Pane do atômico nasce embaixo dele (split vertical).
8. Atômico lê issue (com âncora no body), executa, commita,
   `open-pr.sh` → push + `gh pr create` com `Closes #N` obrigatório
   + comment na issue + kill-pane em 8s.
9. Orq cockpit manda `msg.sh master status pr-aberto-N ...`.
10. Master vê resumo no pane, atualiza modelo mental.
11. Rick revê PR, mergeia.
12. Orq cockpit (próxima vez que vier ao trabalho): `task-end.sh` +
    `msg.sh master status task-fechada ...`.
13. Master marca briefing como ✅ + nota narrativa.

A qualquer momento, `cd mmb-logger && uv run mmb-logger reconcile`
materializa o estado completo em SQLite (idempotente).

## Substituibilidade das sessões

Qualquer sessão Claude pode ser desligada e reaberta sem perda
crítica. Estado vive em arquivos:

- Abre Claude em `/MMB/` → carrega `CLAUDE.md` → vira Mestre.
- Workers locais são stateless; nascem por mensagem, morrem após.
- Abre Claude em `/MMB/<repo>/.worktrees/<slug>/` → lê
  `atomic-agent.md` + brief da sub-issue → vira Atômico.

Estado em-voo:

- **GitHub** (issues, PRs) — fonte canônica de trabalho real.
- **`inbox/`** — comunicação pendente entre sessões.
- **`intents/`** — histórico de briefings produzidos.
- **`mmb-logger.db`** — projeção retrospectiva (não autoritativa).

## Quando NÃO usar este andaime

- Hotfix mínimo (1 linha) que Rick pede direto pro orq —
  modo dev tradicional.
- Pergunta exploratória / debug — conversa direta sem ritual.
- Refactor interno do próprio andaime — Rick + Mestre editam
  arquivos do `.tooling/`.

## Como este andaime evolui

Heurística: padrão se repetiu 3x do mesmo jeito → codifique.
Não codifique antes — andaime ganha peso só onde paga custo.

Quando codificar:

- Regras gerais → `profiles/<nível>.md`.
- Formato de artefato → `templates/`.
- Operação repetitiva → `bin/<nome>.sh` (com lib testável em `bin/lib/`
  quando faz sentido).
- Protocolo de comm → `protocol.md`.
- Contrato com mmb-logger → `source-of-truth.md`.

Nunca:

- Dentro dos repos de produto.
- Em `CLAUDE.md` de repo (que é contexto local, não método).

## Evolução futura — MCP

Quando o protocolo de mailbox + commd ficar limitante (provavelmente
após muitos épicos cross-repo paralelos), considerar migração pra
MCP server custom. Documentado em [`protocol.md`](protocol.md) seção
"Evolução pra MCP".

Não migrar agora. Custo de manter MCP > benefício pra escala atual.

## Dependências do sistema

- `git` ≥ 2.43 (worktree).
- `tmux` ≥ 3.0 (layout + split-pane).
- `inotify-tools` (`inotifywait`).
- `gh` CLI autenticado com scope `repo`.
- `claude` CLI (Claude Code) no PATH.
- `uv` (para o `mmb-logger`).
- SSH key configurada pro GitHub.
