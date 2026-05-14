# Protocolo de comunicação entre sessões — MMB v3

## Por que este doc existe

Sessões Claude são silos. Não há API nativa de "enviar mensagem
de uma sessão pra outra". O Claude Code CLI também não expõe
inter-session messaging.

Pra remover Rick do loop de relay humano, definimos este
protocolo de mensageria assíncrona baseado em **filesystem
+ ping via tmux**.

## Topologia

```
┌─────────────────────────────────────────────────────────────┐
│  RICK                                                        │
│  ↕ (conversa só com Mestre)                                  │
│                                                              │
│  MASTER (tab tmux: master)                                   │
│  ↕ (via msg.sh + inbox/master/)                              │
│                                                              │
│  CORE / COCKPIT / AQUARIUM (tabs respectivas)                │
│  ↓ (cria sub-issue no GitHub, spawna atômico)                │
│                                                              │
│  ATÔMICOS (panes efêmeros nas tabs dos projetos)             │
│  → leem issue como prompt, executam, abrem PR, encerram      │
│                                                              │
│  Rick revisa PR → mergeia                                    │
└─────────────────────────────────────────────────────────────┘
```

**Atômicos não participam do protocolo de mensagens.** Eles
recebem brief como prompt inicial via tmux send-keys e morrem
ao abrir PR.

## Estrutura física

```
.tooling/inbox/
├── master/       ← mensagens recebidas pelo Mestre
├── core/         ← recebidas pelo Orq de mmb-core
├── cockpit/      ← recebidas pelo Orq de mmb-cockpit
└── aquarium/     ← recebidas pelo Orq de mmb-aquarium
```

Cada arquivo é uma mensagem completa com frontmatter + corpo.
Nome do arquivo é ordenável por timestamp natural:

```
YYYY-MM-DDTHH-MM-SSZ_<from>_<type>_<subject-slug>.md
```

Exemplos:
- `2026-05-14T16-32-00Z_master_briefing_cleanup-scripts.md`
- `2026-05-14T16-45-12Z_core_status_pr-aberto-3.md`
- `2026-05-14T16-50-00Z_master_answer_brief-ambiguidade.md`

## Schema de mensagem

```markdown
---
from: <master|core|cockpit|aquarium>
to: <master|core|cockpit|aquarium>
type: <briefing|question|answer|status|error>
subject: <kebab-case-curto>
thread: <épico-slug ou conversation-id>   # opcional
created: <ISO8601 UTC>
---

# Corpo livre em markdown
```

### Tipos de mensagem

| Type | Quem envia | Pra quem | Pra quê |
|---|---|---|---|
| `briefing` | master | orq local | Trabalho novo: faça issue + spawn atômico |
| `question` | orq local | master | Brief ambíguo / decisão fora do meu escopo |
| `answer` | master | orq local | Resposta a uma `question` |
| `status` | orq local | master | Marco: issue criada / PR aberto / PR mergeado / task fechada |
| `error` | qualquer | master | Algo quebrou: spawn falhou, push rejeitado, etc |

## O ping

`msg.sh` grava o arquivo no inbox do destinatário e envia 2-3
linhas via `tmux send-keys` pra tab dele:

```
MSG [master->core] briefing: cleanup-scripts
  inbox: /home/eliezer/llab/MMB/.tooling/inbox/core/2026-05-14T16-32-00Z_master_briefing_cleanup-scripts.md
```

**Por que o ping é ASCII puro (sem emoji, sem aspas):** o
`tmux send-keys` atravessa shell layers. Quanto mais simples o
payload, menor o risco de quoting bug. Prefixo `MSG ` é
distintivo o suficiente pros profiles instruírem agentes a
reconhecer.

Profiles ensinam: "quando você ver linha começando com `MSG `
seguida de `inbox: <path>`, leia o arquivo e aja conforme o
`type`."

## Helper único: `msg.sh`

Único ponto de envio. Centraliza:
- Validação de campos (`to`, `type`).
- Detecção do remetente (via env `MMB_TAB` ou nome da tab tmux).
- Escrita atômica do arquivo.
- Envio do ping pra tab correta (window 0, sempre — orq local
  mora ali; atômicos vivem em panes >0 e não recebem mensagens).

Uso:
```bash
msg.sh <to> <type> <subject-slug> <body-file> [thread]
```

## Fluxos canônicos

### Fluxo 1 — briefing single-repo

