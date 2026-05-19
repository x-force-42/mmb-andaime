# Guardrails — comportamentos a inibir (MMB v3)

Matriz de **comportamentos indesejados** observados ou previstos
no método, com a regra correta e o mecanismo de mitigação no
andaime. Cada profile (`master.md`, `project-orchestrator.md`,
`atomic-agent.md`) referencia este doc.

**Convenção:** ❌ = nunca; ✅ = fazer assim; 🛡️ = onde no andaime
isso é mitigado.

> **Atualização v0.3+ — workers stateless.** Orq locais não são mais
> sessões Claude vivas; são processos efêmeros disparados pelo
> `commd` quando uma mensagem cai no inbox. Implicações:
> - **L8** (polling do orq) e **L12** (supervision tick do orq) viram
>   **obsoletos** — worker não tem turn, não tem filho pra supervisionar
>   entre invocações.
> - **M5** (polling do master) **continua valendo** — master segue
>   sessão Claude interativa.
> - **A6** (heartbeat do atômico) **continua valendo** — atômico
>   continua processo de vida média em pane tmux.
> - Novo: **L14** sobre não "aguardar" dentro do worker (escale + termine).

## Mestre

### M1 — Criar issue diretamente no GitHub

❌ `gh issue create ...` partindo da sessão master.
✅ Mestre **dispara briefing** via `msg.sh <repo> briefing ...`.
   Orq local é quem materializa como issue.
🛡️ Profile master.md proíbe explicitamente; profile do orq
   local instrui que **só** ele cria issues do repo dele.

### M2 — Tocar código de produção

❌ Editar `.py`, `.ts`, `bot.py`, etc nos 3 repos.
✅ Vira tarefa pro orq local, mesmo que trivial.
🛡️ Profile master.md tem "constraints duras" no topo.

### M3 — Disparar briefing sem aprovação do Rick

❌ Rodar `msg.sh ... briefing` sem mostrar briefing pro Rick
   antes na conversa.
✅ Fase 3 do ciclo: mostrar briefing completo, aguardar "ok"
   explícito.
🛡️ Anti-padrão registrado; é o único ponto de aprovação humana
   antes do PR final.

### M4 — Conversar com orq local fora do `msg.sh`

❌ `tmux send-keys -t mmb:cockpit "..."` manual.
✅ Sempre via `msg.sh` — garante audit trail + frontmatter
   + ping consistente.
🛡️ Profile lista `msg.sh` como **único canal de saída**.

### M8 — Pedir aprovação a cada passo (over-cautious)

❌ Confirmar com Rick "posso ler tal arquivo?", "posso rodar
   gh pr list?", "posso mandar status?".
✅ Aprovação humana é nos **3 momentos canônicos**:
   - Intenção (Rick → master no início)
   - Briefing aprovado (master → Rick na fase 3)
   - PR mergeado (Rick → repo no fim)
   Entre eles, **autonomia total**.
🛡️ Profile master.md tem seção "Princípios implícitos" sobre
   autonomia.

### M9 — Executar tarefa sozinho em vez de dispatch

❌ Mestre pega tarefa single-repo simples e tenta "resolver
   rápido" rodando comandos no repo.
✅ Mesmo single-repo trivial vai pro orq local. Sempre.
🛡️ Anti-padrão atualizado pós-teste de fogo (v2 rejeitava
   single-repo; v3 dispatcha mas Mestre nunca executa).

### M5 — Pular polling do inbox no início do turn (v0.1+)

❌ Começar turn agindo direto sem checar mensagens frias.
✅ Primeira ação de cada turn:
   `ls -1t .tooling/inbox/master/ | grep -v '^\.'`. Processa
   o que aparecer, depois prossegue.
🛡️ Polling-on-every-turn fecha o gap de pings perdidos
   durante thinking (observado no smoke test do v0). Profile
   master.md instrui explicitamente.

### M6 — Fechar épico sem rodar review-cycle (v0.2+)

❌ Marcar épico como ✅ sem agregar o diário de bordo.
✅ Ao fechar épico, rode `review-cycle.sh <slug>` e apresenta
   o relatório pro Rick. Apenas com consentimento dele, gerar
   briefings de fortificação a partir de eventos não resolvidos.
🛡️ Perder a janela de aprendizado do épico é desperdício de
   sinal. Anti-overengineering exige Rick no loop.

## Orq Local

### L1 — Conversar direto com Rick

❌ Pedir input pro Rick, perguntar pra ele, esperar resposta dele.
✅ Tudo via `msg.sh master question ...`. Mestre conversa com
   Rick se precisar.
🛡️ Profile project-orchestrator.md: "Você NÃO conversa com
   Rick. Diretamente, nunca."

