# source-of-truth.md — contrato do mmb-logger

Este documento governa o que entra na DB do mmb-logger, quem escreve cada
coluna, e quais sinais externos são fonte canônica para cada estado. É
contrato entre três peças do ecossistema MMB:

- **Andaime** — produz os sinais (briefings em inbox, issues no GH, PRs,
  agents.jsonl, journal.jsonl, transcripts Claude).
- **Logger** — projeta esses sinais em DB SQLite via reconciler.
- **Cockpit** — consome o projetado e anota julgamento humano (score, notes).

Convenções deste doc vinculam os três. Quebrar este contrato é quebrar o
método.

## Princípio operacional

Três frases que governam o resto:

1. **Reconcile** reconstrói fatos observáveis a partir de fontes canônicas
   que existem por outras razões (PR existe porque é o trabalho real, não
   pra alimentar logger).
2. **Emit** registra intenção irredutível sem outra fonte primária.
   **Começa com zero kinds.** Ganha kind novo só se passar pelo filtro
   *"isso não cabe como coluna nova em row existente?"*.
3. **Cockpit** anota julgamento humano sobre rows que o reconciler
   estabeleceu. Reconciler nunca pisa em anotação.

O logger é onde a verdade assenta, não onde ela nasce.

## Dois domínios na tabela `ciclos`

A tabela `ciclos` tem duas naturezas misturadas. A fronteira é lei.

### Domínio derivado (reconciler escreve)

```
status, instruction, briefing_md, pr_url, pr_number,
closed_partial_at, closed_complete_at, merged_to_main,
abort_at, abort_origin, abort_reason,
cost_usd, tokens_input, tokens_output,
diff_added, diff_deleted, diff_files,
andaime_version
```

Reconciler tem permissão exclusiva. UPSERT toca **só** essas colunas —
nunca um UPDATE da row inteira.

### Domínio humano (cockpit PATCH escreve)

```
assertiveness_score, review_note
```

Reconciler **nunca** sobrescreve. Teste automatizado obrigatório:
inserir `assertiveness_score=4`, rodar `reconcile --reset`, verificar
sobrevivência. Fronteira testada, não só documentada.

`epicos` segue lógica análoga: todas as colunas atuais são derivadas. Se
algum dia houver `epicos.review_note` ou similar, entra no domínio humano
explicitamente.

## Matriz de fontes de verdade

### Tabela `epicos`

| Coluna | Fonte canônica | Escritor | Fallback |
|---|---|---|---|
| `id` | igual a `slug` (chave determinística) | reconciler | n/a |
| `slug` | `thread` em frontmatter do briefing master→planner | reconciler | n/a |
| `started_at` | `created` do briefing master→planner mais antigo do épico | reconciler | n/a |
| `intencao` | título do `master-briefing.md` em `.tooling/intents/<date>-<slug>/` | reconciler | first-line do body do primeiro briefing |
| `status` | função(ciclos abertos, fechamento explícito) — ver abaixo | reconciler | `aberto` |
| `closed_at` | timestamp do ato de fechamento explícito | reconciler | `NULL` |
| `andaime_version` | `git describe --tags --abbrev=0` no repo MMB no momento do reconcile | reconciler | `NULL` |

### Tabela `ciclos` — colunas derivadas

| Coluna | Fonte canônica | Escritor | Fallback |
|---|---|---|---|
| `id` | `<epic_slug>__<project_short>__<briefing_created_ts>` | reconciler | n/a |
| `epico_id` | FK em `epicos` derivada do `thread` do briefing | reconciler | n/a |
| `project` | `to` do briefing master→planner (prefixado com `mmb-`) | reconciler | n/a |
| `planner_invoked_at` | `created` do briefing master→planner | reconciler | n/a |
| `status` | função(briefing, issue, PR, sinais de falha) — ver abaixo | reconciler | n/a |
| `instruction` | `subject` do briefing | reconciler | first-line do body |
| `briefing_md` | body completo do arquivo de briefing em `.tooling/inbox/<repo-short>/.../` | reconciler | `NULL` |
| `pr_url` | `pr.url` do GH | reconciler | `NULL` |
| `pr_number` | `pr.number` do GH | reconciler | `NULL` |
| `closed_partial_at` | `pr.createdAt` do GH | reconciler | `NULL` |
| `closed_complete_at` | `pr.mergedAt` do GH | reconciler | `NULL` |
| `merged_to_main` | `pr.mergedAt IS NOT NULL` do GH | reconciler | `NULL` |
| `abort_at` | timestamp do sinal de falha — ver "aborto" abaixo | reconciler | `NULL` |
| `abort_origin` | classificação do sinal de falha | reconciler | `NULL` |
| `abort_reason` | texto do sinal de falha | reconciler | `NULL` |
| `cost_usd` | soma de `usage` no transcript Claude × tabela de preços (ver "Custo via transcripts" abaixo) | reconciler | `NULL` (nunca estimar) |
| `tokens_input` | input_tokens + cache_creation + cache_read no transcript | reconciler | `NULL` |
| `tokens_output` | output_tokens no transcript | reconciler | `NULL` |
| `diff_added` | `pr.additions` do GH | reconciler | `NULL` |
| `diff_deleted` | `pr.deletions` do GH | reconciler | `NULL` |
| `diff_files` | `pr.changedFiles` do GH | reconciler | `NULL` |
| `andaime_version` | `git describe` no momento do reconcile | reconciler | `NULL` |

### Tabela `ciclos` — colunas humanas

| Coluna | Fonte canônica | Escritor | Reconciler |
|---|---|---|---|
| `assertiveness_score` | Rick via cockpit | cockpit PATCH | **nunca toca** |
| `review_note` | Rick via cockpit | cockpit PATCH | **nunca toca** |

