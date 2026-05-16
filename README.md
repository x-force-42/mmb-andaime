# mmb-andaime

Método operacional + sistema de observabilidade para desenvolvimento de software conduzido por múltiplos agentes Claude coordenados. Camada cross-repo do ecossistema **Mr. Meeseeks Box (MMB)**.

> O andaime não tem código de produto. Ele vive *sobre* os repos e os coordena. O `mmb-logger` complementa o andaime observando os artefatos canônicos que ele produz e materializando o estado em SQLite para análise retrospectiva via cockpit.

---

## A proposta

O MMB investiga uma pergunta prática: **é possível conduzir o ciclo completo de desenvolvimento de software — do levantamento de requisitos ao PR mergeado — usando agentes Claude autônomos, com um humano apenas nos pontos de decisão estratégica?**

O ecossistema tem quatro repos coordenados:

| Repo | Papel |
|---|---|
| [`mmb-core`](https://github.com/x-force-42/mmb-core) | Bot Discord + API REST + lógica Meeseeks (Python) |
| [`mmb-cockpit`](https://github.com/x-force-42/mmb-cockpit) | SPA de governança retrospectiva do ecossistema (React) |
| [`mmb-aquarium`](https://github.com/x-force-42/mmb-aquarium) | Visualização em tempo real dos agentes (PixiJS + áudio) |
| [`mmb-logger`](https://github.com/x-force-42/mmb-logger) | Projeção SQLite + API REST sobre os artefatos do andaime (Python/FastAPI) |

O **andaime** permite que agentes diferentes trabalhem nesses repos sem se atropelar — com rastreabilidade, isolamento e comunicação assíncrona. O **logger** lê os artefatos produzidos pelo andaime e materializa em DB para que o cockpit possa exibir o histórico operacional.

---

## Arquitetura

### Hierarquia de agentes (4 camadas + observabilidade)

```
┌─────────────────────────────────────────────────────┐
│  Rick (humano)                                       │
│  Decide estratégia, aprova briefings, revisa PRs     │
└───────────────────┬─────────────────────────────────┘
                    │ conversa natural
┌───────────────────▼─────────────────────────────────┐
│  Master (sessão Claude na raiz /MMB/)                │
│  Recebe intenções, faz discovery, produz briefings,  │
│  coordena os repos, acompanha épicos                 │
└───────────────────┬─────────────────────────────────┘
                    │ mailbox (arquivos em .tooling/inbox/)
┌───────────────────▼─────────────────────────────────┐
│  Workers stateless (claude -p por mensagem)          │
│  Um por repo de produto                              │
│  Materializam issues no GitHub, spawnam atômicos     │
└───────────────────┬─────────────────────────────────┘
                    │ git worktree por task
┌───────────────────▼─────────────────────────────────┐
│  Atômicos (claude em worktree efêmera)               │
│  Implementam a task, fazem commit, abrem PR, morrem  │
└─────────────────────────────────────────────────────┘
                    │
                    │ artefatos colaterais ao longo do caminho
                    │ (GitHub PRs/issues, inbox/, journal,
                    │  agents registry, transcripts Claude)
                    ▼
┌─────────────────────────────────────────────────────┐
│  mmb-logger — projeção retrospectiva                 │
│  reconcile lê todos os artefatos canônicos e         │
│  materializa em SQLite. API REST serve o cockpit.    │
└─────────────────────────────────────────────────────┘
```

### O barramento de mensagens

O coração do andaime é um daemon simples (`commd.sh`) que assiste os diretórios de inbox com `inotifywait`. Quando o Master (ou qualquer camada) deposita uma mensagem via `msg.sh`, o daemon acorda e despacha um worker stateless (`claude -p`) para processá-la.

```
msg.sh core briefing <slug> <arquivo> <thread>
  └→ escreve .tooling/inbox/core/<ts>_<meta>.md
       └→ commd.sh detecta via inotifywait
            └→ worker.sh core <arquivo>
                 └→ claude -p [profile de orq] [mensagem]
```

Sessões Claude ociosas não acordam com `tmux send-keys`. Workers stateless, por design, só existem quando há trabalho.

### Isolamento por worktree

Cada task atômica roda em uma `git worktree` separada:

```
mmb-core/
├── (main checkout)
└── .worktrees/
    ├── 1.2-auth-refactor/     ← atômico A trabalhando aqui
    └── 1.3-rate-limiting/     ← atômico B trabalhando aqui
```

Dois atômicos podem trabalhar no mesmo repo simultaneamente sem conflito de working tree.

### Âncora `mmb-cycle-key`

O wrapper `.tooling/bin/create-task-issue.sh` prepende a cada body de issue:

```html
<!-- mmb-cycle-key: <epic_slug>/<project_short>/<briefing_created_ts>
     mmb-briefing-file: <basename do arquivo em inbox> -->
```

Isso garante casamento determinístico briefing ↔ issue no reconcile do logger — sem precisar inferir o link via regex em subject. Spec completa em [`.tooling/source-of-truth.md`](.tooling/source-of-truth.md).

### Camada de observabilidade — `mmb-logger`

O logger não é empurrado. Ele observa.

```
              ┌──────────────────────────┐
              │ Artefatos canônicos      │
              │  • GitHub issues/PRs     │
              │  • inbox/ briefings      │
              │  • journal.jsonl         │
              │  • agents.jsonl          │
              │  • ~/.claude/projects/   │
              │  • intents/              │
              └──────────┬───────────────┘
                         ↓
              ┌──────────────────────────┐
              │ mmb-logger reconcile     │
              │ (one-shot, idempotente)  │
              └──────────┬───────────────┘
                         ↓
              ┌──────────────────────────┐
              │ SQLite                   │
              │  • epicos                │
              │  • ciclos                │
              │  • eventos (audit)       │
              └──────────┬───────────────┘
                         ↓
              ┌──────────────────────────┐
              │ FastAPI → mmb-cockpit    │
              └──────────────────────────┘
```

Princípios operacionais:

1. **Pull, não push.** O logger lê artefatos que já existem por outras razões; nenhum agente precisa "lembrar de declarar".
2. **NULL honesto > número falso.** Sem fonte = NULL + warning. Custo só preenche se há transcript real.
3. **Órfão honesto > linkagem inventada.** Eventos sem ciclo casável ficam `ciclo_id=NULL`.
4. **Idempotência por construção.** UPSERT seletivo + UNIQUE `source_key`.
5. **Convenções validadas com warning ruidoso.** Quebra de contrato vira entrada estruturada visível, não silêncio.

Contrato canônico vive em [`.tooling/source-of-truth.md`](.tooling/source-of-truth.md) — define o que cada coluna projeta, de qual fonte, com que fallback.

### Visualização em tempo real

O `aquario-bridge` (daemon Python) observa os logs do andaime e traduz eventos de ciclo de vida dos agentes para `AppMessage`, publicando via WebSocket no relay do `mmb-aquarium`. Cada worker que nasce vira uma criatura PixiJS; quando o PR é aberto, ela morre feliz.

```
logs/workers/<dest>.log  ──┐
state/agents.jsonl         ├──→ aquario-bridge.py ──→ ws://localhost:8080/ws ──→ PixiJS
state/heartbeats/*.alive  ─┘
```

---

## Design decisions

**Workers stateless em vez de sessões vivas.** `claude -p` é um processo que começa, processa e termina. Sem polling, sem estado acumulado, sem `tmux send-keys` que pode falhar.

**Mailbox de arquivos em vez de filas.** Arquivos em disco são legíveis, auditáveis, versionáveis e não precisam de servidor. `inotifywait` é o único daemon necessário para transformar isso em push real.

**Git worktrees em vez de branches locais.** Múltiplos atômicos trabalham no mesmo repo em paralelo, cada um com seu próprio working directory.

**GitHub como fonte canônica do estado em-voo.** Issues e PRs são a verdade do que está acontecendo. O andaime não mantém estado próprio. O `mmb-logger` materializa esse estado em SQLite como projeção — não como fonte autoritativa.

**Reconcile pull-based no logger.** Em vez de pedir aos agentes que declarem eventos, o reconcile observa artefatos colaterais (PR existe porque é o trabalho real, não pra alimentar logger). Substitui inferência por regex em subject — paradigma anterior — por projeção determinística sobre fontes canônicas.

**Âncora explícita briefing ↔ issue.** O wrapper de criação de issue injeta `mmb-cycle-key` no body, garantindo casamento determinístico no logger. Sem isso, o reconcile cairia em heurísticas frágeis.

**Agnosticismo do aquário.** O aquário recebe qualquer publisher que falar o protocolo `AppMessage` via WebSocket. O andaime faz a tradução de vocabulário; o aquário permanece desacoplado.

---

## Estrutura do repositório

```
/
├── CLAUDE.md                            ← instruções para a sessão Master
├── .tooling/
│   ├── README.md                        ← detalhe do método (este nível)
│   ├── source-of-truth.md               ← contrato canônico do logger
│   ├── protocol.md                      ← protocolo mailbox+ping (legado: tmux)
│   ├── guardrails.md                    ← comportamentos vetados por papel
│   ├── config.sh                        ← knobs centrais (modelos, owner, timeouts)
│   ├── bin/
│   │   ├── commd.sh                     ← daemon de despacho (inotifywait)
│   │   ├── worker.sh                    ← worker stateless por mensagem
│   │   ├── msg.sh                       ← envia mensagem para inbox de um dest
│   │   ├── agents.sh                    ← registry de agentes + heartbeats
│   │   ├── log.sh                       ← journal estruturado de incidentes
│   │   ├── task-start.sh                ← cria worktree + branch para task
│   │   ├── task-end.sh                  ← cleanup pós-merge
│   │   ├── task-abort.sh                ← cleanup pré-merge (descarta)
│   │   ├── spawn-atomic.sh              ← inicia agente atômico em worktree
│   │   ├── create-task-issue.sh         ← wrapper de gh issue create com âncora
│   │   ├── open-pr.sh                   ← push + gh pr create + Closes #N
│   │   ├── check-deps.sh                ← verifica PRs de deps via gh
│   │   ├── review-cycle.sh              ← agrega journal por épico
│   │   ├── up.sh                        ← sobe sessão tmux com layout padrão
│   │   ├── smoke.sh                     ← testes de sanidade do método
│   │   ├── reset-all.sh                 ← reset total do estado em-voo
│   │   ├── aquario-bridge.py            ← bridge de eventos → WebSocket
│   │   ├── aquario-bridge.sh            ← wrapper com venv automático
│   │   └── lib/
│   │       └── pr-body.sh               ← funções puras testáveis de body de PR
│   ├── profiles/
│   │   ├── master.md                    ← modus operandi do Master
│   │   ├── project-orchestrator.md      ← modus operandi dos workers
│   │   └── atomic-agent.md              ← protocolo dos atômicos
│   ├── templates/                       ← briefing/PR bodies versionados
│   ├── tests/
│   │   └── test-pr-body.sh              ← testes shell do lib de PR body
│   ├── inbox/                           ← mailbox por destinatário (runtime)
│   ├── state/                           ← registry de agentes + heartbeats (runtime)
│   ├── logs/                            ← logs de workers e daemons (runtime)
│   └── intents/                         ← histórico de épicos (gitignored — runtime)
├── mmb-core/                            ← repo separado (não commitado aqui)
├── mmb-cockpit/                         ← repo separado (não commitado aqui)
├── mmb-aquarium/                        ← repo separado (não commitado aqui)
└── mmb-logger/                          ← repo separado (não commitado aqui)
```

---

## Tecnologias

| Camada | Tecnologia |
|---|---|
| Agentes | [Claude Code CLI](https://claude.ai/code) (`claude`, `claude -p`) |
| Daemon de mensagens | `inotifywait` ([inotify-tools](https://github.com/inotify-tools/inotify-tools)) |
| Automação GitHub | [`gh` CLI](https://cli.github.com/) |
| Sessão / layout | [tmux](https://github.com/tmux/tmux) |
| Bridge de eventos | Python 3.11+ · asyncio · [websockets](https://websockets.readthedocs.io/) |
| Logger | Python 3.12+ · FastAPI · SQLite · typer (no repo `mmb-logger`) |
| Isolamento de tasks | Git worktrees (`git worktree`) |
| Orquestração | Bash puro (sem dependências extras) |

Os 4 repos de produto têm suas próprias stacks (Python/Discord, React, PixiJS, FastAPI) — este repo não depende delas.

---

## Como rodar

### Pré-requisitos

```bash
# Ferramentas de sistema
sudo apt install inotify-tools tmux

# GitHub CLI autenticado
gh auth login

# Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Python 3.11+ (para aquario-bridge e mmb-logger)
# O wrapper aquario-bridge.sh cria o venv automaticamente
# mmb-logger usa uv (https://docs.astral.sh/uv/)
```

### Setup inicial

```bash
# Clone os repos lado a lado
git clone git@github.com:x-force-42/mmb-andaime.git MMB
cd MMB
git clone git@github.com:x-force-42/mmb-core.git
git clone git@github.com:x-force-42/mmb-cockpit.git
git clone git@github.com:x-force-42/mmb-aquarium.git
git clone git@github.com:x-force-42/mmb-logger.git

# Configure o GitHub owner se necessário
# edite .tooling/config.sh → MMB_GH_OWNER
```

### Subir o andaime

```bash
# Sobe sessão tmux com Master + commd + logs + aquário
.tooling/bin/up.sh

# Se você já é o Master (sessão Claude externa ao tmux):
.tooling/bin/up.sh --no-master-claude
```

### Inicializar e rodar o logger

```bash
cd mmb-logger
uv sync
uv run mmb-logger init-db
uv run mmb-logger reconcile        # one-shot; projeta GH + filesystem em SQLite
uv run mmb-logger serve            # API REST em localhost:8765
```

`reconcile` é idempotente — pode rodar quantas vezes quiser. O cockpit aponta para a API.

### Smoke test

```bash
.tooling/bin/smoke.sh comm         # commd → worker roundtrip (~90s)
.tooling/bin/smoke.sh aquario      # bridge → aquário visual (requer aquarium rodando)
```

### Reset

```bash
.tooling/bin/reset-all.sh --yes    # limpa estado em-voo (PRs, issues, worktrees, inbox, logs)
```

Para resetar o DB do logger (cuidado — apaga ciclos e anotações humanas):

```bash
cd mmb-logger
uv run mmb-logger reconcile --reset
```

---

## Releases

Tags no formato `vX.Y.Z`. A versão atual é a [`v0.6.0`](https://github.com/x-force-42/mmb-andaime/releases/tag/v0.6.0), que estabelece o contrato `source-of-truth.md` e o wrapper `create-task-issue.sh` — base para o paradigma reconcile do logger.

Histórico de marcos:

- **v0.6.0** — contrato source-of-truth + wrapper de âncora + hardening de open-pr.sh.
- **v0.5.0** — workers stateless via commd.
- **v0.4.0 e anteriores** — evolução do protocolo mailbox+ping.

---

## Contribuindo

O projeto está em evolução ativa. Áreas mais abertas para contribuição:

- **Robustez do commd**: backpressure, dead-letter queue, retry com backoff.
- **Portabilidade**: hoje depende de Linux (`inotifywait`); suporte a macOS via `fswatch`.
- **Modelos por camada**: experimentos com Opus no Master + Sonnet/Haiku nas camadas executivas.
- **Cockpit + logger**: novos painéis ("órfãos por kind", "saúde do reconcile", "custo por épico/projeto").
- **Watch mode do logger**: hoje o reconcile é one-shot; um modo watch com inotify ainda não foi implementado por princípio (esperar caso de uso real).
- **aquario-bridge**: mais tipos de eventos visuais; integração com métricas de heartbeat.

Issues e discussões em cada repo. O método como um todo é discutido neste repo (`mmb-andaime`).