### L4 — Spawnar atômico sem criar issue antes

❌ `spawn-atomic.sh mmb-cockpit 1.1` sem ter rodado `gh issue create`.
✅ Sequência rígida: 1) `gh issue create`, 2) anota número,
   3) `spawn-atomic.sh <repo> <id> <issue-number>`.
🛡️ `spawn-atomic.sh` v3 **exige** issue# como 3º arg (não
   faz mais autodescoberta silenciosa).

### L5 — Não mandar status pro Mestre / mandar sem schema

❌ (a) Criar issue, spawnar atômico, esperar PR — sem nenhuma
   mensagem pro mestre. Mestre fica cego.
❌ (b) Mandar status com body em prosa livre sem os campos
   obrigatórios. Worker-master cai em heurística e escala
   pending-human por falso positivo (caso real: épico dark-mode
   2026-05-16 — 2 status `issue-criada-N` sem `issue_url` foram
   escalados).
✅ **3 status obrigatórios**, cada um com payload do contrato
   semântico em [`protocol.md`](protocol.md) seção "Contrato
   semântico dos `status`":
   - `status: issue-criada-<N>` (após criar+spawn) — campos:
     `issue_url`, `issue_number`, `repo`, `thread`.
   - `status: pr-aberto-<N>` (após PR aberto pelo atômico) —
     campos: `pr_url`, `pr_number`, `issue_number`, `suite_status`.
   - `status: task-fechada-<id>` ou `error: task-abortada-<id>`
     (após task-end/task-abort) — campos: `pr_url`, `pr_number`,
     `issue_number`, `merged_at`, `last_in_epic`.
🛡️ Profile project-orchestrator.md lista os marcos; `protocol.md`
   define o schema canônico. Worker-master faz matching exato
   sobre os campos — sem schema, não há matching seguro.

### L6 — Escalar pergunta trivial pro Mestre

❌ `msg.sh master question como-nomear-funcao ...` sobre coisa
   óbvia.
✅ Decisão local com bom senso, documentada no PR body.
   Escalar SÓ:
   - Decisão cross-repo (toca contrato de outro projeto).
   - Mudança de sentido do briefing.
   - Ambiguidade real que não dá pra desambiguar lendo o brief.
🛡️ Profile project-orchestrator.md tem "Escalação é exceção".

### L7 — Ignorar ping `MSG`

❌ Aparecer `MSG [...]` no prompt e Claude responder algo
   genérico ou continuar o que estava fazendo.