```
Rick → master pane: "limpar scripts X do mmb-core"
master:
  1. lê repo read-only
  2. produz briefing em .tooling/intents/<date>-<slug>/briefing-core.md
  3. msg.sh core briefing <slug> <briefing-file> <slug>

core (recebe ping):
  1. lê arquivo no inbox
  2. lê briefing apontado (ou inline, depende)
  3. cria sub-issue no GitHub (labels: task, project:mmb-core)
  4. spawn-atomic.sh mmb-core <id> <issue-number>
  5. msg.sh master status issue-criada <body> <slug>

atômico (pane novo):
  1. lê issue como prompt
  2. executa, commita, push
  3. open-pr.sh → push + gh pr create + kill-pane em 8s

core (detecta PR):
  msg.sh master status pr-aberto <body> <slug>

Rick → revisa PR, mergeia.

core (próxima vez que checar):
  1. task-end.sh
  2. msg.sh master status task-fechada <body> <slug>

master:
  marca épico como fechado em .tooling/intents/<date>-<slug>/
```

### Fluxo 2 — escalação de dúvida

```
core (lendo briefing):
  "esse brief diz pra rename X mas X é importado por Y em outro repo
   — fora do escopo da minha task, escalando"

core: msg.sh master question rename-cross-repo <pergunta> <thread>

master (recebe ping):
  1. lê pergunta
  2. avalia: pode decidir sozinho?
     - se sim: msg.sh core answer rename-cross-repo <decisão>
     - se não: conversa com Rick na própria tab master
  3. responde

core (recebe answer):
  prossegue com a decisão
```

### Fluxo 3 — cross-repo

```
master:
  1. produz briefing mestre em .tooling/intents/<date>-<slug>/master-briefing.md
  2. produz N child briefings (1 por projeto)
  3. msg.sh core briefing <slug> <core-briefing>  thread=<slug>
  4. msg.sh cockpit briefing <slug> <cockpit-briefing>  thread=<slug>
  5. (se houver deps cross-repo, briefings carregam requires)

cada orq local: idem fluxo 1, em paralelo
master: agrega status pelo thread
```

## Garantias e limitações

**Garantias:**
- Ordem natural por timestamp no nome do arquivo.
- Persistência total: mensagens sobrevivem a crash de sessão.
- Audit trail completo em `inbox/`.
- Visibilidade: Rick vê os pings em todas as tabs.

**Limitações conhecidas:**
- **Sem ACK:** quem envia não sabe se quem recebeu processou.
  Mitigação: receptor envia `status` em marcos importantes.
- **Sem retry:** se o ping não for visto (Claude crashou no
  momento exato), mensagem fica no inbox aguardando o próximo
  start da sessão ler.
- **Sem queue size limit:** inbox pode acumular. Cleanup
  manual ou via script futuro.
- **`MMB_TAB` env não está garantido:** detecção via nome de
  window pode falhar se você renomear as tabs. Solução: setar
  `MMB_TAB=master` (ou core/etc) no início de cada sessão via
  `up.sh`.

## Evolução pra MCP (Model Context Protocol)

Este protocolo é deliberadamente simples — FS + ping. Funciona
mas tem limites quando o sistema cresce:

- Sem auth/autorização (qualquer sessão escreve em qualquer
  inbox).
- Sem schema validation além das checagens de `msg.sh`.
- Difícil de estender pra agentes fora da máquina.

Quando isso virar um problema (provavelmente após 5+ épicos
multi-repo paralelos), migrar pra **MCP server custom**:

- Cada Claude session se conecta a um servidor MCP local
  (`stdio` ou HTTP).
- Tools expostas: `send_message(to, type, subject, body)`,
  `list_inbox()`, `read_message(id)`.
- Receptor ainda precisa de algum tipo de notificação ativa
  (MCP é request/response). Mantém `tmux send-keys` ou usa
  long-polling.
- Vantagens: schema typed (pydantic), auth opcional,
  observabilidade via MCP server logs, expansível.

**Caminho de migração:** o conceito (mensagens com type/from/to/body)
sobrevive. O que muda é a implementação do `msg.sh` (vira
chamada de tool MCP) e o read do inbox (vira `list_inbox()` tool).
Profiles e fluxos canônicos seguem idênticos.

Não migrar agora. Migrar quando o custo do FS for maior que o
custo de manter um MCP server.