### Tabela `eventos`

Eventos são audit trail. Reconciler insere; ninguém edita.

| `kind` | Fonte | Notas |
|---|---|---|
| `msg_send` / `msg_receive` | `.tooling/inbox/**/*.md` | **somente audit; nunca transiciona estado de ciclo** |
| `atomic_spawn` / `atomic_deregister` | `.tooling/state/agents.jsonl` | linka a ciclo via agent-id (`<repo-short>-<task-id>`) |
| `pr_opened` | GH PR (derivado no reconcile) | redundante com `ciclos.pr_*`; serve linha do tempo |
| `state_change` | calculado pelo reconciler quando status muda entre runs | linka transição a evidência observada |
| `journal_warn` / `journal_error` / `journal_critical` | `.tooling/logs/journal.jsonl` | linka a ciclo via `epic`+`task` quando presentes |
| `heartbeat_loss` | derivado de `agents.jsonl` heartbeats + timeout | base para `abort_origin="heartbeat"` |

#### `source_key` e idempotência

Eventos audit (gerados pelo reconciler nas fases 3+) carregam
`source_key` único por origem:

| Fonte | `source_key` |
|---|---|
| journal entry | `journal:<ts>:<event-slug>` |
| agents entry | `agents:<id>:<ts>:<ev>` |
| inbox mensagem | `inbox:<path-absoluto>` |

UNIQUE INDEX parcial em `eventos.source_key WHERE source_key IS NOT NULL`
garante que reconcile repetido **não duplica** eventos. Eventos legacy
(pré-fase 3, sem `source_key`) coexistem com NULL.

#### Eventos linkados vs eventos órfãos

Cada evento existe em um de dois estados em relação a ciclos:

- **Linkado** (`ciclo_id NOT NULL`): pertence à linha do tempo de um
  ciclo específico. Reconciler conseguiu casar via heurística clara
  (anchor cycle_key, epic+project, epic+task). Cockpit deve renderizar
  esse evento na timeline do ciclo correspondente.

- **Órfão** (`ciclo_id IS NULL`): audit cru, sem ciclo associado.
  **NÃO é erro do sistema** — é evidência honesta de que o evento
  existe sem âncora suficiente pra associar a um ciclo materializado.

Causas legítimas de órfão (encontradas no estado real):

- Mensagem do inbox sem `thread` no frontmatter (status genéricos do orq
  pra master, mensagens manuais do Rick fora do método).
- Agent spawn/deregister cujo `epic` não corresponde a nenhum briefing
  materializado (smoke tests rápidos, demos ad-hoc, demos antigos).
- Journal entry sem `epic` nem `task` (eventos sistêmicos do andaime
  como `atomic-spawn-env-broken` que afetam infra, não ciclo específico).

**Princípio: órfão honesto é melhor que linkagem inventada.** O
reconciler **não introduz heurísticas novas pra reduzir órfãos** — se
a linkagem não está clara nos artefatos canônicos (anchor, labels,
agent-id, epic+task), o evento permanece órfão. Linkagem inventada é
exatamente o tipo de inferência por subject que matamos com R1-R5 na
fase 3; não voltamos atrás.

Cockpit deve tolerar `ciclo_id NULL` em respostas de eventos. O contrato
TS já reflete (`Evento.ciclo_id: string | null`). Painel sugerido:
"audit cru" com filtro por kind, separado da timeline de ciclos.

Quando a contagem de órfãos preocupa: o reconciler não inventa; o
caminho correto é refinar as fontes canônicas (ex: master começar a
sempre incluir `thread` em mensagens, andaime adicionar `epic` em todos
os events do journal). Isso é mudança no andaime, não no reconciler.

### Tabela `projetos`

Seed estático no runner. Sem reconcile dinâmico.

## Âncora de linkagem briefing ↔ issue

A âncora resolve o casamento determinístico entre nascimento do ciclo
(briefing em `inbox/`) e formalização no GH (issue).

### Formato

Todo `gh issue create` chamado pelo orq local DEVE prepender ao body o
bloco:

```html
<!-- mmb-cycle-key: <epic_slug>/<project_short>/<briefing_created_ts>
     mmb-briefing-file: <basename do arquivo em inbox> -->
```

Campos:

- `<epic_slug>` — `thread` do briefing (ex: `mmb-logger-destilacao`).
- `<project_short>` — `core` / `cockpit` / `aquarium` (o `to` do briefing).
- `<briefing_created_ts>` — `created` do frontmatter em ISO8601 (`2026-05-16T01:53:10Z`).
- `<basename>` — nome do arquivo de briefing sem path
  (`2026-05-16T01-53-10Z_master_briefing_<subject>.md`).

Por que HTML comment: invisível no markdown renderizado do GH, parseável
por regex simples no source.