✅ **TODA mensagem é processada.** Acuse leitura ("recebi
   briefing X, processando"), depois aja.
🛡️ Profile project-orchestrator.md: "TODA mensagem é processada".

### L11 — Não usar task-abort em task quebrada

❌ Task atômico falhou, worktree fica pendurada por dias.
✅ Se atômico não chegou a abrir PR (crashou, decidiu não
   entregar, escopo bloqueado): `task-abort.sh <repo> <id>` +
   `msg.sh master error task-abortada-<id> ...`.
🛡️ Script `task-abort.sh` existe especificamente pra isso.

### ~~L8~~ — Pular polling do inbox no início do turn (OBSOLETO desde v0.3)

> No modelo de workers stateless, o `commd` invoca o worker com a
> mensagem específica como parâmetro. Não há "início de turn" pra
> fazer polling. Worker pode ler inbox por contexto histórico
> (mensagens da mesma thread), mas não está obrigado.

### ~~L12~~ — Esquecer supervision tick (OBSOLETO desde v0.3)

> Worker stateless não fica vivo entre invocações; não há "checar
> filho periodicamente". A supervision de atômicos passa a ser
> responsabilidade do *próximo* worker do mesmo papel (que ao
> receber qualquer mensagem nova, pode rodar `agents.sh
> check-children` se fizer sentido) ou de um cron simples.

### L14 — Worker tentar "aguardar" dentro da invocação (v0.3+)

❌ Worker recebe briefing ambíguo, manda `msg.sh master question`,
   e fica tentando *esperar* a answer chegar (sleep, loop, etc).
✅ Escala via `msg.sh master question`, escreve resumo curto via
   stdout dizendo "aguardando answer X (thread Y)", e **termina**.
   Quando a answer chegar no inbox, o commd dispara um worker novo
   que lê a thread, vê o estado, e continua o trabalho.
🛡️ Worker stateless é caro de manter vivo (claude -p consume
   tokens enquanto roda). "Esperar" é desperdício e bloqueia o
   slot serializado por destinatário, impedindo outras mensagens
   do mesmo papel de serem processadas.

### L15 — Criar sub-issue do método sem o wrapper (v0.4+)

❌ `gh issue create --repo ... --label task,... --body-file <briefing>`
   chamado direto pra sub-issue do método.
✅ `.tooling/bin/create-task-issue.sh <repo> <briefing-file>`. Wrapper
   extrai frontmatter, prepende âncora `mmb-cycle-key`, aplica labels
   obrigatórias, valida que `to` casa com repo. Stdout = número da issue
   (capturável).
🛡️ Sem a âncora, o reconciler do mmb-logger regride pra heurística
   "briefing mais recente sem issue casada" e gera warning
   `missing-anchor`. Contrato em
   [`source-of-truth.md`](source-of-truth.md). Exceção: issues criadas
   pelo Rick fora do método (hotfix, doc, etc) — essas viram warning
   esperado, sem ser violação.

### L13 — Erro de fluxo só em prosa, não estruturado (v0.2+)

❌ `msg.sh master error` com texto livre sem entrada no journal.
✅ Sempre que mandar `error` pro mestre, também rode:
   `log.sh error <event-slug> "<msg>" --epic <slug> --task <id>`.
🛡️ Sem o journal, `review-cycle.sh` ao fechar o épico não
   enxerga o erro — perde-se sinal pra evolução do andaime.

## Atômico

### A1 — Sair do escopo "Dentro" do brief

❌ Refatorar arquivo vizinho "já que estou aqui".
✅ Escopo do brief é lei. Anota oportunidades no PR body
   pro orq local decidir.
🛡️ Profile atomic-agent.md: "Escopo do brief vence" +
   sub-issue tem seção "Fora" explícita.

### A2 — Push direto pra main/master

❌ `git push origin main` ou `git checkout main && commit`.
✅ Único caminho: branch `task/<id>-<slug>` + `open-pr.sh`.
🛡️ Pré-flight obrigatório: "Você não está em main/master".
   `open-pr.sh` valida que branch é `task/*`.

### A3 — Usar `--no-verify` em commit/push

❌ Pular hooks que estão "atrapalhando".
✅ Conserte a causa, não silencie o sensor.
🛡️ Profile: "Nunca pule (--no-verify proibido)". Convenção
   listada na tabela.

### A4 — Pular testes locais

❌ Commitar sem rodar pytest/npm test.
✅ Rodar antes de cada commit. Se quebrar, conserta antes
   do próximo.
🛡️ Profile fluxo de trabalho lista como passo 2.

### A5 — Inventar decisão pra "decisão em aberto"

❌ Brief tem "decidir entre A e B" e atômico escolhe sem
   sinalizar.
✅ **Pare e saia sem agir.** Você não tem canal pra perguntar.
   Sua não-entrega sinaliza ao orq local que brief estava ruim.
🛡️ Profile: "Pare e saia sem agir. Não chute, não escale."

### A8 — Continuar trabalhando após `open-pr.sh`

❌ Atômico abre PR e tenta "polir" mais alguma coisa antes
   do pane fechar.
✅ Após `open-pr.sh`, sessão termina. Pane se fecha em 8s.
   Nada mais a fazer.
🛡️ `open-pr.sh` agenda `kill-pane` em background; profile
   diz "você não precisa rodar exit".

### A9 — Tentar mandar mensagem via `msg.sh`

❌ Atômico tenta `msg.sh master ...` ou similar.
✅ **Você não tem canal.** Toda comunicação é via PR body
   e commits.
🛡️ Profile: "Você não tem canal" + lista no anti-padrão.

### A6 — Esquecer heartbeat antes de cada commit (v0.1+)

❌ Trabalhar várias horas sem chamar `agents.sh heartbeat`.
✅ Antes de cada commit (ou no mínimo a cada 5 min de trabalho):
   `.tooling/bin/agents.sh heartbeat $MMB_AGENT_ID`. É 1
   linha de bash, sem overhead.
🛡️ Sem heartbeat, supervision tick do orq vai te declarar
   zumbi após `MMB_HEARTBEAT_TIMEOUT` e abortar a task —
   trabalho perdido.

### A7 — Sair sem entregar sem registrar no journal (v0.2+)

❌ Pré-flight falhou / hook quebrou / decisão em aberto → sair
   silenciosamente (atômico não tem `msg.sh`, mas tem `log.sh`).
✅ Antes de sair: `log.sh critical <event-slug> "<motivo>"
   --epic <slug> --task <id>`. Orq local diagnostica
   imediatamente via `review-cycle` ou `journal.jsonl`.
🛡️ Atômico sem voz = causa-raiz mascarada. log.sh é seu único
   canal de saída estruturada.

### A10 — Mergear PR (v0.8+)

❌ Atômico chama `gh pr merge` (qualquer variante: `--squash`,
   `--auto`, sem flags) após abrir PR.
✅ **Atômico NUNCA mergeia.** Autoridade de merge é exclusiva
   do Mestre/Rick. Após `open-pr.sh`, atômico encerra e o pane
   fecha sozinho em 8s (A8). Não roda mais nenhum comando `gh`.
🛡️ Profile do atômico tem instrução explícita; `open-pr.sh` não
   contém nenhuma chain de merge; `mmb_build_pr_body` produz PR
   pronto pra revisão humana. Origem: episódio do ux-refresh-v07
   onde logger PR #9 apareceu como já-merged quando o Mestre
   tentou mergear — auditoria pós-fato não achou auto-merge no
   andaime, então a hipótese forte é atômico Claude tendo
   decidido mergear autonomamente após `open-pr.sh`. Esta
   guardrail é a barreira explícita.

### A11 — Abrir PR sem suíte verde no body (v0.8+)

❌ Rodar `open-pr.sh` sem `MMB_SUITE_OUTPUT` apontando pra arquivo
   com output literal da suíte de testes verde.
✅ Antes de `open-pr.sh`, rode a suíte completa do repo (Pytest,
   Vitest, npm test, etc), redirecione output pra arquivo, e
   exporte:
   ```bash
   npm test 2>&1 | tee /tmp/suite.txt
   [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "vermelha"; exit 1; }
   MMB_SUITE_OUTPUT=/tmp/suite.txt .tooling/bin/open-pr.sh
   ```
🛡️ `open-pr.sh` valida (a) variável existe e não-vazia,
   (b) arquivo existe, (c) arquivo não-vazio, (d) >= 100 bytes
   (anti-gaming via `MMB_SUITE_MIN_BYTES`). Falha ruidosa com
   mensagem clara se ausente — exit 3. `mmb_build_pr_body` embute
   conteúdo na seção `## Suíte verde` do PR body, truncado em 4KB
   com nota se exceder. Revisores veem que testes rodaram sem
   precisar pedir. Origem: ux-refresh-v07, 3 PRs (logger #9,
   cockpit #14, aquarium #13) abertos sem qualquer evidência de
   teste no body apesar do Rick ter sido enfático no briefing.

## Concorrência

### X1 — 2 atômicos no mesmo arquivo (mesmo repo)

❌ Spawnar 2 tasks que tocam arquivo X simultaneamente sem
   coordenação.
✅ Briefing declara "Conflito potencial com" outras tasks.
   Orq local sequencializa, ou se forem inevitavelmente
   paralelos, último a mergear rebaseia.
🛡️ Template `task-briefing.md` tem seção "Conflito potencial
   com". `check-deps.sh` verifica deps mergeadas.

### X2 — Ping caindo em zsh (sessão Claude morta)

❌ Sessão Claude morreu/saiu; ping de outra tab vai pro shell
   e quebra.
✅ Ao reabrir sessão Claude, primeira ação é `ls inbox/<tab>/`
   pra ver mensagens pendentes.
🛡️ `up.sh` instrui sessão a listar inbox como primeira ação.
   Mensagem está persistida no arquivo — só o ping é volátil.

### X3 — `msg.sh` executado fora de tmux

❌ Rodar `msg.sh` em terminal solto fora da sessão `mmb`.
✅ msg.sh detecta ausência de tmux, grava arquivo, avisa que
   não enviou ping. Receptor lê inbox quando reabrir.
🛡️ Já implementado no script.

## Padrão de violação → recuperação

Quando você (Claude session) perceber que está prestes a violar
um destes guardrails:

1. **PARE** antes de executar a ação.
2. **Sinalize** na conversa: "ia fazer X mas isso viola guardrail
   <id>. Vou fazer Y em vez."
3. Se for caso ambíguo: pergunte (no caso do mestre, ao Rick;
   no caso do orq, ao mestre via `msg.sh ... question`).
4. **Nunca** rode a ação proibida só pra "ver se funciona".
   O custo de reverter é alto.

## Como este doc evolui

- Quando um novo padrão indesejado for observado: adicione
  aqui PRIMEIRO, depois reforce o profile relevante.
- Numere por camada (M para mestre, L para orq local, A para
  atômico, X para cross-cutting) pra facilitar referência
  cruzada.
- Cada item: ❌ comportamento, ✅ correto, 🛡️ mitigação.

## Referências cruzadas

- [`protocol.md`](protocol.md) — protocolo de comunicação.
- [`profiles/master.md`](profiles/master.md) — papel do mestre.
- [`profiles/project-orchestrator.md`](profiles/project-orchestrator.md) — papel do orq local.
- [`profiles/atomic-agent.md`](profiles/atomic-agent.md) — papel do atômico.
- [`README.md`](README.md) — visão geral do andaime.
