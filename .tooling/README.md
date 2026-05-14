# `.tooling/` — andaime cross-repo do MMB (v3)

Diretório de **orquestração** do ecossistema MMB. Vive fora dos
3 repos (`mmb-core`, `mmb-cockpit`, `mmb-aquarium`) e os coordena.
Não tem código de produto. Existe pra ser usado, evoluído, e —
quando o ponto de inflexão chegar — absorvido ou desligado.

## Modelo v3 — protocolo de comunicação

```
┌─────────────────────────────────────────────────────────────┐
│  RICK                                                        │
│  ↕ (conversa SÓ com Mestre)                                  │
│                                                              │
│  MASTER (tab tmux: master)                                   │
│  - faz curadoria + briefings                                 │
│  - NÃO toca GitHub                                           │
│  - dispara briefings via msg.sh                              │
│  ↕ (mailbox + ping em .tooling/inbox/)                       │
│                                                              │
│  CORE / COCKPIT / AQUARIUM (tabs respectivas)                │
│  - autônomos: criam sub-issue + spawnam atômico              │
│  - escalam dúvidas via msg.sh master question                │
│  ↓ (spawn-atomic.sh)                                         │
│                                                              │
│  ATÔMICOS (panes efêmeros nas tabs dos projetos)             │
│  - lêem issue como prompt direto                             │
│  - executam, commitam, abrem PR, pane fecha em 8s            │
│                                                              │
│  Rick → revisa PR → mergeia                                  │
└─────────────────────────────────────────────────────────────┘
```

**Você (Rick) interage SÓ com:** a tab master, e os PRs no GitHub.
Tudo no meio rola via mensagens entre sessões.

## O que mudou de v2 pra v3

| Aspecto | v2 | v3 |
|---|---|---|
| Quem cria issue | Mestre | Orq Local |
| Canal Mestre ↔ Orq Local | Rick (relay humano) | mailbox + ping (msg.sh) |
| Aprovação humana | Cada disparo | Só briefing (na conversa) + PRs |
| Atômico lê de onde | Issue OU brief local | Só issue (é o prompt) |
| Mestre toca GitHub | Sim (cria issues) | Não (só lê via `gh ... view`) |

## O que está aqui

```
.tooling/
├── README.md                       ← este arquivo
├── protocol.md                     ← especificação do protocolo mailbox+ping
├── config.sh                       ← knobs centrais (sourced pelos scripts)
├── profiles/
│   ├── master.md                   ← modus operandi do mestre (v3)
│   ├── project-orchestrator.md     ← modus operandi dos orquestradores (v3)
│   └── atomic-agent.md             ← protocolo dos atômicos (v3)
├── templates/
│   ├── master-briefing.md          ← briefing local (não vira issue)
│   ├── task-briefing.md            ← body de sub-issue (prompt do atômico)
│   └── pr-body.md                  ← body de PR (preenchido por open-pr.sh)
├── bin/
│   ├── msg.sh                      ← protocolo: envia mensagem entre sessões
│   ├── up.sh                       ← sobe layout tmux (master + 3 projetos)
│   ├── task-start.sh               ← worktree + branch (default branch agnóstico)
│   ├── task-end.sh                 ← cleanup pós-merge (squash detection)
│   ├── task-abort.sh               ← cleanup pré-merge (descarta)
│   ├── spawn-atomic.sh             ← task-start + tmux split-pane + claude
│   ├── open-pr.sh                  ← push + gh pr create + kill-pane
│   └── check-deps.sh               ← verifica PRs de deps via gh
├── inbox/                          ← mailbox por destinatário
│   ├── master/                     ← Mestre recebe aqui
│   ├── core/
│   ├── cockpit/
│   └── aquarium/
└── intents/                        ← histórico local de briefings
    └── <YYYY-MM-DD>-<slug>/
        ├── master-briefing.md
        └── briefings/
            ├── core-<slug>.md      ← (se cross-repo)
            └── ...
```

## Protocolo de mensagens

Spec completo em [`protocol.md`](protocol.md). Resumo:

- Cada mensagem é um arquivo markdown em `inbox/<destinatário>/`.
- Nome: `YYYY-MM-DDTHH-MM-SSZ_<from>_<type>_<subject>.md`.
- Frontmatter padrão: `from`, `to`, `type`, `subject`, `thread`, `created`.
- Tipos: `briefing | question | answer | status | error`.
- Após gravar arquivo, `msg.sh` envia ping curto via
  `tmux send-keys` pra tab do destinatário:
  ```
  MSG [master->core] briefing: cleanup-scripts
    inbox: /MMB/.tooling/inbox/core/...md
  ```
- Profiles instruem agentes a reconhecer `MSG ` como marcador
  e ler o arquivo apontado.

Helper único: `msg.sh <to> <type> <subject> <body-file> [thread]`.

## `config.sh` — knobs centrais

Sourced por `up.sh`, `spawn-atomic.sh`, `task-end.sh`, `open-pr.sh`,
`msg.sh`.