Por que dois campos: `mmb-cycle-key` é a chave determinística que casa
com `ciclos.id`; `mmb-briefing-file` é redundância de debug útil ("qual
arquivo gerou esse ciclo?"). Reconciler valida coerência entre os dois —
divergência vira warning ruidoso.

### Quem escreve

Orq local, via wrapper `.tooling/bin/create-task-issue.sh` (a criar na
fase 0). Wrapper recebe `(repo, briefing-path, epic-slug)`, lê frontmatter
pra montar a chave, prepende ao body, chama `gh issue create`. Profile do
orq passa a referenciar o wrapper em vez de `gh issue create` direto.

### Quem lê

Reconciler, ao processar issues do GH. Lookup primário pela chave;
fallback pra "briefing mais recente sem issue casada de `(epic_slug,
project_short)`" com warning ruidoso. Fallback **não é caminho silencioso
de operação normal** — sua execução gera entrada em `journal.jsonl` e
aparece em painel do cockpit.

Issues sem âncora indicam: (a) criada manualmente pelo Rick fora do
método, (b) bug no orq, (c) issue pré-cutover. Todas merecem visibilidade
explícita.

## Função canônica: `ciclos.status`

Status é projeção pura sobre 4 sinais. Reconciler computa, nunca herda.

```
Entradas:
  B = briefing master→planner existe em inbox?
  I = issue GH OPEN existe com âncora (ou label epic/project como fallback)?
  C = issue GH CLOSED existe com âncora (ou labels)?
  P = PR existe linkando a issue (via Closes #N)?
  M = PR.mergedAt IS NOT NULL?
  F = sinal de falha colateral (worker exit/timeout, heartbeat loss,
      deregister com reason de erro, idade > threshold)

Saída:
  B ∧ ¬I ∧ ¬C ∧ ¬F                   → iniciado
  B ∧ I ∧ ¬P                          → planejado
  B ∧ I ∧ P ∧ ¬M                      → pr_aberto
  M                                    → completo
  B ∧ ¬I ∧ F                          → abortado (pré-GH)
  C ∧ ¬M                              → abortado (pós-GH, sem merge)
```

Estados ortogonais: cada ciclo está em exatamente um. Conflito (ex:
B ∧ I ∧ P ∧ M ∧ F) indica bug no sinal de falha; reconciler escolhe o
estado mais avançado e registra warning.

## Função canônica: `epicos.status`

```
Entradas:
  algum_aberto = existe ciclo do épico em {iniciado, planejado, pr_aberto}
  fechamento_explicito = master marcou ✅ no master-briefing.md
                          (linha que casa `^\s*[-*]?\s*Status:\s*.*✅`)

Saída:
  algum_aberto                          → aberto
  ¬algum_aberto ∧ fechamento_explicito → fechado
  ¬algum_aberto ∧ ¬fechamento_explicito → aberto  (todas as tasks
                                          terminaram mas Rick ainda não
                                          bateu o ✅)
```

Por que requer fechamento explícito: "todos os ciclos completos" pode
acontecer no meio de um épico que vai ganhar mais tasks. O ✅ é o ato
humano que diz "acabou de verdade". Sem ele, épico fica "aberto idle" —
sinal pro cockpit mostrar painel "épicos com todos ciclos prontos,
fechamento pendente".

### Implementação no reconciler (v0.4+)

A leitura do `fechamento_explicito` é projetada por
`_enrich_epicos_closure(conn, tooling_root)` em
`mmb-logger/src/mmb_logger/reconcile/reconcile.py` (mmb-logger PR #13).
Roda na mesma fase de `_enrich_epicos_intencao`, após upsert de épicos.

Regra de transição (idempotente):

| Briefing | Row DB | Ação |
|---|---|---|
| ✅ presente | `aberto` ou `closed_at IS NULL` | UPDATE `status='fechado', closed_at=<reconcile-time>` |
| ✅ presente | `fechado` + `closed_at NOT NULL` | no-op (preserva `closed_at` original) |
| ✅ ausente | `fechado` | UPDATE `status='aberto', closed_at=NULL` (**reabre** — projeção segue fonte canônica) |
| ✅ ausente | `aberto` | no-op |
| Briefing ausente | qualquer | tratado como `✅ ausente` |

`closed_at` = momento da **primeira observação** do ✅ pelo reconciler
(`datetime.now(UTC).isoformat()`). Não tenta parsear timestamp do
briefing (sem schema confiável) nem usa `mtime` (instável a edits
pós-fechamento). Reabertura sob remoção do ✅ é deliberada — estado
derivado acompanha a fonte canônica.

Campos humanos (`assertiveness_score`, `review_note`) e demais campos
derivados (`intencao`, `andaime_version`) **não são tocados** por essa
função.

## Custo via transcripts (fase 4)

`cost_usd`, `tokens_input`, `tokens_output` derivam de transcripts
Claude reais em `~/.claude/projects/<encoded-worktree-path>/<session>.jsonl`.
Sem transcript → NULL honesto. Sem modelo na tabela de preços → cost_usd
NULL mas tokens preenchidos. Nunca estima.

### Localização dos transcripts

Encoding determinístico validado fase 0:

```
path.replace("/", "-").replace(".", "-")
```

Ex: `/home/eliezer/llab/MMB/mmb-core/.worktrees/X1-cleanup-task-scripts` →
`-home-eliezer-llab-MMB-mmb-core--worktrees-X1-cleanup-task-scripts`.

Reconciler:
1. Lê `pr.head_ref_name` do PR linkado ao ciclo (convenção `task/<id>-<slug>`).
2. Constrói worktree path: `<MMB_ROOT>/<repo>/.worktrees/<id>-<slug>`.
3. Aplica encoding → dir em `~/.claude/projects/`.
4. Lê todos `*.jsonl` no dir e soma `usage` por turn.

Ciclos sem PR (status `iniciado`, `planejado` sem PR, abortado pré-GH) NÃO
têm transcript esperado → `cost_usd = tokens_* = NULL`, sem warning.

### Tabela de preços (USD per million tokens)

**Última verificação: 2026-05-16** (fonte: anthropic.com/pricing).
Manter sincronizado com `mmb_logger/reconcile/transcripts.py::PRICING`.

| Modelo | input | output | cache 5m write | cache 1h write | cache read |
|---|---:|---:|---:|---:|---:|
| `claude-opus-4-7` | $15.00 | $75.00 | $18.75 | $30.00 | $1.50 |
| `claude-sonnet-4-6` | $3.00 | $15.00 | $3.75 | $6.00 | $0.30 |
| `claude-haiku-4-5-20251001` | $1.00 | $5.00 | $1.25 | $2.00 | $0.10 |

Ratios canônicos:
- `cache_5m_write` = `input × 1.25`
- `cache_1h_write` = `input × 2.0`
- `cache_read` = `input × 0.1`

Modelos fora da tabela: `cost_usd` permanece `NULL` (warning `unknown-model`),
mas `tokens_input` e `tokens_output` ainda são preenchidos.

### Multi-session

Quando `>1` JSONL aparece no mesmo dir de transcripts, reconciler **soma
todos** (mesma worktree = mesma task = mesmo ciclo, por convenção do
spawn-atomic) e emite warning `transcript-multi-session`. Reviewer humano
pode validar se a soma faz sentido ou se sessões diferentes deveriam ter
sido separadas.

Cenários conhecidos onde isso acontece: atomic crashed e foi restartado,
Rick reabriu o Claude na worktree, demo ad-hoc.

### Warnings da fase 4

| Categoria | Quando |
|---|---|
| `transcript-missing` | PR existe com head_ref válido mas dir não existe em ~/.claude/projects |
| `transcript-multi-session` | 2+ JSONLs no mesmo dir; soma é aplicada com aviso |
| `transcript-malformed-lines` | Linhas JSON inválidas no JSONL — ignoradas, processamento continua |
| `transcript-no-usage` | Sessões lidas mas nenhum turn tinha `usage` (transcript corrompido / cancelado cedo) |
| `transcript-mixed-model` | Modelos diferentes no mesmo transcript (raro; cost usa dominante) |
| `unknown-model` | Modelo válido mas fora de `PRICING` — tokens preenchem, cost NULL |

### Princípios

1. **NULL honesto > número falso.** Não tem transcript = NULL. Modelo
   desconhecido = NULL. JSONL inválido = pula linha, não inventa.
2. **Tabela de preços é versionada.** Sem expiração automática, mas o
   header "última verificação" sinaliza quando reauditar.
3. **`tokens_input` inclui cache.** Diferente de mostrar só fresh-input,
   inclui tokens de cache write + cache read pra evitar enganar o
   reviewer humano sobre o volume real de trabalho.
4. **Idempotência via leitura pura.** Transcripts não mudam; reconcile
   repetido produz mesmos números.
5. **Reconciler escreve só fase 4 derivada.** UPSERT seletivo continua
   protegendo `assertiveness_score` e `review_note`. Se transcript
   desaparecer entre runs, `cost_usd`/`tokens_*` voltam para NULL —
   sem lixo derivado antigo.

### Limitações conhecidas do `cost_usd`

`cost_usd` é **sinal operacional honesto sobre suas limitações**, não
número-de-balanço. Cinco caveats que cockpit/Rick devem entender:

1. **Estimativa operacional, não fatura oficial.** Soma `tokens × tabela
   de preços local`. Anthropic fatura via outros critérios (rounding,
   batching, retry costs internos) que não estão visíveis no transcript.
   Útil pra ranking/proporção entre ciclos, não pra contabilidade.

2. **Preços retail, sem desconto.** A tabela `PRICING` assume preço
   público em anthropic.com/pricing. Plano enterprise, créditos
   promocionais ou descontos contratuais NÃO são considerados —
   `cost_usd` aparece maior que o custo real cobrado quando há
   desconto.

3. **Pricing não congelado por ciclo.** Se a tabela mudar (atualização
   de preços pela Anthropic), o próximo reconcile recomputa custo dos
   ciclos antigos com os novos números. Não há `pricing_snapshot_at`
   por row. Aceito por agora — congelamento exigiria coluna adicional e
   migração. Significa: histórico de custo é "a verdade segundo a tabela
   atual", não "a verdade do dia do ciclo".

4. **Mixed-model usa modelo dominante.** Quando turns no mesmo
   transcript alternam entre modelos (ex: Sonnet pra plan + Haiku pra
   execução), `cost_usd` aplica `PRICING[modelo_dominante]` em **todos
   os tokens**, não pro-rata. Underestima/overestima conforme
   distribuição. Warning `transcript-mixed-model` sinaliza com a
   contagem por modelo pra reviewer julgar.

5. **Multi-session soma sem distinção.** Múltiplas sessões na mesma
   worktree (atomic restartado, Rick reabriu, demo ad-hoc) são somadas
   como um único ciclo. Pode incluir overhead irrelevante. Warning
   `transcript-multi-session` sinaliza pra revisão humana validar.

Cockpit deve mostrar `cost_usd` com aviso "estimativa" pra não
confundir com fatura. Quando a contagem precisar ser auditada,
referência canônica é o billing dashboard do Anthropic, não esta DB.

## Aborto pré-GH: sinais de falha

Pra classificar ciclo como `abortado` antes da issue existir, reconciler
combina briefing órfão (sem issue casada) com pelo menos um sinal de
falha colateral. Os sinais têm **forças diferentes** e a ordem abaixo é
prioridade de matching:

### Sinais fortes (evidência positiva de falha)

1. **Worker exit não-zero** registrado em `journal.jsonl` como
   `event=commd-worker-exit`, casando por `dest=<project_short>` e janela
   temporal (signal_ts entre briefing.created e briefing.created + stale_threshold).
   `abort_origin="worker-exit"`.
2. **Worker timeout** (`event=commd-worker-timeout`), mesmo casamento.
   `abort_origin="worker-timeout"`.
3. **Deregister do orq com reason de erro** em `state/agents.jsonl` cujo
   `reason` casa heurística de classificação (`heartbeat`/`manual`/`self`).
   `abort_origin` ∈ {`heartbeat`, `manual`, `self`}.

Esses três têm em comum: **algo aconteceu** e foi registrado como falha
em outro artefato canônico. Confiança alta.

### Sinal fraco (inferência por ausência+tempo)

4. **Stale**: nenhum dos 3 sinais acima apareceu dentro do
   `stale_threshold_s` (default `3600s` = 1h, configurável via env
   `MMB_LOGGER_STALE_THRESHOLD_S` ou parâmetro `stale_threshold_s` no
   `reconcile()`). `abort_origin="stale"`.

Stale **NÃO é evidência positiva de falha** — é a constatação de que o
briefing existe há muito tempo e nada aconteceu. Pode significar:
- Worker realmente travou e não registrou nada (caso legítimo de falha).
- Briefing foi smoke/demo e ninguém esperava resultado.
- Issue foi criada fora do método (sem âncora), então o reconciler não
  conseguiu casar.
- Master dispatchou e depois desistiu sem abortar formalmente.

Por isso o `abort_reason` de stale é explícito sobre a natureza inferida:

```
stale: sem issue casada e sem sinal colateral
(worker-exit / worker-timeout / agents-deregister) em <threshold>s.
briefing criado em <ts>, idade <age>s. classificação por
ausência+tempo — confiança inferior aos outros 3 sinais; revisor humano
pode reclassificar.
```

### Quando o ciclo fica `iniciado` indefinidamente

Sem nenhum dos 4 sinais (briefing recente, dentro do threshold, sem
falha registrada), o ciclo permanece `iniciado`. Cockpit deve mostrar
"em curso" — é o estado normal entre dispatch e formalização da issue.

### Recomendação para revisão humana

`stale` tem natureza diferente dos outros 3 origens. Revisor humano que
inspecionar um ciclo com `abort_origin=stale` deve considerar:

- **Reclassificar como `manual`** se a verdade for "smoke test, ninguém
  esperava conclusão".
- **Reclassificar como `worker-exit`/`worker-timeout`** se houver pista
  externa (log do tmux, lembrança do Rick) de que worker realmente travou.
- **Voltar para `iniciado`** se o briefing for legítimo e ainda for
  retomado (caso raro — aumentar `stale_threshold_s` resolve a fonte).

Reclassificação é via cockpit PATCH em colunas humanas — reconciler
preserva `assertiveness_score` e `review_note` mas os campos de aborto
em si (`abort_origin`, `abort_reason`) são derivados. Pra editar
manualmente sem que o próximo reconcile sobrescreva, considere usar
`review_note` pra explicar a reclassificação e deixar o `stale` no
campo derivado como evidência do que o reconciler inferiu.

## Convenções que o reconciler depende

Reconciler é projeção, não inferência. Mas projeção pressupõe que sinais
canônicos sigam contrato. As convenções abaixo são duras; quebra é
warning ruidoso, não silêncio.

| Convenção | Quem honra | Como validar |
|---|---|---|
| Issue carrega labels `task`, `project:<repo>`, `epic:<slug>` | orq local | reconciler grep nos labels; ausente → warning |
| Issue body começa com âncora `mmb-cycle-key` | orq local (wrapper) | reconciler regex no body; ausente → fallback + warning |
| PR body contém `Closes #<N>` | atômico (`open-pr.sh` valida `GH_SUBISSUE` e injeta automaticamente; fail-loud antes do push se ausente/inválido) | reconciler grep no body do PR; ausente → warning `pr-without-closes` (cenário só possível pra PRs criados fora do método) |
| Branch = `task/<task-id>-<slug>` | atômico (`task-start.sh`) | reconciler valida `pr.headRefName` |
| Worktree = `<repo>/.worktrees/<task-id>-<slug>` | atômico | usado pra encontrar transcript Claude (fase 4) |
| Briefing `to` ∈ {core, cockpit, aquarium} | master (via `msg.sh`) | já validado em msg.sh; reconciler revalida |
| Briefing tem `thread` em frontmatter | master | sem thread, reconciler não consegue âncora; warning |
| Agent-id de atômico = `<repo-short>-<task-id>` | `spawn-atomic.sh` | usado pra linkar agent events a ciclo |

Lista é fechada. Convenção nova só entra aqui via mudança versionada
deste doc.

## Convenção de fuso (v0.9.0+)

### Storage permanece UTC

Todos os timestamps em colunas do DB são **UTC** (ISO 8601 com `Z`,
ex: `2026-05-16T18:39:12Z`). Nenhuma coluna é local. Persistência,
comparações, ordering, `WHERE ts >= cutoff` — tudo UTC. Reconciler
escreve UTC, API devolve UTC nos campos de timestamp.

### Bucketing diário de métricas usa BRT

A view `/api/metricas/overview` agrega séries diárias (`custo_por_dia`,
`ciclos_por_dia`) por **dia operacional local do MMB, atualmente
BRT (UTC-3)**, derivado em runtime via SQLite modifier
`datetime(planner_invoked_at, '-3 hours')`. Implementado em
`mmb-logger/src/mmb_logger/db.py::metrics_overview`.

Motivo: eventos rodados entre 21:00–23:59 BRT caem no dia UTC
seguinte. Sem o modifier, o Dashboard do cockpit contabilizava
ciclos no dia errado pro operador. O fix preserva storage UTC mas
projeta dia operacional local na agregação reportada.

Detalhes do contrato:
- Campo `dia` da resposta: `str` no formato `"YYYY-MM-DD"`.
- Semântica de `dia`: dia BRT. Frontend assume local (`formatLocalDate`).
- Storage não muda: `ciclos.planner_invoked_at` continua UTC ISO 8601.

### Esta convenção NÃO generaliza

Vale **apenas** pro bucketing diário em `/api/metricas/overview`.
Não vale automaticamente pra:
- Outros endpoints que vierem a agregar por dia (decidir explicitamente).
- Campos individuais de timestamp na API (`started_at`, `closed_at`,
  `planner_invoked_at`, etc) — esses continuam UTC literais.
- Filtros baseados em data (ex: "últimos N dias") — `cutoff_iso` é UTC.

Sem decisão explícita em outro contexto, default é UTC (estado nativo
do storage).

### Hardcode `-3 hours` é decisão MVP

Brasil aboliu horário de verão em 2019; offset estável. Promover pra
configuração explícita (`MMB_LOGGER_TZ_OFFSET` env var) se:
- Brasil voltar a usar DST, **ou**
- operação ficar multi-timezone (usuários fora do fuso BRT).

Até lá, hardcode é aceitável e auditado por teste de borda em
`mmb-logger/tests/test_metrics_bucketing.py`.

## `--reset` é destrutivo (atenção)

`mmb-logger reconcile --reset` apaga as tabelas `ciclos` e `epicos`
antes de reconciliar. Implicações que precisam estar claras:

- Eventos órfãos caem via `ON DELETE CASCADE` (`eventos.ciclo_id`
  REFERENCES `ciclos.id`).
- **`assertiveness_score` e `review_note` SÃO PERDIDOS** com o ciclo
  — não são tabela separada; são colunas da row que está sendo
  apagada. Anotação humana de avaliação não sobrevive a `--reset`.
- Não toca `projetos`, `processed_files`, `jsonl_cursor`.

Quando usar:
- Cutover inicial (sair de inferência R1-R9 → reconcile).
- Rebuild controlado quando a projeção saiu de sincronia com GH
  (ex: depois de mudar regra de derivação em fix bug grave).
- Smoke / debug em DB descartável.

Quando **não** usar:
- Sempre que houver avaliações humanas reais no DB que importam.
  Reconcile aditivo (sem flag) já preserva colunas humanas por
  UPSERT seletivo — é o caminho normal.

Protocolo antes de rodar:
1. `cp mmb-logger.db mmb-logger.pre-reset-<data>.sqlite`.
2. Confirmar com humano interessado nas avaliações (se aplicável).
3. Rodar `reconcile --reset`.
4. Inspecionar snapshot pra reconciliar manualmente
   `assertiveness_score` / `review_note` se necessário (cockpit PATCH).

CLI mostra `⚠  --reset é DESTRUTIVO` em vermelho antes de proceder.
Não há confirmação interativa — flag explícita é o consentimento.

## Não-objetivos do reconciler

O que o reconciler **nunca** faz:

- Transiciona estado a partir de subject de mensagem (era R1-R9; morto
  na fase 3).
- Cria evento "artificial" pra preencher gap (se PR não casou com issue,
  NÃO inventa o link).
- Inventa linkagem entre evento órfão e ciclo via heurística agressiva
  (manter órfão honesto é melhor que linkagem inventada — ver seção
  "Eventos linkados vs órfãos" acima).
- Sobrescreve coluna do domínio humano.
- Apaga registros pré-existentes em `eventos` (audit é imutável).
- Estima `cost_usd` quando transcript ausente (`NULL` honesto).
- Renomeia slugs ou IDs depois de criados (natural key é estável).
- Decide fechar épico (apenas projeta o estado da decisão humana).

## Validação e warnings

Toda quebra de convenção produz entrada em `.tooling/logs/journal.jsonl`
com `kind="reconcile-warning"`. Categorias:

| Categoria | Quando dispara |
|---|---|
| `missing-anchor` | issue GH sem `mmb-cycle-key` no body |
| `anchor-mismatch` | âncora presente mas `mmb-briefing-file` não bate com `mmb-cycle-key` |
| `orphan-issue` | issue tem âncora mas nenhum briefing casa |
| `orphan-briefing-stale` | briefing > threshold sem issue nem sinal de falha |
| `pr-without-closes` | PR sem `Closes #<N>` no body |
| `branch-off-convention` | `pr.headRefName` não casa com `task/<id>-<slug>` |
| `multiple-prs-for-issue` | mais de um PR linkando a mesma issue (deveria ser 1:1) |
| `multiple-briefings-no-anchor` | fallback heurística acionado com >1 candidato |
| `transcript-missing` | fase 4: worktree esperada não tem transcript |
| `transcript-multi-session` | fase 4: múltiplos session UUIDs no mesmo worktree dir |

Cockpit deve ter painel "saúde do reconcile" listando warnings recentes.
Sem isso, drift de convenção acumula em silêncio.

## Cockpit como consumidor: contrato de NULL

Reconciler garante consistência referencial, **não** preenchimento total.
Cockpit deve tolerar `NULL` em qualquer coluna do domínio derivado
exceto PKs e timestamps de nascimento (`id`, `epico_id`, `slug`,
`started_at`, `planner_invoked_at`). Em particular:

- `pr_url`, `pr_number`, `merged_to_main`, `diff_*`: `NULL` para ciclos
  em `iniciado`, `planejado`, ou `abortado` pré-GH.
- `cost_usd`, `tokens_*`: `NULL` enquanto fase 4 não estiver implementada,
  ou para qualquer ciclo cujo transcript não foi encontrado.
- `assertiveness_score`, `review_note`: `NULL` até o Rick anotar.
- `abort_*`: `NULL` para ciclos não-abortados.

Quebra de UI em `NULL` é bug do cockpit, não do logger. Os tipos em
`mmb-cockpit/src/types/api.ts` devem refletir opcionalidade corretamente.

## Plano de implementação por fase

### Fase 0 — contrato e snapshot ✅

1. Este documento existir e estar revisado.
2. Implementar `.tooling/bin/create-task-issue.sh` (wrapper que prepende
   âncora ao body).
3. Atualizar profile do orq local pra referenciar o wrapper.
4. Validar empiricamente os 5 inputs (GH issues/PRs reais com labels,
   transcript Claude parseável).
5. Decidir se custo será automatizado (fase 4 sim/não) e registrar.
6. `cp mmb-logger.db mmb-logger.pre-reconcile.sqlite` + commit
   descritivo. Snapshot é lápide, não migration.

### Fase 1 — reconcile GH-only ✅

1. Implementar `mmb-logger/src/mmb_logger/reconcile/gh.py` +
   `reconcile.py`.
2. Deriva ciclos do GH (não cria `iniciado` ainda — limitação
   reconhecida da fase).
3. UPSERT com `DERIVED_COLS` constante; teste de preservação humana.
4. Validação ruidosa de âncora ausente, `Closes #N` ausente, etc.
5. CLI: `mmb-logger reconcile [--reset]`.
6. Cutover: drop ciclos+épicos, reconcile, valida estado real do GH.

### Fase 2 — inbox dispatch como nascimento ✅

1. Reconciler lê `.tooling/inbox/<repo-short>/**/*_master_briefing_*.md`
   (inclui `.processing/`, `.done/`).
2. Cria ciclos `iniciado` para briefings sem issue casada.
3. Casa briefing → issue via âncora; fallback heurística com warning.
4. Detecta abortado pré-GH via sinais colaterais (worker
   exit/timeout/deregister/staleness).
5. Natural key passa a ser `(epic_slug, project_short, briefing_ts)` —
   re-dispatch gera ciclo novo.

### Fase 3 — desarmar inferência antiga + audit/enriquecimento ✅

1. Deletar `ingest/inference.py`, `runner.py`, `watcher.py`. Remover
   `ingest-once` e `watch` do CLI.
2. `reconcile/audit.py` escreve eventos `journal_*`, `atomic_*`,
   `msg_send`, `msg_receive` com `source_key` único (INSERT OR IGNORE).
3. `reconcile/intents.py` preenche `epicos.intencao` a partir de
   `master-briefing.md`.
4. R1-R5 (transição de estado via regex em subject) morrem por construção
   física: o arquivo não existe mais.
5. Inbox volta a ser canal de comunicação + audit, nunca motor de estado.

### Fase 4 — custo via transcripts ✅

1. `reconcile/transcripts.py` resolve worktree path canônico por ciclo
   (encoding `/→-`, `.→-`).
2. Encontra dir `~/.claude/projects/<encoded>`, parseia JSONLs.
3. Soma `usage`, aplica tabela de preço por modelo.
4. `NULL` honesto quando transcript ausente, modelo desconhecido,
   JSONL inválido. Warnings explícitos pra multi-session / mixed-model.

### Fase 5 — `emit` restrito (deferred, zero kinds)

**Status: adiada por princípio. Zero kinds. Não há implementação.**

A fase 5 representa a categoria "intenção irredutível que não cabe em
nenhuma outra fonte canônica nem em cockpit PATCH". Em ~5 meses de
operação do método não apareceu caso real que satisfaça isso. **Default
é permanecer aqui.**

Critério rigoroso pra eventualmente abrir fase 5 — precisa satisfazer
**TODAS** as 4 condições:

1. **Não é derivável** de nenhuma das fontes canônicas existentes:
   - GitHub (issues, PRs, labels, body, merges, diffs)
   - Inbox (briefings master→planner + msgs audit)
   - Journal (warn/error/critical + commd ops)
   - Agents.jsonl (spawn/deregister + reasons)
   - Transcripts Claude (cost/tokens/model)
   - Intents (master-briefing.md em `.tooling/intents/<slug>/`)

2. **Não cabe em cockpit PATCH.** Não é anotação humana sobre row
   existente — é fato independente que precisa de row própria.

3. **Não é melhor representado por ADR ou documento markdown.** Não é
   decisão arquitetural ou nota; é evento operacional discreto,
   indexável.

4. **Precisa entrar no SQLite como evento.** Não é só audit humano;
   tem que ser queryable estruturadamente pelo cockpit.

Se um caso real satisfizer as 4 condições, abrir fase 5 com escopo
mínimo: 1 kind concreto, schema versionado, contrato registrado aqui
no source-of-truth.md.

**Permanecer em zero kinds é sucesso.** Indica que o paradigma reconcile
+ cockpit PATCH cobriu tudo que apareceu. Adicionar kind por antecipação
é exatamente o anti-padrão que evitamos desde o início.

## Visão arquitetural — estado pós-fase 4

O método operacional convergiu para um paradigma único: **reconcile
como projeção pura sobre artefatos canônicos**. O logger não é onde a
verdade nasce, é onde ela assenta.

### Fluxo operacional

```
              ┌─────────────────┐
              │ master (sessão) │  ← Rick conversa
              └────────┬────────┘
                       │ dispatch via msg.sh
                       ↓
            ┌──────────────────────┐
            │  inbox/<repo>/*.md   │  ← briefing master→planner
            └──────────┬───────────┘
                       │
                       ↓ commd → worker stateless
                       │
              orq local cria issue   (create-task-issue.sh com âncora)
                       ↓
              spawn-atomic.sh → atômico em worktree
                       ↓
              transcript em ~/.claude/projects/
                       ↓
              atômico abre PR        (open-pr.sh com Closes #N)
                       ↓
              Rick mergeia

      [+] artefatos colaterais ao longo do caminho:
          • logs/journal.jsonl     warn/error/critical
          • state/agents.jsonl    spawn/deregister
          • .tooling/intents/     master-briefing.md por épico

                       ↓
            ┌────────────────────────┐
            │  reconcile (one-shot)  │  ← projeta tudo em DB
            └──────────┬─────────────┘
                       ↓
                ┌──────────────┐
                │ SQLite DB    │
                │  • ciclos    │
                │  • epicos    │
                │  • eventos   │
                └──────┬───────┘
                       ↓
                ┌──────────────┐
                │ cockpit UI   │  ← Rick anota via PATCH
                └──────────────┘
```

### Seis fontes canônicas (input do reconciler)

| Fonte | O que entrega | Fase |
|---|---|---|
| **GitHub API** (via `gh` CLI) | issues + PRs dos 3 repos. Coluna vertebral de `planejado/pr_aberto/completo/abortado-pós-GH`. | 1 |
| **Inbox** (`.tooling/inbox/**`) | briefings master→planner (nascimento de ciclos `iniciado`) + auditoria de mensagens. | 2, 3 |
| **Journal** (`.tooling/logs/journal.jsonl`) | warn/error/critical como eventos audit + commd-worker-exit/timeout como sinais de aborto pré-GH. | 2, 3 |
| **Agents** (`.tooling/state/agents.jsonl`) | spawn/deregister como audit + reasons classificáveis como sinais de aborto. | 2, 3 |
| **Transcripts Claude** (`~/.claude/projects/<encoded>/*.jsonl`) | cost/tokens/model por ciclo com PR. | 4 |
| **Intents** (`.tooling/intents/<slug>/master-briefing.md`) | `epicos.intencao` legível. | 3 |

### Dois domínios na DB (fronteira lei)

- **Derivado** (reconciler escreve, UPSERT seletivo): tudo que vem das
  fontes canônicas. Idempotente. NULL quando fonte ausente.
- **Humano** (cockpit PATCH escreve, reconciler **nunca** toca):
  `assertiveness_score`, `review_note`. Protegido por constante
  `DERIVED_COLS` testada por reconcile que insere score, roda
  reconcile, verifica sobrevivência.

### Cinco princípios operacionais

1. **Pull, não push.** Reconcile lê o mundo como está; nenhum agente
   precisa "lembrar de declarar". Os artefatos existem por outras
   razões (PR foi aberto porque é o trabalho real, não pra alimentar
   logger).

2. **NULL honesto > número falso.** Sem fonte = NULL + warning.
   Estimativa inventada é exatamente o que matamos em R1-R5; não
   regredimos.

3. **Órfão honesto > linkagem inventada.** Eventos sem ciclo casável
   ficam `ciclo_id=NULL`. Reconciler não tenta heurística agressiva
   pra reduzir órfãos.

4. **Idempotência por construção.** UPSERT seletivo de colunas
   derivadas + UNIQUE parcial `source_key` em eventos. Rodar
   reconcile N vezes produz o mesmo estado.

5. **Convenções validadas com warning ruidoso.** Quando contrato é
   quebrado (PR sem `Closes #N`, issue sem âncora, briefing sem
   thread, etc), reconciler sinaliza explicitamente em vez de fingir
   entender.

### O que o reconciler nunca faz

- Transiciona estado por regex em subject (R1-R9 deletadas na fase 3).
- Inventa linkagem entre evento órfão e ciclo.
- Sobrescreve coluna humana.
- Estima cost_usd quando dados faltam.
- Renomeia natural keys já estabelecidas.
- Decide fechar épico (sem fonte canônica clara — épico fechado é
  pendência consciente até critério canônico ser definido).

### Snapshot do estado real (2026-05-16)

- **13 épicos**, **29 ciclos**, **68 eventos** materializados.
- **4 ciclos com custo computado**, **$11.28 acumulado** (resto NULL
  por design — sem PR ou sem transcript disponível).
- **1 épico com intenção enriquecida** a partir de master-briefing.md.
- **23 warnings** misturando sujeira pré-cutover (issues sem âncora,
  PRs sem Closes #N) e estados raros legítimos (multi-session,
  mixed-model, transcript missing).
- **3 runs back-to-back** produzem estado idêntico.

### Tamanho do código resultante

- `reconcile/` (~9 módulos): `gh.py`, `inbox.py`, `derive.py`,
  `abort.py`, `audit.py`, `intents.py`, `transcripts.py`,
  `reconcile.py`, `_runtime.py`.
- Código legado deletado na fase 3: 4 arquivos, ~26 KB
  (`inference.py`, `runner.py`, `watcher.py`, `test_inference.py`).
- Testes: 111/111 verde (23 fase 1 + 19 fase 2 + 13 fase 3 + 19 fase 4
  + 37 outros).
- CLI: 4 comandos (`version`, `init-db`, `serve`, `reconcile`).

## Evolução deste documento

Este doc é versionado em git como qualquer código. Mudanças relevantes:

- **Coluna nova** (derivada ou humana): adiciona linha na matriz,
  identifica fase de implementação, garante que cockpit tolera `NULL`
  antes do deploy.
- **Convenção nova** que reconciler passa a depender: adiciona na seção
  "Convenções", com mecanismo de validação correspondente em warnings.
- **Kind de evento novo**: registra na matriz de eventos.
- **Kind de `emit` novo**: só entra se passar pelo filtro do princípio
  operacional. Quando passar, ganha seção própria.

Mudanças no contrato exigem PR no andaime que **simultaneamente**
atualize: este doc, o profile relevante (master/orq/atômico), e o teste
do reconciler. Sem alinhamento dos três, PR é bloqueado.

## Referências cruzadas

- [`protocol.md`](protocol.md) — protocolo de mensageria (briefings, msg.sh).
- [`guardrails.md`](guardrails.md) — comportamentos vetados dos agentes.
- [`profiles/master.md`](profiles/master.md) — papel do mestre (origem dos briefings).
- [`profiles/project-orchestrator.md`](profiles/project-orchestrator.md) — papel do orq (origem das issues, deve usar wrapper de âncora).
- [`profiles/atomic-agent.md`](profiles/atomic-agent.md) — papel do atômico (origem dos PRs).
- `../mmb-logger/schema.sql` — schema SQLite que este contrato projeta.
- `../mmb-logger/src/mmb_logger/models.py` — tipos Pydantic espelhados em TS no cockpit.
