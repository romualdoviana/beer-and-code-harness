# Beer and Code Harness (`bc-harness`)

Plugin de [Claude Code](https://claude.com/claude-code) com comandos, agentes e scripts para levar um projeto da ideia à implementação de forma estruturada: especificação formal, planejamento em fases e execução autônoma com validação mecânica — sem abrir mão do controle humano nos pontos de decisão.

O harness é **agnóstico de stack**: quem define linguagem, framework, comandos e convenções são os documentos do próprio projeto (`AGENTS.md`, `CLAUDE.md`, cadeia `.spec/`), nunca o harness.

## Visão geral do fluxo

```
 IDEIA                                             CÓDIGO
   │                                                 ▲
   ▼                                                 │
 /init:project-description  ──┐                      │
 /init:user-stories           │  cadeia init         │
 /init:database-schema        │  (.spec/init/)       │
 /init:project-phases       ──┘                      │
   │                                                 │
   │            /plan "<descrição da feature>"       │
   │            (.spec/features/<slug>/)             │
   ▼                                                 │
 project-phases.md  ou  PHASES.md ────────► scripts/ralph.sh
                                            (execução autônoma
                                             com 4 gates)
   ▲                                                 │
   │            /bugfix "<relato do bug>"            │
   │            baixo ─► correção inline, sem commit ┤
   └──────────  alto  ─► .spec/bugfixes/<slug>/      │
                                                     │
 /ai-context ─► AGENTS.md + docs/agents/*  (documenta o código JÁ implementado;
                                            alimenta /plan, /bugfix e o ralph)
```

Quatro pipelines independentes que se encaixam:

1. **`/init`** — do zero ao plano de construção do projeto (descrição → user stories → schema → fases).
2. **`/plan`** — de uma descrição de feature a SPEC formal + plano faseado, pronto para execução.
3. **`/bugfix`** — de um relato de bug a uma causa raiz provada e corrigida: inline quando o defeito é pequeno, faseado quando é sistêmico.
4. **`ralph.sh`** — executa qualquer documento de fases de forma autônoma, uma sessão nova de agente por fase, com gates mecânicos e um commit por fase concluída.

Transversal a tudo: **`/ai-context`** mantém a árvore de contexto (`AGENTS.md`, `CLAUDE.md`, `docs/agents/*.md`) sincronizada com o código real.

## Instalação

O repositório é um plugin de Claude Code (`.claude-plugin/plugin.json`). Instale via marketplace/caminho local conforme sua configuração de plugins:

```
/plugin install bc-harness
```

Os comandos ficam disponíveis com namespace: `/bc-harness:init`, `/bc-harness:plan`, etc. (nesta documentação, abreviados sem o namespace).

O `ralph.sh` é um script bash independente — copie ou referencie `scripts/ralph.sh` e rode direto no repositório do projeto-alvo.

**Pré-requisitos do ralph.sh:**

- Engine Codex: `npm install -g @openai/codex` + `OPENAI_API_KEY`
- Engine Claude: `npm install -g @anthropic-ai/claude-code` + `ANTHROPIC_API_KEY`
- Raiz de um repositório git com árvore de trabalho **limpa**

## Comandos

### `/init` — roteador da cadeia init

Mostra o estado dos artefatos de `.spec/init/` (presente / ausente / desatualizado) e **invoca o próximo comando da cadeia** (um passo por execução — re-rode `/init` para avançar). Não escreve nada por conta própria; toda autoria vive no comando `init:*` invocado.

A cadeia, em ordem:

| # | Artefato | Comando | Insumos |
|---|---|---|---|
| 1 | `.spec/init/project-description.md` | `/init:project-description` | — (cabeça da cadeia) |
| 2 | `.spec/init/user-stories.md` | `/init:user-stories` | project-description |
| 3 | `.spec/init/database-schema.md` | `/init:database-schema` | description + stories |
| 4 | `.spec/init/project-phases.md` | `/init:project-phases` | description + stories + schema |
| — | `.spec/init/design/` | manual (opcional) | — |

Cada artefato gerado carrega na linha 3 um **stamp** dos insumos (`arquivo@sha256:<12 chars>`). Se um insumo mudar depois, o `/init` detecta e reporta o downstream como *stale* — re-rodar o comando correspondente é upsert-safe: ele entrevista só sobre os deltas e atualiza o stamp.

- **`/init:project-description`** — entrevista o desenvolvedor, descobre a stack e produz a descrição estruturada do projeto.
- **`/init:user-stories`** — deriva user stories estruturadas e testáveis da descrição.
- **`/init:database-schema`** — deriva um schema de banco sugerido em DBML.
- **`/init:project-phases`** — planeja a construção em fases numeradas, agent-ready, com tasks, acceptance criteria e feature tests. **É o input padrão do `ralph.sh`.** Lê `.spec/init/design/` quando existir (refs de telas/componentes).

### `/plan` — pipeline de planejamento de feature

```
/plan "<descrição da feature ou caminho para arquivo de descrição>"
```

Produz, sob `.spec/features/<slug>/`:

| Artefato | Conteúdo |
|---|---|
| `SPEC.md` | Especificação formal em GEARS, com seções RIGID/FLEXIBLE, diagramas AS IS / TO BE e acceptance criteria binários |
| `PLAN.md` | Decomposição de tasks consciente da arquitetura, com fases de dependência, riscos e critérios de validação |
| `PHASES.md` | Visão do PLAN no formato executável pelo `ralph.sh` |
| `openapi.yaml` / `service.proto` / `asyncapi.yaml` | Contratos formais, quando a SPEC declara superfície de API (condicional) |

Características:

- **Sem issue tracker** — a descrição confirmada + ACs são a fonte de verdade. Nada de Jira.
- **Tier de complexidade** (`light` / `standard` / `complete`) classificado por sinais objetivos (nº de requisitos, multi-repo, contratos, mensageria); ajusta a profundidade da SPEC, a obrigatoriedade do clarifier e a emissão de contratos.
- **Checkpoints humanos** em cada etapa: confirmação do input normalizado, aprovação da SPEC, resolução de ambiguidades, confirmação da decomposição.
- **Clarifier em duas fases** — o agente analisa a SPEC e devolve perguntas priorizadas; o roteador as apresenta ao desenvolvedor e re-invoca o agente com as respostas, que atualiza a SPEC in-place.
- **Gate de arquitetura** — exige `AGENTS.md` / `docs/agents/` (ou avisa e marca `architecture_reference_status: missing`). Sem contexto de arquitetura o pipeline nunca planeja em silêncio.
- **Nunca escreve código de aplicação.** O fechamento aponta o handoff de execução:

```bash
./ralph.sh .spec/features/<slug>/PHASES.md
```

### `/bugfix` — pipeline de defeito

```
/bugfix "<relato do bug ou caminho de um arquivo com o relato>"
```

O `/plan` especifica algo que ainda não existe. Defeito é diferente em dois pontos que mudam o pipeline inteiro: carrega **evidência** (stack trace, log, comportamento observado) que dá para reproduzir e provar, e carrega **não-regressão** como critério obrigatório. Forçar um bug pelo `/plan` produz especificação de código que já existe e está quebrado.

O pipeline reproduz o bug, rastreia a causa raiz e então pega a rota mais barata que ainda prova a correção:

| Tier | Sinais | Rota |
|---|---|---|
| `light` | causa raiz identificada E ≤ 2 arquivos E 1 camada E sem migration E sem alterar contrato público | corrige inline: teste que falha → patch → suite completa, **sem commit** |
| `standard` | 3+ arquivos OU 2+ camadas OU exige migration OU altera contrato de API/evento | `.spec/bugfixes/<slug>/BUGFIX.md` + `PHASES.md` |
| `complete` | multi-repo OU causa raiz sistêmica OU risco de regressão em cascata | igual ao `standard` |

Sinais empatando entre tiers → sobe o tier. O tier é apresentado **junto com os sinais que o produziram** e confirmado pelo desenvolvedor antes de qualquer escrita.

Características principais:

- **Causa raiz, nunca sintoma.** Sem causa raiz não sai patch nem `PHASES.md`: o comando reporta as hipóteses e os dados que faltam.
- **Teste vermelho primeiro.** O comando de teste é resolvido pelas mesmas regras do `ralph.sh`, então o que a correção roda e o que o gate 2 roda são o mesmo comando. Projeto sem runner → aviso alto e ACs verificáveis à mão no lugar do teste.
- **Teste vermelho e correção na MESMA fase.** O gate 2 do ralph roda a suite inteira; uma fase que termina vermelha queimaria todos os ciclos de correção e abortaria o run. Fase 1 é `reproduzir e corrigir`; fase 2+ cobrem regressão e bordas. Nenhuma fase termina com suite vermelha.
- **Bug que não reproduz para num checkpoint.** O desenvolvedor decide: parar e juntar dados, ou seguir especulativo — e aí todo artefato carrega o marcador `[NAO REPRODUZIDO]` e os ACs explicitamente não são sustentados por teste vermelho.
- **Gate de arquitetura não-bloqueante**, diferente do `/plan`: defeito é reativo e muitas vezes urgente, então `AGENTS.md` ausente vira aviso e flag `architecture_reference_status: missing`, nunca bloqueio.
- **Fecha registrando o aprendizado.** A causa raiz é classificada um nível acima da instância, escopada (global vs `-project`) e proposta como uma linha `| bug | root cause | prevention |` em inglês no agent certo — escrita só após confirmação explícita.
- **Nenhuma escrita no git, em nenhum tier.** O desenvolvedor revisa com `git diff` e commita.

O tier alto encerra com o handoff de execução:

```bash
./ralph.sh .spec/bugfixes/<slug>/PHASES.md
```

### `/ai-context` — árvore de contexto canônica

```
/ai-context [path] [+id] [-id] [--adopt]
```

Gera ou atualiza 10 artefatos a partir do **código implementado** (nunca lê `.spec/`):

| Artefato | Conteúdo |
|---|---|
| `AGENTS.md` | 6 seções: comandos, convenções, regras comportamentais, setup, referências, índice de docs |
| `CLAUDE.md` | Redirect ≤ 400 bytes para AGENTS.md |
| `docs/agents/project_overview.md` | Propósito, consumidores, fluxo macro |
| `docs/agents/architecture.md` | Estilo, layout, responsabilidades por camada |
| `docs/agents/tech_stack.md` | Linguagem, framework, runtime, tooling de teste |
| `docs/agents/coding_guidelines.md` | ≥ 3 padrões observados + enforcement |
| `docs/agents/domain_rules.md` | Regras de negócio como implementadas |
| `docs/agents/api_contracts.md` | Endpoints, payloads, formatos de mensagem |
| `docs/agents/data_model.md` | Entidades, storage, migrations |
| `docs/agents/dependencies.md` | Serviços externos, libs internas, infra compartilhada |

Regras centrais:

- **Idempotente** — upsert seguro; re-rodar atualiza só o que sofreu drift.
- **Documenta a realidade (AS IS)** — código, manifests, CI e configs são as únicas fontes; nunca inventa, nunca prescreve.
- **Contrato de ownership** — todo arquivo gerado carrega banner na linha 3. Arquivo sem banner (escrito à mão) nunca é sobrescrito; `--adopt` incorpora as regras concretas dele à árvore gerada e assume a posse.
- **Preserva blocos de terceiros** — regiões `<tag>...</tag>` (ex.: Laravel Boost) são re-anexadas verbatim na regeneração.
- Filtros `+id` / `-id` geram só um subconjunto (ex.: `/ai-context +AGENTS +architecture`).

## `scripts/ralph.sh` — orquestrador de execução

Lê um documento de fases, quebra pelo heading `## Phase N: <título>` e alimenta cada fase a uma sessão **nova** do Codex CLI ou Claude Code, sem interação humana, do início ao fim.

```bash
./scripts/ralph.sh [opções] [caminho-do-arquivo]
```

Sem argumento, resolve o input nesta ordem: `.spec/init/project-phases.md` → `.spec/project-phases.md` (layout pré-init, com aviso). Um `PHASES.md` de feature também é input válido.

### Invariantes

1. Cada fase **e** cada ciclo de correção roda em sessão nova, com prompt auto-contido. Nunca reutiliza sessão.
2. Zero perguntas — execução totalmente autônoma.
3. Fase só é "completa" quando passa pelos **4 gates mecânicos**, nunca pelo exit code do engine.
4. Limite de uso da API → espera o reset e re-executa a **mesma** fase, sem consumir ciclo de correção.
5. **Um commit por fase concluída** (`feat(phase-N): <título>`).

### Os 4 gates

| Gate | Pergunta | Como decide |
|---|---|---|
| 0 | O engine terminou de verdade? | claude: `is_error` no JSON de resultado; codex: exit code |
| 1 | A sessão escreveu código? | Assinatura da árvore antes/depois. **Sinal, não veredito** — fase já implementada faz o engine (corretamente) não escrever nada; o sinal alimenta a causa do ciclo de correção |
| 2 | A suite de testes passa? | Rodada **pelo ralph**, fora da sessão do agente — o agente não pode "mentir verde" |
| 3 | Cada task está de fato no código? | Sessão verificadora independente, read-only, que emite `TASK <n>: DONE/INCOMPLETE` por task. Roda em toda fase por default (`RALPH_VERIFY=always`); no engine claude usa modelo barato (haiku) |

Qualquer gate vermelho → **ciclo de correção**: sessão nova recebe a fase inteira + a causa real da falha (nunca "os testes falharam" genérico). Default: 3 ciclos por fase.

Gates verdes com árvore limpa → fase já estava implementada em HEAD: marcada como feita, sem commit.

### Detecção do comando de teste (gate 2)

Primeira regra que resolver: `--test-cmd` → `RALPH_TEST_CMD` → detecção por manifest (Laravel Sail → `composer test` → `php artisan test` → `npm test` → `pytest` → `go test ./...` → `cargo test`) → nada resolvido = gate 2 pulado com aviso alto (gate 3 segura sozinho).

Projeto Laravel Sail: a suite roda **dentro do container** (`vendor/bin/sail test`); containers parados abortam no preflight — todo gate 2 falharia e queimaria ciclos à toa.

### Opções e variáveis

| Opção | Efeito |
|---|---|
| `--engine codex\|claude` | Engine de implementação (default: `codex`) |
| `--from N` | Começa na fase N (limpa o progresso das fases ≥ N) |
| `--keep-going` | Continua após fase falhar (cria commit `wip(phase-N)`; default: para) |
| `--max-cycles N` | Ciclos de correção por fase (default: 3) |
| `--test-cmd "<cmd>"` | Comando de teste do projeto (gate 2) |
| `--no-verify` | Desliga o gate 3 |
| `--ui` / `--no-ui` | Força o painel ANSI ligado / desligado (ver abaixo) |
| `--serve[=PORTA]` | Dashboard web local sobre o mesmo estado |

| Variável | Efeito |
|---|---|
| `RALPH_TEST_CMD` | Comando de teste (gate 2) |
| `RALPH_VERIFY` | Gate 3: `always` (default) \| `auto` (economiza: só quando o gate 2 não basta) \| `off` |
| `RALPH_VERIFY_MODEL` | Modelo do verificador (default no claude: `haiku`) |
| `RALPH_MAX_CYCLES` | Ciclos de correção por fase (default: 3) |
| `RALPH_MAX_LIMIT_WAITS` | Esperas consecutivas por limite de uso, por fase (default: 20) |
| `RALPH_LIMIT_WAIT_DEFAULT` | Fallback de espera em segundos (default: 1800) |
| `RALPH_LIMIT_BUFFER` | Segundos extras após o reset (default: 60) |
| `RALPH_NOTIFY_CMD` | Comando de notificação (vazio = desligado) |
| `RALPH_NOTIFY_TIMEOUT` | Timeout do comando de notificação em segundos (default: 20) |
| `RALPH_UI` | Painel: `auto` (default) \| `panel` \| `plain` |
| `RALPH_UI_FPS` | Repinturas do painel por segundo (default: 2) |
| `RALPH_UI_KEYS` | Navegação por teclado na tabela do painel: `1` (default) \| `0` desliga |
| `RALPH_SERVE_PORT` | Primeira porta tentada pelo `--serve` (default: 7433) |

Durante cada sessão, o ralph exporta `RALPH_ENGINE`, `RALPH_PROJECT`, `RALPH_PHASE_TITLE`, `RALPH_PHASE_NUM`, `RALPH_PHASE_TOTAL`, `RALPH_PHASE_ATTEMPT` e `RALPH_PHASE_MAX_ATTEMPTS`.

### Painel visual e dashboard web

Run é coisa de olhar, não de ler. O ralph desenha um painel de tela cheia enquanto o run acontece:

```
RALPH
Projeto: beer-and-code-harness   Engine: claude       Status: ▶ Em execução
Duração: 12m 04s                 Run:    run-48213    PID:    48213

┌─────────── PROGRESSO ────────────┐  ┌────────── TRABALHO ATUAL ──────────┐
│ Fases  2/9     [██████░░░░  22%] │  │ Fase:  3 · Autenticação JWT        │
│ Tasks  7/31    [████░░░░░░  22%] │  │ Ciclo: 1/3   Gate: G2              │
└──────────────────────────────────┘  │ Atividade: executando a suite      │
                                      │ Último erro: —                     │
                                      └────────────────────────────────────┘
┌──────────────────────── FASES E TASKS ─────────────────────────┐
│ ID   Fase / Task              Status         Tentativa  Gates  │
├────────────────────────────────────────────────────────────────┤
│ F1   Setup                    ✓ Concluída    1          G0 ✓ … │
│ F2   Migrations               ✓ Concluída    1          G0 ✓ … │
│ F3   Autenticação JWT         ▶ Em execução  1          G2 ⣾ … │
│ T1     ↳ Middleware de guard  ✓ Concluída    -          -      │
│ T2     ↳ Refresh token        ! Incompleta   -          -      │
│ F4   Policies                 · Pendente     -          G0 · … │
└────────────────────────────────────────────────────────────────┘
· reading app/Http/Middleware/Authenticate.php
14:22:07 Gate 2 — rodando a suite do projeto: vendor/bin/sail test
```

O painel roda no **buffer alternado** do terminal (como `vim` ou `less`): ocupa a tela inteira durante o run e, ao sair, devolve o terminal com o scrollback anterior intacto. É o que permite layout de altura variável — a tabela cresce com o número de fases e tasks do documento.

Seções: cabeçalho (projeto, engine, status, duração, run id, pid), **PROGRESSO** (barras de fases e de tasks concluídas), **TRABALHO ATUAL** (fase corrente, ciclo, gate ativo, atividade, último erro), **FASES E TASKS** (uma linha por fase e uma por task, veredito por gate na fase corrente, janela deslizante quando não cabe) e um rodapé com a última linha de progresso do engine mais as mensagens recentes.

O layout se adapta: os dois quadros de cima empilham abaixo de 100 colunas, a coluna `Gates` cai abaixo de 96 e `Tentativa` abaixo de 74. As linhas de task saem dos itens `- [ ]` de cada fase, e o veredito individual vem do gate 3 — `✓ Concluída` / `! Incompleta` por task, então dá para ver *qual* task travou a fase.

Quando a tabela não cabe na tela, dá para **andar pelas linhas** sem parar o run:

| Tecla | Ação |
| --- | --- |
| `↑` / `↓`, `k` / `j` | Uma linha para cima / para baixo |
| `PgUp` / `PgDn`, espaço | Uma tela para cima / para baixo |
| `g` / `Home`, `G` / `End` | Primeira / última linha |
| `a` | Volta ao modo automático (a janela segue a fase corrente) |

O rodapé da tabela mostra a faixa visível e o modo atual (`↑↓ rolar` = automático, `manual` = topo fixado por você). A leitura de tecla **não bloqueia nada**: ela substitui a espera entre repinturas, então o run segue nos gates independente do que for digitado — a invariante "zero perguntas" continua de pé. Sem `/dev/tty` legível, ou com `RALPH_UI_KEYS=0`, o painel volta ao comportamento anterior (janela sempre automática).

Uma sessão do engine dura minutos e a CLI pode não emitir nada legível nesse tempo. A seção **AO VIVO** existe para responder a uma pergunta só: *está travado ou trabalhando?* Tudo nela é medido **pelo processo que pinta a tela**, não publicado pelo orquestrador — durante `run_split` o processo principal está bloqueado esperando o engine e não teria como republicar nada:

| Sinal | Fonte | Por que muda sozinho |
|---|---|---|
| Etapa + tempo próprio | `stage_start`, reescrito a cada troca de etapa | separa "3m nesta fase" de "3m neste gate" |
| Saída do engine + taxa | `wc -c` nos dois logs da sessão, delta entre frames | engine vivo escreve; engine travado não |
| Arquivos tocados | `git status --porcelain`, recalculado a cada ~3s | mostra o trabalho aparecendo na árvore |
| Última linha de progresso | `tail` do `.stderr.log`, lido a cada frame | quando a CLI streama, é o que ela está fazendo |

Quando a CLI não streama progresso (`claude -p --output-format json` não escreve no stderr), a linha vira `engine em silêncio há Xs` em vez de repetir "aguardando" — a taxa de saída e a contagem de arquivos continuam sendo a prova de vida.

### Qual task está sendo trabalhada

O engine roda numa sessão **opaca**: nenhum evento diz em que task ele está. O que existe de concreto é (a) o texto da task, que nomeia identificadores de código, e (b) a árvore de trabalho mudando. O painel casa um com o outro.

De cada task o ralph extrai **âncoras** — conteúdo entre crases, `CamelCase`, `snake_case`, caminhos e nomes de arquivo, descartando o que não parece identificador. A cada ~3s ele confere quais âncoras já aparecem em algum caminho do repositório (rastreado ou recém-criado):

- **`▶ ~67%`** — task ativa: alguma âncora dela casa com o arquivo de **mtime mais recente**
- **`◐ ~100%`** — artefatos da task já apareceram, mas outra está sendo tocada agora
- **`· Pendente`** — nenhuma âncora casou, ou a task não nomeia identificador nenhum

O **`~` é deliberado**: é palpite fundamentado em arquivo real, não veredito. Presença de arquivo não prova implementação correta — quem julga a task continua sendo o gate 3, e o veredito dele (`✓ Concluída` / `! Incompleta`) **sempre** substitui a inferência quando chega. Task cujo texto não cita nenhum identificador não gera palpite algum, em vez de inventar um.


Marcas de status: `✓ Concluída`, `▶ Em execução`, `! Incompleta`, `✗ Falhou`, `» Pulada`, `· Pendente`. Marcas de gate: `·` não rodou, `⣾` rodando (spinner), `✓` verde, `✗` vermelho, `⊘` pulado. Durante espera por limite de uso, o status do cabeçalho vira um countdown até o reset.

`RALPH_UI=auto` (o default) desenha o painel **só** quando stdout é um TTY. Sob `nohup`, em CI ou através de pipe a saída é o placar em linha corrida, byte a byte igual à de um ralph sem painel — essa compatibilidade é asserção da suite. `--verbose` sempre ganha: os dois streams do engine precisam do terminal. Com o painel ativo o placar é desviado para `.phases/ui/messages.log`, aparece no rodapé e é **reimpresso por inteiro na tela normal** quando o painel sai — sem isso ele existiria só no arquivo. Saída longa (causa de gate vermelho, relatório final) vem sempre depois de desmontar o painel. **Falha ao desenhar degrada para o placar: o painel nunca altera veredito de gate nem exit code.**

O `--serve` adicionalmente escreve um `.phases/ui/index.html` auto-contido (sem CDN, sem fonte remota, sem fetch externo) e sobe `python3 -m http.server` preso a `127.0.0.1`, na primeira porta livre a partir de 7433. A URL sai uma vez no topo; o navegador **não** é aberto. A página mostra a fase corrente, o veredito de cada gate, a lista de fases e uma timeline com duração por gate. O trap de saída mata o servidor; o estado fica em disco para inspeção depois. Sem `python3` no `PATH` → aviso alto e o run segue só com o painel.

### Estado estruturado

O painel, o dashboard e qualquer ferramenta externa leem os mesmos dois arquivos. Nenhum deles parseia o placar humano — esse é justamente o ponto.

| Arquivo | Forma | Papel |
|---|---|---|
| `.phases/state.json` | snapshot JSON | O agora: fase corrente, ciclo, veredito de cada gate, lista de fases com status, espera por limite, última linha de progresso do engine |
| `.phases/events.jsonl` | JSON Lines append-only | O histórico: uma linha por transição |

O `state.json` é reescrito atomicamente (`tmp` + `mv`), então um leitor concorrente vê a versão velha ou a nova, nunca meio arquivo. O `events.jsonl` carrega `gate_start` / `gate_end` — com veredito e duração — dos 4 gates em toda fase, além dos mesmos 7 eventos que o hook de notificação recebe, com os mesmos nomes. Tempo por gate não existe em nenhum outro lugar do harness.

### Notificação de progresso

Um run longo não precisa de terminal aberto. Com `RALPH_NOTIFY_CMD` definido, o ralph chama `$RALPH_NOTIFY_CMD <evento> <mensagem>` a cada evento relevante:

| Evento | Quando |
|---|---|
| `run_start` | Run começou — quantas fases faltam, engine e arquivo de input |
| `phase_done` | Fase passou os gates (commitada ou já implementada em HEAD) |
| `phase_failed` | Fase reprovada após `RALPH_MAX_CYCLES`, ou commit falhou |
| `limit_hit` | Limite de uso atingido — inclui o horário previsto do reset |
| `limit_over` | Limite liberado, retomando a mesma fase |
| `limit_abort` | Abortado por bater `RALPH_MAX_LIMIT_WAITS` esperas na mesma fase |
| `run_done` | Relatório final: completas, falharam, puladas e duração |

O comando roda sob `timeout` com stdin fechado e todo erro é engolido — **notificar nunca altera o resultado do run**. `RALPH_PROJECT` chega no ambiente do comando, o que distingue runs paralelos de projetos diferentes.

Adaptador pronto para Telegram em `scripts/notify-telegram.sh` (credenciais só via env ou `~/.config/ralph-notify/telegram.env`, nunca no script):

```bash
export RALPH_NOTIFY_CMD="$HOME/.claude/scripts/notify-telegram.sh"
./ralph.sh .spec/features/<slug>/PHASES.md
```

### Estado e progresso

Trabalho interno em `.phases/` (registrado em `.git/info/exclude`, sem tocar o `.gitignore` do projeto): fases quebradas, prompts, logs, manifest, `.progress`, o estado estruturado (`state.json`, `events.jsonl`) e os assets do painel/dashboard (`ui/`). O progresso sobrevive entre execuções, mas só vale para o **mesmo input** (stamp sha256) — documento de fases alterado zera o progresso.

Cada sessão do engine grava **dois** logs, nunca unidos:

| Arquivo | Stream | Papel |
|---|---|---|
| `.phases/logs/<fase>.<etapa>.log` | stdout | Resposta final do engine — **única** fonte de veredito dos gates |
| `.phases/logs/<fase>.<etapa>.stderr.log` | stderr | Progresso/telemetria — só diagnóstico |

Os dois vão inteiros para os logs; `--verbose` também os streama ao vivo. Unir os streams (`2>&1`) fazia o Codex ecoar a resposta final nos dois e o gate 3 contar cada task duas vezes, reprovando fase inteiramente implementada por "cobertura incompleta". Por isso o gate 3 mede cobertura em **índices únicos** de task: eco duplicado não infla nem esconde cobertura, `INCOMPLETE` vence `DONE` no mesmo índice, e índice fora de `1..N` ou task sem veredito deixam o gate vermelho.

Exit code: `0` = todas as fases verdes; `1` = alguma falhou ou abortou.

### Contrato de formato do input

Validado no preflight:

- ≥ 1 heading `## Phase N: <título>`
- Nenhum heading `## Phase ...` fora desse formato (heading torto some silenciosamente do run — o preflight aborta antes de gastar tokens)
- Sub-fases em `### Phase N.M:` (não viram sessão própria)
- Qualquer outro `## ` encerra a captura da fase anterior

## Agentes

Os comandos são **roteadores finos** — todo conhecimento de template vive nos agentes:

| Agente | Pipeline | Papel |
|---|---|---|
| `specifier` | `/plan` §5 | Descrição confirmada + ACs → SPEC.md formal (GEARS, RIGID/FLEXIBLE) |
| `clarifier` | `/plan` §6 | QA adversarial de requisitos: analisa ambiguidades, resolve com as respostas do dev |
| `planner` | `/plan` §7, `/bugfix` §7b | SPEC (ou BUGFIX) → PLAN.md + PHASES.md + contratos; read-only sobre o código |
| `bug-analyst` | `/bugfix` §4 e §7b | `investigate`: reproduz, rastreia a causa raiz, classifica o tier. `author`: escreve o BUGFIX.md. Nunca escreve código de aplicação |
| `ai-context-inspector` | `/ai-context` §3 | Varredura read-only do repo → digest estruturado |
| `ai-context-core` | `/ai-context` §4 | Digest → `AGENTS.md` + `CLAUDE.md` |
| `ai-context-docs` | `/ai-context` §4 | Digest → 8 arquivos `docs/agents/*.md` |

Os dois writers de `/ai-context` rodam em paralelo (arquivos disjuntos, digest read-only).

## Estrutura do repositório

```
.claude-plugin/plugin.json     manifest do plugin
commands/
  init.md                      /init (roteador diagnóstico)
  init/                        /init:project-description, user-stories,
                               database-schema, project-phases
  plan.md                      /plan (roteador do pipeline de planejamento)
  bugfix.md                    /bugfix (roteador do pipeline de defeito)
  ai-context.md                /ai-context (roteador da árvore de contexto)
agents/                        specifier, clarifier, planner, bug-analyst,
                               ai-context-{inspector,core,docs}
scripts/
  ralph.sh                     orquestrador de execução por fases
  test-ralph.sh                suite red/green do ralph com engine mock
  notify-telegram.sh           adaptador de RALPH_NOTIFY_CMD para o Telegram
  check-init-drift.sh          guarda contra drift textual das regras
                               duplicadas nos comandos init
  check-shell.sh               bash -n + shellcheck em scripts/*.sh
docs/plans/                    planos de hardening internos do harness
```

## Desenvolvimento

```bash
scripts/test-ralph.sh        # suite do ralph.sh — binários fake `claude`/`codex`
                             # no PATH, zero rede, zero token; exit 0 = verde
scripts/test-ralph.sh <caso> # roda um caso específico
scripts/check-shell.sh       # bash -n em todos os scripts + shellcheck se disponível
scripts/check-init-drift.sh  # âncoras verbatim das regras compartilhadas dos init:*
```

Sobre o `check-init-drift.sh`: os quatro `commands/init/*.md` **inlinam de propósito** as mesmas regras de entrevista, idioma, re-run e staleness — comandos de plugin precisam ser auto-contidos em runtime (executam dentro do projeto do desenvolvedor, onde a raiz do plugin não é alcançável via `@`-includes). O custo dessa duplicação é drift silencioso; o script torna o drift barulhento.

## Princípios de design

- **Roteadores finos, agentes donos do conteúdo** — comandos orquestram, verificam artefatos em disco e reportam; nunca autoram SPEC/PLAN/docs.
- **Confie, mas verifique** — todo artefato entregue por agente é validado mecanicamente (existência, headings, contagens) pelo roteador.
- **Realidade ≠ intenção** — `/ai-context` documenta só o implementado; `.spec/` é invisível para ele. A cadeia `.spec/` documenta a intenção.
- **Sem escrita em git pelos comandos** — o desenvolvedor revisa com `git diff` e commita manualmente. O único que commita é o `ralph.sh`, por design (um commit por fase validada).
- **Sem segredos** — `.env` nunca é lido; nomes de variáveis vêm de `.env.example`.
- **Staleness explícita, nunca bloqueante** — stamps sha256 detectam insumos desatualizados; a decisão é sempre do desenvolvedor.