| Variável | Default | Pra quê |
|---|---|---|
| `MMB_MODEL_MASTER` | `claude-opus-4-7` | Modelo do Mestre |
| `MMB_EFFORT_MASTER` | `high` | Effort do Mestre |
| `MMB_MODEL_PROJECT_ORCHESTRATOR` | `claude-opus-4-7` | Modelo orqs locais |
| `MMB_EFFORT_PROJECT_ORCHESTRATOR` | `high` | Effort orqs locais |
| `MMB_MODEL_ATOMIC` | `claude-opus-4-7` | Modelo atômicos (knob principal) |
| `MMB_EFFORT_ATOMIC` | `high` | Effort atômicos |
| `MMB_SKIP_PERMS` | `true` | `--dangerously-skip-permissions` no spawn |
| `MMB_GH_OWNER` | `x-force-42` | Owner GitHub dos repos |
| `MMB_TMUX_SESSION` | `mmb` | Nome da sessão tmux |
| `MMB_TMUX_SPLIT` | `-v` | Split-pane do atômico: `-v`, `-h`, `win` |

Override por sessão:
```bash
MMB_MODEL_ATOMIC=claude-sonnet-4-6 .tooling/bin/spawn-atomic.sh mmb-core 1.1 4
```

## Fluxo completo (smoke walk)

1. Você → master pane: *"limpar scripts/task-*.sh do mmb-core"*
2. Master lê o repo read-only, produz briefing em
   `.tooling/intents/<date>-<slug>/master-briefing.md`,
   te mostra na conversa.
3. Você aprova.
4. Master roda:
   ```bash
   msg.sh core briefing cleanup-scripts <briefing-path> cleanup-scripts
   ```
5. Pane do orq core recebe ping `MSG [master->core] ...`.
   Orq lê arquivo do inbox, lê briefing apontado.
6. Orq core cria issue no GitHub:
   ```bash
   gh issue create --repo x-force-42/mmb-core \
     --title "..." --label "task,project:mmb-core,epic:cleanup-scripts" \
     --body-file <briefing-path>
   ```
7. Orq core: `spawn-atomic.sh mmb-core 1.1 <issue-number>`.
   Pane do atômico nasce embaixo dele (split vertical).
8. Atômico lê issue, executa, commita, push, `open-pr.sh` →
   PR aberto + comment na issue + kill-pane em 8s.
9. Orq core manda `msg.sh master status pr-aberto-N ...`.
10. Master vê ping no inbox/master/, atualiza modelo mental.
11. Você revê PR, mergeia.
12. Orq core (na próxima vez que olhar): `task-end.sh` + manda
    `msg.sh master status task-fechada ...`.
13. Master marca briefing como ✅ + nota narrativa.

## Substituibilidade das sessões

Qualquer sessão Claude pode ser desligada e reaberta sem perda
crítica. Estado vive em arquivos:

- Abre Claude em `/MMB/` → carrega `CLAUDE.md` → vira Mestre.
- Abre Claude em `/MMB/<repo>/` → carrega CLAUDE.md local +
  `project-orchestrator.md` → vira Orq Local.
- Abre Claude em `/MMB/<repo>/.worktrees/<slug>/` → lê
  `atomic-agent.md` + brief da sub-issue → vira Atômico.

Estado em-voo:
- **GitHub** (issues, PRs) — fonte canônica de trabalho real.
- **`inbox/`** — comunicação pendente entre sessões.
- **`intents/`** — histórico de briefings produzidos.

## Quando NÃO usar este andaime

- Hotfix mínimo (1 linha) que Rick pede direto pro orq local
  — modo dev tradicional.
- Pergunta exploratória / debug — conversa direta sem ritual.
- Refactor interno do próprio andaime — Rick + Mestre editam
  arquivos do `.tooling/`.

## Como este andaime evolui

Heurística: padrão se repetiu 3x do mesmo jeito → codifique.
Não codifique antes — andaime ganha peso só onde paga custo.

Quando codificar:
- Regras gerais → `profiles/<nível>.md`.
- Formato de artefato → `templates/`.
- Operação repetitiva → `bin/<nome>.sh`.
- Protocolo de comm → `protocol.md`.

Nunca:
- Dentro dos repos de produto.
- Em CLAUDE.md de repo (que é contexto local, não método).

## Evolução futura — MCP

Quando o protocolo de mailbox+ping ficar limitante (provavelmente
após 5+ épicos cross-repo paralelos), migrar pra MCP server custom.
Documentado em [`protocol.md`](protocol.md) seção "Evolução pra MCP".

Não migrar agora. Custo de manter MCP > benefício pra escala
atual.

## Dependências do sistema

- `git` ≥ 2.43 (worktree).
- `tmux` ≥ 3.0 (layout + split-pane).
- `gh` CLI autenticado com scope `repo`.
- `claude` CLI (Claude Code) no PATH.
- SSH key configurada pro GitHub.
