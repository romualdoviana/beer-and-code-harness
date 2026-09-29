#!/usr/bin/env bash
#
# ralph.sh
#
# Orquestrador que le um documento de fases, quebra em fases, e alimenta cada
# uma ao Codex CLI ou Claude Code para implementacao automatica.
#
# Invariantes:
#   1. Cada fase E cada ciclo de correcao roda em sessao NOVA, com prompt
#      auto-contido. Nunca reutiliza sessao.
#   2. Zero perguntas. Do inicio ao fim sem interacao humana.
#   3. Fase so e "completa" quando passa por 4 gates mecanicos, nunca pelo
#      exit code do engine.
#   4. Limite de uso -> espera o reset e re-executa a MESMA fase, sem consumir
#      ciclo de correcao.
#   5. Um commit por fase concluida.
#   6. O conserto cirurgico (repair) nunca commita e nunca substitui um gate:
#      ele so devolve a fase para a MESMA cadeia de gates. Nenhum commit sai
#      sem gate 2 e gate 3 completos verdes.
#
# Agnostico de stack: a fase e o CLAUDE.md/AGENTS.md do projeto definem
# linguagem, framework, comandos e convencoes.
#
# Uso:
#   ./ralph.sh [opcoes] [caminho-do-arquivo]
#
# Opcoes:
#   --engine codex|claude    engine de implementacao (default: codex)
#   --model NOME             modelo das sessoes de implementacao e correcao
#                            (default: o da CLI do engine). O verificador e o
#                            conserto tem modelo proprio — ver RALPH_VERIFY_MODEL
#                            e RALPH_REPAIR_MODEL
#   --from N                 comeca na fase N (limpa do progresso as fases >= N)
#   --keep-going             continua apos uma fase falhar (default: para)
#   --max-cycles N           ciclos de correcao por fase (default: 3)
#   --max-repairs N          consertos cirurgicos por ciclo (default: 2; 0 = off)
#   --no-repair              desliga o conserto cirurgico (RALPH_REPAIR=off)
#   --max-rescues N          sessoes de resgate por fase (default: 2; 0 = off)
#   --no-rescue              desliga a sessao de resgate (RALPH_RESCUE=off)
#   --rescue-model NOME      modelo do resgate (default: opus no claude)
#   --baseline               mede as falhas ja existentes em HEAD antes do run e
#                            faz o gate 2 cobrar so o DELTA. Use quando a suite
#                            ja esta vermelha por algo alheio as fases; NAO use
#                            em fase cujo teste-alvo ja esta commitado vermelho,
#                            porque o perdao seria permanente (RALPH_BASELINE=on)
#   --no-heal-head           desliga o saneamento do HEAD (RALPH_HEAL_HEAD=off):
#                            suite vermelha em HEAD volta a nao ser tratada e as
#                            fases comecam sobre gate vermelho
#   --no-verify              desliga o gate 3 (equivale a RALPH_VERIFY=off)
#   --ui-shot-cmd "<cmd>"    comando que fotografa uma tela (evidencia visual
#                            do gate 3; ver RALPH_UI_SHOT_CMD)
#   --no-ui-verify           desliga a evidencia visual (RALPH_UI_VERIFY=off)
#   --no-env-guard           desliga a deteccao de ambiente fora do ar no gate 2
#                            (RALPH_ENV_GUARD=off): toda falha volta a ser
#                            vermelho da fase
#   --test-cmd "<cmd>"       comando de teste do projeto (gate 2)
#   --full-suite             gate 2 roda a suite COMPLETA em toda fase
#                            (comportamento anterior; equivale a
#                            RALPH_TEST_SCOPE=full)
#   --verbose                streama o progresso do engine no terminal
#   --quiet                  so o placar do ralph no terminal (DEFAULT)
#   --ui-layout <nome>       cockpit (default), focus ou diagnostic; teclas 1/2/3
#   --ui                     forca o painel ANSI (equivale a RALPH_UI=panel)
#   --no-ui                  forca o placar em linha corrida (RALPH_UI=plain)
#   --serve[=PORTA]          sobe um dashboard web local sobre o mesmo estado
#   --attach                 nao roda fase nenhuma: acompanha um run JA em
#                            andamento neste diretorio, republicando o status
#                            por task e a inferencia. Read-only sobre o run.
#
# Input (primeiro arquivo posicional). Sem argumento, resolve nesta ordem:
#   1. .spec/init/project-phases.md      (cadeia init)
#   2. .spec/project-phases.md           (repos pre-init, com aviso)
#
#   Um PHASES.md de feature tambem e input valido:
#     ./ralph.sh .spec/features/<slug>/PHASES.md
#
# Contrato de formato do input (validado no preflight):
#   - >= 1 heading `## Phase N: <titulo>`
#   - nenhum heading `## Phase ...` fora desse formato
#   - sub-fases em `### Phase N.M:` (nao viram sessao propria)
#   - qualquer outro `## ` encerra a captura da fase anterior
#
# Gates por fase (todos verdes -> commit; qualquer vermelho -> ciclo de correcao):
#   0. engine terminou de verdade (claude: is_error no JSON; codex: exit code)
#   1. a sessao escreveu codigo? SINAL, nao veredito — uma fase ja implementada
#      faz o engine (corretamente) nao escrever nada. Alimenta a causa do ciclo
#      de correcao quando um gate posterior reprova.
#   2. testes do projeto, rodados PELO ralph (fora da sessao do agente). O
#      ESCOPO varia por fase — veja "Escopo do gate 2" abaixo
#   3. sessao verificadora independente, read-only, task a task — o gate final.
#      RALPH_VERIFY=auto (default) so gasta a sessao quando o gate 2 nao basta:
#      fase que a suite nao cobriu (escopo `skip` — fiacao, view, config),
#      sessao que nao escreveu nada (claim "ja implementada"), ciclo de
#      correcao, ou gate 2 desabilitado. RALPH_VERIFY=always roda em toda fase. --no-verify / RALPH_VERIFY=off desliga. No engine
#      claude o verificador usa RALPH_VERIFY_MODEL (default: sonnet) — e
#      leitura + checklist, nao escreve codigo.
#
# Escopo do gate 2 — a suite inteira e o gate da SPEC, nao o de cada fase.
#   Rodar a suite completa ao fim de toda fase custa minutos por fase, e o custo
#   pior nem e o tempo: e o incentivo. Uma fase mecanica (fiacao, config,
#   rename, view) que precisa "fechar o gate 2" empurra o engine a inventar
#   teste — getter, cast, "a classe existe" — so para ter algo verde no proprio
#   escopo. Teste inutil e ruido permanente no repositorio.
#   Por fase o gate 2 resolve UM entre tres escopos, primeira regra que casar:
#     1. modo suite completa (--full-suite / RALPH_TEST_SCOPE=full)  -> completo
#     2. ULTIMA fase pendente do documento (fim da spec)             -> completo
#     3. gate 3 desligado (--no-verify): o gate 2 vira a unica prova -> completo
#     4. a fase declara `Suite: completa` no proprio texto           -> completo
#     5. o diff da fase toca caminho critico (migration, schema,
#        dependencias, config, bootstrap, CI — RALPH_CRITICAL_PATHS) -> completo
#     6. ha arquivo de teste alterado na arvore ou citado no campo
#        `Testes:` da fase, e o runner aceita escopo                 -> escopado
#     7. nada disso                                                  -> pulado
#   Fail-safe em toda borda: runner que nao aceita caminho (go, cargo, comando
#   desconhecido) cai em completo, nunca em escopado. A fase pode DECLARAR mais
#   rigor (`Suite: completa`), jamais menos. E o gate 3 — verificacao
#   independente task a task — continua rodando inteiro em toda fase: escopo
#   encurta o gate 2, nunca a prova de que a fase foi feita.
#
# Conserto cirurgico (repair) — acionamento independente entre o gate vermelho
# e o ciclo de correcao:
#   Um ciclo de correcao e caro: sessao nova com o preambulo de contexto, a
#   fase inteira no prompt e acesso total ao projeto. Pagar isso porque UMA
#   assertion ficou vermelha e desperdicio. Antes de gastar um ciclo, o ralph
#   tenta ate RALPH_MAX_REPAIRS consertos cirurgicos (default 0 — desligado;
#   RALPH_REPAIR=on religa):
#     - prompt minimo: SO a assinatura da falha (teste, arquivo:linha, mensagem)
#       ou SO as linhas INCOMPLETE do verificador. Sem preambulo, sem a fase.
#     - modelo proprio e FORTE (RALPH_REPAIR_MODEL, default: opus no claude):
#       e a unica etapa que escreve codigo com contexto minimo e a unica que
#       pode abortar a fase sozinha com REPAIR_ABORT
#     - o conserto NAO consome ciclo: os RALPH_MAX_CYCLES continuam de reserva
#   Fail-closed. So repara o que da para localizar:
#     - gate 2 vermelho com assinatura extraivel apontando <= RALPH_REPAIR_MAX_FILES
#       arquivos distintos
#     - gate 3 vermelho por task INCOMPLETE (<= RALPH_REPAIR_MAX_TASKS tasks)
#   Gate 0 vermelho (engine morreu), causa nao parseavel, falha larga demais ou
#   protocolo do verificador quebrado NAO sao reparaveis: vao direto para o
#   ciclo completo. O modelo tambem pode desistir sozinho respondendo
#   REPAIR_ABORT — desistir barato vale mais que um patch as cegas.
#   Revalidacao: entre rounds de conserto o gate 3 roda ESCOPADO (so as tasks
#   que estavam INCOMPLETE; as posicoes continuam as originais, nada e
#   renumerado). Verde no escopo NAO fecha a fase: a cadeia completa — gate 2
#   inteiro + gate 3 de todas as tasks — roda antes de qualquer commit.
#
# Sessao de resgate (rescue) — ultima etapa antes de dar a fase por perdida:
#   Quando a fase trava — conserto cirurgico desistindo com REPAIR_ABORT,
#   consertos esgotados, ciclo improdutivo ou os --max-cycles no fim — o ralph
#   parava e o dev recebia um log. Mas o motivo real do travamento quase nunca e
#   falta de forca do modelo: e que TODAS as etapas anteriores trabalham com
#   autoridade estreita. O ciclo corrige "o que falta"; o conserto mexe so no
#   arquivo da assinatura; nenhum dos dois pode reorganizar a implementacao nem
#   encostar num teste existente que passou a contradizer a fase.
#   O resgate e a etapa com a autoridade que faltava:
#     - prompt auto-contido e LARGO: preambulo de contexto + a fase inteira + o
#       motivo do travamento + o veredito bruto do ultimo gate + a desistencia
#       do conserto (verbatim) + o diff do trabalho parcial na arvore
#     - modelo proprio e forte (RALPH_RESCUE_MODEL, default: opus no claude)
#     - pode reorganizar a implementacao entre arquivos e camadas, e pode
#       ajustar teste EXISTENTE que contradiz o comportamento exigido pela fase
#     - NAO pode afrouxar teste para ficar verde (apagar, pular, comentar,
#       enfraquecer assert, mudar o runner ou a config) nem criar teste que a
#       fase nao pediu. Toda alteracao de teste sai justificada por escrito.
#   Nao substitui gate nenhum: depois do resgate roda a cadeia COMPLETA — gate 2
#   inteiro + gate 3 de todas as tasks — e so entao a fase commita, como
#   qualquer outra. Verde de resgate e verde igual; o commit registra a origem.
#   Orcamento proprio: RALPH_MAX_RESCUES (default 1), que nao consome ciclo nem
#   conserto. Ambiente fora do ar NAO aciona resgate — servico morto nao e
#   defeito de codigo. E o resgate tambem pode desistir, com RESCUE_BLOCKED,
#   quando o bloqueio e contradicao da propria especificacao: nesse caso nenhum
#   round adicional e gasto — a decisao e humana, nao de modelo.
#
# Vermelho herdado de HEAD — saneamento antes da primeira fase:
#
#   A suite roda UMA vez em HEAD (arvore limpa, garantida pelo preflight) antes
#   da fase 1. Vermelho ali nao e defeito de nenhuma fase: e vermelho que o run
#   herdou, e ele prende o ciclo de TODAS as fases. Regra de ouro do operador:
#   nunca iniciar fase nova sobre gate vermelho.
#
#   O run real que motivou isto: duas guardas de higiene de features ANTIGAS
#   estavam vermelhas em HEAD — uma congelava byte a byte um metodo de um
#   arquivo de OUTRO repositorio que um commit posterior mudou de proposito, a
#   outra congelava a posicao de um item de menu que uma SPEC posterior moveu.
#   A fase em curso nao tocava nenhuma das duas. O ralph gastou 5 ciclos, 2
#   consertos cirurgicos e 2 sessoes de resgate (16 min) para chegar ao veredito
#   correto e tardio "isto nao se conserta escrevendo codigo da fase".
#
#   Desfecho: UMA sessao de saneamento, com mandato explicito de consertar o
#   vermelho herdado — inclusive ATUALIZAR guarda obsoleta de outra feature
#   quando o texto congelado mudou por decisao registrada (a prova e o commit
#   que mudou), preservando a regra que a guarda protege. Verde => commit
#   proprio e o run segue com HEAD limpo. Ainda vermelho => aborta ANTES da fase
#   1, nomeando os testes: e decisao humana, e custa uma rodada de suite em vez
#   de uma fase inteira.
#
#   --baseline tem precedencia e desliga o saneamento: quem declara "herde o
#   vermelho como delta" esta dizendo que o vermelho e intencional (fase escrita
#   em TDD com o teste ja commitado vermelho). --no-heal-head desliga tudo.
#
#   O MESMO mandato vai no prompt do conserto cirurgico e do resgate: num plano
#   multi-repo a guarda pode ficar obsoleta NO MEIO do run, quando uma fase
#   anterior commita no repositorio vizinho que a guarda le.
#
# Ambiente fora do ar (gate 2) — veredito PROPRIO, nem verde nem vermelho:
#   Servico externo caido (banco, cache, fila, container derrubado por falta de
#   memoria) nao e defeito de codigo: a suite nao chegou a julgar a fase.
#   Tratar isso como gate 2 vermelho custa ciclo, custa conserto cirurgico e no
#   fim descarta o trabalho da fase — nenhum patch faz um container morto subir.
#   Ao reconhecer a assinatura (recusa de conexao, DNS que nao resolve, SQLSTATE
#   de conexao), o ralph:
#     1. tenta levantar o que esta caido — `docker start` nos containers
#        NOMEADOS no proprio erro (podem ser de outro compose project) e, se o
#        projeto usa Sail e os containers dele estao parados, `sail up -d`
#     2. reexecuta a suite UMA vez (por fase). Voltou verde: o run segue normal
#     3. ainda fora do ar: encerra o RUN inteiro (mesmo com --keep-going, porque
#        a proxima fase encontraria o mesmo servico morto), salva o trabalho da
#        fase num commit `wip(phase-N): interrompido por falha de ambiente` e sai
#        com exit code 3
#   Re-rodar com o ambiente de pe revalida a fase e segue de onde parou.
#   --no-env-guard / RALPH_ENV_GUARD=off desliga (util se a suite ASSERTA
#   mensagens de erro de conexao e o guard as confunde com ambiente caido).
#
# Streams do engine (stdout != stderr — nunca unir):
#   .phases/logs/<fase>.<etapa>.log         stdout = RESPOSTA FINAL do engine.
#                                           Unica fonte de veredito dos gates.
#   .phases/logs/<fase>.<etapa>.stderr.log  stderr = progresso/telemetria.
#                                           Diagnostico apenas, nunca veredito.
# Medido no codex 0.146.0: uma sessao trivial deu 13 bytes de stdout (so a
# resposta final) contra 48894 de stderr (banner, eco do prompt, hooks, traces
# de exec). Unir os streams fazia o codex ecoar a resposta final nos dois e o
# gate 3 contar cada task duas vezes ("cobertura incompleta" com a fase inteira
# pronta). Por isso o gate 3 conta INDICES UNICOS de task, nao linhas: eco
# duplicado nao infla nem esconde cobertura, e INCOMPLETE sempre vence DONE no
# mesmo indice.
#
# Terminal (default --quiet): so o placar do ralph — fase, gates, commit. Os
# dois streams do engine vao INTEIROS para os logs, e um heartbeat periodico
# mostra o tempo decorrido e a ultima linha de progresso, para o run nao
# parecer travado. Gate vermelho ja imprime o tail dos dois streams no
# GATE_CAUSE. --verbose volta a streamar o progresso ao vivo.
#
# Estado estruturado (.phases/state.json + .phases/events.jsonl):
#   state.json    foto do agora — fase corrente, ciclo, veredito de cada gate,
#                 lista de fases com status, espera por limite, ultima linha de
#                 progresso do engine. Reescrito atomicamente (tmp + mv): um
#                 leitor concorrente nunca ve arquivo pela metade.
#   events.jsonl  append-only, uma linha JSON por transicao. Carrega os eventos
#                 gate_start/gate_end (com veredito e duracao) alem dos 7
#                 eventos que o RALPH_NOTIFY_CMD ja recebe.
# Sao CONTRATO, nao detalhe interno: o painel, o dashboard web e qualquer
# ferramenta externa leem esses arquivos. Nenhum deles parseia o placar humano.
#
# Painel ANSI (RALPH_UI, default auto):
#   auto    stdout e TTY -> painel; nao-TTY (nohup, CI, pipe) -> placar em
#           linha corrida, identico ao de sempre. --verbose sempre desliga o
#           painel (os dois streams ja ocupam o terminal).
#   panel   forca o painel (--ui)
#   plain   forca o placar em linha corrida (--no-ui)
#
# O painel roda no BUFFER ALTERNADO do terminal (ESC[?1049h), como vim ou less:
# ocupa a tela inteira enquanto o run acontece e, ao sair, devolve o terminal
# com o scrollback anterior intacto. Tres telas (teclas 1/2/3):
#   1 Visao geral  cabecalho, metricas (tempo, fases, ciclo, %), barra
#                  segmentada, jornada das fases, EM ANDAMENTO + VALIDACAO DA
#                  FASE (G0..G3), ULTIMOS EVENTOS
#   2 Foco         tarefa corrente em destaque, confirmacao independente,
#                  TAREFAS DA FASE, pipeline e ciclo
#   3 Diagnostico  gate que falhou (ou "Nenhum gate falhou"), tentativa
#                  anterior, correcao atual, linha do tempo, saida do teste
# >= 144x40 as caixas ficam lado a lado; ate 100x24 empilham e, sem altura,
# caem ULTIMOS EVENTOS e depois LINHA DO TEMPO/SAIDA DO TESTE; abaixo de
# 100x24 so o aviso "aumente para 100x24". Campo sem valor aparece como "—".
# RALPH_UI_GLYPHS=ascii troca ✓ ▶ ● × — por ASCII (fonte sem esses glifos).
#
# Status por task — quatro fontes, nesta ordem de autoridade:
#   1. fase concluida        todas as tasks dela sao verificadas
#   2. veredito do gate 3    DONE -> verificada, INCOMPLETE -> incompleta
#   3. checkbox `- [x]`      declarada — o engine marcou a task no arquivo da
#                            fase ao fechar os testes dela. E o unico sinal que
#                            se move DURANTE a sessao; nao e veredito.
#   4. inferencia por ancora ~N% — quantos artefatos que a task nomeia ja
#                            existem no disco. Sempre prefixado por `~`.
# Uma fonte mais alta sempre sobrescreve a mais baixa: presenca de arquivo, e
# ate a palavra do engine, jamais viram veredito no lugar do gate 3.
#
# --attach: mesmo painel, sobre o .phases/ de um run que JA esta rodando (outro
# terminal). Nao roda fase, nao escreve codigo, nao commita — so republica
# tasks.txt/taskprog.txt e desenha. E o unico jeito de melhorar a leitura de um
# run em andamento: bash nao troca as funcoes de um processo vivo.
#
# Com o painel ativo o placar vai para .phases/ui/messages.log e aparece na area
# de mensagens. Ao sair do buffer alternado o placar inteiro do run e reimpresso
# na tela normal — sem isso ele existiria so no arquivo. Saida longa (causa de
# gate vermelho, relatorio final) sempre vem DEPOIS do ui_stop. Falha ao
# desenhar degrada para o placar: o painel nunca altera veredito de gate nem
# exit code.
#
# Dashboard web (--serve, opcional): escreve .phases/ui/index.html (auto-contido,
# sem CDN) e sobe `python3 -m http.server` preso a 127.0.0.1, na primeira porta
# livre a partir de RALPH_SERVE_PORT (default 7433). A URL sai uma vez no topo;
# o navegador NAO e aberto. O trap de saida mata o servidor. Sem python3 no
# PATH: aviso alto e o run segue normalmente, so com o painel.
#
# Gates verdes com a arvore limpa => a fase ja estava implementada em HEAD:
# marcada como feita, sem commit (nao ha o que commitar).
#
# Comando de teste (gate 2), primeira regra que resolver:
#   1. --test-cmd "<cmd>"
#   2. RALPH_TEST_CMD
#   3. deteccao por manifest:
#        Laravel Sail (artisan + vendor/bin/sail)  -> vendor/bin/sail test
#        composer.json com scripts.test            -> composer test
#        artisan                                   -> php artisan test
#        package.json com scripts.test             -> npm test
#        pytest.ini / pyproject [tool.pytest]      -> pytest
#        go.mod                                    -> go test ./...
#        Cargo.toml                                -> cargo test
#   4. nada resolvido -> aviso alto + gate 2 pulado (o gate 3 segura sozinho)
#
# Laravel Sail: a suite roda dentro do container, entao Sail tem precedencia
# sobre `composer test`. Containers parados -> abort no preflight (todo gate 2
# falharia, queimando ciclos de correcao).
#
# Variaveis de ambiente:
#   RALPH_TEST_CMD           comando de teste (gate 2); --test-cmd tem prioridade
#   RALPH_TEST_SCOPE         escopo do gate 2: auto (default) | full
#   RALPH_HEAL_HEAD          saneamento do HEAD vermelho: on (default) | off
#   RALPH_HEAL_ROUNDS        sessoes de saneamento antes de abortar (default: 1)
#   RALPH_CRITICAL_PATHS     regex ERE de caminho critico: diff da fase que
#                            casa forca a suite completa naquela fase
#   RALPH_TEST_FILE_RE       regex ERE que reconhece arquivo de teste
#   RALPH_VERIFY             gate 3: auto (default) | always | off
#   RALPH_VERIFY_MODEL       modelo do verificador (default: sonnet no claude)
#   RALPH_VERIFY_EVIDENCE    required (default) | optional. Com required, um
#                            `TASK n: DONE` sem `— <evidencia>` (arquivo:linha
#                            ou caminho .png) reprova o gate 3 por protocolo:
#                            veredito sem prova nao e veredito.
#   RALPH_UI_VERIFY          evidencia visual: auto (default) | off. Em auto,
#                            toda task com o campo `Tela:` exige que o RALPH
#                            fotografe a rota antes do verificador julgar —
#                            fase com `Tela:` e sem RALPH_UI_SHOT_CMD reprova
#                            (fail-closed). off desliga de proposito.
#   RALPH_UI_SHOT_CMD        comando de captura, chamado pelo ralph (nunca
#                            pelo engine). Vazio => autodetecta no repo
#                            scripts/ralph-ui-shot.{mjs,js,sh,py}. Chamada:
#                              <cmd> <rota> <saida.png> [<seletores CSS>] [<tema>]
#                            Deve sair 0 e gravar o PNG; deve sair != 0 se um
#                            seletor obrigatorio nao existir na pagina. A
#                            captura vai para .phases/evidence/<fase>/task-<n>.png
#                            e o verificador compara com o PNG-alvo da task.
#   RALPH_UI_VIEWPORT        exportada pelo ralph para o comando de captura:
#                            desktop (task-<n>.png) ou mobile
#                            (task-<n>-mobile.png). O script do projeto escolhe
#                            o tamanho (sugestao: 1440x900 / 400x900); script
#                            que ignora a variavel grava duas fotos iguais.
#                            O executor usa o mesmo comando para se fotografar
#                            em .phases/selfcheck/ antes de entregar a fase.
#   RALPH_UI_SHOT_TIMEOUT    timeout da captura em segundos (default: 120)
#
# Campo `Tela:` (opcional, por task, dentro do bloco do checkbox):
#   Tela: <rota> | <seletor CSS>[, <seletor>...] | <png-alvo> | <tema>
#   ex.: Tela: /admin | [data-tc="health-strip"], .fi-header | .spec/features/x/artboards/01-main.png
#        Tela: /admin | .fi-header | .spec/features/x/artboards/01-main.png | claro
#   Rota e seletores sao obrigatorios; o PNG-alvo e opcional (sem ele o
#   verificador julga so pela captura + seletores); o tema (4o campo) e
#   opcional e vai ao comando de captura como 4o argumento (ex.: claro/light). O ralph fotografa, o
#   verificador le a captura E o alvo (Read abre imagem) e decide. A evidencia
#   nasce fora da sessao do agente: ele nao escreve, nao escolhe e nao edita
#   o arquivo que o julga.
#   RALPH_MODEL              modelo das sessoes de implementacao/correcao
#                            (default: vazio = o da CLI do engine)
#   RALPH_ENV_GUARD          on (default) | off — deteccao de ambiente caido
#   RALPH_ENV_RECOVER_TIMEOUT segundos de espera pelos servicos ao tentar
#                            levantar o ambiente (default: 90)
#   RALPH_VERBOSE            1 = streama o progresso do engine (igual --verbose)
#   RALPH_HEARTBEAT          segundos entre heartbeats no modo quiet (default:
#                            60; 0 desliga)
#   RALPH_MAX_CYCLES         ciclos de correcao por fase (default: 2)
#   RALPH_REPAIR             conserto cirurgico: off (default) | on
#   RALPH_MAX_REPAIRS        consertos por ciclo (default: 0 = desligado)
#   RALPH_REPAIR_MODEL       modelo do conserto (default: opus no claude)
#   RALPH_RESCUE             sessao de resgate: on (default) | off
#   RALPH_MAX_RESCUES        sessoes de resgate por fase (default: 1; 0 desliga)
#   RALPH_RESCUE_MODEL       modelo do resgate (default: opus no claude)
#   RALPH_CAVEMAN            nivel do plugin caveman nas sessoes claude que
#                            escrevem codigo — implementacao e conserto
#                            (default: ultra; `off` desliga). O verificador
#                            fica sempre no formato normal: o output dele e
#                            contrato de maquina. Sem o plugin instalado a
#                            variavel e inerte.
#   RALPH_REPAIR_MAX_FILES   acima de N arquivos distintos na assinatura da
#                            falha, a falha e larga demais para conserto
#                            cirurgico e vai direto ao ciclo (default: 5)
#   RALPH_REPAIR_MAX_TASKS   acima de N tasks INCOMPLETE, idem (default: 3)
#   RALPH_MAX_LIMIT_WAITS    esperas consecutivas por limite, por fase (default: 20)
#   RALPH_LIMIT_WAIT_DEFAULT fallback de espera em segundos (default: 1800)
#   RALPH_LIMIT_BUFFER       segundos extras apos o reset (default: 60)
#   RALPH_WEEKLY_THRESHOLD   reset mais distante que isso e limite semanal:
#                            encerra o run em vez de dormir (default: 21600 = 6h)
#   RALPH_NOTIFY_CMD         comando de notificacao (opcional, vazio = desligado)
#   RALPH_UI                 painel: auto (default) | panel | plain
#   RALPH_UI_LAYOUT          tela inicial: cockpit (default, Visao geral) |
#                            focus | diagnostic
#   RALPH_UI_FPS             repinturas por segundo do painel (default: 2)
#   RALPH_UI_KEYS            1 (default) = navegacao por teclado no painel;
#                            0 desliga (terminal que engole escapes)
#   RALPH_UI_GLYPHS          ascii = glifos ASCII no painel (default: ✓ ▶ ● × —)
#   RALPH_SERVE_PORT         primeira porta tentada por --serve (default: 7433)
#
# Notificacao (opcional): com RALPH_NOTIFY_CMD definido, o ralph chama
#   $RALPH_NOTIFY_CMD <evento> <mensagem>
# nos eventos run_start, phase_done, phase_failed, limit_hit, limit_over,
# limit_abort e run_done. Para acompanhar um run longo fora do terminal. Roda
# com timeout e o erro e engolido: notificacao e efeito colateral, nunca gate.
# Adaptador pronto para Telegram: scripts/notify-telegram.sh.
#
# Exportadas para o engine e para RALPH_NOTIFY_CMD:
#   RALPH_ENGINE             codex | claude
#   RALPH_PROJECT            nome do repo (distingue runs paralelos)
#   RALPH_PHASE_TITLE        titulo da fase corrente
#   RALPH_PHASE_NUM          numero da fase corrente
#   RALPH_PHASE_TOTAL        total de fases do run
#   RALPH_PHASE_ATTEMPT      ciclo corrente (1 = implementacao inicial)
#   RALPH_PHASE_MAX_ATTEMPTS igual a RALPH_MAX_CYCLES
#   RALPH_PHASE_REPAIR       round de conserto corrente (0 = nenhum)
#   RALPH_EVENT              evento corrente (so no processo de notificacao)
#
# Exit code: 0 = todas as fases verdes; 1 = alguma falhou ou abortou;
#            3 = run encerrado por ambiente fora do ar (nenhum veredito sobre o
#            codigo — suba os servicos e re-rode).
#
# Pre-requisitos:
#   - Codex: npm install -g @openai/codex + OPENAI_API_KEY
#   - Claude: npm install -g @anthropic-ai/claude-code + ANTHROPIC_API_KEY
#   - Raiz de um repo git, com a arvore de trabalho limpa

set -euo pipefail

ENGINE="codex"
IMPL_MODEL="${RALPH_MODEL:-}"
INPUT_FILE=""
FROM_PHASE=0
KEEP_GOING=false
TEST_CMD_FLAG=""
# Orcamento de recuperacao por fase. Os defaults sao deliberadamente curtos.
#
# Eram 5 ciclos x 2 consertos cirurgicos + 2 resgates: ate ~29 sessoes de
# engine numa unica fase, e o gasto nao comprava veredito novo — depois do
# segundo ciclo vermelho o modelo repete a mesma tentativa com outras palavras.
# Agora: 2 ciclos e, se ainda estiver vermelho, 1 sessao de resgate (larga, com
# modelo forte) antes de devolver a fase para o humano.
#
# O conserto cirurgico sai do default (RALPH_REPAIR=on religa): ele era o nivel
# intermediario entre o ciclo e o resgate, e com so 2 ciclos o resgate ja chega
# cedo o bastante.
MAX_CYCLES="${RALPH_MAX_CYCLES:-2}"
VERIFY_MODE="${RALPH_VERIFY:-auto}"
VERIFY_MODEL=""
REPAIR_MODE="${RALPH_REPAIR:-off}"
MAX_REPAIRS="${RALPH_MAX_REPAIRS:-0}"
# Resgate: orcamento PROPRIO, por fase. Nao sai do bolso dos ciclos nem dos
# consertos — e a etapa que so existe quando os dois ja falharam.
RESCUE_MODE="${RALPH_RESCUE:-on}"
MAX_RESCUES="${RALPH_MAX_RESCUES:-1}"
# Baseline do gate 2: a suite roda uma vez em HEAD (arvore limpa, garantida pelo
# preflight) e o conjunto de testes ja vermelhos vira linha de base. Sem isso,
# UMA falha pre-existente e alheia a fase prende o loop ate esgotar --max-cycles,
# gastando um ciclo inteiro de engine + uma suite por rodada para reafirmar um
# vermelho que nenhum codigo escrito pela fase pode consertar.
#
# DEFAULT OFF, e de proposito. O ralph nao tem como saber se um teste vermelho em
# HEAD e alheio a fase ou e justamente o teste que a fase deve fazer passar (fase
# escrita em TDD com o teste ja commitado vermelho). Ligado as cegas, ele
# perdoaria para sempre o vermelho que a fase existe para consertar. Quem sabe a
# diferenca e o operador: --baseline e a declaracao explicita dele.
BASELINE_MODE="${RALPH_BASELINE:-off}"
BASELINE_FILE=""
BASELINE_COUNT=0
BASELINE_ACTIVE=false
GATE2_DELTA_NOTE=""
# Saneamento do HEAD (ver "Vermelho herdado de HEAD" no cabecalho).
#   HEAL_MODE      on (default) = HEAD vermelho ganha uma sessao de saneamento
#   HEAL_ROUNDS    sessoes de saneamento antes de abortar o run
#   HEAD_RED       1 = a medicao em HEAD achou vermelho AINDA nao sanado
#   HEAL_ABORT_WHY desistencia declarada pela sessao (HEAL_ABORT: <motivo>)
HEAL_MODE="${RALPH_HEAL_HEAD:-on}"
HEAL_ROUNDS="${RALPH_HEAL_ROUNDS:-1}"
HEAD_RED=0
HEAL_ABORT_WHY=""
# Memoria do gate 2 DENTRO da fase: assinatura da arvore na ultima execucao e o
# veredito que ela deu. Arvore identica => mesmo veredito, sem gastar a suite.
GATE2_LAST_SIG=""
GATE2_LAST_VERDICT=""
# 1 quando o gate 2 acabou de repetir o MESMO vermelho sobre a MESMA arvore.
GATE2_STALE_RED=0
# Ambiente fora do ar: veredito do gate 2 que NAO e vermelho da fase.
#   GATE2_INFRA   1 = a ultima execucao da suite caiu por servico fora do ar
#   INFRA_RETRIED 1 = esta fase ja gastou a sua reexecucao pos-recuperacao
#   ENV_ABORT     1 = o run inteiro para; exit code 3
ENV_GUARD=true
[ "${RALPH_ENV_GUARD:-on}" = "off" ] && ENV_GUARD=false
ENV_RECOVER_TIMEOUT="${RALPH_ENV_RECOVER_TIMEOUT:-90}"
GATE2_INFRA=0
INFRA_RETRIED=0
# Escopo do gate 2 (ver "Escopo do gate 2" no cabecalho).
#   TEST_SCOPE_MODE   auto = resolve por fase | full = suite completa sempre
#   GATE2_SCOPE       resultado da resolucao desta execucao: full|scoped|skip
#   GATE2_SCOPE_CMD   comando efetivamente executado pelo gate
#   GATE2_SCOPE_WHY   frase curta que explica a escolha (vai para o log)
#   GATE2_SCOPE_FILES arquivos de teste do escopo, separados por espaco (so scoped)
#   PHASE_IS_FINAL    1 na ultima fase pendente do documento — o fim da spec
TEST_SCOPE_MODE="${RALPH_TEST_SCOPE:-auto}"
GATE2_SCOPE=""
GATE2_SCOPE_CMD=""
GATE2_SCOPE_WHY=""
GATE2_SCOPE_FILES=""
# Fase corrente, para o gate 2 ler os testes que o documento declara.
GATE2_PHASE_FILE=""
PHASE_IS_FINAL=0
FINAL_PHASE_FILE=""
# Caminho critico: mudanca que pode quebrar teste que a fase nunca olhou —
# schema, dependencia, config global, bootstrap, imagem, pipeline. Escopo ali
# nao protege ninguem, entao a suite inteira roda na propria fase.
CRITICAL_PATHS_RE="${RALPH_CRITICAL_PATHS:-(^|/)(database/migrations|migrations|db/migrate|prisma)/|(^|/)(composer\.(json|lock)|package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|go\.(mod|sum)|Cargo\.(toml|lock)|pyproject\.toml|Gemfile(\.lock)?)$|(^|/)(config|bootstrap)/|(^|/)\.env\.example$|(^|/)(Dockerfile|docker-compose\.ya?ml)$|(^|/)\.github/workflows/}"
# O que conta como arquivo de teste, em qualquer stack.
TEST_FILE_RE="${RALPH_TEST_FILE_RE:-(^|/)(tests?|spec|specs|__tests__)/|(Test|Spec)\.[A-Za-z0-9]+$|_test\.[A-Za-z0-9]+$|\.(test|spec)\.[A-Za-z0-9]+$}"
# Gate 3 com prova: DONE sem evidencia e "linguagem confiante", nao veredito.
VERIFY_EVIDENCE_MODE="${RALPH_VERIFY_EVIDENCE:-required}"
# Evidencia visual: o ralph fotografa toda task com `Tela:` ANTES do
# verificador. O agente nunca produz nem toca o arquivo que o julga.
UI_VERIFY_MODE="${RALPH_UI_VERIFY:-auto}"
UI_SHOT_CMD="${RALPH_UI_SHOT_CMD:-}"
UI_SHOT_TIMEOUT="${RALPH_UI_SHOT_TIMEOUT:-120}"
# Tasks `Tela:` da fase corrente, uma por linha: pos|rota|seletores|alvo|tema.
# Preenchido pela captura; lido pelo prompt do verificador.
UI_SCREEN_TASKS=""
ENV_ABORT=0
# Desistencia explicita do conserto cirurgico (REPAIR_ABORT) e abortos de fase.
REPAIR_ABORTED=0
# Motivo verbatim da ultima desistencia do conserto: insumo do prompt de
# resgate. Sem ele, o resgate reexploraria do zero o que o conserto ja concluiu.
REPAIR_ABORT_WHY=""
PHASE_ABORT_REASON=""
# Resgate: bloqueio declarado pelo modelo (RESCUE_BLOCKED) encerra o orcamento
# — contradicao de especificacao nao se resolve gastando outra sessao.
RESCUE_BLOCKED=0
RESCUE_BLOCK_WHY=""
REPAIR_MODEL=""
RESCUE_MODEL=""
# Caveman: o run e headless, ninguem le a prosa do engine. O plugin caveman
# (se instalado) le CAVEMAN_DEFAULT_MODE no SessionStart, entao o ralph pede o
# nivel maximo — `ultra` — nas sessoes que ESCREVEM codigo (implementacao e
# conserto). O verificador fica de fora de proposito: o output dele e contrato
# de maquina (`TASK <n>: DONE|INCOMPLETE`), ja e minimo, e comprimir prosa la
# nao economiza nada enquanto arrisca o gate 3. Sem o plugin instalado a
# variavel e inerte. `off` desliga.
CAVEMAN_MODE="${RALPH_CAVEMAN:-ultra}"
# Conteudo de ~/.claude/.caveman-active antes da sessao: o hook do plugin
# reescreve esse arquivo global com o nivel pedido, e o run headless nao pode
# arrastar a sessao interativa do dev para ultra.
CAVEMAN_FLAG_FILE=""
CAVEMAN_FLAG_BEFORE=""
REPAIR_MAX_FILES="${RALPH_REPAIR_MAX_FILES:-5}"
REPAIR_MAX_TASKS="${RALPH_REPAIR_MAX_TASKS:-3}"
VERBOSE=false
[ "${RALPH_VERBOSE:-0}" = "1" ] && VERBOSE=true
HEARTBEAT_SECS="${RALPH_HEARTBEAT:-60}"
UI_MODE="${RALPH_UI:-auto}"
UI_LAYOUT="${RALPH_UI_LAYOUT:-cockpit}"
SERVE=false
SERVE_PORT="${RALPH_SERVE_PORT:-7433}"
ATTACH=false
ATTACH_INTERVAL="${RALPH_ATTACH_INTERVAL:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine)      ENGINE="$2"; shift 2 ;;
    --engine=*)    ENGINE="${1#*=}"; shift ;;
    --model)       IMPL_MODEL="$2"; shift 2 ;;
    --model=*)     IMPL_MODEL="${1#*=}"; shift ;;
    --from)        FROM_PHASE="$2"; shift 2 ;;
    --from=*)      FROM_PHASE="${1#*=}"; shift ;;
    --max-cycles)  MAX_CYCLES="$2"; shift 2 ;;
    --max-cycles=*) MAX_CYCLES="${1#*=}"; shift ;;
    --max-repairs) MAX_REPAIRS="$2"; shift 2 ;;
    --max-repairs=*) MAX_REPAIRS="${1#*=}"; shift ;;
    --no-repair)   REPAIR_MODE="off"; shift ;;
    --max-rescues) MAX_RESCUES="$2"; shift 2 ;;
    --max-rescues=*) MAX_RESCUES="${1#*=}"; shift ;;
    --no-rescue)   RESCUE_MODE="off"; shift ;;
    --rescue-model) RESCUE_MODEL="$2"; shift 2 ;;
    --rescue-model=*) RESCUE_MODEL="${1#*=}"; shift ;;
    --baseline)    BASELINE_MODE="on"; shift ;;
    --no-baseline) BASELINE_MODE="off"; shift ;;
    --no-heal-head) HEAL_MODE="off"; shift ;;
    --test-cmd)    TEST_CMD_FLAG="$2"; shift 2 ;;
    --test-cmd=*)  TEST_CMD_FLAG="${1#*=}"; shift ;;
    --full-suite)  TEST_SCOPE_MODE="full"; shift ;;
    --keep-going)  KEEP_GOING=true; shift ;;
    --no-verify)   VERIFY_MODE="off"; shift ;;
    --ui-shot-cmd) UI_SHOT_CMD="$2"; shift 2 ;;
    --ui-shot-cmd=*) UI_SHOT_CMD="${1#*=}"; shift ;;
    --no-ui-verify) UI_VERIFY_MODE="off"; shift ;;
    --no-env-guard) ENV_GUARD=false; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --quiet)       VERBOSE=false; shift ;;
    --ui-layout)   UI_LAYOUT="$2"; shift 2 ;;
    --ui-layout=*) UI_LAYOUT="${1#*=}"; shift ;;
    --ui)          UI_MODE="panel"; shift ;;
    --no-ui)       UI_MODE="plain"; shift ;;
    --serve)       SERVE=true; shift ;;
    --serve=*)     SERVE=true; SERVE_PORT="${1#*=}"; shift ;;
    --attach)      ATTACH=true; shift ;;
    # Todo o cabecalho, ate a primeira linha de codigo: um intervalo fixo
    # (sed '2,70p') truncava o help sempre que a doc crescia.
    -h|--help)     awk 'NR > 1 && /^set -e/ { exit } NR > 1' "$0"; exit 0 ;;
    *)             INPUT_FILE="$1"; shift ;;
  esac
done

case "$UI_LAYOUT" in cockpit|focus|diagnostic) ;; *) UI_LAYOUT=cockpit ;; esac

PHASES_DIR=".phases"
LOG_DIR=".phases/logs"
PROMPT_DIR=".phases/prompts"
MANIFEST="$PHASES_DIR/manifest.txt"
PROGRESS_FILE="$PHASES_DIR/.progress"

# Contrato publico de estado — ver o cabecalho. Tres consumidores: painel,
# dashboard web e qualquer ferramenta externa.
STATE_FILE="$PHASES_DIR/state.json"
EVENTS_FILE="$PHASES_DIR/events.jsonl"
UI_DIR="$PHASES_DIR/ui"
# Capturas de tela do gate 3 (evidencia visual): <fase>/task-<n>.png
EVIDENCE_DIR="$PHASES_DIR/evidence"
# Autocaptura do executor: rascunho dele, nunca lido pelo gate 3.
SELFCHECK_DIR="$PHASES_DIR/selfcheck"
UI_MSG_FILE="$UI_DIR/messages.log"
# Inferencia por task. Em --attach vai para um arquivo proprio: o pintor do run
# original continua escrevendo o dele, e dois processos disputando o mesmo
# arquivo fariam os dois piscarem entre um resultado e outro.
UI_TASKPROG="$UI_DIR/taskprog.txt"
$ATTACH && UI_TASKPROG="$UI_DIR/taskprog.attach.txt"
# Janelas das listas desenhadas no ultimo frame, uma linha por lista
# (lista|start|total|budget). O pintor precisa delas para mover a rolagem, e
# nao consegue le-las da memoria: ui_frame roda dentro de uma substituicao de
# comando. Mesmo motivo do taskprog para separar o do --attach: dois processos
# disputando o arquivo fariam a janela dos dois pular.
UI_VIEWPORT="$UI_DIR/.viewport"
$ATTACH && UI_VIEWPORT="$UI_DIR/.viewport.attach"
# Mapa de cliques do ultimo frame (linha|col_ini|col_fim|acao, 1-based):
# regioes clicaveis exatamente como foram desenhadas.
UI_HITMAP="$UI_DIR/.hitmap"
$ATTACH && UI_HITMAP="$UI_DIR/.hitmap.attach"
# "q Sair" (RF-03): o pintor fecha o painel sozinho e deixa aqui quantas linhas
# do messages.log ja reimprimiu. O principal le a contagem e reimprime so o
# resto — nem linha perdida, nem linha em dobro. O attach tem o seu: o run que
# ele acompanha pode estar com o painel proprio aberto.
UI_PANEL_FLAG="$UI_DIR/.panel-closed"
$ATTACH && UI_PANEL_FLAG="$UI_DIR/.panel-closed.attach"
UI_HTML="$UI_DIR/index.html"

MAX_LIMIT_WAITS="${RALPH_MAX_LIMIT_WAITS:-20}"
LIMIT_WAIT_DEFAULT="${RALPH_LIMIT_WAIT_DEFAULT:-1800}"
LIMIT_BUFFER="${RALPH_LIMIT_BUFFER:-60}"
# O limite de sessao reseta em <= 5h; o semanal, em dias. O horizonte do reset e
# a unica pista no output da CLI para separar os dois. Acima do limiar dormir
# seria segurar o terminal por dias — o run encerra e devolve o comando de
# retomada em vez disso.
WEEKLY_THRESHOLD="${RALPH_WEEKLY_THRESHOLD:-21600}"

NOTIFY_CMD="${RALPH_NOTIFY_CMD:-}"
NOTIFY_TIMEOUT="${RALPH_NOTIFY_TIMEOUT:-20}"
# Fora de um repo git o preflight aborta depois; o fallback existe so para o
# --help e para os modos de teste nao morrerem sob `set -e`.
PROJECT_NAME="$(basename "$(git rev-parse --show-toplevel 2> /dev/null || pwd)")"

TEST_CMD=""
SAIL_BIN=""
LIMIT_WAITS=0

UI_ACTIVE=false
UI_PAINTER_PID=""
UI_FPS="${RALPH_UI_FPS:-2}"
# Navegacao por teclado no painel. Nao viola a invariante 2 ("zero perguntas"):
# o run nunca espera por tecla — a leitura tem timeout e ela substitui o proprio
# sleep entre frames. Sem tecla, o comportamento e identico ao de antes.
UI_KEYS="${RALPH_UI_KEYS:-1}"
# Rolagem por lista (UI_SCROLL_<lista>) e selecao (UI_SEL_*) vivem no processo
# do pintor, unico que le teclado — ver ui_list_window.
UI_KEY=""
UI_QUIT=0
UI_REPRINTED=0
# Termios de antes do painel. O `read -s` do pintor desliga o eco e o restaura
# sozinho ao voltar — mas o pintor morre por sinal (ui_stop, Ctrl-C), e ai o
# restore nao acontece e o dev fica com um terminal mudo depois do run.
UI_TTY_STATE=""
UI_MOUSE=false
SERVE_PID=""
SERVE_URL=""
RUN_START_EPOCH=0

# Estado corrente, espelhado no state.json a cada state_sync.
ST_RUN_STATUS="starting"
ST_PHASE_NUM=0
ST_PHASE_SEQ=0
ST_PHASE_TOTAL=0
ST_PHASE_TITLE=""
ST_PHASE_STATUS="pending"
ST_PHASE_START=0
ST_CYCLE=0
ST_GATE0="pending"
ST_GATE1="pending"
ST_GATE2="pending"
ST_GATE3="pending"
ST_LIMIT_UNTIL=0
ST_LIMIT_WAITING=0
ST_STDERR_LOG=""
ST_ACTIVITY=""
ST_LAST_ERROR=""
ST_FAILURE_GATE=""
ST_FAILURE_CYCLE=0
ST_FAILURE_LOG=""
ST_TEST_LOG=""
ST_STAGE_START=0
ST_STDOUT_LOG=""
# Gates da tentativa anterior (ciclo ou round de conserto), para a tela de
# diagnostico comparar com a atual. Snapshot antes de cada reset.
ST_PREV_GATE0="pending"
ST_PREV_GATE1="pending"
ST_PREV_GATE2="pending"
ST_PREV_GATE3="pending"
# Digest da falha corrente (ui_failure_digest), recalculado so quando a falha
# muda — a chave e gate|ciclo|log. Ver state_derive.
SD_FAIL_KEY=""
SD_FAIL_NAME=""
SD_FAIL_MESSAGE=""
SD_FAIL_HEADLINE=""
SD_FAIL_FILE=""
SD_TEST_FILE=""
SD_TASKS=""
SD_TASK_ACTIVE=0
SD_CORRECTION=""
SD_STATUS_WORD=""
SD_STATUS_TONE=""
SD_PHASES_DONE=0
SD_PHASES_TOTAL=0
SD_PERCENT=0
# Conserto cirurgico: idle | running | ok | fail | skipped. ST_REPAIR_ROUND e o
# round corrente DENTRO do ciclo (0 = nenhum conserto em curso).
ST_REPAIR="idle"
ST_REPAIR_ROUND=0
ST_RESCUE="idle"
ST_RESCUE_ROUND=0
# Sufixo dos logs/prompts dos gates dentro de um mesmo ciclo. Vazio no round 0
# (nomes historicos preservados); "r<N>" nas revalidacoes pos-conserto, para que
# um round nao sobrescreva o log do anterior.
GATE_TAG=""
# Escopo do gate 3: posicoes a verificar, separadas por espaco. Vazio = a fase
# inteira (o comportamento normal).
VERIFY_ONLY_IDX=""
GATE_STARTED_AT=0
FAILED_NUMS=""
RALPH_PID=$$
RUN_ID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Com o painel ativo o placar nao vai para o terminal (o quadro ocupa as
# ultimas linhas e e repintado no lugar); vai para o messages.log, de onde o
# painel mostra as ultimas linhas. Sem painel o caminho e o de sempre, byte a
# byte — e o que mantem nohup/CI/pipe identicos ao ralph pre-painel.
ui_sink() {
  printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$UI_MSG_FILE" 2> /dev/null || true
}

# O painel ainda esta na tela? Com "q Sair" (ou o pintor morto) ele ja nao
# esta: o principal passa para o placar corrido na primeira linha que loga.
# Subshell nao consegue mudar o estado do pai — so decide a propria linha.
ui_panel_live() {
  $UI_ACTIVE || return 1
  if [ "$BASHPID" != "$RALPH_PID" ]; then
    [ -f "$UI_PANEL_FLAG" ] && return 1
    return 0
  fi
  if ui_panel_gone; then ui_panel_closed; return 1; fi
  return 0
}

log()     { if ui_panel_live; then ui_sink info "$1"; else echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; fi; }
success() { if ui_panel_live; then ui_sink ok   "$1"; else echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; fi; }
warn()    { if ui_panel_live; then ui_sink warn "$1"; else echo -e "${YELLOW}[$(date '+%H:%M:%S')] $1${NC}"; fi; }
fail()    { if ui_panel_live; then ui_sink fail "$1"; else echo -e "${RED}[$(date '+%H:%M:%S')] $1${NC}"; fi; }

# ---------------------------------------------------------------------------
# Notificacao externa (opcional)
# ---------------------------------------------------------------------------

# notify <evento> <mensagem>
#
# No-op sem RALPH_NOTIFY_CMD. O comando externo roda sob `timeout` e com
# stdin fechado: um adaptador travado (rede lenta, prompt acidental) nao pode
# parar o run nem consumir o manifest lido pelo loop de fases. Todo erro e
# engolido — invariante: notificar nunca altera o resultado do run.
notify() {
  [ -n "$NOTIFY_CMD" ] || return 0
  local event="$1" message="${2:-}" outcome="$ST_RUN_STATUS"
  [ "${ENV_ABORT:-0}" = 1 ] && outcome=environment

  RALPH_OUTCOME="$outcome" \
  RALPH_RUN_ID="$RUN_ID" \
  RALPH_PHASE_ATTEMPT="$ST_CYCLE" \
  RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES" \
  RALPH_GATE2="$ST_GATE2" \
  RALPH_GATE3="$ST_GATE3" \
  RALPH_TEST_SCOPE="$GATE2_SCOPE" \
  RALPH_LOG_PATH="${ST_FAILURE_LOG:-${ST_STDERR_LOG:-$LOG_DIR/}}" \
  RALPH_EVENT="$event" \
  RALPH_PROJECT="$PROJECT_NAME" \
  RALPH_ENGINE="$ENGINE" \
    timeout "$NOTIFY_TIMEOUT" \
    bash -c "$NOTIFY_CMD \"\$@\"" _ "$event" "$message" \
    > /dev/null 2>&1 < /dev/null || true

  return 0
}

# Primeira linha util do GATE_CAUSE, curta o bastante para caber numa celula do
# painel. O texto integral continua no terminal e nos logs.
gate_cause_summary() {
  printf '%s' "$GATE_CAUSE" | grep -v '^[[:space:]]*$' | head -n 1 | cut -c1-100 || true
}

format_duration() {
  local total_seconds=$1
  local hours=$((total_seconds / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$seconds"
  else
    printf "%ds" "$seconds"
  fi
}

# ---------------------------------------------------------------------------
# Estado estruturado — .phases/state.json + .phases/events.jsonl
#
# CONTRATO PUBLICO. O painel, o dashboard web e ferramentas externas leem
# daqui; nenhum deles parseia o placar humano. Escrever estado nunca pode
# falhar o run: todo erro e engolido, igual ao notify.
# ---------------------------------------------------------------------------

json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # Controles que sobraram quebrariam o JSON — o dashboard so precisa do texto.
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# Ecoa o status de uma fase pelo numero, para o snapshot e para o painel.
phase_status_of() {
  local num="$1" file="$2"

  if [ "$num" -lt "$FROM_PHASE" ]; then
    echo "skipped"
  elif [ "$num" = "$ST_PHASE_NUM" ] && [ "$ST_PHASE_STATUS" = "running" ]; then
    echo "running"
  elif is_phase_done "$file"; then
    echo "done"
  elif [[ " ${FAILED_NUMS} " == *" $num "* ]]; then
    echo "failed"
  else
    echo "pending"
  fi
}

# Ultima linha nao-vazia do stderr do engine: prova de vida no painel e no web.
current_progress_line() {
  [ -n "$ST_STDERR_LOG" ] && [ -s "$ST_STDERR_LOG" ] || return 0
  grep -v '^[[:space:]]*$' "$ST_STDERR_LOG" 2> /dev/null | tail -n 1 | cut -c1-160 || true
}

# ui_failure_digest <log>
#
# Nome do teste vermelho e mensagem da assertion, lidos do log da suite para a
# manchete das telas. Reusa as mesmas regras do gate 2 (gate2_failure_ids) e do
# conserto (extract_failure_signature) — o painel nunca inventa um parser.
# Publica em SD_FAIL_NAME/SD_FAIL_MESSAGE/SD_FAIL_FILE. REPAIR_SIGNATURE e
# REPAIR_FILES sao insumo do conserto em curso: salvos e restaurados.
ui_failure_digest() {
  local log="$1" saved_sig="$REPAIR_SIGNATURE" saved_files="$REPAIR_FILES" line
  SD_FAIL_NAME=""; SD_FAIL_MESSAGE=""; SD_FAIL_FILE=""
  [ -s "$log" ] || return 0

  if [ -n "$(gate2_failure_ids "$log" | head -n 1)" ]; then
    # Primeira linha de falha NA ORDEM DO LOG (os ids saem ordenados), com o
    # nome inteiro: "FAIL  rejects insufficient stock" tem espacos.
    line="$(sed -e 's/\x1b\[[0-9;]*m//g' "$log" 2> /dev/null | awk '
      /^[[:space:]]*FAIL[[:space:]]+[^[:space:]]/ ||
      /^[[:space:]]*FAILED[[:space:]]+[^[:space:]]+::/ ||
      /^[[:space:]]*--- FAIL: / ||
      /^test .* \.\.\. FAILED/ { print; exit }
    ' || true)"
    SD_FAIL_NAME="$(printf '%s' "$line" \
      | sed -E 's/^[[:space:]]*(--- FAIL:|FAILED|FAIL)[[:space:]]+//; s/^test[[:space:]]+(.*)[[:space:]]+\.\.\.[[:space:]]+FAILED$/\1/; s/[[:space:]]+$//' \
      | cut -c1-160)"
  fi

  if extract_failure_signature "$log" 30; then
    SD_FAIL_MESSAGE="$(printf '%s\n' "$REPAIR_SIGNATURE" \
      | grep -aE '(Failed asserting|Expected|AssertionError|panicked at|Error[[:space:]]*:|Exception|^[[:space:]]*E[[:space:]]{2,})' \
      | grep -avE '^[[:space:]]*(FAIL|FAILED|--- FAIL:)[[:space:]]' \
      | head -n 1 | sed -E 's/^[[:space:]]+//' | cut -c1-200 || true)"
    SD_FAIL_FILE="$(printf '%s\n' "$REPAIR_FILES" | head -n 1)"
  fi

  REPAIR_SIGNATURE="$saved_sig"
  REPAIR_FILES="$saved_files"
  return 0
}

# Rotulo das telas para cada gate, o mesmo da caixa "VALIDACAO DA FASE".
gate_display_name() {
  case "$1" in
    gate0) printf 'G0 Sessão' ;; gate1) printf 'G1 Código' ;;
    gate2) printf 'G2 Testes' ;; gate3) printf 'G3 Verificação' ;;
    *) printf '%s' "$1" ;;
  esac
}

# task_label_split <rotulo> -> TLS_T (titulo) e TLS_S (subtitulo): o texto
# depois do PRIMEIRO separador, " — " ou ": ", sem `(PLAN: TNN)`. Sem
# separador o subtitulo e vazio. Fonte unica: state.json e painel dividem o
# rotulo do mesmo jeito.
task_label_split() {
  local label="${1//$'\t'/ }" a b
  while [[ "$label" =~ ^(.*)\(PLAN:[[:space:]]*T[0-9]+\)(.*)$ ]]; do
    label="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  done
  label="${label%"${label##*[![:space:]]}"}"
  a="${label%%' — '*}"
  b="${label%%': '*}"
  TLS_T="$label"; TLS_S=""
  if [ "$a" != "$label" ] && { [ "$b" = "$label" ] || [ "${#a}" -le "${#b}" ]; }; then
    TLS_T="$a"; TLS_S="${label#"$a — "}"
  elif [ "$b" != "$label" ]; then
    TLS_T="$b"; TLS_S="${label#"$b: "}"
  fi
}

# Campos aditivos do estado (RF-14). Calculados UMA vez por state_sync e lidos
# pelas duas saidas — state.json e state.env —, entao terminal e navegador
# nunca derivam valores diferentes do mesmo instante.
#
# SD_TASKS: uma linha por task da fase corrente, campos separados por \x1f
# (idx, status, titulo, subtitulo). Separador fora do texto: TAB colapsaria
# num `read` com campo vazio.
state_derive() {
  local key="$ST_FAILURE_GATE|$ST_FAILURE_CYCLE|$ST_FAILURE_LOG"
  if [ -z "$ST_FAILURE_GATE" ]; then
    SD_FAIL_KEY=""; SD_FAIL_NAME=""; SD_FAIL_MESSAGE=""; SD_FAIL_HEADLINE=""; SD_FAIL_FILE=""
  elif [ "$key" != "$SD_FAIL_KEY" ]; then
    # Log so e relido quando a falha muda: o state_sync roda a cada atividade.
    SD_FAIL_KEY="$key"
    SD_FAIL_NAME=""; SD_FAIL_MESSAGE=""; SD_FAIL_FILE=""
    [ "$ST_FAILURE_GATE" = gate2 ] && ui_failure_digest "$ST_FAILURE_LOG"
    if [ -n "$SD_FAIL_NAME" ]; then
      SD_FAIL_HEADLINE="$SD_FAIL_NAME${SD_FAIL_MESSAGE:+: $SD_FAIL_MESSAGE}"
    else
      SD_FAIL_HEADLINE="$ST_LAST_ERROR"
    fi
  fi
  SD_TEST_FILE="${GATE2_SCOPE_FILES:-$SD_FAIL_FILE}"

  local sep=$'\x1f' file num title idx status label
  local pdone=0 ptotal=0 running=0
  SD_TASKS=""
  SD_TASK_ACTIVE=0
  [ "$ST_RUN_STATUS" = running ] && [ "$ST_PHASE_STATUS" = running ] && running=1

  if [ -f "$MANIFEST" ]; then
    while IFS='|' read -r file num title; do
      [ -n "$num" ] || continue
      ptotal=$((ptotal + 1))
      [ "$(phase_status_of "$num" "$file")" = "done" ] && pdone=$((pdone + 1))
      [ "$num" = "$ST_PHASE_NUM" ] || continue

      while IFS='|' read -r idx status label; do
        [ -n "$idx" ] || continue
        # Tarefa ativa: a primeira que ainda nao fechou, so com a fase rodando.
        if [ "$running" = 1 ] && [ "$SD_TASK_ACTIVE" = 0 ]; then
          case "$status" in
            pending) status=running; SD_TASK_ACTIVE="$idx" ;;
            partial) SD_TASK_ACTIVE="$idx" ;;
          esac
        fi
        task_label_split "$label"
        SD_TASKS+="$idx$sep$status$sep$TLS_T$sep$TLS_S"$'\n'
      done < <(phase_task_rows "$file" "$num")
    done < <(manifest_entries)
  fi
  SD_PHASES_DONE="$pdone"
  SD_PHASES_TOTAL="$ptotal"
  SD_PERCENT=0
  [ "$ptotal" -gt 0 ] && SD_PERCENT=$((pdone * 100 / ptotal))

  SD_CORRECTION=""
  if [ "$running" = 1 ]; then
    if [ "$ST_REPAIR" = running ]; then
      SD_CORRECTION="Conserto cirúrgico $ST_REPAIR_ROUND/$MAX_REPAIRS — $(gate_display_name "$ST_FAILURE_GATE")"
    elif [ "$ST_RESCUE" = running ]; then
      SD_CORRECTION="Resgate $ST_RESCUE_ROUND/$MAX_RESCUES"
    elif [ "$ST_CYCLE" -gt 1 ]; then
      SD_CORRECTION="Ciclo de correção $ST_CYCLE/$MAX_CYCLES — ${SD_FAIL_NAME:-${SD_FAIL_HEADLINE:-$(gate_display_name "$ST_FAILURE_GATE")}}"
    fi
  fi

  case "$ST_RUN_STATUS" in
    running)
      if [ "$ST_LIMIT_WAITING" = 1 ]; then
        SD_STATUS_WORD="AGUARDANDO LIMITE"; SD_STATUS_TONE="warn"
      elif [ -n "$SD_CORRECTION" ]; then
        SD_STATUS_WORD="CORRIGINDO"; SD_STATUS_TONE="warn"
      else
        SD_STATUS_WORD="IMPLEMENTANDO"; SD_STATUS_TONE="run"
      fi ;;
    done)    SD_STATUS_WORD="CONCLUÍDO"; SD_STATUS_TONE="ok" ;;
    failed)  SD_STATUS_WORD="FALHOU";    SD_STATUS_TONE="err" ;;
    aborted) SD_STATUS_WORD="ABORTADO";  SD_STATUS_TONE="err" ;;
    *)       SD_STATUS_WORD="INICIANDO"; SD_STATUS_TONE="dim" ;;
  esac
  return 0
}

# state.json reescrito por tmp + mv: `mv` no mesmo filesystem e atomico, entao
# um leitor concorrente ve a versao velha OU a nova, nunca meio arquivo. Escrever
# por cima do proprio state.json daria JSON invalido a quem lesse no meio.
state_sync() {
  [ -d "$PHASES_DIR" ] || return 0

  local tmp now progress
  now=$(date +%s)
  tmp="$STATE_FILE.tmp.$$"
  progress="$(current_progress_line)"
  state_derive 2> /dev/null || true

  if ! {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "project": "%s",\n'   "$(json_escape "$PROJECT_NAME")"
    printf '  "engine": "%s",\n'    "$ENGINE"
    printf '  "input": "%s",\n'     "$(json_escape "$INPUT_FILE")"
    printf '  "test_cmd": "%s",\n'  "$(json_escape "$TEST_CMD")"
    printf '  "started_at": %d,\n'  "$RUN_START_EPOCH"
    printf '  "updated_at": %d,\n'  "$now"
    printf '  "run_status": "%s",\n' "$ST_RUN_STATUS"
    printf '  "phase": {"num": %d, "seq": %d, "total": %d, "title": "%s", "status": "%s", "cycle": %d, "max_cycles": %d, "started_at": %d},\n' \
      "$ST_PHASE_NUM" "$ST_PHASE_SEQ" "$ST_PHASE_TOTAL" "$(json_escape "$ST_PHASE_TITLE")" \
      "$ST_PHASE_STATUS" "$ST_CYCLE" "$MAX_CYCLES" "$ST_PHASE_START"
    printf '  "gates": {"0": "%s", "1": "%s", "2": "%s", "3": "%s"},\n' \
      "$ST_GATE0" "$ST_GATE1" "$ST_GATE2" "$ST_GATE3"
    printf '  "repair": {"status": "%s", "round": %d, "max": %d},\n' \
      "$ST_REPAIR" "$ST_REPAIR_ROUND" "$MAX_REPAIRS"
    printf '  "rescue": {"status": "%s", "round": %d, "max": %d},\n' \
      "$ST_RESCUE" "$ST_RESCUE_ROUND" "$MAX_RESCUES"
    printf '  "limit": {"waiting": %s, "until": %d, "waits": %d, "max_waits": %d},\n' \
      "$([ "$ST_LIMIT_WAITING" = "1" ] && echo true || echo false)" \
      "$ST_LIMIT_UNTIL" "$LIMIT_WAITS" "$MAX_LIMIT_WAITS"
    printf '  "progress_line": "%s",\n' "$(json_escape "$progress")"
    printf '  "activity": "%s",\n'      "$(json_escape "$ST_ACTIVITY")"
    printf '  "last_error": "%s",\n'    "$(json_escape "$ST_LAST_ERROR")"
    printf '  "pid": %d,\n'             "$RALPH_PID"
    printf '  "run_id": "%s",\n'        "$(json_escape "$RUN_ID")"
    printf '  "phases": [\n'

    local first=1 file num title status
    if [ -f "$MANIFEST" ]; then
      while IFS='|' read -r file num title; do
        [ -n "$num" ] || continue
        status="$(phase_status_of "$num" "$file")"
        [ "$first" = "1" ] || printf ',\n'
        first=0
        printf '    {"num": %d, "title": "%s", "status": "%s"}' \
          "$num" "$(json_escape "$title")" "$status"
      done < <(manifest_entries)
    fi

    printf '\n  ],\n'

    # Campos aditivos (RF-14). Sempre DEPOIS das chaves antigas: um leitor que
    # compara o prefixo do arquivo continua vendo os mesmos bytes (CT-01).
    printf '  "failure": {"gate": "%s", "cycle": %d, "headline": "%s", "name": "%s", "message": "%s", "log": "%s"},\n' \
      "$ST_FAILURE_GATE" "$ST_FAILURE_CYCLE" "$(json_escape "$SD_FAIL_HEADLINE")" \
      "$(json_escape "$SD_FAIL_NAME")" "$(json_escape "$SD_FAIL_MESSAGE")" "$(json_escape "$ST_FAILURE_LOG")"
    printf '  "test": {"scope": "%s", "file": "%s", "log": "%s"},\n' \
      "$GATE2_SCOPE" "$(json_escape "$SD_TEST_FILE")" "$(json_escape "$ST_TEST_LOG")"
    printf '  "tasks": ['
    local tfirst=1 tidx tstatus ttitle tsub
    while IFS=$'\x1f' read -r tidx tstatus ttitle tsub; do
      [ -n "$tidx" ] || continue
      [ "$tfirst" = "1" ] || printf ','
      tfirst=0
      printf '\n    {"idx": %d, "title": "%s", "subtitle": "%s", "status": "%s"}' \
        "$tidx" "$(json_escape "$ttitle")" "$(json_escape "$tsub")" "$tstatus"
    done <<< "$SD_TASKS"
    if [ "$tfirst" = "1" ]; then printf '],\n'; else printf '\n  ],\n'; fi
    printf '  "task_active": %d,\n' "$SD_TASK_ACTIVE"
    printf '  "correction": {"title": "%s"},\n' "$(json_escape "$SD_CORRECTION")"
    printf '  "previous_gates": {"0": "%s", "1": "%s", "2": "%s", "3": "%s"},\n' \
      "$ST_PREV_GATE0" "$ST_PREV_GATE1" "$ST_PREV_GATE2" "$ST_PREV_GATE3"
    printf '  "display": {"status_word": "%s", "status_tone": "%s", "phases_done": %d, "phases_total": %d, "percent": %d}\n' \
      "$SD_STATUS_WORD" "$SD_STATUS_TONE" "$SD_PHASES_DONE" "$SD_PHASES_TOTAL" "$SD_PERCENT"
    printf '}\n'
  } > "$tmp" 2> /dev/null || ! mv -f "$tmp" "$STATE_FILE" 2> /dev/null; then
    rm -f "$tmp" 2> /dev/null
  fi

  ui_state_cache
  return 0
}

# Cache achatado para o painel. O state.json e o contrato publico (JSON, pro
# web); o painel roda em bash sem jq garantido, entao le key=value daqui. Nao e
# duplicacao de contrato: e um indice privado, derivado do mesmo estado.
ui_state_cache() {
  local tmp="$UI_DIR/.state.tmp.$$"
  [ -d "$UI_DIR" ] || return 0

  if ! {
    printf 'run_status=%s\n'  "$ST_RUN_STATUS"
    printf 'phase_num=%s\n'   "$ST_PHASE_NUM"
    printf 'phase_seq=%s\n'   "$ST_PHASE_SEQ"
    printf 'phase_total=%s\n' "$ST_PHASE_TOTAL"
    printf 'phase_title=%s\n' "${ST_PHASE_TITLE//$'\n'/ }"
    printf 'cycle=%s\n'       "$ST_CYCLE"
    printf 'max_cycles=%s\n'  "$MAX_CYCLES"
    printf 'phase_start=%s\n' "$ST_PHASE_START"
    printf 'gate0=%s\n'       "$ST_GATE0"
    printf 'gate1=%s\n'       "$ST_GATE1"
    printf 'gate2=%s\n'       "$ST_GATE2"
    printf 'gate3=%s\n'       "$ST_GATE3"
    printf 'repair=%s\n'      "$ST_REPAIR"
    printf 'repair_round=%s\n' "$ST_REPAIR_ROUND"
    printf 'max_repairs=%s\n' "$MAX_REPAIRS"
    printf 'rescue=%s\n'      "$ST_RESCUE"
    printf 'rescue_round=%s\n' "$ST_RESCUE_ROUND"
    printf 'max_rescues=%s\n' "$MAX_RESCUES"
    printf 'test_cmd=%s\n'    "${TEST_CMD//$'\n'/ }"
    printf 'limit_waiting=%s\n' "$ST_LIMIT_WAITING"
    printf 'limit_until=%s\n' "$ST_LIMIT_UNTIL"
    printf 'progress=%s\n'    "$(current_progress_line)"
    printf 'activity=%s\n'    "${ST_ACTIVITY//$'\n'/ }"
    printf 'last_error=%s\n'  "${ST_LAST_ERROR//$'\n'/ }"
    printf 'failure_gate=%s\n' "$ST_FAILURE_GATE"
    printf 'failure_cycle=%s\n' "$ST_FAILURE_CYCLE"
    printf 'failure_log=%s\n' "$ST_FAILURE_LOG"
    printf 'test_log=%s\n' "$ST_TEST_LOG"
    printf 'test_scope=%s\n' "$GATE2_SCOPE"
    printf 'test_scope_cmd=%s\n' "${GATE2_SCOPE_CMD//$'\n'/ }"
    printf 'test_scope_why=%s\n' "${GATE2_SCOPE_WHY//$'\n'/ }"
    printf 'env_abort=%s\n' "${ENV_ABORT:-0}"
    printf 'updated=%s\n' "$(date +%s)"
    printf 'stage_start=%s\n' "$ST_STAGE_START"
    printf 'stderr_log=%s\n'  "$ST_STDERR_LOG"
    printf 'stdout_log=%s\n'  "$ST_STDOUT_LOG"
    printf 'pid=%s\n'         "$RALPH_PID"
    printf 'run_id=%s\n'      "$RUN_ID"
    printf 'started=%s\n'     "$RUN_START_EPOCH"
    # O --attach desenha o painel de um run alheio: sem isso o cabecalho dele
    # mostraria a engine default em vez da que o run de verdade esta usando.
    printf 'engine=%s\n'      "$ENGINE"
    printf 'project=%s\n'     "$PROJECT_NAME"
    # Campos aditivos (RF-14): os MESMOS valores do state.json, da mesma
    # derivacao (state_derive). task= se repete, uma linha por tarefa, com
    # idx/status/titulo/subtitulo separados por TAB.
    printf 'failure_name=%s\n'     "${SD_FAIL_NAME//$'\n'/ }"
    printf 'failure_message=%s\n'  "${SD_FAIL_MESSAGE//$'\n'/ }"
    printf 'failure_headline=%s\n' "${SD_FAIL_HEADLINE//$'\n'/ }"
    printf 'test_file=%s\n'        "${SD_TEST_FILE//$'\n'/ }"
    printf 'task_active=%s\n'      "$SD_TASK_ACTIVE"
    printf 'correction_title=%s\n' "$SD_CORRECTION"
    printf 'prev_gate0=%s\n'       "$ST_PREV_GATE0"
    printf 'prev_gate1=%s\n'       "$ST_PREV_GATE1"
    printf 'prev_gate2=%s\n'       "$ST_PREV_GATE2"
    printf 'prev_gate3=%s\n'       "$ST_PREV_GATE3"
    printf 'status_word=%s\n'      "$SD_STATUS_WORD"
    printf 'status_tone=%s\n'      "$SD_STATUS_TONE"
    printf 'phases_done=%s\n'      "$SD_PHASES_DONE"
    printf 'phases_total=%s\n'     "$SD_PHASES_TOTAL"
    printf 'percent=%s\n'          "$SD_PERCENT"
    printf '%s' "$SD_TASKS" | tr '\037' '\t' | sed 's/^/task=/'
  } > "$tmp" 2> /dev/null || ! mv -f "$tmp" "$UI_DIR/state.env" 2> /dev/null; then
    rm -f "$tmp" 2> /dev/null
  fi

  local ptmp="$UI_DIR/.phases.tmp.$$"
  if [ -f "$MANIFEST" ]; then
    if ! {
      local file num title
      while IFS='|' read -r file num title; do
        [ -n "$num" ] || continue
        printf '%s|%s|%s\n' "$num" "$(phase_status_of "$num" "$file")" "$title"
      done < <(manifest_entries)
    } > "$ptmp" 2> /dev/null || ! mv -f "$ptmp" "$UI_DIR/phases.txt" 2> /dev/null; then
      rm -f "$ptmp" 2> /dev/null
    fi
  fi

  ui_tasks_cache
  return 0
}

# Rotulo curto de cada task de uma fase, na ordem em que aparecem — a MESMA
# posicao que o gate 3 usa como indice. Tira o markdown e o rotulo global
# (`T33 —`) que um PHASES.md multi-fase carrega.
extract_task_labels() {
  sed -nE 's/^[[:space:]]*- \[[ xX]\][[:space:]]*(.*)$/\1/p' "$PHASES_DIR/$1" 2> /dev/null \
    | sed -E 's/\*\*//g; s/^\*?T[0-9]+[[:space:]]*[—–-][[:space:]]*//; s/^Task:[[:space:]]*//; s/[[:space:]]+$//' \
    | awk 'NF { printf "%d|%s\n", ++n, $0 }'
}

# Bloco inteiro de uma task: a linha `- [ ]` mais as linhas de continuacao
# indentadas, ate a proxima task ou o fim do bloco.
#
# Ler so a linha do titulo era o motivo de a inferencia nunca sair do lugar: num
# PHASES.md de verdade o titulo e prosa ("Job assincrono de import") e TODO o
# artefato concreto — `Arquivos:`, `Testes:`, nomes de classe — vive nas
# continuacoes. Sem elas o conjunto de ancoras saia vazio.
extract_task_block() {
  local phase_file="$1" want="$2"
  awk -v want="$want" '
    /^[[:space:]]*- \[[ xX]\]/ {
      n++
      if (n > want) exit
      inblock = (n == want)
      if (inblock) { print; next }
    }
    # Linha nao indentada encerra o bloco (heading, paragrafo solto).
    inblock && /^[^[:space:]]/ { exit }
    inblock { print }
  ' "$PHASES_DIR/$phase_file" 2> /dev/null
}

# Ancoras de uma task: os identificadores de codigo que o bloco dela nomeia —
# conteudo entre crases, CamelCase, snake_case, caminhos e nomes de arquivo.
# Sao o unico elo entre a linguagem da task e o que aparece no disco.
#
# Caminho vence identificador: quando a task declara arquivos, sao eles que
# medem a task ("o artefato que ela nomeia ja existe?"). Identificador solto so
# entra quando nao ha nenhum caminho — senao um `WhatsappConnectionStatus`
# citado de passagem valeria tanto quanto o arquivo que a task cria.
extract_task_anchors() {
  local phase_file="$1" want="$2" block tokens paths
  block="$(extract_task_block "$phase_file" "$want")"
  [ -n "$block" ] || return 0

  # tr -c: qualquer coisa fora do alfabeto de caminho vira quebra de linha. Sem
  # isso um trecho entre crases com espacos (`status !== Foo::Bar`) viraria uma
  # ancora unica que jamais casa com um caminho.
  tokens="$(printf '%s' "$block" \
    | tr -c 'A-Za-z0-9_/.-' '\n' \
    | sed -E 's#^/+##; s/^[^A-Za-z0-9_]+//; s/[^A-Za-z0-9_/.-]+$//' \
    | awk 'length($0) >= 5' | sort -u)"

  # Candidato a caminho: tem extensao, ou tem barra E algum sinal de nome de
  # codigo (maiuscula ou underscore). So a barra nao basta — prosa tecnica em
  # portugues produz `try/catch` e `o/grupo`, que jamais casam com a arvore e
  # so diluiriam o percentual da task.
  paths="$(printf '%s\n' "$tokens" \
    | awk '$0 ~ /\.[A-Za-z0-9]{2,4}$/ || ($0 ~ /\// && $0 ~ /[A-Z_]/)' \
    | head -n 12)"
  if [ -n "$paths" ]; then
    printf '%s\n' "$paths"
    return 0
  fi

  printf '%s\n' "$tokens" \
    | awk '$0 ~ /[_\/.]/ || $0 ~ /[a-z][A-Z]/' \
    | head -n 12
}

# Estado do checkbox de cada task da fase: `indice|x` ou `indice| `.
#
# E o sinal de progresso que se move DURANTE a sessao — o engine e instruido a
# trocar `- [ ]` por `- [x]` quando os testes daquela task passam. Nao e
# veredito: o gate 3 confere task a task depois e sempre vence. `.phases/` esta
# em .git/info/exclude, entao marcar nao suja a arvore nem falsifica o gate 1.
extract_task_checks() {
  awk '
    match($0, /^[[:space:]]*- \[[ xX]\]/) {
      n++
      c = substr($0, RSTART + RLENGTH - 2, 1)
      printf "%d|%s\n", n, (c == "x" || c == "X") ? "x" : "-"
    }
  ' "$PHASES_DIR/$1" 2> /dev/null
}

# tasks.txt: fase|indice|status|rotulo. Uma linha por task de todas as fases.
#
# O status vem em ordem decrescente de autoridade:
#   1. fase concluida            => done
#   2. veredito do gate 3        => done | partial
#   3. checkbox `- [x]` na fase  => declared (o engine marcou; nao e veredito)
#   4. nada                      => pending
#
# O checkbox nunca sobrescreve veredito: uma task marcada pelo engine e depois
# reprovada pelo gate 3 tem que aparecer como Incompleta, e nao de verde.
# phase_task_rows <phase_file> <num> -> indice|status|rotulo, uma linha por
# task da fase. Fonte unica do status de task: tasks.txt e o state.json leem
# daqui, entao painel e navegador nunca discordam.
phase_task_rows() {
  local file="$1" num="$2" idx label status vfile checks pstatus
  vfile="$UI_DIR/verdicts-$num.txt"
  pstatus="$(phase_status_of "$num" "$file")"
  checks="$(extract_task_checks "$file")"
  while IFS='|' read -r idx label; do
    [ -n "$idx" ] || continue
    if [ "$pstatus" = "done" ]; then
      status="done"
    elif [ -f "$vfile" ] && grep -q "^$idx|" "$vfile" 2> /dev/null; then
      case "$(grep "^$idx|" "$vfile" | tail -1 | cut -d'|' -f2)" in
        DONE) status="done" ;;
        *)    status="partial" ;;
      esac
    elif [ "$(printf '%s\n' "$checks" | awk -F'|' -v i="$idx" '$1 == i { print $2; exit }')" = "x" ]; then
      status="declared"
    else
      status="pending"
    fi
    printf '%s|%s|%s\n' "$idx" "$status" "$label"
  done < <(extract_task_labels "$file")
}

ui_tasks_cache() {
  [ -f "$MANIFEST" ] || return 0
  local tmp="$UI_DIR/.tasks.tmp.$$"

  if ! {
    local file num title
    while IFS='|' read -r file num title; do
      [ -n "$num" ] || continue
      phase_task_rows "$file" "$num" | sed "s/^/$num|/"
    done < <(manifest_entries)
  } > "$tmp" 2> /dev/null || ! mv -f "$tmp" "$UI_DIR/tasks.txt" 2> /dev/null; then
    rm -f "$tmp" 2> /dev/null
  fi

  return 0
}

# state_event <evento> [par chave=valor]...
# Uma linha JSON por transicao, append-only. Nunca reescrito: o historico do run
# e o que permite ao dashboard montar timeline e duracao por gate.
state_event() {
  [ -d "$PHASES_DIR" ] || return 0
  local event="$1"; shift

  {
    printf '{"ts": %d, "event": "%s", "phase": %d, "cycle": %d' \
      "$(date +%s)" "$(json_escape "$event")" "$ST_PHASE_NUM" "$ST_CYCLE"
    local kv key value
    for kv in "$@"; do
      key="${kv%%=*}"
      value="${kv#*=}"
      if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        printf ', "%s": %s' "$(json_escape "$key")" "$value"
      else
        printf ', "%s": "%s"' "$(json_escape "$key")" "$(json_escape "$value")"
      fi
    done
    printf '}\n'
  } >> "$EVENTS_FILE" 2> /dev/null || true

  if [ -d "$UI_DIR" ]; then
    local detail="F$ST_PHASE_NUM C$ST_CYCLE $*"
    detail="${detail//$'\n'/ }"; detail="${detail//$'\t'/ }"
    printf '%s\t%s\t%s\n' "$(date '+%H:%M:%S')" "$event" "${detail:0:500}" \
      >> "$UI_DIR/events.tsv" 2>/dev/null || true
  fi
  state_sync
  return 0
}

# Os 7 eventos do hook tambem entram no events.jsonl: um consumidor externo ve
# a corrente inteira sem precisar registrar RALPH_NOTIFY_CMD.
notify_and_record() {
  state_event "$1" "message=$2"
  notify "$1" "$2"
}

# set_activity <texto>
#
# Atribuir a ST_ACTIVITY sem sincronizar era o bug do painel congelado: o
# state_sync so acontecia em transicao de evento (gate_start/gate_end), e o
# primeiro gate de uma fase so roda DEPOIS que o engine termina. A sessao de
# implementacao — a etapa mais longa do run — passava inteira sem republicar,
# entao o painel mostrava "preparando" por minutos.
set_activity() {
  ST_ACTIVITY="$1"
  ST_STAGE_START=$(date +%s)
  state_sync
}

gate_start() {
  GATE_STARTED_AT=$(date +%s)
  case "$1" in
    0) ST_GATE0="running" ;; 1) ST_GATE1="running" ;;
    2) ST_GATE2="running" ;; 3) ST_GATE3="running" ;;
  esac
  state_event gate_start "gate=$1"
}

# Guarda os gates da tentativa que acabou antes de uma nova comecar.
snapshot_gates() {
  ST_PREV_GATE0="$ST_GATE0"; ST_PREV_GATE1="$ST_GATE1"
  ST_PREV_GATE2="$ST_GATE2"; ST_PREV_GATE3="$ST_GATE3"
}

# gate_end <gate> <veredito: pass|fail|skip>
gate_end() {
  local gate="$1" verdict="$2" duration=$(($(date +%s) - GATE_STARTED_AT))
  case "$gate" in
    0) ST_GATE0="$verdict" ;; 1) ST_GATE1="$verdict" ;;
    2) ST_GATE2="$verdict" ;; 3) ST_GATE3="$verdict" ;;
  esac
  state_event gate_end "gate=$gate" "verdict=$verdict" "duration=$duration"
}

# ---------------------------------------------------------------------------
# Painel ANSI — tela cheia (alternate screen buffer)
#
# Invariante: o painel e uma camada de APRESENTACAO. Nunca altera veredito de
# gate nem exit code, e qualquer falha ao desenhar cai para o placar.
#
# Por que alternate screen e nao um quadro de altura fixa: as telas ocupam a
# janela inteira e adaptam a altura dela, e um quadro fixo so poderia repintar
# movendo o cursor N linhas para cima — N precisaria ser constante. Com o buffer alternado
# o painel manda na tela inteira, o layout pode ter qualquer altura, e ao sair o
# terminal volta com o scrollback anterior intacto.
#
# O placar (log/success/warn/fail) nao some: vai para .phases/ui/messages.log e
# as ultimas linhas aparecem no rodape do painel. Saida longa (causa de gate
# vermelho, relatorio final) e impressa DEPOIS de ui_stop, na tela normal.
# ---------------------------------------------------------------------------

# Glifos do placar de texto e do ui_line: toda marca aqui tem largura 1
# garantida. As telas usam o conjunto UI_GL_* (abaixo).
if [ "${RALPH_UI_GLYPHS:-ascii}" = "unicode" ]; then
  UI_G_CUT='…'; UI_G_NONE='—'
else
  UI_G_CUT='+'; UI_G_NONE='-'
fi
UI_C_OFF='\033[0m'

# ---------------------------------------------------------------------------
# Tokens visuais dos artboards (SPEC, tabela de tokens).
#
# Truecolor quando o terminal anuncia (COLORTERM=truecolor|24bit); senao o
# indice mais proximo da paleta 256. Os valores guardam o ESC de verdade, nao a
# string '\033': texto externo (log, titulo de task) entra nas linhas por %s e
# nunca pode ter barra invertida interpretada.
# ---------------------------------------------------------------------------
UI_TRUECOLOR=0
case "${COLORTERM:-}" in truecolor | 24bit) UI_TRUECOLOR=1 ;; esac

# ui_tok <fg|bg> <hex> <indice256> -> a sequencia SGR do token.
ui_tok() {
  local kind=38
  [ "$1" = bg ] && kind=48
  if [ "$UI_TRUECOLOR" = 1 ]; then
    printf '\033[%s;2;%d;%d;%dm' "$kind" "0x${2:0:2}" "0x${2:2:2}" "0x${2:4:2}"
  else
    printf '\033[%s;5;%sm' "$kind" "$3"
  fi
}
# Fundo do painel: o terminal ja pinta o proprio fundo; o token fica aqui para
# a paleta ser uma so (o dashboard usa o mesmo hex).
# shellcheck disable=SC2034
UI_K_PANEL="$(ui_tok bg 0b1018 233)"
UI_K_BOX="$(ui_tok bg 101923 234)"
UI_K_RULE="$(ui_tok fg 283545 237)"
UI_K_RULE_BG="$(ui_tok bg 283545 237)"
UI_K_TAB="$(ui_tok bg 233b48 23)"
UI_K_TEXT="$(ui_tok fg dce6ef 254)"
UI_K_DIM="$(ui_tok fg 91a3b5 109)"
UI_K_CYAN="$(ui_tok fg 66d9e8 80)"
UI_K_GREEN="$(ui_tok fg 8cdeb0 115)"
UI_K_AMBER="$(ui_tok fg f3c879 222)"
UI_K_RED="$(ui_tok fg ff8d94 210)"
UI_K_BANNER="$(ui_tok bg 291c25 235)"
# Faixa vertical e segmento cheio: celula com fundo na cor do token.
UI_K_CYAN_BG="$(ui_tok bg 66d9e8 80)"
UI_K_GREEN_BG="$(ui_tok bg 8cdeb0 115)"
UI_K_RED_BG="$(ui_tok bg ff8d94 210)"
UI_K_B=$'\033[1m'
# Dentro de caixa com fundo a cor do texto volta so no primeiro plano: um 0m
# no meio da linha apagaria o fundo da celula ate o fim dela.
UI_K_FG_OFF=$'\033[22;39m'
UI_K_OFF=$'\033[0m'

# Glifos das telas (D4). O default e o conjunto dos artboards; ascii e recuo
# para terminal/fonte sem esses caracteres.
if [ "${RALPH_UI_GLYPHS:-}" = "ascii" ]; then
  UI_GL_OK='v'; UI_GL_RUN='>'; UI_GL_DOT='*'; UI_GL_X='x'; UI_GL_NONE='-'
  UI_GL_ACT='>'; UI_GL_ARROW='->'; UI_GL_NE='!='; UI_GL_CUT='+'; UI_GL_BAR='='
else
  UI_GL_OK='✓'; UI_GL_RUN='▶'; UI_GL_DOT='●'; UI_GL_X='×'; UI_GL_NONE='—'
  UI_GL_ACT='›'; UI_GL_ARROW='→'; UI_GL_NE='≠'; UI_GL_CUT='…'; UI_GL_BAR=''
fi
UI_GL_PEND='·'

# Largura em COLUNAS no pior caso. East-Asian Ambiguous mede 1 no bash e 2 no
# terminal que resolve ambiguo como largo (Windows Terminal sobre WSL): cada
# um conta 2 aqui, e toda linha ainda guarda 1 coluna de folga (ui_frame usa
# w-1). Linha que quebra desmonta o frame inteiro; o preco do pior caso e, em
# terminal que desenha ambiguo estreito, a coluna da direita andar 1 casa por
# glifo — RALPH_UI_GLYPHS=ascii zera os dois. · e x (Latin-1) medem 1 em toda
# fonte monoespacada. Resultado em UI_VW, sem subshell — e chamado centenas de
# vezes por frame.
UI_AMB='▶●—→≠…'
ui_vw() {
  local t="${1//[$UI_AMB]/}"
  UI_VW=$((${#1} * 2 - ${#t}))
}

# ui_fit <texto> <colunas> -> UI_FIT: o texto cortado para caber, com marca de
# corte quando perde caractere.
ui_fit() {
  local s="$1" max="$2" cw
  UI_FIT="$s"
  [ "$max" -lt 1 ] && { UI_FIT=""; return 0; }
  ui_vw "$s"
  [ "$UI_VW" -le "$max" ] && return 0
  ui_vw "$UI_GL_CUT"; cw=$UI_VW
  s="${s:0:$max}"
  ui_vw "$s"
  while [ "${#s}" -gt 0 ] && [ $((UI_VW + cw)) -gt "$max" ]; do
    s="${s:0:$((${#s} - 1))}"
    ui_vw "$s"
  done
  UI_FIT="$s$UI_GL_CUT"
  [ "$cw" -gt "$max" ] && UI_FIT="${s:0:$max}"
  return 0
}

# --- linha em construcao ----------------------------------------------------
# UIR_P = texto plain (mede), UIR_C = texto com cor (desenha), UIR_W = colunas
# ocupadas, UIR_H = alvos de clique da linha ("col_ini|col_fim|acao", 0-based,
# fim exclusivo, relativos ao inicio da linha).
ui_r0() { UIR_P=""; UIR_C=""; UIR_W=0; UIR_H=(); }

# ui_rt <cor> <texto> [max_colunas] — acrescenta um trecho. Sem max, o trecho
# pode ocupar ate o fim da linha corrente (UIR_MAX).
ui_rt() {
  local color="$1" text="$2" max="${3:-}"
  local room=$((UIR_MAX - UIR_W))
  [ -z "$max" ] || [ "$max" -gt "$room" ] && max=$room
  ui_fit "$text" "$max"
  [ -n "$UI_FIT" ] || return 0
  ui_vw "$UI_FIT"
  UIR_P+="$UI_FIT"
  UIR_C+="$color$UI_FIT$UI_K_FG_OFF"
  UIR_W=$((UIR_W + UI_VW))
}

# ui_rpad <coluna> — espaco ate a coluna (0-based). Ja passou: um espaco, para
# dois campos nunca colarem.
ui_rpad() {
  local n=$(($1 - UIR_W))
  [ "$n" -lt 1 ] && [ "$UIR_W" -gt 0 ] && n=1
  [ $((UIR_W + n)) -gt "$UIR_MAX" ] && n=$((UIR_MAX - UIR_W))
  [ "$n" -gt 0 ] || return 0
  printf -v UI_PAD '%*s' "$n" ''
  UIR_P+="$UI_PAD"; UIR_C+="$UI_PAD"; UIR_W=$((UIR_W + n))
}

# ui_rhit <acao> <col_ini> — alvo do trecho que vai de col_ini ate o fim atual.
ui_rhit() { [ "$UIR_W" -gt "$2" ] && UIR_H+=("$2|$UIR_W|$1"); return 0; }

# --- blocos -----------------------------------------------------------------
# Um bloco e uma lista de linhas prontas + alvos de clique. As telas montam
# blocos por regiao e ui_frame os empilha ou poe lado a lado; os alvos andam
# junto, entao o mapa de cliques sai do MESMO desenho, sem segunda conta.
ui_blk() { eval "${1}_P=(); ${1}_C=(); ${1}_H=()"; }

# ui_emit <bloco> [largura fundo faixa] — fecha a linha corrente no bloco.
# Com fundo, a linha e preenchida ate a largura na cor da celula; com faixa,
# a primeira celula leva o fundo da faixa (linha vertical de 1 coluna).
# shellcheck disable=SC2178
ui_emit() {
  local -n _ep="${1}_P" _ec="${1}_C" _eh="${1}_H"
  local width="${2:-0}" bg="${3:-}" stripe="${4:-}" off=0 p c h row n a b act
  p="$UIR_P"; c="$UIR_C"
  if [ -n "$stripe" ]; then
    p=" $p"; c="$stripe $UI_K_OFF$bg$c"; off=1
  fi
  if [ "$width" -gt 0 ]; then
    ui_vw "$p"
    n=$((width - UI_VW))
    if [ "$n" -gt 0 ]; then printf -v UI_PAD '%*s' "$n" ''; p+="$UI_PAD"; c+="$UI_PAD"; fi
  fi
  row=${#_ep[@]}
  _ep+=("$p")
  _ec+=("$bg$c$UI_K_OFF")
  for h in "${UIR_H[@]}"; do
    IFS='|' read -r a b act <<< "$h"
    _eh+=("$row|$((a + off + 1))|$((b + off))|$act")
  done
  ui_r0
}

# ui_blank <bloco> [largura fundo faixa] — linha vazia (espacamento ou padding
# de caixa).
ui_blank() { ui_r0; ui_emit "$@"; }

# ui_cat <destino> <origem> — empilha; os alvos descem junto.
# shellcheck disable=SC2178
ui_cat() {
  local -n _dp="${1}_P" _dc="${1}_C" _dh="${1}_H" _sp="${2}_P" _sc="${2}_C" _sh="${2}_H"
  local base=${#_dp[@]} h
  _dp+=("${_sp[@]}"); _dc+=("${_sc[@]}")
  for h in "${_sh[@]}"; do _dh+=("$((base + ${h%%|*}))|${h#*|}"); done
}

# ui_side <destino> <esquerda> <largura_esq> <espaco> <direita> — lado a lado.
# O lado mais curto e completado com linha vazia da propria largura; os alvos
# da direita andam largura_esq + espaco colunas.
# shellcheck disable=SC2178
ui_side() {
  local -n _dp="${1}_P" _dc="${1}_C" _dh="${1}_H" _lp="${2}_P" _lc="${2}_C" _lh="${2}_H" _rp="${5}_P" _rc="${5}_C" _rh="${5}_H"
  local lw="$3" gap="$4" base=${#_dp[@]} n i p c h a rest shift
  n=${#_lp[@]}; [ "${#_rp[@]}" -gt "$n" ] && n=${#_rp[@]}
  shift=$((lw + gap))
  for ((i = 0; i < n; i++)); do
    p="${_lp[$i]:-}"; c="${_lc[$i]:-}"
    ui_vw "$p"
    printf -v UI_PAD '%*s' $((shift - UI_VW)) ''
    _dp+=("$p$UI_PAD${_rp[$i]:-}")
    _dc+=("$c$UI_PAD${_rc[$i]:-}")
  done
  for h in "${_lh[@]}"; do _dh+=("$((base + ${h%%|*}))|${h#*|}"); done
  for h in "${_rh[@]}"; do
    IFS='|' read -r i a b rest <<< "$h"
    _dh+=("$((base + i))|$((a + shift))|$((b + shift))|$rest")
  done
}

# ui_rule_line <bloco> <largura> — regua na cor de borda.
ui_rule_line() {
  ui_r0
  local r
  printf -v r '%*s' "$2" ''
  r="${r// /─}"
  UIR_P="$r"; UIR_C="$UI_K_RULE$r$UI_K_FG_OFF"; UIR_W="$2"
  ui_emit "$1"
}

# ui_seg_bar <bloco> <largura> <pct> — barra segmentada: segmentos de 2
# celulas e 1 de intervalo, cheios em verde ate o percentual.
ui_seg_bar() {
  local blk="$1" width="$2" pct="$3" n filled i cell p="" c=""
  n=$((width / 3)); [ "$n" -lt 1 ] && n=1
  filled=$((n * pct / 100)); [ "$filled" -gt "$n" ] && filled=$n
  for ((i = 0; i < n; i++)); do
    if [ -n "$UI_GL_BAR" ]; then
      [ "$i" -lt "$filled" ] && cell='##' || cell='..'
      p+="$cell "
      if [ "$i" -lt "$filled" ]; then c+="$UI_K_GREEN$cell$UI_K_FG_OFF "; else c+="$UI_K_RULE$cell$UI_K_FG_OFF "; fi
    else
      p+='   '
      if [ "$i" -lt "$filled" ]; then c+="$UI_K_GREEN_BG  $UI_K_OFF "; else c+="$UI_K_RULE_BG  $UI_K_OFF "; fi
    fi
  done
  ui_r0; UIR_P="$p"; UIR_C="$c"; UIR_W=$((n * 3))
  ui_emit "$blk"
}

# --- listas rolaveis ----------------------------------------------------------
# Uma janela por lista (events, tasks, timeline, testout). -1 = auto: a lista
# segue o agora (fim do historico, tarefa corrente). >= 0 = topo fixado pelo
# dev. O pintor precisa dos numeros do ULTIMO frame para rolar, e ui_frame roda
# num subshell: vao para UI_VIEWPORT, uma linha por lista desenhada.
UI_SCROLL_events=-1
UI_SCROLL_tasks=-1
UI_SCROLL_timeline=-1
UI_SCROLL_testout=-1

# ui_list_window <lista> <total> <orcamento> <topo_auto> -> UI_LS (topo).
ui_list_window() {
  local name="$1" total="$2" budget="$3" start="$4" v="UI_SCROLL_$1"
  [ "${!v:--1}" -ge 0 ] 2> /dev/null && start="${!v}"
  UI_LS="$(ui_scroll_fit "$start" "$total" "$budget")"
  UI_VP+=("$name|$UI_LS|$total|$budget")
}

# Rodape da janela: so quando ha linha escondida — e quando a dica importa.
ui_list_hint() {
  local name="$1" total="$2" budget="$3" start="$4" v="UI_SCROLL_$1" last
  UI_HINT=""
  [ "$total" -gt "$budget" ] || return 0
  last=$((start + budget)); [ "$last" -gt "$total" ] && last=$total
  UI_HINT="mostrando $((start + 1))-$last de $total"
  if [ "$UI_KEYS" = 1 ]; then
    if [ "${!v:--1}" -ge 0 ] 2> /dev/null; then UI_HINT+=" · manual · f = seguir"
    else UI_HINT+=" · j/k rolar"; fi
  fi
}

ui_should_activate() {
  # --verbose ocupa o terminal com os dois streams do engine: o painel sairia
  # por cima do output ao vivo.
  $VERBOSE && return 1
  [ "$UI_MODE" = "plain" ] && return 1
  # Sem TTY (nohup, CI, pipe) nenhuma sequencia de escape pode sair — nem com
  # RALPH_UI=panel. Redirecionar um painel para arquivo produz lixo binario.
  [ -t 1 ] || return 1
  return 0
}

ui_term_cols() {
  local n
  n=$(tput cols 2> /dev/null || echo 80)
  [[ "$n" =~ ^[0-9]+$ ]] || n=80
  [ "$n" -lt 40 ] && n=40
  echo "$n"
}

ui_term_lines() {
  local n
  n=$(tput lines 2> /dev/null || echo 24)
  [[ "$n" =~ ^[0-9]+$ ]] || n=24
  [ "$n" -lt 10 ] && n=10
  echo "$n"
}

# Trunca e preenche pelo numero de CARACTERES. Nunca receba texto com escape
# aqui: `${#s}` contaria os bytes do escape e a coluna sairia do lugar. Para
# celula colorida, meca o texto plain com ui_padlen e concatene a cor por fora.
ui_cell() {
  local text="$1" width="$2"
  [ "$width" -lt 1 ] && width=1
  if [ "${#text}" -gt "$width" ]; then
    text="${text:0:$((width - 1))}$UI_G_CUT"
  fi
  printf '%s%*s' "$text" $((width - ${#text})) ''
}

# Le o cache achatado que o state_sync grava. Popula UIV_* no escopo do chamador.
# Os campos aditivos (RF-14) sao lidos por todas as telas, nao so por esta
# funcao — o shellcheck nao enxerga o consumo fora dela.
# shellcheck disable=SC2034
ui_load_state() {
  UIV_run_status=""; UIV_phase_num=0; UIV_phase_total=0
  UIV_phase_title=""; UIV_cycle=0; UIV_max_cycles=0
  UIV_gate0=""; UIV_gate1=""; UIV_gate2=""; UIV_gate3=""
  UIV_limit_waiting=0; UIV_limit_until=0; UIV_progress=""; UIV_activity=""
  UIV_last_error=""; UIV_pid=""; UIV_run_id=""; UIV_started=0
  UIV_stage_start=0; UIV_stdout_log=""
  UIV_engine=""; UIV_project=""
  UIV_repair=""; UIV_repair_round=0; UIV_max_repairs=0
  UIV_rescue=""; UIV_rescue_round=0; UIV_max_rescues=0
  UIV_failure_gate=""; UIV_failure_cycle=0; UIV_failure_log=""; UIV_test_log=""
  UIV_test_scope=""; UIV_test_scope_cmd=""; UIV_test_scope_why=""
  UIV_env_abort=0; UIV_updated=0
  UIV_failure_name=""; UIV_failure_message=""; UIV_failure_headline=""
  UIV_test_file=""; UIV_task_active=0; UIV_correction_title=""
  UIV_prev_gate0=""; UIV_prev_gate1=""; UIV_prev_gate2=""; UIV_prev_gate3=""
  UIV_status_word=""; UIV_status_tone=""
  UIV_phases_done=0; UIV_phases_total=0; UIV_percent=0
  # Tarefas da fase corrente, alinhadas por posicao (RF-14).
  UIV_task_idx=(); UIV_task_status=(); UIV_task_title=(); UIV_task_subtitle=()

  [ -f "$UI_DIR/state.env" ] || return 0
  local k v rest
  while IFS='=' read -r k v; do
    case "$k" in
      task)
        UIV_task_idx+=("${v%%$'\t'*}"); rest="${v#*$'\t'}"
        UIV_task_status+=("${rest%%$'\t'*}"); rest="${rest#*$'\t'}"
        UIV_task_title+=("${rest%%$'\t'*}"); UIV_task_subtitle+=("${rest#*$'\t'}") ;;
      failure_name) UIV_failure_name="$v" ;;
      failure_message) UIV_failure_message="$v" ;;
      failure_headline) UIV_failure_headline="$v" ;;
      test_file) UIV_test_file="$v" ;;     task_active) UIV_task_active="$v" ;;
      correction_title) UIV_correction_title="$v" ;;
      prev_gate0) UIV_prev_gate0="$v" ;;   prev_gate1) UIV_prev_gate1="$v" ;;
      prev_gate2) UIV_prev_gate2="$v" ;;   prev_gate3) UIV_prev_gate3="$v" ;;
      status_word) UIV_status_word="$v" ;; status_tone) UIV_status_tone="$v" ;;
      phases_done) UIV_phases_done="$v" ;; phases_total) UIV_phases_total="$v" ;;
      percent) UIV_percent="$v" ;;
      run_status) UIV_run_status="$v" ;;   phase_num) UIV_phase_num="$v" ;;
      phase_total) UIV_phase_total="$v" ;;
      phase_title) UIV_phase_title="$v" ;; cycle) UIV_cycle="$v" ;;
      max_cycles) UIV_max_cycles="$v" ;;
      gate0) UIV_gate0="$v" ;; gate1) UIV_gate1="$v" ;;
      gate2) UIV_gate2="$v" ;; gate3) UIV_gate3="$v" ;;
      limit_waiting) UIV_limit_waiting="$v" ;;
      limit_until) UIV_limit_until="$v" ;; progress) UIV_progress="$v" ;;
      activity) UIV_activity="$v" ;;       last_error) UIV_last_error="$v" ;;
      pid) UIV_pid="$v" ;;                 run_id) UIV_run_id="$v" ;;
      started) UIV_started="$v" ;;         stage_start) UIV_stage_start="$v" ;;
      stdout_log) UIV_stdout_log="$v" ;;
      engine) UIV_engine="$v" ;;           project) UIV_project="$v" ;;
      repair) UIV_repair="$v" ;;           repair_round) UIV_repair_round="$v" ;;
      max_repairs) UIV_max_repairs="$v" ;;
      rescue) UIV_rescue="$v" ;;           rescue_round) UIV_rescue_round="$v" ;;
      max_rescues) UIV_max_rescues="$v" ;;
      failure_cycle) UIV_failure_cycle="$v" ;;
      failure_gate) UIV_failure_gate="$v" ;; failure_log) UIV_failure_log="$v" ;;
      test_log) UIV_test_log="$v" ;; test_scope) UIV_test_scope="$v" ;;
      test_scope_cmd) UIV_test_scope_cmd="$v" ;; test_scope_why) UIV_test_scope_why="$v" ;;
      env_abort) UIV_env_abort="$v" ;; updated) UIV_updated="$v" ;;
    esac
  done < "$UI_DIR/state.env"
}

# Clampa o topo da janela ao intervalo valido. Fora dele a tabela desenharia
# linhas vazias no fim (start alto demais) ou esconderia o comeco sem motivo.
# Com menos linhas que orcamento o unico topo valido e 0.
ui_scroll_fit() {
  local start="$1" total="$2" budget="$3"
  local max=$((total - budget))
  [ "$max" -lt 0 ] && max=0
  [ "$start" -gt "$max" ] && start="$max"
  [ "$start" -lt 0 ] && start=0
  printf '%s' "$start"
}

# Acumulador de arquivos tocados por fase.
#
# `git status` esvazia no instante em que a fase commita, e o stream do engine
# some quando o log do ciclo e substituido. Sem memoria, o progresso das tasks
# cairia a zero justamente quando a fase fecha.
#
# Alimentado pelo PINTOR (a cada ~3s, enquanto o engine trabalha) E pelo
# processo principal em pontos deterministicos (fim da sessao, antes do
# commit). So o pintor nao basta: se a ultima varredura dele cair antes do
# engine escrever o ultimo arquivo, aquela task nunca e contada — um flake que
# aparecia so com a maquina carregada.
#
# Vive em .phases/, que split_phases recria: nao atravessa runs.
ui_touched_file() {
  printf '%s/touched-%s.txt' "$UI_DIR" "${1:-0}"
}

ui_touch_record() {
  local phase_num="${1:-0}" stdout_log="${2:-}"
  [ -n "$phase_num" ] && [ "$phase_num" -gt 0 ] 2> /dev/null || return 0
  [ -d "$UI_DIR" ] || return 0

  local seen tmp
  seen="$(ui_touched_file "$phase_num")"
  tmp="$seen.tmp.$$"

  {
    [ -n "$stdout_log" ] && engine_written_files "$stdout_log"
    git status --porcelain -uall 2> /dev/null | awk '{ $1=""; sub(/^ /,""); print }' || true
    [ -f "$seen" ] && cat "$seen"
  } 2> /dev/null | awk 'NF && !s[$0]++' > "$tmp" 2> /dev/null

  # tmp + mv porque o pintor le este diretorio em paralelo.
  mv -f "$tmp" "$seen" 2> /dev/null || rm -f "$tmp" 2> /dev/null
  return 0
}

# ui_infer_tasks — qual task esta sendo trabalhada, e quanto dela ja apareceu.
#
# HEURISTICA, e o painel a rotula como tal. Nenhum evento do engine diz em que
# task ele esta. O que existe de concreto e (a) o texto da task, que nomeia
# identificadores de codigo, e (b) os arquivos que o engine ESCREVEU nesta
# sessao — Edit/Write emitidos no stream, mais a arvore suja. Casar um com o
# outro da "os artefatos que esta task nomeia foram escritos agora".
#
# A fonte era `git ls-files`, o repo inteiro: uma task que cita arquivo
# preexistente nascia ~100% antes de alguem encostar nela, e era isso que a
# tabela mostrava. Existir nao e prova de nada; ter sido escrito e.
#
# NAO substitui o gate 3: presenca de arquivo nao e prova de implementacao
# correta. Por isso o veredito do gate 3, quando existe, sempre vence.
#
# Escreve $UI_TASKPROG: indice|pct|ativa(0|1)
ui_infer_tasks() {
  local phase_num="$1" stdout_log="${2:-}"
  local out="$UI_TASKPROG" tmp="$UI_TASKPROG.tmp.$$"
  local pf
  pf="$(printf 'phase-%02d.md' "$phase_num" 2> /dev/null)"
  if [ -z "$phase_num" ] || ! [ "$phase_num" -gt 0 ] 2> /dev/null; then
    : > "$out" 2> /dev/null
    return 0
  fi
  [ -f "$PHASES_DIR/$pf" ] || { : > "$out" 2> /dev/null; return 0; }

  local anchors="$UI_DIR/.anchors.$$" paths="$UI_DIR/.paths.$$"
  : > "$anchors"

  # Conta as tasks UMA vez e itera 1..N. A versao anterior decidia parar dentro
  # do laco a partir do resultado do proprio extract_*: uma task sem ancora
  # abortava a varredura e as seguintes nunca eram medidas.
  local ntasks n=1 a one
  ntasks="$(grep -cE '^[[:space:]]*- \[[ xX]\]' "$PHASES_DIR/$pf" 2> /dev/null || true)"
  [[ "$ntasks" =~ ^[0-9]+$ ]] || ntasks=0
  [ "$ntasks" -gt 40 ] && ntasks=40
  while [ "$n" -le "$ntasks" ]; do
    a="$(extract_task_anchors "$pf" "$n")"
    if [ -n "$a" ]; then
      while IFS= read -r one; do
        [ -n "$one" ] && printf '%s\t%s\n' "$n" "$one" >> "$anchors"
      done <<< "$a"
    fi
    n=$((n + 1))
  done

  # Nenhuma task nomeou artefato: nao ha o que inferir, e sair AQUI e
  # obrigatorio. O awk de duas passadas abaixo separa os arquivos por FILENAME;
  # com o primeiro arquivo vazio ele lia o universo de caminhos como se fosse a
  # lista de ancoras — foi assim que o taskprog.txt de um run real virou 60 KB
  # de linhas `caminho|0|0` e a tabela ficou Pendente do inicio ao fim.
  if [ ! -s "$anchors" ]; then
    : > "$out" 2> /dev/null
    rm -f "$anchors" 2> /dev/null
    return 0
  fi

  # Universo de caminhos: SO o que ESTA FASE tocou.
  #
  # Antes isto era `git ls-files` — todo arquivo rastreado do repo. Uma task que
  # cita um arquivo preexistente ja nascia 100%, e a tabela mostrava ~100% na
  # task que ninguem tinha comecado. Agora a prova e o ATO de escrever.
  #
  # O acumulador e obrigatorio: `git status` esvazia no instante em que a fase
  # commita, e sem memoria o progresso das tasks recem-concluidas cairia de
  # 100% para 0 justamente no fim da fase. O arquivo vive em .phases, que
  # split_phases recria a cada run, entao nao atravessa runs.
  ui_touch_record "$phase_num" "$stdout_log"
  cp -f "$(ui_touched_file "$phase_num")" "$paths" 2> /dev/null || : > "$paths"

  # Nada escrito ainda: toda task em 0, sem chamar o awk.
  if [ ! -s "$paths" ]; then
    awk -F'\t' '{ t[$1] = 1 } END { for (k in t) printf "%s|0|0\n", k }' "$anchors" \
      2> /dev/null | sort -n > "$tmp" && mv -f "$tmp" "$out" 2> /dev/null
    rm -f "$anchors" "$paths" "$tmp" 2> /dev/null
    return 0
  fi

  # Arquivo tocado mais recentemente: e ele que aponta a task ativa.
  local newest=""
  newest="$(git status --porcelain -uall 2> /dev/null | awk '{ $1=""; sub(/^ /,""); print }' \
    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done \
    | xargs -r ls -1t 2> /dev/null | head -n 1 || true)"
  # Sem arvore suja (o engine escreveu e ja commitou, ou o Edit falhou), a
  # ultima linha do stream ainda diz onde ele estava.
  if [ -z "$newest" ] && [ -n "$stdout_log" ]; then
    newest="$(engine_written_files "$stdout_log" | tail -n 1 || true)"
  fi

  # FILENAME, e nao NR == FNR: a separacao tem que vir do arquivo que esta
  # sendo lido, nunca de uma contagem que empata quando um dos dois e vazio.
  awk -F'\t' -v newest="$newest" -v af="$anchors" '
    FILENAME == af { idx[FNR] = $1; anc[FNR] = $2; total[$1]++; na = FNR; next }
    {
      for (i = 1; i <= na; i++) {
        if (!hit[i] && anc[i] != "" && index($0, anc[i])) hit[i] = 1
      }
    }
    END {
      for (i = 1; i <= na; i++) {
        if (hit[i]) matched[idx[i]]++
        if (newest != "" && anc[i] != "" && index(newest, anc[i])) active[idx[i]] = 1
      }
      for (t in total) {
        pct = int(matched[t] * 100 / total[t])
        printf "%s|%d|%d\n", t, pct, (t in active ? 1 : 0)
      }
    }
  ' "$anchors" "$paths" 2> /dev/null | sort -n > "$tmp" && mv -f "$tmp" "$out" 2> /dev/null

  rm -f "$anchors" "$paths" "$tmp" 2> /dev/null
  return 0
}

# Texto externo nunca pode mover o cursor ou introduzir uma linha no quadro.
# LC_ALL=C: as faixas sao de BYTES ASCII. Em en_US.UTF-8 o GNU sed recusa
# `[ -/]` pela collation ("Invalid range end") e todo ui_line saia em branco.
# Byte a byte, o UTF-8 do texto passa intacto.
ui_clean_text() {
  LC_ALL=C sed -E $'s/\033\\][^\007]*(\007|\033\\\\)//g; s/\033\\[[0-?]*[ -/]*[@-~]//g' \
    | tr -d '\000-\010\013-\037\177' | tr '\t\n' '  '
}

ui_line() {
  local text
  text="$(printf '%s' "$2" | ui_clean_text)"
  printf '%b%s%b\n' "${3:-$UI_C_OFF}" "$(ui_cell "$text" "$1")" "$UI_C_OFF"
}

ui_gate_words() {
  local status="$1" gate="${2:-}"
  if [ "$gate" = 1 ]; then
    case "$status" in
      pass) printf 'alteração detectada'; return ;;
      fail) printf 'sem alteração (sinal)'; return ;;
    esac
  fi
  case "$status" in
    pass) printf 'aprovado' ;; fail) printf 'falhou' ;;
    skip) printf 'não executado' ;; running) printf 'em execução' ;;
    *) printf 'aguardando' ;;
  esac
}

ui_scope_words() {
  case "$UIV_test_scope" in
    full) printf 'completa' ;; scoped) printf 'escopada' ;;
    skip) printf 'não executada' ;; *) printf 'a resolver' ;;
  esac
}

# ---------------------------------------------------------------------------
# Telas do painel: 1 Visao geral, 2 Foco, 3 Diagnostico (artboards 01/02/03).
#
# O terminal nao tem tamanho de fonte: o que no artboard e maior vira negrito
# na cor do token; caixa e banner viram fundo de celula. Toda cor vem com
# simbolo ou palavra (RNF-03) — o painel tem que ser legivel sem cor.
# Campo sem valor = "—" na mesma posicao (RF-14), exceto subtitulo de tarefa.
# ---------------------------------------------------------------------------

# Selecao manual (RF-05): fase/tarefa escolhida pelo dev. Vazio = seguir o run.
UI_SEL_PHASE=""
UI_SEL_TASK=""

ui_or_none() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "$UI_GL_NONE"; fi; }

# Numero com 2 digitos, como nos artboards ("FASE 03 / 06").
ui_nn() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%02d' "$((10#$1))"; else printf '%s' "$UI_GL_NONE"; fi; }
# Idem, mas zero vira "—": fase, ciclo e tarefa comecam em 1 — zero e ausencia.
ui_nz() { if [[ "$1" =~ ^[0-9]+$ ]] && [ "$((10#$1))" -gt 0 ]; then ui_nn "$1"; else printf '%s' "$UI_GL_NONE"; fi; }

# Ultima acao do engine em palavras ("Edit a.php" -> "Editando a.php").
ui_action_words() {
  local t="$1"
  case "$t" in
    Edit\ * | MultiEdit\ * | NotebookEdit\ *) printf 'Editando %s' "${t#* }" ;;
    Write\ *) printf 'Escrevendo %s' "${t#* }" ;;
    Read\ *)  printf 'Lendo %s' "${t#* }" ;;
    Bash\ *)  printf 'Executando %s' "${t#* }" ;;
    Grep\ * | Glob\ *) printf 'Buscando %s' "${t#* }" ;;
    *) printf '%s' "$t" ;;
  esac
}

# Dados comuns do frame. Popula UD_* a partir do state.env (fonte unica do
# run) e dos caches phases.txt/tasks.txt — estes o pintor republica sozinho
# durante a sessao do engine, quando o processo principal esta bloqueado.
ui_data() {
  local now num status title
  now=$(date +%s)
  case "$UIV_run_status" in done | failed | aborted) [ "${UIV_updated:-0}" -gt 0 ] 2> /dev/null && now=$UIV_updated ;; esac
  UD_elapsed=0
  [ "${UIV_started:-0}" -gt 0 ] 2> /dev/null && UD_elapsed=$((now - UIV_started))
  [ "$UD_elapsed" -lt 0 ] && UD_elapsed=0

  UD_word="$UIV_status_word"; UD_tone="$UIV_status_tone"
  if [ -z "$UD_word" ]; then
    case "$UIV_run_status" in
      running) UD_word='IMPLEMENTANDO'; UD_tone=run
        [ "${UIV_cycle:-0}" -gt 1 ] 2> /dev/null && { UD_word='CORRIGINDO'; UD_tone=warn; } ;;
      done) UD_word='CONCLUÍDO'; UD_tone=ok ;;
      failed) UD_word='FALHOU'; UD_tone=err ;;
      aborted) UD_word='ABORTADO'; UD_tone=err ;;
      *) UD_word='INICIANDO'; UD_tone=dim ;;
    esac
    [ "$UIV_limit_waiting" = 1 ] && { UD_word='AGUARDANDO LIMITE'; UD_tone=warn; }
  fi
  [ "$UIV_env_abort" = 1 ] && { UD_word='AMBIENTE INDISPONÍVEL'; UD_tone=err; }
  case "$UD_tone" in
    run) UD_tone_c="$UI_K_CYAN" ;; warn) UD_tone_c="$UI_K_AMBER" ;;
    ok) UD_tone_c="$UI_K_GREEN" ;; err) UD_tone_c="$UI_K_RED" ;; *) UD_tone_c="$UI_K_DIM" ;;
  esac

  UDP_num=(); UDP_status=(); UDP_title=()
  while IFS='|' read -r num status title; do
    [ -n "$num" ] || continue
    UDP_num+=("$num"); UDP_status+=("$status"); UDP_title+=("$title")
  done < <(cat "$UI_DIR/phases.txt" 2> /dev/null || true)

  UD_total="$UIV_phases_total"; UD_done="$UIV_phases_done"; UD_pct="$UIV_percent"
  if ! [ "${UD_total:-0}" -gt 0 ] 2> /dev/null; then
    UD_total=${#UDP_num[@]}; UD_done=0
    for status in "${UDP_status[@]}"; do [ "$status" = "done" ] && UD_done=$((UD_done + 1)); done
    UD_pct=0; [ "$UD_total" -gt 0 ] && UD_pct=$((UD_done * 100 / UD_total))
  fi
  [ "${UIV_phase_total:-0}" -gt 0 ] 2> /dev/null || UIV_phase_total="$UD_total"
}

# ui_phase_tasks <fase> — tarefas de uma fase em UDT_* (idx, status, titulo,
# subtitulo) e a ativa em UDT_active.
#
# Fase corrente: status do tasks.txt, que o pintor republica durante a sessao
# (checkbox -> declarada) com a mesma autoridade do state.json.
# Outra fase (M6): tarefas do plano daquela fase — todas verificadas se ela ja
# fechou, todas pendentes se nao. Nenhum historico novo e lido nem gravado.
ui_phase_tasks() {
  local want="$1" num idx status label file ptitle pstatus i
  UDT_idx=(); UDT_status=(); UDT_title=(); UDT_sub=(); UDT_active=0
  [ -n "$want" ] || return 0

  if [ "$want" = "$UIV_phase_num" ]; then
    while IFS='|' read -r num idx status label; do
      [ "$num" = "$want" ] || continue
      task_label_split "$label"
      UDT_idx+=("$idx"); UDT_status+=("$status"); UDT_title+=("$TLS_T"); UDT_sub+=("$TLS_S")
    done < <(cat "$UI_DIR/tasks.txt" 2> /dev/null || true)
    if [ ${#UDT_idx[@]} -eq 0 ] && [ ${#UIV_task_idx[@]} -gt 0 ]; then
      UDT_idx=("${UIV_task_idx[@]}"); UDT_status=("${UIV_task_status[@]}")
      UDT_title=("${UIV_task_title[@]}"); UDT_sub=("${UIV_task_subtitle[@]}")
    fi
    # A ativa publicada pelo run vale enquanto nao fechou; fechou durante a
    # sessao (checkbox), a proxima aberta assume.
    if [ "${UIV_task_active:-0}" -gt 0 ] 2> /dev/null; then
      for i in "${!UDT_idx[@]}"; do
        [ "${UDT_idx[$i]}" = "$UIV_task_active" ] || continue
        case "${UDT_status[$i]}" in pending | running | partial) UDT_active="$UIV_task_active" ;; esac
      done
      if [ "$UDT_active" = 0 ]; then
        for i in "${!UDT_idx[@]}"; do
          case "${UDT_status[$i]}" in pending | running | partial) UDT_active="${UDT_idx[$i]}"; break ;; esac
        done
      fi
    fi
    for i in "${!UDT_idx[@]}"; do
      [ "${UDT_idx[$i]}" = "$UDT_active" ] && [ "${UDT_status[$i]}" = pending ] && UDT_status[i]=running
    done
    return 0
  fi

  pstatus=pending
  for i in "${!UDP_num[@]}"; do [ "${UDP_num[$i]}" = "$want" ] && pstatus="${UDP_status[$i]}"; done
  if [ "$pstatus" = "done" ]; then status="done"; else status=pending; fi
  while IFS='|' read -r file num ptitle; do
    [ "$num" = "$want" ] || continue
    while IFS='|' read -r idx label; do
      [ -n "$idx" ] || continue
      task_label_split "$label"
      UDT_idx+=("$idx"); UDT_status+=("$status"); UDT_title+=("$TLS_T"); UDT_sub+=("$TLS_S")
    done < <(extract_task_labels "$file")
  done < <(manifest_entries 2> /dev/null || true)
  return 0
}

# Palavra e cor de cada status de tarefa (Foco e contagens).
ui_task_word() {
  case "$1" in
    done) UTW='verificada'; UTC="$UI_K_GREEN" ;;
    running) UTW='em andamento'; UTC="$UI_K_CYAN" ;;
    declared) UTW='declarada'; UTC="$UI_K_TEXT" ;;
    partial | failed) UTW='incompleta'; UTC="$UI_K_RED" ;;
    *) UTW='pendente'; UTC="$UI_K_DIM" ;;
  esac
}

# Frase de um evento do historico privado (events.tsv) e sua cor semantica.
# ui_event_phrase <evento> <detalhe> -> UEP (frase), UEC (cor)
ui_event_phrase() {
  local ev="$1" d="$2" ph="" cy="" g="" v="" r="" msg=""
  [[ "$d" =~ ^F([0-9]+) ]] && ph="$(ui_nn "${BASH_REMATCH[1]}")"
  [[ "$d" =~ \ C([0-9]+) ]] && cy="${BASH_REMATCH[1]}"
  [[ "$d" =~ gate=([^ ]+) ]] && g="${BASH_REMATCH[1]#gate}"
  [[ "$d" =~ verdict=([^ ]+) ]] && v="${BASH_REMATCH[1]}"
  [[ "$d" =~ round=([0-9]+) ]] && r="${BASH_REMATCH[1]}"
  [[ "$d" =~ message=(.*)$ ]] && msg="${BASH_REMATCH[1]}"
  UEC="$UI_K_TEXT"
  case "$ev" in
    run_start) UEP='Run iniciado' ;;
    run_done) UEP='Run encerrado' ;;
    phase_start) UEP="Fase $ph iniciada · ciclo ${cy:-1} de ${UIV_max_cycles:-?}" ;;
    phase_done) UEP="Fase $ph concluída e commit registrado"; UEC="$UI_K_GREEN" ;;
    phase_failed) UEP="Fase $ph interrompida"; UEC="$UI_K_RED" ;;
    gate_start) UEP="G$g iniciado"; UEC="$UI_K_DIM" ;;
    gate_end)
      case "$v" in
        pass) UEP="G$g aprovado"; UEC="$UI_K_GREEN" ;;
        fail) UEP="G$g registrou falha"; UEC="$UI_K_RED" ;;
        *) UEP="G$g não executado"; UEC="$UI_K_DIM" ;;
      esac ;;
    repair_start) UEP="Correção iniciada · conserto ${r:-?}"; UEC="$UI_K_AMBER" ;;
    repair_end) UEP='Conserto encerrado'; UEC="$UI_K_DIM" ;;
    rescue_start) UEP="Resgate iniciado · ${r:-?}"; UEC="$UI_K_AMBER" ;;
    rescue_end) UEP='Resgate encerrado'; UEC="$UI_K_DIM" ;;
    limit_*) UEP="Limite de uso: ${msg:-aguardando}"; UEC="$UI_K_AMBER" ;;
    *) UEP="$ev${msg:+ · $msg}"; UEC="$UI_K_DIM" ;;
  esac
}

# ui_events_block <bloco> <lista> <largura> <orcamento> <rotulo> [so_fase]
# Rotulo + linhas "HH:MM:SS  frase". Auto = as mais recentes.
ui_events_block() {
  local blk="$1" list="$2" width="$3" budget="$4" label="$5" only="${6:-0}" ts ev d i
  local -a rows_ts=() rows_ev=() rows_d=()
  while IFS=$'\t' read -r ts ev d; do
    [ -n "$ev" ] || continue
    if [ "$only" = 1 ]; then [[ "$d" == "F${UIV_phase_num:-x} "* ]] || continue; fi
    rows_ts+=("$ts"); rows_ev+=("$ev"); rows_d+=("$d")
  done < <(tail -n 200 "$UI_DIR/events.tsv" 2> /dev/null || true)
  local total=${#rows_ts[@]}
  ui_list_window "$list" "$total" "$budget" $((total - budget))
  ui_list_hint "$list" "$total" "$budget" "$UI_LS"
  ui_label "$blk" "$label" "$width" "$UI_HINT"
  UIR_MAX="$width"
  if [ "$total" -eq 0 ]; then
    ui_r0; ui_rt "$UI_K_DIM" "$UI_GL_NONE"; ui_rhit "scroll:$list" 0; ui_emit "$blk"
    return 0
  fi
  for ((i = UI_LS; i < total && i < UI_LS + budget; i++)); do
    ui_event_phrase "${rows_ev[$i]}" "${rows_d[$i]}"
    ui_r0
    ui_rt "$UI_K_DIM" "${rows_ts[$i]}"
    ui_rpad 12
    ui_rt "$UEC" "$UEP"
    ui_rhit "scroll:$list" 0
    ui_emit "$blk"
  done
}

# Rotulo de secao: maiusculas, secundario, negrito — e dica de rolagem a
# direita quando a lista tem linha escondida.
ui_label() {
  local blk="$1" text="$2" width="$3" hint="${4:-}"
  UIR_MAX="$width"; ui_r0
  ui_rt "$UI_K_B$UI_K_DIM" "$text"
  if [ -n "$hint" ]; then
    ui_vw "$hint"
    ui_rpad $((width - UI_VW))
    ui_rt "$UI_K_DIM" "$hint"
  fi
  ui_emit "$blk"
}

# --- regioes comuns -----------------------------------------------------------

ui_region_header() {
  local blk="$1" W="$2"
  UIR_MAX="$W"; ui_r0
  ui_rt "$UI_K_B$UI_K_CYAN" 'RALPH'
  ui_rpad 9
  ui_rt "$UI_K_TEXT" "$(ui_or_none "${UIV_project:-$PROJECT_NAME}")" $((W * 60 / 100 - 10))
  ui_rpad $((W * 63 / 100))
  ui_rt "$UI_K_DIM" "$(ui_or_none "${UIV_engine:-$ENGINE}" | tr '[:lower:]' '[:upper:]')" 14
  ui_rpad $((W * 75 / 100))
  ui_rt "$UI_K_B$UD_tone_c" "$UI_GL_DOT $UD_word"
  ui_emit "$blk"
  ui_rule_line "$blk" "$W"
}

# Barra de abas (UI-01 item 7): ativa com fundo de aba, f Seguir e q Sair a
# direita. Cada rotulo e alvo de clique.
ui_region_tabs() {
  local blk="$1" W="$2" active="$3" i col label t0
  ui_rule_line "$blk" "$W"
  UIR_MAX="$W"; ui_r0
  local -a labels=('1 Visão geral' '2 Foco' '3 Diagnóstico')
  local -a cols=(0 $((W * 16 / 100)) $((W * 30 / 100)))
  for i in 0 1 2; do
    col=${cols[$i]}; label=" ${labels[$i]} "
    ui_rpad "$col"; t0=$UIR_W
    if [ "$((i + 1))" = "$active" ]; then
      ui_fit "$label" 20
      printf -v UI_PAD '%*s' $((20 - ${#UI_FIT} > 0 ? 20 - ${#UI_FIT} : 0)) ''
      UIR_P+="$UI_FIT$UI_PAD"; UIR_C+="$UI_K_TAB$UI_K_B$UI_K_CYAN$UI_FIT$UI_PAD$UI_K_OFF"
      ui_vw "$UI_FIT$UI_PAD"; UIR_W=$((UIR_W + UI_VW))
    else
      ui_rt "$UI_K_DIM" "$label"
    fi
    ui_rhit "tab:$((i + 1))" "$t0"
  done
  ui_rpad $((W * 72 / 100)); t0=$UIR_W
  ui_rt "$UI_K_DIM" 'f Seguir'; ui_rhit follow "$t0"
  ui_rpad $((W * 81 / 100)); t0=$UIR_W
  ui_rt "$UI_K_DIM" 'q Sair'; ui_rhit quit "$t0"
  ui_emit "$blk"
}

# --- 1 Visao geral (UI-01) ------------------------------------------------------

ui_ov_metrics() {
  local blk="$1" W="$2" i
  local -a cols=(0 $((W * 22 / 100)) $((W * 49 / 100)) $((W * 78 / 100)))
  local -a labels=('TEMPO TOTAL' 'FASES CONCLUÍDAS' 'CICLO ATUAL' 'PROGRESSO / FASES')
  local -a vals=(
    "$(format_duration "$UD_elapsed")"
    "$(ui_nn "$UD_done") / $(ui_nn "$UD_total")"
    "$(ui_nz "$UIV_cycle") / $(ui_nz "$UIV_max_cycles")"
    "${UD_pct:-0}%"
  )
  [ "${UD_total:-0}" -gt 0 ] 2> /dev/null || vals[1]="$UI_GL_NONE"
  [ "${UIV_max_cycles:-0}" -gt 0 ] 2> /dev/null || vals[2]="$UI_GL_NONE"
  UIR_MAX="$W"; ui_r0
  for i in 0 1 2 3; do ui_rpad "${cols[$i]}"; ui_rt "$UI_K_B$UI_K_DIM" "${labels[$i]}"; done
  ui_emit "$blk"
  ui_r0
  for i in 0 1 2 3; do ui_rpad "${cols[$i]}"; ui_rt "$UI_K_B$UI_K_TEXT" "${vals[$i]}"; done
  ui_emit "$blk"
}

# Jornada: uma entrada por fase. Plano longo mostra a janela em volta da fase
# corrente — o agora nunca fica atras de dezenas de fases feitas.
ui_ov_journey() {
  local blk="$1" W="$2" n=${#UDP_num[@]} max first=0 cur=0 i slot col mark color num t0
  UIR_MAX="$W"; ui_r0
  if [ "$n" -eq 0 ]; then ui_rt "$UI_K_DIM" "$UI_GL_NONE"; ui_emit "$blk"; return 0; fi
  max=$((W / 16)); [ "$max" -lt 1 ] && max=1
  for i in "${!UDP_num[@]}"; do [ "${UDP_num[$i]}" = "$UIV_phase_num" ] && cur=$i; done
  if [ "$n" -gt "$max" ]; then
    first=$((cur - 1)); [ "$first" -lt 0 ] && first=0
    [ $((first + max)) -gt "$n" ] && first=$((n - max))
  else
    max=$n
  fi
  slot=$((W / max))
  for ((i = first; i < first + max && i < n; i++)); do
    col=$(((i - first) * slot)); num="$(ui_nn "${UDP_num[$i]}")"
    case "${UDP_status[$i]}" in
      done) mark="$UI_GL_OK"; color="$UI_K_GREEN" ;;
      failed) mark="$UI_GL_X"; color="$UI_K_RED" ;;
      skipped) mark='»'; color="$UI_K_DIM" ;;
      *) mark="$UI_GL_PEND"; color="$UI_K_DIM" ;;
    esac
    [ "${UDP_num[$i]}" = "$UIV_phase_num" ] && [ "${UDP_status[$i]}" != "done" ] && { mark="$UI_GL_RUN"; color="$UI_K_B$UI_K_CYAN"; }
    ui_rpad "$col"; t0=$UIR_W
    ui_rt "$color" "$mark $num ${UDP_title[$i]}" $((slot - 2))
    ui_rhit "phase:${UDP_num[$i]}" "$t0"
  done
  ui_emit "$blk"
}

# Caixa EM ANDAMENTO. <sp>=1 poe o padding de caixa do artboard.
ui_ov_current() {
  local blk="$1" bw="$2" sp="$3" i v=0 d=0 k=0 a=0 p=0 title="" pct="" stage=0 text t0
  local in=$((bw - 3))
  ui_phase_tasks "$UIV_phase_num"
  for i in "${!UDT_idx[@]}"; do
    case "${UDT_status[$i]}" in
      done) v=$((v + 1)) ;; declared) d=$((d + 1)) ;; partial | failed) k=$((k + 1)) ;;
      running) a=$((a + 1)) ;; *) p=$((p + 1)) ;;
    esac
    [ "${UDT_idx[$i]}" = "$UDT_active" ] && title="${UDT_title[$i]}"
  done
  if [ "$UDT_active" -gt 0 ] && [ -f "$UI_TASKPROG" ]; then
    pct="$(awk -F'|' -v i="$UDT_active" '$1 == i && $2 > 0 { print $2; exit }' "$UI_TASKPROG" 2> /dev/null || true)"
  fi
  [ "${UIV_stage_start:-0}" -gt 0 ] 2> /dev/null && stage=$(($(date +%s) - UIV_stage_start))
  [ "$stage" -lt 0 ] && stage=0

  [ "$sp" = 1 ] && ui_blank "$blk" "$bw" "$UI_K_BOX"
  UIR_MAX="$in"
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" "EM ANDAMENTO / FASE $(ui_nz "$UIV_phase_num")"; ui_rhit "phase:$UIV_phase_num" 0
  ui_emit_boxed "$blk" "$bw"
  ui_r0; ui_rt "$UI_K_B$UI_K_TEXT" "$(ui_or_none "$UIV_phase_title")"
  ui_emit_boxed "$blk" "$bw"
  ui_r0
  if [ "$UDT_active" -gt 0 ]; then
    ui_rt "$UI_K_CYAN" "$UI_GL_RUN Tarefa $UDT_active: $(ui_or_none "$title")" $((in - 8))
    ui_rhit "task:$UIV_phase_num:$UDT_active" 0
    [ -n "$pct" ] && ui_rt "$UI_K_DIM" "  ~$pct%"
  else
    ui_rt "$UI_K_DIM" "$UI_GL_RUN Tarefa $UI_GL_NONE"
  fi
  ui_emit_boxed "$blk" "$bw"
  text="$v verificadas"
  [ "$d" -gt 0 ] && text+="  /  $d declaradas"
  [ "$k" -gt 0 ] && text+="  /  $k incompletas"
  text+="  /  $a ativa  /  $p pendentes"
  ui_r0; ui_rt "$UI_K_DIM" "$text"; ui_emit_boxed "$blk" "$bw"
  # Etapa do run (o que o ralph faz agora) + prova de vida medida pelo pintor.
  ui_r0; ui_rt "$UI_K_DIM" "Etapa: $(ui_or_none "$UIV_activity") · $(format_duration "$stage") · Ações do engine: ${UIL_ACTIONS:-0} · Árvore: ${UIL_DIRTY_N:-0} arquivo(s) tocado(s)"
  ui_emit_boxed "$blk" "$bw"
  text="${UIL_TAIL:-${UIV_progress:-$UIV_activity}}"
  text="$(printf '%s' "$text" | ui_clean_text)"
  ui_r0; ui_rt "$UI_K_TEXT" "$UI_GL_ACT $(ui_or_none "$(ui_action_words "$text")")"; ui_emit_boxed "$blk" "$bw"
  [ "$sp" = 1 ] && ui_blank "$blk" "$bw" "$UI_K_BOX"
  return 0
}

# Fecha a linha corrente como linha de caixa com recuo de 2 colunas; os alvos
# andam junto com o recuo.
ui_emit_boxed() {
  local h a b act
  local -a moved=()
  for h in "${UIR_H[@]}"; do IFS='|' read -r a b act <<< "$h"; moved+=("$((a + 2))|$((b + 2))|$act"); done
  UIR_H=("${moved[@]}")
  UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; UIR_W=$((UIR_W + 2))
  ui_emit "$1" "$2" "$UI_K_BOX" "${3:-}"
}

ui_ov_gates() {
  local blk="$1" bw="$2" sp="$3" rows="$4" g val label word color n=0
  local in=$((bw - 3))
  [ "$sp" = 1 ] && { ui_blank "$blk" "$bw" "$UI_K_BOX"; n=1; }
  UIR_MAX="$in"
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'VALIDAÇÃO DA FASE'; ui_emit_boxed "$blk" "$bw"; n=$((n + 1))
  for g in 0 1 2 3; do
    case "$g" in
      0) val="$UIV_gate0"; label='Sessão' ;; 1) val="$UIV_gate1"; label='Código' ;;
      2) val="$UIV_gate2"; label='Testes' ;; 3) val="$UIV_gate3"; label='Verificação' ;;
    esac
    word="$(ui_gate_words "$val" "$g")"
    case "$val" in
      pass) color="$UI_K_GREEN" ;; fail) color="$UI_K_RED" ;; running) color="$UI_K_CYAN" ;; *) color="$UI_K_DIM" ;;
    esac
    [ "$g" = 1 ] && [ "$val" = pass ] && color="$UI_K_CYAN"
    [ "$g" = 2 ] && [ "$UIV_env_abort" = 1 ] && { word='ambiente indisponível'; color="$UI_K_RED"; }
    ui_r0; ui_rt "$UI_K_TEXT" "G$g"; ui_rpad 4; ui_rt "$UI_K_TEXT" "$label"
    ui_rpad $((in * 60 / 100)); ui_rt "$color" "$word"
    ui_emit_boxed "$blk" "$bw"; n=$((n + 1))
  done
  while [ "$n" -lt "$rows" ]; do ui_blank "$blk" "$bw" "$UI_K_BOX"; n=$((n + 1)); done
}

ui_screen_overview() {
  local out="$1" W="$2" H="$3" side="$4" sp="$4" lw rw avail used
  ui_blk OVH; ui_region_header OVH "$W"; [ "$sp" = 1 ] && ui_blank OVH
  ui_blk OVM; ui_ov_metrics OVM "$W"; ui_seg_bar OVM "$W" "${UD_pct:-0}"
  [ "$sp" = 1 ] && ui_blank OVM
  ui_ov_journey OVM "$W"; [ "$sp" = 1 ] && ui_blank OVM
  ui_blk OVB
  if [ "$side" = 1 ]; then
    lw=$((W * 59 / 100)); rw=$((W - lw - 2))
    ui_blk OVL; ui_ov_current OVL "$lw" "$sp"
    ui_blk OVR; ui_ov_gates OVR "$rw" "$sp" "${#OVL_P[@]}"
    ui_side OVB OVL "$lw" 2 OVR
  else
    ui_ov_current OVB "$W" "$sp"
    ui_ov_gates OVB "$W" "$sp" 0
  fi
  ui_blk OVT; ui_region_tabs OVT "$W" 1

  used=$((${#OVH_P[@]} + ${#OVM_P[@]} + ${#OVB_P[@]} + ${#OVT_P[@]}))
  avail=$((H - used))
  ui_cat "$out" OVH; ui_cat "$out" OVM; ui_cat "$out" OVB
  # ULTIMOS EVENTOS e a primeira regiao a cair (RF-15): so entra com espaco
  # para o respiro, o rotulo e 3 eventos.
  if [ "$avail" -ge 5 ]; then
    ui_blk OVE; ui_blank OVE
    ui_events_block OVE events "$W" $((avail - 2)) 'ÚLTIMOS EVENTOS'
    ui_cat "$out" OVE
    avail=$((avail - ${#OVE_P[@]}))
  fi
  while [ "$avail" -gt 0 ] && [ "$sp" = 1 ]; do ui_blank "$out"; avail=$((avail - 1)); done
  ui_cat "$out" OVT
}

# --- 2 Foco (UI-02) -------------------------------------------------------------

ui_fo_stage() {
  UFS=0
  [ "$UIV_gate2" = running ] && UFS=1
  [ "$UIV_gate3" = running ] && UFS=2
  case "$UIV_activity" in *commit*) UFS=3 ;; esac
}

ui_screen_focus() {
  local out="$1" W="$2" H="$3" side="$4" sp="$4"
  local ph="${UI_SEL_PHASE:-$UIV_phase_num}" ptitle="" pstatus="" i sel=0 seli=-1 n v=0
  for i in "${!UDP_num[@]}"; do
    [ "${UDP_num[$i]}" = "$ph" ] && { ptitle="${UDP_title[$i]}"; pstatus="${UDP_status[$i]}"; }
  done
  [ "$ph" = "$UIV_phase_num" ] && [ -n "$UIV_phase_title" ] && ptitle="$UIV_phase_title"
  ui_phase_tasks "$ph"
  n=${#UDT_idx[@]}
  sel="${UI_SEL_TASK:-$UDT_active}"
  [ "${sel:-0}" -gt 0 ] 2> /dev/null || sel=0
  if [ "$sel" = 0 ]; then
    for i in "${!UDT_idx[@]}"; do case "${UDT_status[$i]}" in done) ;; *) sel="${UDT_idx[$i]}"; break ;; esac; done
    [ "$sel" = 0 ] && [ "$n" -gt 0 ] && sel="${UDT_idx[$((n - 1))]}"
  fi
  for i in "${!UDT_idx[@]}"; do
    [ "${UDT_idx[$i]}" = "$sel" ] && seli=$i
    [ "${UDT_status[$i]}" = "done" ] && v=$((v + 1))
  done

  ui_blk FOH; ui_region_header FOH "$W"; [ "$sp" = 1 ] && ui_blank FOH
  UIR_MAX="$W"; ui_r0
  ui_rt "$UI_K_B$UI_K_CYAN" "FASE $(ui_nz "$ph") / $(ui_nz "$UIV_phase_total")"
  ui_rpad $((W * 22 / 100)); ui_rt "$UI_K_TEXT" "$(ui_or_none "$ptitle")" $((W * 50 / 100))
  ui_rpad $((W * 78 / 100)); ui_rt "$UI_K_DIM" "TOTAL $(format_duration "$UD_elapsed" | tr -d ' ')"
  ui_emit FOH
  [ "$sp" = 1 ] && ui_blank FOH

  # Destaque da tarefa (faixa ciano) + confirmacao independente.
  local lw="$W" state title="" sub="" text
  [ "$side" = 1 ] && lw=$((W * 58 / 100))
  if [ "$seli" -ge 0 ]; then
    ui_task_word "${UDT_status[$seli]}"; state="$UTW"
    title="${UDT_title[$seli]}"; sub="${UDT_sub[$seli]}"
  else
    state="$UI_GL_NONE"
  fi
  ui_blk FOL
  UIR_MAX=$((lw - 4))
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" "TAREFA $(ui_nz "$sel") / $(ui_nz "$n")  ·  $(printf '%s' "$state" | tr '[:lower:]' '[:upper:]')"
  UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; ui_emit FOL 0 "" "$UI_K_CYAN_BG"
  ui_r0; ui_rt "$UI_K_B$UI_K_TEXT" "$(ui_or_none "$title")"
  [ "$seli" -ge 0 ] && ui_rhit "task:$ph:$sel" 0
  UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; ui_shift_hits 2; ui_emit FOL 0 "" "$UI_K_CYAN_BG"
  # Subtitulo vazio = linha em branco, sem "—" (RF-14).
  ui_r0; ui_rt "$UI_K_DIM" "$sub"; UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; ui_emit FOL 0 "" "$UI_K_CYAN_BG"
  [ "$sp" = 1 ] && ui_blank FOL 0 "" "$UI_K_CYAN_BG"
  text="${UIL_TAIL:-${UIV_progress:-$UIV_activity}}"
  [ "$ph" = "$UIV_phase_num" ] || text=""
  text="$(printf '%s' "$text" | ui_clean_text)"
  ui_r0; ui_rt "$UI_K_CYAN" "$UI_GL_ACT $(ui_or_none "$(ui_action_words "$text")")"
  UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; ui_emit FOL 0 "" "$UI_K_CYAN_BG"
  [ "$sp" = 1 ] && { ui_blank FOL; ui_blank FOL; }
  UIR_MAX=$((lw - 4))
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'CONFIRMAÇÃO INDEPENDENTE'; UIR_P="   $UIR_P"; UIR_C="   $UIR_C"; ui_emit FOL
  [ "$sp" = 1 ] && ui_blank FOL
  ui_r0; ui_rt "$UI_K_GREEN" "$v de $n tarefas verificadas"; UIR_P="   $UIR_P"; UIR_C="   $UIR_C"; ui_emit FOL
  ui_r0; ui_rt "$UI_K_DIM" "Atividade da sessão $UI_GL_NE tarefa concluída"; UIR_P="   $UIR_P"; UIR_C="   $UIR_C"; ui_emit FOL

  # Pipeline + ciclo + abas.
  ui_blk FOB
  ui_fo_stage
  local -a names=('IMPLEMENTAÇÃO' 'TESTES' 'VERIFICAÇÃO' 'COMMIT')
  local -a nexts=('executar testes após a sessão terminar.' 'verificação independente das tarefas.' 'commit da fase.' 'próxima fase.')
  local -a pcols=(0 $((W * 27 / 100)) $((W * 48 / 100)) $((W * 78 / 100)))
  [ "$sp" = 1 ] && ui_blank FOB
  ui_rule_line FOB "$W"
  [ "$sp" = 1 ] && ui_blank FOB
  UIR_MAX="$W"; ui_r0
  for i in 0 1 2 3; do
    ui_rpad "${pcols[$i]}"
    [ "$i" -gt 0 ] && ui_rt "$UI_K_DIM" "$UI_GL_ARROW "
    if [ "$i" = "$UFS" ] && [ "$UIV_run_status" = running ]; then
      ui_rt "$UI_K_B$UI_K_CYAN" "[ ${names[$i]} ]"
    else
      ui_rt "$UI_K_DIM" "${names[$i]}"
    fi
  done
  ui_emit FOB
  [ "$sp" = 1 ] && ui_blank FOB
  ui_r0
  ui_rt "$UI_K_TEXT" "Ciclo $(ui_nz "$UIV_cycle" | sed 's/^0//')/$(ui_nz "$UIV_max_cycles" | sed 's/^0//')"
  ui_rpad $((W * 22 / 100))
  text="${nexts[$UFS]}"; [ "$UIV_run_status" = running ] || text="$UI_GL_NONE"
  ui_rt "$UI_K_DIM" "Próximo: $text"
  ui_emit FOB
  ui_blk FOT; ui_region_tabs FOT "$W" 2
  [ "$sp" = 1 ] && ui_blank FOB

  # Caixa TAREFAS DA FASE: o que sobra de altura vira lista rolavel.
  local fixed avail rows_item=2 budget rw box_h
  [ "$sp" = 1 ] && rows_item=3
  fixed=$((${#FOH_P[@]} + ${#FOB_P[@]} + ${#FOT_P[@]}))
  if [ "$side" = 1 ]; then
    avail=$((H - fixed))
    rw=$((W - lw - 2))
    # A caixa cresce com as tarefas ate a altura livre; o resto vira respiro
    # acima do pipeline, que fica colado nas abas como no artboard.
    box_h=$((3 + n * rows_item))
    [ "$box_h" -lt "${#FOL_P[@]}" ] && box_h=${#FOL_P[@]}
    [ "$box_h" -gt "$avail" ] && box_h=$avail
    budget=$(((box_h - 3) / rows_item))
  else
    rw="$W"
    avail=$((H - fixed - ${#FOL_P[@]}))
    budget=$(((avail - 1) / rows_item))
  fi
  [ "$budget" -lt 0 ] && budget=0
  local auto=$((seli - budget / 2))
  ui_list_window tasks "$n" "$budget" "$auto"
  ui_list_hint tasks "$n" "$budget" "$UI_LS"
  ui_blk FOR
  [ "$sp" = 1 ] && ui_blank FOR "$rw" "$UI_K_BOX"
  UIR_MAX=$((rw - 3))
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'TAREFAS DA FASE'
  if [ -n "$UI_HINT" ]; then ui_vw "$UI_HINT"; ui_rpad $((rw - 5 - UI_VW)); ui_rt "$UI_K_DIM" "$UI_HINT"; fi
  ui_emit_boxed FOR "$rw"
  local color tcolor
  for ((i = UI_LS; i < n && i < UI_LS + budget; i++)); do
    ui_task_word "${UDT_status[$i]}"
    color="$UTC"; tcolor="$UI_K_TEXT"
    case "${UDT_status[$i]}" in done) tcolor="$UI_K_GREEN" ;; pending) tcolor="$UI_K_DIM" ;; esac
    [ "${UDT_idx[$i]}" = "$sel" ] && tcolor="$UI_K_CYAN"
    ui_r0; ui_rt "$UI_K_B$tcolor" "$(ui_nn "${UDT_idx[$i]}")"; ui_rpad 5; ui_rt "$tcolor" "${UDT_title[$i]}"
    ui_rhit "task:$ph:${UDT_idx[$i]}" 0; ui_rhit scroll:tasks 0
    ui_emit_boxed FOR "$rw"
    ui_r0; ui_rpad 5; ui_rt "$color" "$UTW"; ui_rhit "task:$ph:${UDT_idx[$i]}" 0; ui_rhit scroll:tasks 0
    ui_emit_boxed FOR "$rw"
    [ "$rows_item" = 3 ] && ui_blank FOR "$rw" "$UI_K_BOX"
  done
  if [ "$n" -eq 0 ]; then ui_r0; ui_rt "$UI_K_DIM" "$UI_GL_NONE"; ui_emit_boxed FOR "$rw"; fi
  if [ "$side" = 1 ]; then
    while [ "${#FOR_P[@]}" -lt "$box_h" ]; do ui_blank FOR "$rw" "$UI_K_BOX"; done
    while [ "${#FOL_P[@]}" -lt "$box_h" ]; do ui_blank FOL; done
  fi

  ui_cat "$out" FOH
  if [ "$side" = 1 ]; then
    ui_side "$out" FOL "$lw" 2 FOR
  else
    ui_cat "$out" FOL; ui_cat "$out" FOR
  fi
  if [ "$side" = 1 ]; then
    local fill=$((avail - box_h))
    while [ "$fill" -gt 0 ]; do ui_blank "$out"; fill=$((fill - 1)); done
  fi
  ui_cat "$out" FOB
  ui_cat "$out" FOT
}

# Desloca os alvos da linha corrente em <n> colunas (recuo aplicado a mao).
ui_shift_hits() {
  local h a b act
  local -a moved=()
  for h in "${UIR_H[@]}"; do IFS='|' read -r a b act <<< "$h"; moved+=("$((a + $1))|$((b + $1))|$act"); done
  UIR_H=("${moved[@]}")
}

# --- 3 Diagnostico (UI-03) -------------------------------------------------------

# Frase da tentativa anterior por gate: simbolo + cor + palavra.
ui_prev_gate() {
  local g="$1" v="$2" w
  case "$g:$v" in
    0:pass) w='Sessão terminou' ;; 0:fail) w='Sessão falhou' ;;
    1:pass) w='Alteração detectada' ;; 1:fail) w='Sem alteração detectada' ;;
    2:pass) w='Testes aprovados' ;; 2:fail) w='Testes falharam' ;;
    3:pass) w='Verificação aprovada' ;; 3:fail) w='Verificação reprovou' ;;
    *:running) w='Em execução' ;; *) w='Não executado' ;;
  esac
  case "$v" in
    pass) UPG_M="$UI_GL_OK"; UPG_C="$UI_K_GREEN" ;;
    fail) UPG_M="$UI_GL_X"; UPG_C="$UI_K_RED" ;;
    running) UPG_M="$UI_GL_DOT"; UPG_C="$UI_K_CYAN" ;;
    *) UPG_M="$UI_GL_PEND"; UPG_C="$UI_K_DIM" ;;
  esac
  # G1 aprovado e sinal, nao veredito: ponto ciano, como no artboard.
  [ "$g:$v" = 1:pass ] && { UPG_M="$UI_GL_DOT"; UPG_C="$UI_K_CYAN"; }
  UPG_W="$w"
}

# Log exibido: so arquivo local sob $LOG_DIR publicado pelo produtor.
ui_diag_log_path() {
  local log="${UIV_failure_log:-${UIV_test_log:-}}"
  UDL=""
  if [[ "$log" == "$LOG_DIR/"* ]] && [[ "$log" != *'/../'* ]] && [ -f "$log" ]; then UDL="$log"; fi
}

ui_screen_diag() {
  local out="$1" W="$2" H="$3" side="$4" sp="$4" gate="${UIV_failure_gate#gate}" gname text i
  ui_blk DGH; ui_region_header DGH "$W"; [ "$sp" = 1 ] && ui_blank DGH
  UIR_MAX="$W"; ui_r0
  ui_rt "$UI_K_TEXT" "FASE $(ui_nz "$UIV_phase_num") / $(ui_nz "$UIV_phase_total")"
  ui_rpad 17; ui_rt "$UI_K_TEXT" "$(ui_or_none "$UIV_phase_title")" $((W * 55 / 100))
  ui_rpad $((W * 76 / 100)); ui_rt "$UI_K_B$UI_K_AMBER" "CICLO $(ui_nz "$UIV_cycle") / $(ui_nz "$UIV_max_cycles")"
  ui_emit DGH
  [ "$sp" = 1 ] && ui_blank DGH

  # Banner: gate que falhou, ou faixa verde sem falha (RF-16). Mesmas linhas
  # nos dois casos — o layout nao pula quando a falha aparece.
  local bg="$UI_K_BANNER" stripe="$UI_K_RED_BG" scope file
  ui_blk DGB
  UIR_MAX=$((W - 4))
  if [ -n "$gate" ] || [ "$UIV_env_abort" = 1 ]; then
    [ -n "$gate" ] || gate=2
    case "$gate" in
      0) gname='SESSÃO FALHOU' ;; 1) gname='CÓDIGO FALHOU' ;; 3) gname='VERIFICAÇÃO FALHOU' ;; *) gname='TESTES FALHARAM' ;;
    esac
    [ "$UIV_env_abort" = 1 ] && gname='AMBIENTE INDISPONÍVEL'
    [ "$sp" = 1 ] && ui_blank DGB "$W" "$bg" "$stripe"
    ui_r0; ui_rt "$UI_K_B$UI_K_RED" "G$gate / $gname"; ui_emit_banner DGB "$W" "$bg" "$stripe"
    text="${UIV_failure_headline:-$UIV_last_error}"
    [ "$UIV_env_abort" = 1 ] && [ -z "$text" ] && text='Ambiente indisponível: sem veredito sobre o código'
  else
    bg="$UI_K_BOX"; stripe="$UI_K_GREEN_BG"
    [ "$sp" = 1 ] && ui_blank DGB "$W" "$bg" "$stripe"
    ui_r0; ui_rt "$UI_K_B$UI_K_GREEN" "$UI_GL_DOT Nenhum gate falhou"; ui_emit_banner DGB "$W" "$bg" "$stripe"
    text=""
  fi
  ui_r0; ui_rt "$UI_K_B$UI_K_TEXT" "$(ui_or_none "$(printf '%s' "$text" | ui_clean_text)")"; ui_emit_banner DGB "$W" "$bg" "$stripe"
  scope="$(ui_scope_words)"; [ "$scope" = 'a resolver' ] && scope=""
  file="${UIV_test_file:-}"
  ui_r0; ui_rt "$UI_K_DIM" "Escopo executado: $(ui_or_none "$scope")  ·  $(ui_or_none "$file")"; ui_emit_banner DGB "$W" "$bg" "$stripe"
  [ "$sp" = 1 ] && ui_blank DGB "$W" "$bg" "$stripe"
  [ "$sp" = 1 ] && ui_blank DGB

  # TENTATIVA ANTERIOR + CORRECAO ATUAL.
  local lw="$W" rw="$W" g v any=0
  [ "$side" = 1 ] && { lw=$((W * 46 / 100)); rw=$((W - lw - 2)); }
  for g in 0 1 2 3; do v="UIV_prev_gate$g"; case "${!v}" in '' | pending) ;; *) any=1 ;; esac; done
  ui_blk DGP
  [ "$sp" = 1 ] && ui_blank DGP "$lw" "$UI_K_BOX"
  UIR_MAX=$((lw - 3))
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'TENTATIVA ANTERIOR'; ui_emit_boxed DGP "$lw"
  for g in 0 1 2 3; do
    v="UIV_prev_gate$g"
    ui_prev_gate "$g" "${!v}"
    ui_r0
    if [ "$any" = 1 ]; then ui_rt "$UPG_C" "$UPG_M G$g $UPG_W"
    else ui_rt "$UI_K_DIM" "$UI_GL_PEND G$g $UI_GL_NONE"; fi
    ui_emit_boxed DGP "$lw"
  done
  [ "$sp" = 1 ] && ui_blank DGP "$lw" "$UI_K_BOX"

  ui_blk DGC
  [ "$sp" = 1 ] && ui_blank DGC "$rw" "$UI_K_BOX"
  UIR_MAX=$((rw - 3))
  ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'CORREÇÃO ATUAL'; ui_emit_boxed DGC "$rw"
  ui_r0; ui_rt "$UI_K_B$UI_K_AMBER" "$UI_GL_RUN $(ui_or_none "$UIV_correction_title")"; ui_emit_boxed DGC "$rw"
  text="${UIL_TAIL:-$UIV_activity}"
  text="$(printf '%s' "$text" | ui_clean_text)"
  ui_r0; ui_rt "$UI_K_TEXT" "Atividade: $(ui_or_none "$(ui_action_words "$text")")"; ui_emit_boxed DGC "$rw"
  [ "$sp" = 1 ] && ui_blank DGC "$rw" "$UI_K_BOX"
  ui_r0; ui_rt "$UI_K_DIM" 'Depois: reavaliar os gates'; ui_emit_boxed DGC "$rw"
  if [ "$side" = 1 ]; then
    while [ "${#DGC_P[@]}" -lt "${#DGP_P[@]}" ]; do ui_blank DGC "$rw" "$UI_K_BOX"; done
    while [ "${#DGP_P[@]}" -lt "${#DGC_P[@]}" ]; do ui_blank DGP "$lw" "$UI_K_BOX"; done
  fi
  ui_blk DGM
  if [ "$side" = 1 ]; then ui_side DGM DGP "$lw" 2 DGC; else ui_cat DGM DGP; ui_cat DGM DGC; fi
  [ "$sp" = 1 ] && ui_blank DGM

  ui_blk DGT; ui_region_tabs DGT "$W" 3

  # LINHA DO TEMPO + SAIDA DO TESTE: caem juntas quando falta altura (RF-15).
  # Minimo: rotulo + 3 eventos, e rotulo + FAIL + mensagem + Log.
  local used avail
  used=$((${#DGH_P[@]} + ${#DGB_P[@]} + ${#DGM_P[@]} + ${#DGT_P[@]}))
  avail=$((H - used))
  ui_cat "$out" DGH; ui_cat "$out" DGB; ui_cat "$out" DGM
  local pad=0; [ "$sp" = 1 ] && pad=2
  local need=8
  [ "$side" = 1 ] && need=$((4 + pad))
  if [ "$avail" -ge "$need" ]; then
    local tl_budget lg_budget th
    ui_diag_log_path
    local -a rows=()
    [ -n "$UDL" ] && mapfile -t rows < <(tail -c 16384 -- "$UDL" 2> /dev/null | tail -n 80 | ui_clean_lines)
    if [ "$side" = 1 ]; then
      th=$((avail - 1))
      tl_budget=$((th - 1))
      lg_budget=$((th - 4 - pad))
    else
      local extra=$((avail - 8))
      tl_budget=$((3 + extra / 2))
      lg_budget=$((extra - extra / 2))
      th=0
    fi
    [ "$lg_budget" -lt 0 ] && lg_budget=0
    ui_blk DGL
    ui_events_block DGL timeline "$lw" "$tl_budget" 'LINHA DO TEMPO' 1
    ui_blk DGO
    [ "$sp" = 1 ] && ui_blank DGO "$rw" "$UI_K_BOX"
    UIR_MAX=$((rw - 3))
    ui_r0; ui_rt "$UI_K_B$UI_K_DIM" 'SAÍDA DO TESTE'; ui_emit_boxed DGO "$rw"
    ui_r0
    if [ -n "$UIV_failure_name" ]; then ui_rt "$UI_K_RED" "FAIL  $UIV_failure_name"; else ui_rt "$UI_K_DIM" "$UI_GL_NONE"; fi
    ui_emit_boxed DGO "$rw"
    ui_r0; ui_rt "$UI_K_TEXT" "$(ui_or_none "$(printf '%s' "$UIV_failure_message" | ui_clean_text)")"; ui_emit_boxed DGO "$rw"
    local total=${#rows[@]}
    ui_list_window testout "$total" "$lg_budget" $((total - lg_budget))
    for ((i = UI_LS; i < total && i < UI_LS + lg_budget; i++)); do
      ui_r0; ui_rt "$UI_K_DIM" "${rows[$i]}"; ui_rhit scroll:testout 0; ui_emit_boxed DGO "$rw"
    done
    ui_r0; ui_rt "$UI_K_DIM" "Log: $(ui_or_none "$UDL")"; ui_emit_boxed DGO "$rw"
    [ "$sp" = 1 ] && ui_blank DGO "$rw" "$UI_K_BOX"
    ui_blk DGZ
    if [ "$side" = 1 ]; then
      while [ "${#DGO_P[@]}" -lt "$th" ]; do ui_blank DGO "$rw" "$UI_K_BOX"; done
      ui_side DGZ DGL "$lw" 2 DGO
    else
      ui_cat DGZ DGL; ui_cat DGZ DGO
    fi
    ui_cat "$out" DGZ
    avail=$((avail - ${#DGZ_P[@]}))
  fi
  while [ "$avail" -gt 0 ] && [ "$sp" = 1 ]; do ui_blank "$out"; avail=$((avail - 1)); done
  ui_cat "$out" DGT
}

ui_emit_banner() {
  local h a b act
  local -a moved=()
  for h in "${UIR_H[@]}"; do IFS='|' read -r a b act <<< "$h"; moved+=("$((a + 2))|$((b + 2))|$act"); done
  UIR_H=("${moved[@]}")
  UIR_P="  $UIR_P"; UIR_C="  $UIR_C"; UIR_W=$((UIR_W + 2))
  ui_emit "$1" "$2" "$3" "$4"
}

# Linhas de log ja limpas, uma por linha (ui_clean_text junta tudo numa so).
ui_clean_lines() {
  LC_ALL=C sed -E $'s/\033\\][^\007]*(\007|\033\\\\)//g; s/\033\\[[0-?]*[ -/]*[@-~]//g; s/\r$//; s/\r/\\n/g' \
    | tr -d '\000-\010\013-\037\177' | tr '\t' ' '
}

# ---------------------------------------------------------------------------
# ui_frame — um frame completo da tela ativa (RF-15).
#
# >= 144x40: caixas lado a lado, com o respiro dos artboards. Entre 100x24 e
# 144x40: caixas empilhadas, sem respiro; se a altura nao comporta, caem
# primeiro ULTIMOS EVENTOS (Visao geral), depois LINHA DO TEMPO e SAIDA DO
# TESTE (Diagnostico). Abaixo de 100x24 so o aviso. Nunca mais que h-1 linhas
# (a ultima linha do terminal rolaria a tela) nem mais que w-1 colunas (folga
# para glifo ambiguo). Mapa de cliques e janelas de rolagem saem do MESMO
# desenho: alvo nunca aponta para regiao que nao foi desenhada.
# ---------------------------------------------------------------------------
ui_frame() {
  local tick="${1:-0}" w h W H side=0 i
  w=$(ui_term_cols); h=$(ui_term_lines)
  : "$tick"
  ui_load_state
  UI_VP=()
  ui_blk FR
  W=$((w - 1)); H=$((h - 1))
  if [ "$w" -lt 100 ] || [ "$h" -lt 24 ]; then
    UIR_MAX="$W"; ui_r0
    ui_rt "$UI_K_AMBER" "aumente para 100×24 (agora ${w}×${h})"
    ui_emit FR
  else
    [ "$w" -ge 144 ] && [ "$h" -ge 40 ] && side=1
    ui_data
    case "$UI_LAYOUT" in
      focus) ui_screen_focus FR "$W" "$H" "$side" ;;
      diagnostic) ui_screen_diag FR "$W" "$H" "$side" ;;
      *) ui_screen_overview FR "$W" "$H" "$side" ;;
    esac
  fi

  # Rede de seguranca da geometria: nenhuma regiao pode empurrar o frame para
  # alem de h-1 linhas.
  local n=${#FR_P[@]}
  [ "$n" -gt "$H" ] && n=$H
  for ((i = 0; i < n; i++)); do printf '%s\n' "${FR_C[$i]}"; done

  if [ -d "$UI_DIR" ]; then
    local tmp="$UI_HITMAP.tmp.$$" hh row
    {
      for hh in "${FR_H[@]}"; do
        row="${hh%%|*}"
        [ "$row" -lt "$n" ] && printf '%s|%s\n' "$((row + 1))" "${hh#*|}"
      done
    } > "$tmp" 2> /dev/null
    mv -f "$tmp" "$UI_HITMAP" 2> /dev/null || rm -f "$tmp" 2> /dev/null
    tmp="$UI_VIEWPORT.tmp.$$"
    { for hh in "${UI_VP[@]}"; do printf '%s\n' "$hh"; done; } > "$tmp" 2> /dev/null
    mv -f "$tmp" "$UI_VIEWPORT" 2> /dev/null || rm -f "$tmp" 2> /dev/null
  fi
  return 0
}

# ui_read_key <timeout> — espera o intervalo do frame E captura uma tecla.
#
# O `read` faz as duas coisas de uma vez, entao ele SUBSTITUI o sleep do laco:
# sem tecla ele volta no timeout, com tecla ele volta antes e a tela responde na
# hora. Nada aqui bloqueia o run — quem le teclado e o pintor, o processo
# principal segue nos gates sem saber que existe teclado.
#
# -s (sem eco) tambem conserta um efeito colateral antigo: tecla digitada
# durante o painel aparecia como lixo por cima da moldura.
ui_read_key() {
  local timeout="$1" k="" c="" seq="" i
  UI_KEY=""
  IFS= read -rsn1 -t "$timeout" k 2> /dev/null || true
  [ -n "$k" ] || return 0
  if [ "$k" != $'\033' ]; then UI_KEY="$k"; return 0; fi

  # Seta/PgUp chegam como CSI (ESC [ ... final) ou SS3 (ESC O final). Le BYTE A
  # BYTE ate o terminador, nunca um bloco de tamanho fixo: com a tecla repetindo
  # ha mais de uma sequencia na fila, e um bloco engoliria o ESC da proxima —
  # as duas setas viravam uma sequencia desconhecida e a janela travava depois
  # de andar uma linha.
  while true; do
    c=""
    IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
    case "$c" in
      '[' | 'O') seq="$k$c" ;;
      *) UI_KEY="$k$c"; return 0 ;;
    esac

    # Relato de mouse SGR (ESC [ < b ; x ; y M|m). Tambem byte a byte, ate 16
    # bytes: o terminal pode cortar o relato (buffer cheio, sessao remota) e o
    # que vier depois e outra tecla. Sequencia truncada ou malformada e
    # descartada sem efeito (RF-11) — se o corte foi um ESC, ele abre a
    # proxima sequencia, que segue valendo.
    if [ "$seq" = $'\033[' ]; then
      c=""
      IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
      if [ "$c" = '<' ]; then
        seq+="$c"
        for ((i = 0; i < 16; i++)); do
          c=""
          IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
          case "$c" in
            [0-9\;]) seq+="$c" ;;
            M | m) seq+="$c"; break ;;
            *) break ;;
          esac
        done
        if [[ "$seq" =~ ^$'\033'\[\<[0-9]+\;[0-9]+\;[0-9]+[Mm]$ ]]; then
          UI_KEY="$seq"; return 0
        fi
        [ "$c" = $'\033' ] && continue
        return 0
      fi
      [ -n "$c" ] || { UI_KEY="$seq"; return 0; }
      seq+="$c"
      case "$c" in [A-Za-z~]) UI_KEY="$seq"; return 0 ;; esac
    fi
    break
  done
  for ((i = 0; i < 6; i++)); do
    c=""
    IFS= read -rsn1 -t 0.05 c 2> /dev/null || true
    [ -n "$c" ] || break
    seq+="$c"
    case "$c" in [A-Za-z~]) break ;; esac
  done
  UI_KEY="$seq"
  return 0
}

# Lista que as teclas de rolagem movem em cada tela (RF-06): Visao geral =
# eventos, Foco = tarefas da fase, Diagnostico = saida do teste.
ui_primary_list() {
  case "$UI_LAYOUT" in focus) printf 'tasks' ;; diagnostic) printf 'testout' ;; *) printf 'events' ;; esac
}

# ui_scroll_list <lista> <tecla> — move a janela de uma lista como a tecla de
# rolagem manda. Os numeros da janela vem do ultimo frame desenhado — o pintor
# nao monta as linhas, entao nao tem como saber sozinho quantas sao.
ui_scroll_list() {
  local list="$1" key="$2" var vp start=0 total=0 budget=3
  var="UI_SCROLL_$list"
  vp="$(grep "^$list|" "$UI_VIEWPORT" 2> /dev/null | tail -n 1 || true)"
  [ -n "$vp" ] && IFS='|' read -r _ start total budget <<< "$vp"
  [[ "$start"  =~ ^-?[0-9]+$ ]] || start=0
  [[ "$total"  =~ ^[0-9]+$ ]]   || total=0
  [[ "$budget" =~ ^[0-9]+$ ]]   || budget=3
  [ "$budget" -lt 1 ] && budget=1

  # Ja em manual, a base e a propria rolagem, nao o topo do ultimo frame: com
  # a tecla repetindo, varias teclas chegam entre dois frames e o topo ficaria
  # velho — a janela andaria uma linha e travaria. O topo do frame so serve na
  # PRIMEIRA tecla depois do auto, para sair de onde a janela esta.
  local base="${!var:--1}" delta=0 target=""
  [ "$base" -lt 0 ] 2> /dev/null && base="$start"
  case "$key" in
    $'\033[A' | $'\033OA' | k | K) delta=-1 ;;
    $'\033[B' | $'\033OB' | j | J) delta=1 ;;
    $'\033[5~')                    delta=$((-budget)) ;;
    $'\033[6~' | ' ')              delta=$budget ;;
    g | $'\033[H' | $'\033[1~')    target=0 ;;
    G | $'\033[F' | $'\033[4~')    target=$((total - budget)) ;;
    *) return 0 ;;
  esac

  if [ -n "$target" ]; then base="$target"; else base=$((base + delta)); fi
  printf -v "$var" '%s' "$(ui_scroll_fit "$base" "$total" "$budget")"
  return 0
}

# ui_hit_at <col> <linha> <prefixo> -> UI_HIT_ACT: acao do alvo do ultimo frame
# que contem a celula. Com prefixo, so alvos daquele tipo (scroll:); sem, o
# primeiro alvo que nao e de rolagem (a linha de tarefa e as duas coisas).
ui_hit_at() {
  UI_HIT_ACT="$(awk -F'|' -v x="$1" -v y="$2" -v p="$3" '
    $1 == y && x >= $2 && x <= $3 {
      if (p != "" && index($4, p) == 1) { print $4; exit }
      if (p == "" && index($4, "scroll:") != 1) { print $4; exit }
    }' "$UI_HITMAP" 2> /dev/null || true)"
}

# ui_apply_mouse <b> <x> <y> <M|m> — clique e roda contra o mapa de cliques do
# ultimo frame (CT-04). So o press conta; o release chega depois de todo clique
# e repetiria a acao.
ui_apply_mouse() {
  local b="$1" x="$2" y="$3" fin="$4" act
  [ "$fin" = M ] || return 0
  # Bits 4/8/16 = Shift/Meta/Ctrl: a roda com modificador ainda e roda.
  b=$((b & ~28))
  case "$b" in
    64 | 65)
      ui_hit_at "$x" "$y" scroll:
      [ -n "$UI_HIT_ACT" ] || return 0
      if [ "$b" = 64 ]; then ui_scroll_list "${UI_HIT_ACT#scroll:}" k; else ui_scroll_list "${UI_HIT_ACT#scroll:}" j; fi
      return 0
      ;;
    0) ;;
    *) return 0 ;;
  esac
  ui_hit_at "$x" "$y" ""
  act="$UI_HIT_ACT"
  # shellcheck disable=SC2034
  case "$act" in
    tab:[123]) ui_apply_key "${act#tab:}" ;;
    follow) ui_apply_key f ;;
    quit) ui_apply_key q ;;
    phase:*)
      # Selecao manual (RF-05): o Foco fica na fase clicada ate o Seguir,
      # mesmo com o run avancando.
      UI_SEL_PHASE="${act#phase:}"; UI_SEL_TASK=""; UI_SCROLL_tasks=-1
      UI_LAYOUT=focus
      ;;
    task:*:*)
      act="${act#task:}"
      UI_SEL_PHASE="${act%%:*}"; UI_SEL_TASK="${act#*:}"; UI_SCROLL_tasks=-1
      UI_LAYOUT=focus
      ;;
  esac
  return 0
}

# Aplica a tecla (ou o relato de mouse lido por ui_read_key).
ui_apply_key() {
  local key="$1"
  [ -n "$key" ] || return 0

  if [[ "$key" =~ ^$'\033'\[\<([0-9]+)\;([0-9]+)\;([0-9]+)([Mm])$ ]]; then
    ui_apply_mouse "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    return 0
  fi

  # shellcheck disable=SC2034
  case "$key" in
    1) UI_LAYOUT=cockpit; return 0 ;;
    2) UI_LAYOUT=focus; return 0 ;;
    # "q Sair" (RF-03): so marca. Quem fecha e o laco do pintor, depois de
    # aplicar a tecla — fechar aqui dentro sairia de quem chamou por engano.
    q | Q) UI_QUIT=1; return 0 ;;
    3) UI_LAYOUT=diagnostic; return 0 ;;
    a | A | f | F)
      # Seguir (RF-02): desfaz selecao manual e toda rolagem manual; as listas
      # voltam a acompanhar o run.
      UI_SCROLL_events=-1; UI_SCROLL_tasks=-1; UI_SCROLL_timeline=-1; UI_SCROLL_testout=-1
      UI_SEL_PHASE=""; UI_SEL_TASK=""
      return 0
      ;;
  esac

  ui_scroll_list "$(ui_primary_list)" "$key"
}

ui_start() {
  ui_should_activate || return 0

  mkdir -p "$UI_DIR" 2> /dev/null || return 0
  # Em --attach o messages.log e do run alheio: truncar apagaria o placar dele.
  if ! $ATTACH; then
    : > "$UI_MSG_FILE" 2> /dev/null || return 0
  fi
  # Flag de um painel fechado antes (outro run, outro attach) nao pode fechar
  # este no primeiro log.
  rm -f "$UI_PANEL_FLAG" 2> /dev/null || true
  UI_ACTIVE=true
  # O attach nunca publica estado: ele so le o do run que esta acompanhando.
  $ATTACH || state_sync

  # 1049h = buffer alternado + cursor salvo; 25l = cursor escondido. Ao sair,
  # 1049l devolve a tela anterior com o scrollback do dev intacto.
  printf '\033[?1049h\033[?25l\033[2J'

  local tick_interval="0.5"
  [ "$UI_FPS" -gt 0 ] 2> /dev/null && tick_interval="$(awk -v f="$UI_FPS" 'BEGIN{printf "%.2f", 1/f}')"

  # O laco virou funcao para poder receber `< /dev/tty`: rodado com `&` num
  # script (job control desligado), o bash redireciona a entrada de qualquer
  # comando assincrono para /dev/null — sem o redirect explicito nenhuma tecla
  # chegaria aqui. O `&` ja forka: o corpo da funcao roda em subshell proprio,
  # entao as variaveis do laco seguem isoladas do processo principal SEM
  # precisar de um `( )` interno. E precisa ser assim: `$!` guarda o PID do
  # fork do `&`, e so dele. Um `( )` a mais dentro da funcao criaria um NETO —
  # `ui_stop` mataria o pai, o neto sobreviveria orfao e continuaria pintando
  # por cima da tela normal depois do 1049l, engolindo o relatorio final.
  if [ "$UI_KEYS" = "1" ] && [ -r /dev/tty ]; then
    UI_TTY_STATE="$(stty -g < /dev/tty 2> /dev/null || true)"
    # Relato de mouse (1000 = clique e roda, 1006 = formato SGR, sem limite de
    # coluna) so aqui: quem le o relato e o pintor, e sem teclado ninguem o
    # consumiria — cada clique viraria lixo no terminal (RF-07).
    printf '\033[?1000h\033[?1006h'
    UI_MOUSE=true
    ui_painter_loop "$tick_interval" < /dev/tty &
  else
    UI_KEYS=0
    ui_painter_loop "$tick_interval" &
  fi
  UI_PAINTER_PID=$!
}

ui_painter_loop() {
  local tick_interval="$1"
  # Grupo `{ }`, nao subshell `( )`: `{ }` nao forka. O unico fork e o do `&`
  # em ui_start, entao o PID que ele guarda e exatamente o deste laco — e o
  # kill do ui_stop acerta quem pinta.
  {
    local tick=0 frame
    # As medicoes vivem AQUI, no corpo do loop, e nao dentro de ui_frame: a
    # chamada abaixo e uma substituicao de comando, ou seja, roda num subshell
    # filho — variaveis atribuidas la dentro morrem no fim do frame e nenhuma
    # taxa poderia ser calculada. Atribuidas aqui, elas persistem entre ticks e
    # o subshell as herda.
    local last_heavy=0 now_ts sl ol
    while true; do
      sl=""; ol=""
      if [ -f "$UI_DIR/state.env" ]; then
        sl="$(sed -n 's/^stderr_log=//p' "$UI_DIR/state.env" | tail -1)"
        ol="$(sed -n 's/^stdout_log=//p' "$UI_DIR/state.env" | tail -1)"
      fi

      now_ts=$(date +%s)

      # Ultima acao do engine. Fonte preferida: o NDJSON do stdout, onde cada
      # ferramenta usada vira um evento assim que acontece. O stderr e fallback
      # (codex, e claude quando o stream ainda nao produziu tool_use nenhum).
      UIL_TAIL=""
      UIL_ACTIONS=0
      if [ -n "$ol" ] && [ -s "$ol" ]; then
        UIL_ACTIONS="$(engine_action_count "$ol")"
        UIL_TAIL="$(engine_last_action "$ol" | cut -c1-200 || true)"
      fi
      [ -z "$UIL_TAIL" ] && [ -n "$sl" ] && [ -s "$sl" ] && \
        UIL_TAIL="$(grep -v '^[[:space:]]*$' "$sl" 2> /dev/null | tail -n 1 | cut -c1-200 || true)"

      # git status varre a arvore inteira: a 2 fps num repo grande isso pesaria.
      # A cada ~3s e sinal de vida suficiente e custo desprezivel. O corte e por
      # RELOGIO, nao por contagem de tick: com teclado o tick anda mais rapido
      # que o frame (a tecla encurta a espera) e `tick % 6` dispararia a
      # varredura a cada seta apertada.
      if [ $((now_ts - last_heavy)) -ge 3 ]; then
        last_heavy=$now_ts
        local dirty
        dirty="$(git status --porcelain -uall 2> /dev/null || true)"
        UIL_DIRTY_N="$(printf '%s' "$dirty" | grep -c . || true)"

        local pnum
        pnum="$(sed -n 's/^phase_num=//p' "$UI_DIR/state.env" 2> /dev/null | tail -1)"

        # Republicar tasks.txt AQUI, e nao so no state_sync, e o que faz o
        # checkbox aparecer. Durante a sessao do engine o processo principal
        # fica bloqueado em run_split e nao sincroniza nada por minutos —
        # justamente quando as tasks vao sendo marcadas. O pintor le
        # PROGRESS_FILE e os arquivos de fase do disco, entao nao depende do
        # estado congelado que herdou no fork.
        ui_tasks_cache 2> /dev/null || true
        ui_infer_tasks "${pnum:-0}" "$ol" 2> /dev/null || true

      fi

      # Falha ao desenhar nao pode matar o pintor nem o run: o painel e
      # apresentacao, o veredito vive no state e nos logs.
      frame="$(ui_frame "$tick" 2> /dev/null || true)"
      if [ -n "$frame" ]; then
        # H = cursor no topo; 2K por linha; J apaga o resto da tela. Sem o J,
        # um frame mais curto que o anterior deixaria lixo embaixo.
        printf '\033[H%s\033[J' "$(printf '%s\n' "$frame" | sed 's/$/\x1b[0K/')"
      fi
      tick=$((tick + 1))

      # Espera do frame e leitura de tecla sao a MESMA chamada: com teclado
      # ligado o read cobre o intervalo e ainda responde na hora quando o dev
      # aperta algo. Sem teclado, sleep — o custo e o mesmo de antes.
      if [ "$UI_KEYS" = "1" ]; then
        ui_read_key "$tick_interval"
        if [ -n "$UI_KEY" ]; then ui_apply_key "$UI_KEY"; fi
        [ "$UI_QUIT" = 1 ] && ui_painter_quit
      else
        sleep "$tick_interval"
      fi
    done
  }
}

# Sai do buffer alternado antes de qualquer saida longa (causa de gate vermelho,
# relatorio final). A partir daqui o placar volta a rolar na tela normal.
ui_stop() {
  $UI_ACTIVE || return 0
  # O painel ja fechou por conta propria ("q Sair" ou pintor morto): o
  # terminal ja foi (ou sera la dentro) restaurado; so falta o resto do placar.
  if ui_panel_gone; then ui_panel_closed; return 0; fi
  UI_ACTIVE=false

  if [ -n "$UI_PAINTER_PID" ]; then
    kill "$UI_PAINTER_PID" 2> /dev/null || true
    wait "$UI_PAINTER_PID" 2> /dev/null || true
    # Pintor vivo depois daqui e o pior defeito possivel do painel: ele repinta
    # POR CIMA da tela normal ja restaurada, apaga o relatorio final a cada
    # frame e o run parece travado com o painel congelado na tela. O `wait` so
    # cobre filho direto; se sobrou alguem (sinal perdido, read preso), SIGKILL.
    if kill -0 "$UI_PAINTER_PID" 2> /dev/null; then
      kill -9 "$UI_PAINTER_PID" 2> /dev/null || true
      wait "$UI_PAINTER_PID" 2> /dev/null || true
    fi
    UI_PAINTER_PID=""
  fi

  if [ -n "$UI_TTY_STATE" ]; then
    stty "$UI_TTY_STATE" < /dev/tty 2> /dev/null || true
    UI_TTY_STATE=""
  fi

  # 0m antes de sair: o pintor pode ter morrido no meio de um frame, com cor
  # aberta. O SGR atravessa a troca de buffer — sem o reset o relatorio final
  # sairia tingido com a ultima cor do painel.
  # Mouse desligado antes de sair do buffer: ligado, cada clique depois do run
  # imprimiria a sequencia do relato no shell do dev.
  if $UI_MOUSE; then printf '\033[?1006l\033[?1000l'; UI_MOUSE=false; fi
  printf '\033[0m\033[?25h\033[?1049l'

  # O painel viveu numa tela que acabou de ser descartada. Sem reimprimir, o
  # dev perde o placar inteiro do run — ele existe so no messages.log.
  ui_reprint_messages 0
  return 0
}

# ui_reprint_messages <pular> — reimprime o messages.log na tela normal a partir
# da linha <pular>+1 e devolve em UI_REPRINTED quantas linhas o arquivo tinha
# ate onde foi lido.
ui_reprint_messages() {
  local skip="${1:-0}" n=0 ts level text
  UI_REPRINTED="$skip"
  [ -s "$UI_MSG_FILE" ] || return 0
  while IFS=$'\t' read -r ts level text; do
    n=$((n + 1))
    [ "$n" -gt "$skip" ] || continue
    case "$level" in
      ok)   echo -e "${GREEN}[$ts] $text${NC}" ;;
      warn) echo -e "${YELLOW}[$ts] $text${NC}" ;;
      fail) echo -e "${RED}[$ts] $text${NC}" ;;
      *)    echo -e "${BLUE}[$ts]${NC} $text" ;;
    esac
  done < "$UI_MSG_FILE"
  [ "$n" -gt "$skip" ] && UI_REPRINTED="$n"
  return 0
}

# Painel fechado sem ui_stop? Sim quando o pintor gravou o flag do "q Sair" ou
# quando morreu (kill externo, erro fatal). So o processo principal pergunta.
ui_panel_gone() {
  [ -f "$UI_PANEL_FLAG" ] && return 0
  [ -n "$UI_PAINTER_PID" ] || return 1
  kill -0 "$UI_PAINTER_PID" 2> /dev/null && return 1
  return 0
}

# Processo principal assume o painel fechado: placar corrido daqui em diante.
# Com o flag o pintor ja restaurou o terminal e reimprimiu N linhas — aqui so o
# resto, e sem novo 1049l (sairia do buffer principal para lugar nenhum). Sem
# flag o pintor morreu no meio: a restauracao inteira e daqui.
ui_panel_closed() {
  local skip=0
  UI_ACTIVE=false
  if [ -n "$UI_PAINTER_PID" ]; then
    wait "$UI_PAINTER_PID" 2> /dev/null || true
    UI_PAINTER_PID=""
  fi
  if [ -f "$UI_PANEL_FLAG" ]; then
    skip="$(head -n 1 "$UI_PANEL_FLAG" 2> /dev/null || true)"
    [[ "$skip" =~ ^[0-9]+$ ]] || skip=0
    UI_MOUSE=false
    UI_TTY_STATE=""
  else
    if [ -n "$UI_TTY_STATE" ]; then
      stty "$UI_TTY_STATE" < /dev/tty 2> /dev/null || true
      UI_TTY_STATE=""
    fi
    if $UI_MOUSE; then printf '\033[?1006l\033[?1000l'; UI_MOUSE=false; fi
    printf '\033[0m\033[?25h\033[?1049l'
  fi
  ui_reprint_messages "$skip"
  return 0
}

# "q Sair" dentro do pintor: mesma restauracao do ui_stop, na mesma ordem
# (mouse antes do 1049l), placar reimpresso e o flag com a contagem. O flag vai
# por tmp+mv: o principal nunca le uma contagem pela metade. O run nao e
# tocado — so este processo sai.
ui_painter_quit() {
  if $UI_MOUSE; then printf '\033[?1006l\033[?1000l'; fi
  printf '\033[0m\033[?25h\033[?1049l'
  if [ -n "$UI_TTY_STATE" ]; then
    stty "$UI_TTY_STATE" < /dev/tty 2> /dev/null || true
  fi
  ui_reprint_messages 0
  printf '%s\n' "$UI_REPRINTED" > "$UI_PANEL_FLAG.tmp" 2> /dev/null \
    && mv -f "$UI_PANEL_FLAG.tmp" "$UI_PANEL_FLAG" 2> /dev/null
  exit 0
}

# ---------------------------------------------------------------------------
# Dashboard web (--serve)
# ---------------------------------------------------------------------------

port_free() {
  local port="$1"
  # Conexao bem-sucedida => alguem ja escuta ali.
  (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null && { exec 3<&- 2> /dev/null; return 1; }
  return 0
}

serve_start() {
  $SERVE || return 0

  if ! command -v python3 &> /dev/null; then
    warn "--serve pedido, mas python3 nao esta no PATH: dashboard web desabilitado."
    warn "O run segue normalmente; o estado continua em $STATE_FILE e $EVENTS_FILE."
    return 0
  fi

  if ! [[ "$SERVE_PORT" =~ ^[0-9]+$ ]] || [ "$SERVE_PORT" -lt 1 ] || [ "$SERVE_PORT" -gt 65535 ]; then
    warn "Porta invalida para --serve: '$SERVE_PORT'. Usando 7433."
    SERVE_PORT=7433
  fi

  mkdir -p "$UI_DIR" 2> /dev/null || return 0
  write_dashboard_html

  local port="$SERVE_PORT" limit=$((SERVE_PORT + 100)) found=""
  while [ "$port" -le "$limit" ]; do
    if port_free "$port"; then found="$port"; break; fi
    port=$((port + 1))
  done

  if [ -z "$found" ]; then
    warn "Nenhuma porta livre entre $SERVE_PORT e $limit: dashboard web desabilitado."
    return 0
  fi

  # Preso a 127.0.0.1: o diretorio servido tem prompts e logs do run, e nada
  # disso pode sair da maquina.
  python3 -m http.server "$found" --bind 127.0.0.1 --directory "$PHASES_DIR" \
    > /dev/null 2>&1 < /dev/null &
  SERVE_PID=$!
  SERVE_URL="http://127.0.0.1:$found/ui/"

  # Servidor morto ja no arranque (porta tomada na corrida) nao pode deixar
  # uma URL mentirosa no topo do run.
  sleep 1
  if ! kill -0 "$SERVE_PID" 2> /dev/null; then
    warn "O servidor do dashboard nao subiu na porta $found: dashboard web desabilitado."
    SERVE_PID=""
    SERVE_URL=""
    return 0
  fi

  return 0
}

# Auto-contido de proposito: sem CDN, sem fonte remota, sem fetch externo. O
# unico dado que a pagina busca sao os dois arquivos de estado do proprio run.
write_dashboard_html() {
  cat > "$UI_HTML" <<'HTML'
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ralph</title>
<style>
  :root {
    --bg: #0f1115; --panel: #171a21; --line: #262b36; --fg: #e6e9ef;
    --muted: #8b93a5; --ok: #3fb950; --run: #d29922; --err: #f85149;
    --skip: #6e7681; --accent: #58a6ff;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--fg);
    font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    padding: 1.5rem;
  }
  h1 { font-size: 1.1rem; margin: 0 0 .25rem; font-weight: 600; }
  .sub { color: var(--muted); margin-bottom: 1.25rem; font-size: .85rem; }
  .card {
    background: var(--panel); border: 1px solid var(--line);
    border-radius: 8px; padding: 1rem; margin-bottom: 1rem;
  }
  .card h2 {
    font-size: .75rem; text-transform: uppercase; letter-spacing: .08em;
    color: var(--muted); margin: 0 0 .75rem; font-weight: 600;
  }
  .headline { display: flex; flex-wrap: wrap; gap: 1rem; align-items: baseline; }
  .headline .title { font-size: 1.25rem; font-weight: 600; }
  .headline .meta { color: var(--muted); }
  .gates { display: flex; flex-wrap: wrap; gap: .5rem; }
  .gate {
    border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .7rem; display: flex; gap: .5rem; align-items: center;
  }
  .phases { display: grid; gap: .35rem; }
  .phase { display: flex; gap: .6rem; align-items: baseline; }
  .phase .n { color: var(--muted); min-width: 2.5rem; }
  .dot { width: .6rem; height: .6rem; border-radius: 50%; display: inline-block; flex: none; }
  .s-done .dot, .s-pass { background: var(--ok); }
  .s-running .dot, .s-run { background: var(--run); }
  .s-failed .dot, .s-fail { background: var(--err); }
  .s-skipped .dot, .s-skip { background: var(--skip); }
  .s-pending .dot, .s-pending2 { background: var(--line); }
  .s-done { color: var(--fg); } .s-pending { color: var(--muted); }
  .s-running { color: var(--run); font-weight: 600; }
  .s-failed { color: var(--err); } .s-skipped { color: var(--skip); }
  pre {
    margin: 0; white-space: pre-wrap; word-break: break-word;
    color: var(--muted); font-size: .85rem;
  }
  table { width: 100%; border-collapse: collapse; font-size: .85rem; }
  th, td { text-align: left; padding: .3rem .5rem; border-bottom: 1px solid var(--line); }
  th { color: var(--muted); font-weight: 600; }
  td.num { text-align: right; color: var(--muted); }
  .scroll { max-height: 22rem; overflow-y: auto; overflow-x: auto; }
  .banner {
    border-radius: 6px; padding: .6rem .8rem; margin-bottom: 1rem;
    background: #2d2410; border: 1px solid #6b4f0f; color: #e3b341;
  }
  .off { opacity: .55; }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f6f7f9; --panel: #fff; --line: #dfe3ea; --fg: #1b1f27;
      --muted: #626b7d; --ok: #1a7f37; --run: #9a6700; --err: #cf222e; --skip: #8c959f;
    }
    .banner { background: #fff8e5; border-color: #e3c168; color: #7a5c00; }
  }
</style>
</head>
<body>
  <h1 id="title">ralph</h1>
  <div class="sub" id="subtitle">carregando…</div>
  <div id="stale" class="banner" hidden></div>

  <div class="card">
    <h2>Fase corrente</h2>
    <div class="headline">
      <span class="title" id="phase-title">—</span>
      <span class="meta" id="phase-meta"></span>
    </div>
    <div style="margin-top:.75rem" class="gates" id="gates"></div>
    <pre id="test-cmd" style="margin-top:.75rem"></pre>
    <pre id="progress" style="margin-top:.5rem"></pre>
  </div>

  <div class="card">
    <h2>Fases</h2>
    <div class="phases" id="phases"></div>
  </div>

  <div class="card">
    <h2>Timeline</h2>
    <div class="scroll">
      <table>
        <thead><tr><th>hora</th><th>evento</th><th>fase</th><th>detalhe</th><th class="num">dur.</th></tr></thead>
        <tbody id="timeline"></tbody>
      </table>
    </div>
  </div>

<script>
const GATE_LABEL = {
  0: 'engine concluiu', 1: 'sessao escreveu', 2: 'suite do projeto', 3: 'verificacao independente'
};
const CLS = { pass: 's-pass', fail: 's-fail', running: 's-run', skip: 's-skip', pending: 's-pending2' };

function fmtDur(s) {
  if (s == null || isNaN(s)) return '';
  s = Math.max(0, Math.floor(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  if (h) return `${h}h ${m}m ${r}s`;
  if (m) return `${m}m ${r}s`;
  return `${r}s`;
}
function fmtTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString('pt-BR', { hour12: false });
}
function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

async function tick() {
  let state;
  try {
    state = await (await fetch('../state.json?t=' + Date.now(), { cache: 'no-store' })).json();
  } catch (e) {
    document.getElementById('subtitle').textContent = 'estado indisponivel — o run terminou ou o servidor caiu';
    return;
  }

  document.getElementById('title').textContent = `ralph · ${state.project}`;
  document.getElementById('subtitle').textContent =
    `engine ${state.engine} · ${state.input} · ${state.run_status} · decorrido ${fmtDur(state.updated_at - state.started_at)}`;

  const stale = document.getElementById('stale');
  if (state.limit && state.limit.waiting) {
    stale.hidden = false;
    const left = state.limit.until ? fmtDur(state.limit.until - Math.floor(Date.now() / 1000)) : 'tempo desconhecido';
    stale.textContent = `Limite de uso atingido. Retomando a MESMA fase em ${left} (espera ${state.limit.waits}/${state.limit.max_waits}). Nenhuma acao necessaria.`;
  } else {
    stale.hidden = true;
  }

  const p = state.phase || {};
  // O conserto cirurgico so aparece quando existe: fora dele a linha nao muda.
  const rp = state.repair || {};
  const rpTxt = rp.round > 0 ? ` · conserto ${rp.round}/${rp.max}` : '';
  document.getElementById('phase-title').textContent = p.title || '—';
  document.getElementById('phase-meta').textContent = p.num
    ? `fase ${p.seq}/${p.total} · ciclo ${p.cycle}/${p.max_cycles}${rpTxt} · ${fmtDur(state.updated_at - p.started_at)}`
    : '';

  const gates = document.getElementById('gates');
  gates.replaceChildren();
  for (const g of [0, 1, 2, 3]) {
    const st = (state.gates || {})[g] || 'pending';
    const box = el('div', 'gate' + (st === 'pending' ? ' off' : ''));
    box.append(el('span', 'dot ' + (CLS[st] || CLS.pending)), el('span', null, `gate ${g} — ${GATE_LABEL[g]}`));
    gates.append(box);
  }

  document.getElementById('test-cmd').textContent =
    state.test_cmd ? `gate 2: ${state.test_cmd}` : 'gate 2 desabilitado (nenhum comando de teste resolvido)';
  document.getElementById('progress').textContent = state.progress_line ? '· ' + state.progress_line : '';

  const list = document.getElementById('phases');
  list.replaceChildren();
  for (const ph of state.phases || []) {
    const row = el('div', 'phase s-' + ph.status);
    row.append(el('span', 'dot'), el('span', 'n', String(ph.num)), el('span', null, ph.title));
    list.append(row);
  }

  let lines = [];
  try {
    const raw = await (await fetch('../events.jsonl?t=' + Date.now(), { cache: 'no-store' })).text();
    lines = raw.trim().split('\n').filter(Boolean).map(JSON.parse);
  } catch (e) { /* events sao opcionais para a pagina renderizar */ }

  const tb = document.getElementById('timeline');
  tb.replaceChildren();
  for (const ev of lines.slice(-200).reverse()) {
    const tr = el('tr');
    let detail = ev.message || '';
    if (ev.event === 'gate_start') detail = `gate ${ev.gate} — ${GATE_LABEL[ev.gate]}`;
    if (ev.event === 'gate_end') detail = `gate ${ev.gate} — ${ev.verdict}`;
    tr.append(
      el('td', null, fmtTime(ev.ts)),
      el('td', null, ev.event),
      el('td', null, ev.phase ? String(ev.phase) : ''),
      el('td', null, detail),
      el('td', 'num', ev.duration != null ? fmtDur(ev.duration) : '')
    );
    tb.append(tr);
  }
}

tick();
setInterval(tick, 1500);
</script>
</body>
</html>
HTML
}

serve_stop() {
  [ -n "$SERVE_PID" ] || return 0
  kill "$SERVE_PID" 2> /dev/null || true
  wait "$SERVE_PID" 2> /dev/null || true
  SERVE_PID=""
  return 0
}

# Um trap so para os dois: Ctrl-C nao pode deixar cursor escondido nem servidor
# orfao segurando a porta.
cleanup_ui() {
  ui_stop
  serve_stop
}

# Ctrl-C manda SIGINT para o GRUPO inteiro: o engine morre, mas o bash so roda o
# trap depois que o comando corrente retorna. Com `trap cleanup_ui INT` (sem
# exit) o handler limpava a UI e o loop de ciclos SEGUIA — cada Ctrl-C matava o
# engine, o log saia vazio, o gate 0 dava vermelho e o ciclo era consumido em
# menos de um segundo. Quatro Ctrl-C torravam o orcamento inteiro de ciclos.
# Aqui o sinal encerra o run: e o unico veredito honesto para "o operador mandou
# parar".
on_interrupt() {
  local sig="${1:-INT}"
  trap - EXIT INT TERM
  # --attach e read-only por contrato: acompanha um run ALHEIO. Sincronizar o
  # estado daqui sobrescreveria o state.env desse run com os defaults desta
  # sessao, e o painel do dono passaria a ler lixo.
  if ! $ATTACH; then
    ST_RUN_STATUS="aborted"
    ST_ACTIVITY="interrompido pelo operador ($sig)"
    state_sync 2> /dev/null || true
  fi
  cleanup_ui
  echo ""
  fail "Interrompido pelo operador ($sig) — run encerrado."
  exit 130
}

# ---------------------------------------------------------------------------
# --attach — acompanhar um run JA em andamento
#
# Bash nao troca as funcoes de um processo vivo: um run que comecou continua
# rodando, ate o fim, o codigo com que subiu. Corrigir o painel no meio de um
# run so e possivel por fora — um segundo processo, com o codigo novo, lendo o
# mesmo .phases/ e republicando o que a tabela le.
#
# Read-only sobre o run: nao roda fase, nao chama engine, nao commita, nao
# escreve state.env nem messages.log. Sair do attach nao mexe no run.
# ---------------------------------------------------------------------------

attach_task_tally() {
  awk -F'|' '
    { t++; if ($3 == "done") d++; else if ($3 == "declared") k++ }
    END { printf "%d/%d concluidas, %d declaradas", d + 0, t + 0, k + 0 }
  ' "$UI_DIR/tasks.txt" 2> /dev/null || true
}

attach_run() {
  if [ ! -f "$MANIFEST" ]; then
    fail "--attach: nao ha run neste diretorio ($MANIFEST ausente)."
    fail "Rode o --attach no MESMO diretorio de trabalho do run que voce quer acompanhar."
    exit 1
  fi

  ui_load_state
  [ -n "${UIV_project:-}" ] && PROJECT_NAME="$UIV_project"
  [ -n "${UIV_engine:-}" ] && ENGINE="$UIV_engine"

  log "attach: run ${UIV_run_id:-?} (pid ${UIV_pid:-?}) — projeto $PROJECT_NAME"
  log "attach: republicando status por task a cada ${ATTACH_INTERVAL}s; Ctrl-C sai sem tocar no run"

  trap cleanup_ui EXIT
  trap 'on_interrupt INT' INT
  trap 'on_interrupt TERM' TERM
  ui_start

  local st pnum
  while :; do
    # "q Sair" no attach fecha so o attach: o run alheio nem fica sabendo.
    if $UI_ACTIVE && ui_panel_gone; then
      ui_panel_closed
      log "attach: painel fechado — o run segue sem ser tocado."
      break
    fi

    ui_load_state
    st="${UIV_run_status:-}"
    pnum="${UIV_phase_num:-0}"

    # Com painel, quem republica e o proprio pintor a cada ~3s. Sem painel
    # (nao-TTY, --no-ui) o attach continua util: republica e resume em texto.
    if ! $UI_ACTIVE; then
      ui_tasks_cache 2> /dev/null || true
      ui_infer_tasks "$pnum" "${UIV_stdout_log:-}" 2> /dev/null || true
      log "attach: fase ${pnum} · $(attach_task_tally) · ${UIV_activity:-$UI_G_NONE}"
    fi

    case "$st" in
      done | failed | aborted)
        log "attach: run $st — encerrando."
        break
        ;;
    esac

    # PID sumido = run morto sem publicar estado final (kill -9, terminal
    # fechado). Sem isso o attach ficaria desenhando um run que nao existe.
    if [ -n "${UIV_pid:-}" ] && [ "${UIV_pid}" -gt 0 ] 2> /dev/null \
      && ! kill -0 "$UIV_pid" 2> /dev/null; then
      warn "attach: processo ${UIV_pid} do run nao existe mais — encerrando."
      break
    fi

    sleep "$ATTACH_INTERVAL"
  done

  ui_stop
  return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

resolve_input_file() {
  if [ -n "$INPUT_FILE" ]; then
    return 0
  fi

  if [ -f ".spec/init/project-phases.md" ]; then
    INPUT_FILE=".spec/init/project-phases.md"
  elif [ -f ".spec/project-phases.md" ]; then
    INPUT_FILE=".spec/project-phases.md"
    warn "Usando .spec/project-phases.md (layout pre-init). O padrao atual e .spec/init/project-phases.md."
  else
    fail "Nenhum documento de fases encontrado."
    fail "Esperado .spec/init/project-phases.md (rode /init:project-phases) ou passe o caminho como argumento."
    exit 1
  fi
}

validate_input_format() {
  local top_level
  top_level=$(grep -cE '^## Phase [0-9]+: ' "$INPUT_FILE" || true)

  if [ "$top_level" -lt 1 ]; then
    fail "Contrato de formato violado: nenhum heading '## Phase N: <titulo>' em $INPUT_FILE"
    fail "ralph quebra o documento por esse heading. Corrija o documento antes de rodar."
    exit 1
  fi

  local malformed
  malformed=$(grep -E '^## Phase' "$INPUT_FILE" | grep -vE '^## Phase [0-9]+: ' || true)
  if [ -n "$malformed" ]; then
    fail "Contrato de formato violado: headings '## Phase' fora do formato '## Phase N: <titulo>':"
    printf '    %s\n' "${malformed//$'\n'/$'\n    '}"
    fail "Uma fase com heading torto some silenciosamente do run. Corrija antes de gastar tokens."
    exit 1
  fi

  log "Formato do input OK ($top_level fases declaradas)"
}

exclude_phases_dir() {
  local exclude_file
  exclude_file="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF '/.phases/' "$exclude_file" 2>/dev/null; then
    echo '/.phases/' >> "$exclude_file"
    log "Registrado /.phases/ em .git/info/exclude (nao mexe no .gitignore do projeto)"
  fi
}

# Laravel Sail: a suite roda DENTRO do container. Rodar `composer test` /
# `php artisan test` no host falha (sem PHP, sem banco, sem rede do compose).
# Ecoa o caminho do binario sail quando o projeto usa Sail.
detect_sail() {
  [ -f artisan ] || return 1
  if [ -x vendor/bin/sail ]; then
    echo "vendor/bin/sail"
    return 0
  fi
  # Sail declarado no composer.json mas vendor/ ainda nao instalado.
  if [ -f composer.json ] && grep -qF 'laravel/sail' composer.json; then
    echo "vendor/bin/sail"
    return 0
  fi
  return 1
}

# Containers de pe? O wrapper do sail imprime "Sail is not running." e sai != 0.
sail_running() {
  local out rc=0
  out=$("$SAIL_BIN" ps 2>&1) || rc=$?
  grep -qiF 'is not running' <<< "$out" && return 1
  [ "$rc" -ne 0 ] && return 1
  grep -qiE '(^|[[:space:]])(Up|running)([[:space:]]|$)' <<< "$out"
}

# O comando de teste invoca o sail? Olha o executavel (1o token), nao a string
# inteira: um caminho como /tmp/sail-fixture/test.sh nao usa sail.
test_cmd_uses_sail() {
  local first="${TEST_CMD%% *}"
  [ "$(basename -- "$first")" = "sail" ]
}

# Gate 2 so tem valor se rodar de verdade. Sail com containers parados falha
# toda fase e queima ciclos de correcao inuteis — aborta antes da 1a sessao.
check_sail_running() {
  [ -n "$SAIL_BIN" ] || return 0
  test_cmd_uses_sail || return 0

  if [ ! -x "$SAIL_BIN" ]; then
    fail "Laravel Sail detectado, mas $SAIL_BIN nao existe."
    fail "Rode a instalacao de dependencias do projeto (ex: composer install) antes."
    exit 1
  fi

  if ! sail_running; then
    fail "Laravel Sail detectado, mas os containers nao estao de pe."
    fail "A suite de testes (gate 2) roda dentro do container e falharia em toda fase."
    fail "Suba o ambiente antes de rodar o ralph:"
    fail "    $SAIL_BIN up -d"
    exit 1
  fi

  log "Sail: containers de pe"
}

# Alguns monorepos nao tem manifesto na raiz para a deteccao convencional, mas
# o plano gerado conhece a suite correta. Aceita apenas a declaracao explicita
# `RALPH_TEST_CMD='...'` (ou com aspas duplas), sem avaliar o Markdown como
# shell. Flag e ambiente continuam tendo precedencia sobre esse fallback.
declared_test_cmd() {
  [ -f "$INPUT_FILE" ] || return 1

  local command
  command=$(sed -n "s/.*RALPH_TEST_CMD='\(.*\)'.*/\1/p" "$INPUT_FILE" | head -n 1)
  if [ -z "$command" ]; then
    command=$(sed -n 's/.*RALPH_TEST_CMD="\(.*\)".*/\1/p' "$INPUT_FILE" | head -n 1)
  fi

  [ -n "$command" ] || return 1

  printf '%s\n' "$command"
}

resolve_test_cmd() {
  SAIL_BIN="$(detect_sail || true)"

  if [ -n "$TEST_CMD_FLAG" ]; then
    TEST_CMD="$TEST_CMD_FLAG"
    log "Gate 2 — comando de teste (--test-cmd): $TEST_CMD"
    check_sail_running
    return 0
  fi

  if [ -n "${RALPH_TEST_CMD:-}" ]; then
    TEST_CMD="$RALPH_TEST_CMD"
    log "Gate 2 — comando de teste (RALPH_TEST_CMD): $TEST_CMD"
    check_sail_running
    return 0
  fi

  local plan_test_cmd
  plan_test_cmd=$(declared_test_cmd || true)
  if [ -n "$plan_test_cmd" ]; then
    TEST_CMD="$plan_test_cmd"
    log "Gate 2 — comando de teste (declarado no plano): $TEST_CMD"
    check_sail_running
    return 0
  fi

  # Sail vem ANTES de composer/npm: num projeto Laravel dockerizado o host nao
  # tem PHP nem acesso ao banco, e `composer test` mentiria como gate.
  if [ -n "$SAIL_BIN" ]; then
    TEST_CMD="$SAIL_BIN test"
  elif [ -f composer.json ] && grep -qE '"test"[[:space:]]*:' composer.json; then
    TEST_CMD="composer test"
  elif [ -f artisan ]; then
    TEST_CMD="php artisan test"
  elif [ -f package.json ] && grep -qE '"test"[[:space:]]*:' package.json; then
    TEST_CMD="npm test"
  elif [ -f pytest.ini ] || { [ -f pyproject.toml ] && grep -qF '[tool.pytest' pyproject.toml; }; then
    TEST_CMD="pytest"
  elif [ -f go.mod ]; then
    TEST_CMD="go test ./..."
  elif [ -f Cargo.toml ]; then
    TEST_CMD="cargo test"
  fi

  if [ -n "$TEST_CMD" ]; then
    log "Gate 2 — comando de teste (detectado): $TEST_CMD"
    check_sail_running
  else
    warn "Gate 2 DESABILITADO: nenhum comando de teste resolvido."
    if [ "$VERIFY_MODE" = "off" ]; then
      warn "--no-verify tambem desligou o gate 3: NENHUMA validacao mecanica ativa."
    else
      warn "Passe --test-cmd '<cmd>' ou defina RALPH_TEST_CMD. O gate 3 (verificador) roda em toda fase."
    fi
  fi
}

preflight_checks() {
  if [[ "$ENGINE" != "codex" && "$ENGINE" != "claude" ]]; then
    fail "Engine invalida: $ENGINE. Use 'codex' ou 'claude'."
    exit 1
  fi

  if ! [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --from: '$FROM_PHASE'. Use um numero inteiro (ex: --from 5)."
    exit 1
  fi

  if ! [[ "$MAX_CYCLES" =~ ^[0-9]+$ ]] || [ "$MAX_CYCLES" -lt 1 ]; then
    fail "Valor invalido para --max-cycles: '$MAX_CYCLES'. Use um inteiro >= 1."
    exit 1
  fi

  if ! [[ "$MAX_RESCUES" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --max-rescues: '$MAX_RESCUES'. Use um inteiro >= 0 (0 desliga)."
    exit 1
  fi

  if ! [[ "$MAX_REPAIRS" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para --max-repairs: '$MAX_REPAIRS'. Use um inteiro >= 0 (0 desliga)."
    exit 1
  fi

  case "$REPAIR_MODE" in
    on|off) ;;
    *)
      fail "Valor invalido para RALPH_REPAIR: '$REPAIR_MODE'. Use on ou off."
      exit 1
      ;;
  esac

  # --no-repair e --max-repairs 0 sao o mesmo desligamento; normaliza para um
  # unico predicado (repair_enabled) em vez de checar dois lugares no loop.
  [ "$REPAIR_MODE" = "off" ] && MAX_REPAIRS=0
  [ "$RESCUE_MODE" = "off" ] && MAX_RESCUES=0

  local n
  for n in REPAIR_MAX_FILES REPAIR_MAX_TASKS; do
    if ! [[ "${!n}" =~ ^[0-9]+$ ]] || [ "${!n}" -lt 1 ]; then
      fail "Valor invalido para RALPH_${n}: '${!n}'. Use um inteiro >= 1."
      exit 1
    fi
  done

  if ! [[ "$HEARTBEAT_SECS" =~ ^[0-9]+$ ]]; then
    fail "Valor invalido para RALPH_HEARTBEAT: '$HEARTBEAT_SECS'. Use um inteiro >= 0 (0 desliga)."
    exit 1
  fi

  case "$VERIFY_MODE" in
    auto|always|off) ;;
    *)
      fail "Valor invalido para RALPH_VERIFY: '$VERIFY_MODE'. Use auto, always ou off."
      exit 1
      ;;
  esac

  case "$UI_MODE" in
    auto|panel|plain) ;;
    *)
      fail "Valor invalido para RALPH_UI: '$UI_MODE'. Use auto, panel ou plain."
      exit 1
      ;;
  esac

  # Verificacao e leitura + checklist contra o codigo real: le, compara, emite
  # uma linha por task. Nao escreve nada — modelo intermediario da conta.
  # No codex nao ha default seguro de modelo barato — so aplica se pedido.
  if [ -n "${RALPH_VERIFY_MODEL:-}" ]; then
    VERIFY_MODEL="$RALPH_VERIFY_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    VERIFY_MODEL="sonnet"
  fi

  # Conserto cirurgico e a UNICA etapa que escreve codigo com contexto minimo:
  # so a assinatura da falha, sem a fase e sem preambulo. E tambem a etapa que
  # decide, sozinha, se a causa se resolve escrevendo codigo (REPAIR_ABORT) — um
  # veredito que aborta a fase inteira. Patch cego e desistencia errada custam
  # muito mais do que a diferenca de modelo: aqui vale o mais forte.
  # Mesma regra do codex: sem default, so se pedido.
  if [ -n "${RALPH_REPAIR_MODEL:-}" ]; then
    REPAIR_MODEL="$RALPH_REPAIR_MODEL"
  elif [[ "$ENGINE" == "claude" ]]; then
    REPAIR_MODEL="opus"
  fi

  # Resgate: a sessao mais cara e a de maior autoridade do harness — reorganiza
  # implementacao e decide sobre teste existente. Mesma regra do conserto: sem
  # default no codex, so se pedido.
  if [ -n "${RALPH_RESCUE_MODEL:-}" ] && [ -z "$RESCUE_MODEL" ]; then
    RESCUE_MODEL="$RALPH_RESCUE_MODEL"
  elif [ -z "$RESCUE_MODEL" ] && [[ "$ENGINE" == "claude" ]]; then
    RESCUE_MODEL="opus"
  fi

  log "Modelos — implementacao: ${IMPL_MODEL:-default da CLI}; verificacao: ${VERIFY_MODEL:-default da CLI}; conserto: ${REPAIR_MODEL:-default da CLI}; resgate: ${RESCUE_MODEL:-default da CLI}"

  case "$TEST_SCOPE_MODE" in
    auto|full) ;;
    *)
      fail "Valor invalido para RALPH_TEST_SCOPE: '$TEST_SCOPE_MODE'. Use auto ou full."
      exit 1
      ;;
  esac

  case "$CAVEMAN_MODE" in
    off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra) ;;
    *)
      fail "Valor invalido para RALPH_CAVEMAN: '$CAVEMAN_MODE'. Use off, lite, full, ultra, wenyan-lite, wenyan, wenyan-full ou wenyan-ultra."
      exit 1
      ;;
  esac

  if [[ "$ENGINE" == "claude" && "$CAVEMAN_MODE" != "off" ]]; then
    log "Caveman — nivel '$CAVEMAN_MODE' nas sessoes de implementacao e conserto (verificador fica no formato normal)"
  fi

  if ! command -v "$ENGINE" &> /dev/null; then
    if [[ "$ENGINE" == "codex" ]]; then
      fail "codex CLI nao encontrado. Instale com: npm install -g @openai/codex"
    else
      fail "Claude Code CLI nao encontrado. Instale com: npm install -g @anthropic-ai/claude-code"
    fi
    exit 1
  fi

  # jq e dependencia dura: o engine claude emite NDJSON (stream-json) e todo
  # veredito — gate 0, TASK do gate 3, REPAIR_ABORT, RESCUE_BLOCKED, limite de
  # uso — sai de dentro desse stream. Extrair com grep/sed voltaria a depender
  # de escape de JSON, que foi exatamente o que quebrava antes.
  if [[ "$ENGINE" == "claude" ]] && ! command -v jq &> /dev/null; then
    fail "jq nao encontrado, e ele e obrigatorio para o engine claude."
    fail "Instale: apt install jq | brew install jq | dnf install jq"
    exit 1
  fi

  if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
    fail "Requer um repositorio git."
    exit 1
  fi

  resolve_input_file

  if [ ! -f "$INPUT_FILE" ]; then
    fail "Arquivo nao encontrado: $INPUT_FILE"
    exit 1
  fi

  validate_input_format
  exclude_phases_dir

  # Arvore limpa: 'git add -A' da primeira fase engoliria trabalho nao commitado.
  if [ -n "$(git status --porcelain)" ]; then
    fail "Arvore de trabalho suja. ralph commita por fase e engoliria suas mudancas."
    fail "Commite ou stashe antes de rodar:"
    git status --short | sed 's/^/    /'
    exit 1
  fi

  resolve_test_cmd

  success "Pre-checks OK (engine: $ENGINE, input: $INPUT_FILE)"
}

# ---------------------------------------------------------------------------
# Split + progresso
# ---------------------------------------------------------------------------

manifest_entries() { grep -v '^#' "$MANIFEST" || true; }

split_phases() {
  log "Quebrando $INPUT_FILE em fases..."

  local new_stamp old_stamp="" progress_backup=""
  # O stamp ignora o estado dos checkboxes: o ralph marca `[x]` no input ao
  # fechar cada fase (sync_input_checkboxes) e isso NAO e mudanca do documento.
  new_stamp="$(basename "$INPUT_FILE")@sha256:$(sed -E 's/^([[:space:]]*- )\[[xX]\]/\1[ ]/' "$INPUT_FILE" | sha256sum | cut -c1-12)"

  if [ -f "$MANIFEST" ]; then
    old_stamp=$(sed -n '1s/^# stamp: //p' "$MANIFEST")
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    progress_backup=$(cat "$PROGRESS_FILE")
  fi

  rm -rf "$PHASES_DIR"
  mkdir -p "$PHASES_DIR" "$LOG_DIR" "$PROMPT_DIR" "$UI_DIR"

  # events.jsonl e o historico DESTE run: zerado junto com o resto do .phases/.
  : > "$EVENTS_FILE"
  : > "$UI_MSG_FILE"

  # Progresso sobrevive entre execucoes, mas so vale para o MESMO input.
  if [ -n "$progress_backup" ]; then
    if [ -n "$old_stamp" ] && [ "$old_stamp" = "$new_stamp" ]; then
      printf '%s\n' "$progress_backup" > "$PROGRESS_FILE"
      log "Progresso anterior preservado (input inalterado)"
    else
      warn "O documento de fases mudou desde a ultima execucao — progresso zerado."
      warn "Fases marcadas como feitas pertenciam a outro plano."
    fi
  fi

  echo "# stamp: $new_stamp" > "$MANIFEST"

  local current_file=""
  local phase_count=0

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^##[[:space:]]+Phase[[:space:]]+([0-9]+):[[:space:]]*(.*)$ ]]; then
      phase_count=$((phase_count + 1))

      local phase_num="${BASH_REMATCH[1]}"
      local phase_title="${BASH_REMATCH[2]}"
      phase_title="${phase_title%"${phase_title##*[![:space:]]}"}"

      local slug
      slug=$(printf 'phase-%02d' "$phase_num")

      current_file="$PHASES_DIR/${slug}.md"
      echo "$line" > "$current_file"
      echo "${slug}.md|${phase_num}|${phase_title}" >> "$MANIFEST"
      continue
    fi

    # Heading nivel 2 que nao e "## Phase N:" (ex: "## Open Questions"):
    # encerra a captura para nao vazar a secao para a ultima fase.
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      current_file=""
      continue
    fi

    if [ -n "$current_file" ]; then
      echo "$line" >> "$current_file"
    fi
  done < "$INPUT_FILE"

  success "$phase_count fases extraidas"
}

is_phase_done() {
  local phase_file="$1"
  [ -f "$PROGRESS_FILE" ] && grep -qxF "$phase_file" "$PROGRESS_FILE"
}

mark_phase_done() {
  echo "$1" >> "$PROGRESS_FILE"
}

# --from N tambem limpa do progresso as fases >= N (re-rodar de proposito).
apply_from_override() {
  [ "$FROM_PHASE" -gt 1 ] || return 0
  [ -f "$PROGRESS_FILE" ] || return 0

  local kept="" file num _rest
  while IFS='|' read -r file num _rest; do
    if [ "$num" -lt "$FROM_PHASE" ] && grep -qxF "$file" "$PROGRESS_FILE"; then
      kept+="$file"$'\n'
    fi
  done < <(manifest_entries)

  printf '%s' "$kept" > "$PROGRESS_FILE"
  log "--from $FROM_PHASE: progresso das fases >= $FROM_PHASE limpo"
}

# ---------------------------------------------------------------------------
# Prompts (auto-contidos — cada sessao e nova)
# ---------------------------------------------------------------------------

# O unico sinal de progresso POR TASK que existe durante a sessao.
#
# O engine roda opaco: nenhum evento diz em que task ele esta, e os gates so
# falam no fim da fase. Sem isso o operador olha a tabela por 20 minutos e ve
# tudo Pendente enquanto o run trabalha. Marcar e barato e reversivel.
#
# Nao vira veredito em lugar nenhum: o gate 3 confere task a task depois e
# sobrescreve o checkbox. E `.phases/` esta em .git/info/exclude, entao marcar
# nao muda a assinatura da arvore nem faz o gate 1 achar que a sessao escreveu
# codigo.
progress_marking_rules() {
  local phase_file="$1"
  [ -n "$phase_file" ] || return 0

  cat <<MARK

## Marque o progresso enquanto trabalha (obrigatorio)
O arquivo desta fase e \`$PHASES_DIR/$phase_file\`.
Assim que uma task estiver implementada E com os testes dela (quando a task
listar algum) passando, edite
esse arquivo e troque \`- [ ]\` por \`- [x]\` NA LINHA daquela task — uma de
cada vez, no momento em que ela fecha.
- Nao marque antecipado, nao marque em lote no fim da sessao.
- Nao altere mais nada nesse arquivo: so o caractere do checkbox.
- Marcar nao substitui verificacao: um verificador independente confere task a
  task depois e o veredito dele vence a marcacao.
MARK
}

context_preamble() {
  local phase_file="${1:-}"

  cat <<'PREAMBLE'
## Descubra a stack e as convencoes antes de escrever codigo
Este projeto pode ser de qualquer linguagem ou framework. NAO assuma nenhuma
stack. Antes de comecar, LEIA os que existirem, nesta ordem:
1. AGENTS.md ou CLAUDE.md — convencoes, comandos e regras do projeto
2. .spec/init/project-description.md — descricao geral do projeto
3. .spec/init/user-stories.md — user stories
4. .spec/init/database-schema.md — modelo de dados
5. os documentos citados no proprio texto da fase (ex: SPEC.md/PLAN.md da feature)
Use os comandos de build, teste e execucao definidos por esses documentos e pelo
tooling ja presente no repositorio. Se o projeto tiver uma ferramenta de memoria
ou contexto configurada, use-a para entender o historico.
PREAMBLE

  # O gate 2 roda ESTE comando. Se o agente rodar outro (ex: `php artisan test`
  # no host de um projeto Sail), ele ve verde e o gate ve vermelho.
  progress_marking_rules "$phase_file"

  if [ -n "$TEST_CMD" ]; then
    echo
    echo "## Comando de teste deste projeto"
    echo "Rode a suite SEMPRE com:"
    echo
    echo "    $TEST_CMD"
    echo
    echo "Este e o comando exato usado para validar a fase. Nao use outro runner"
    echo "nem rode os testes por fora dele."
    echo
    echo "Durante a fase, rode-o ESCOPADO — passe o caminho do arquivo de teste"
    echo "(ex: '$TEST_CMD caminho/do/Teste.ext', ou o filtro equivalente do"
    echo "runner). A suite inteira e cara e o ralph so a roda no fim da spec."
    if [ -n "$SAIL_BIN" ]; then
      echo "O projeto usa Laravel Sail: artisan, composer, php e testes rodam DENTRO"
      echo "do container, via '$SAIL_BIN <cmd>'. Nunca rode essas ferramentas no host."
    fi
  fi
}

# Regua visual unica: o executor se corrige contra ela e o verificador reprova
# por ela. Sem artboard, "os seletores existem" era a unica prova — e uma tela
# crua com os data-test certos passava como DONE. So entra defeito que se
# aponta na captura; gosto nao reprova (evita ciclo de correcao por estetica).
ui_defect_rubric() {
  cat <<'RUBRIC'
### Defeitos visuais objetivos
Cada item abaixo, visivel na captura (computador OU celular), e defeito:
1. Rotulo repetido: titulo e label do mesmo campo dizendo a mesma coisa.
2. Texto cortado, sobreposto ou vazando do conteiner; elemento escondido
   atras de outro.
3. Celular: rolagem horizontal, conteudo espremido ou ilegivel.
4. Hierarquia invertida: titulo menor ou mais fraco que o texto abaixo dele;
   o valor principal da tela (total, resultado, KPI) sem destaque.
5. Controle cru: input/select/botao sem o estilo do design system do projeto,
   ou componente que destoa das telas irmas.
6. Desalinhamento: valores/rotulos equivalentes fora do mesmo eixo;
   espacamento irregular entre blocos equivalentes.
7. Layout quebrado: bloco orfao sozinho numa linha de grade, faixa vazia larga
   no meio do conteudo, card dentro de card com moldura dupla.
8. Parede de texto: explicacao longa em paragrafos corridos, sem blocos,
   listas ou destaque que permitam escanear.
9. Estado sem tratamento: zero/vazio/carregando/erro exibindo lixo (NaN,
   undefined, [object Object], placeholder).
10. Contraste ilegivel: texto claro sobre fundo claro (ou escuro sobre escuro).
NAO e defeito: preferencia de cor, estilo ou escolha de componente fora desta
lista.
RUBRIC
}

# Secao de design do executor, so em fase com `Tela:`. Fase de logica recebe o
# prompt de sempre. Carrega a regua e a ordem de se fotografar antes de
# entregar: sem olhar a tela, o executor implementa no escuro.
ui_design_brief() {
  local phase_file="$1"
  local screens
  screens="$(phase_screen_tasks "$phase_file")"
  [ -n "$screens" ] || return 0

  local cmd="$UI_SHOT_CMD"
  [ -n "$cmd" ] || cmd="$(detect_ui_shot_cmd)"
  local shots="$SELFCHECK_DIR/${phase_file%.md}"

  echo
  echo "## Tasks de tela desta fase"
  echo "Estas tasks mudam o que o usuario ve. O gate 3 fotografa cada rota no"
  echo "computador e no celular e reprova a fase por qualquer defeito da regua abaixo."
  local pos route sel target theme
  while IFS='|' read -r pos route sel target theme; do
    [ -n "$pos" ] || continue
    if [ -n "$target" ]; then
      echo "- TASK $pos — rota \`$route\` — alvo \`$target\`"
    else
      echo "- TASK $pos — rota \`$route\` — sem artboard: siga a \`Referencia visual:\` e o \`Layout:\` da task (ausentes => a tela existente mais proxima da mesma area)"
    fi
  done <<< "$screens"
  cat <<'BRIEF'

### Antes de escrever a tela
1. Abra o alvo (Read abre imagem) ou a tela de referencia e reuse os mesmos
   componentes, tokens, espacamentos e padroes do design system do projeto.
   Nao invente estilo novo e nao entregue marcacao crua.
2. Se o ambiente oferecer skill ou agente de UI/design (ex.: frontend-design,
   ui-ux-pro-max, um agente de frontend do projeto), use-o nesta tela.
3. Decida o layout antes do markup: o foco principal, o que agrupa com o que,
   o que fica em destaque e como a tela empilha em 400px de largura.

BRIEF
  ui_defect_rubric
  echo
  echo "### Autocaptura (obrigatoria antes de encerrar)"
  if [ -n "$cmd" ]; then
    echo "Fotografe cada tela voce mesmo, no computador e no celular:"
    echo
    echo "    mkdir -p $shots"
    while IFS='|' read -r pos route sel target theme; do
      [ -n "$pos" ] || continue
      echo "    RALPH_UI_VIEWPORT=desktop $cmd '$route' $shots/task-$pos.png '$sel'${theme:+ $theme}"
      echo "    RALPH_UI_VIEWPORT=mobile $cmd '$route' $shots/task-$pos-mobile.png '$sel'${theme:+ $theme}"
    done <<< "$screens"
    echo
    echo "Abra as fotos com Read, procure cada defeito da regua, corrija e fotografe"
    echo "de novo ate nao sobrar nenhum. Grave SO em \`$SELFCHECK_DIR/\`: \`$EVIDENCE_DIR/\`"
    echo "e do ralph, refeita por ele no gate 3."
  else
    echo "Nenhum comando de captura configurado (RALPH_UI_SHOT_CMD ou"
    echo "scripts/ralph-ui-shot.{mjs,js,sh,py}): nao ha como se fotografar. Revise a"
    echo "tela contra a regua lendo o codigo com atencao redobrada."
  fi
}

build_impl_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior implementando uma fase deste projeto."
    echo
    context_preamble "$phase_file"
    ui_design_brief "$phase_file"
    cat <<'TASK'

## Sua tarefa agora
Implemente COMPLETAMENTE a fase descrita abaixo.

Para cada item:
1. Implemente o codigo completo (nao deixe TODOs ou placeholders)
2. Crie EXATAMENTE os testes listados no campo `Testes:` da task, seguindo o
   framework de testes do projeto. Task com `Testes: none` NAO leva teste — a
   verificacao dela e por inspecao do codigo contra os acceptance criteria
3. Rode SO os testes daquela task (o runner do projeto aceita caminho ou
   filtro). A suite completa e cara: rodar ela a cada item queima minutos e
   memoria da maquina
4. Se um teste falhar, corrija o codigo e rode novamente
5. So passe pro proximo item quando os testes DA TASK passarem
6. NAO rode a suite completa. Quem a roda e o ralph, e so no fim da spec —
   a ultima fase do documento e o gate da suite inteira. No meio do caminho o
   ralph cobra apenas os testes que esta fase alterou

## Regras obrigatorias
- Use SEMPRE os comandos, o runner de testes e as ferramentas ja adotados pelo
  projeto (nao introduza uma stack ou ferramenta nova por conta propria)
- NAO escreva teste alem do que a task lista. Teste extra "por seguranca" —
  getter, cast, relacao declarada, "a classe existe", label cosmetico, default
  de config, mesmo ramo reafirmado em outra camada — e ruido: reprova revisao e
  nao ajuda gate nenhum. Se um comportamento sem cobertura te preocupa, anote
  no relatorio final em vez de criar o teste por conta propria
- Testes e fixtures/factories devem criar todas as dependencias necessarias
- Nomes de classes, arquivos e metodos devem seguir EXATAMENTE o que esta descrito
- Nao pule nenhum item marcado com [ ]
- Nao pare, reinicie nem derrube containers/servicos do ambiente para "liberar
  recurso": o gate 2 roda os testes depois de voce e um servico fora do ar
  interrompe o run inteiro
- Fase inteira com `Testes: none` em todas as tasks e resultado CORRETO, nao
  lacuna: quer dizer que a fase e mecanica. Nao invente teste para ter o que
  mostrar
- Ao final, valide que os testes DESTA fase passam

## Fase a implementar
TASK
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de correcao: auto-contido. Carrega a fase inteira + a causa REAL
# da falha (nunca "os testes falharam" generico).
build_fix_prompt() {
  local phase_file="$1" cycle="$2" gate="$3" cause="$4"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.cycle-${cycle}.txt"

  {
    echo "Voce e um desenvolvedor senior corrigindo uma fase parcialmente implementada."
    echo
    context_preamble "$phase_file"
    ui_design_brief "$phase_file"
    cat <<'INTRO'

## Situacao
Uma sessao anterior tentou implementar a fase abaixo e NAO passou na verificacao.
Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo atual
antes de mudar qualquer coisa.

## Regras obrigatorias
- Corrija APENAS o que falta. Nao reimplemente o que ja esta correto e testado.
- Nao deixe TODOs, placeholders ou testes pulados.
- Rode ao final os testes desta fase (por caminho ou filtro) e garanta que
  passam. Nao rode a suite completa: o ralph a roda no fim da spec.
- Nao crie teste que a fase nao pediu para "cobrir mais": teste extra nao fecha
  gate nenhum e sobra no repositorio.
INTRO
    echo
    echo "## Motivo da falha ($gate)"
    echo '```'
    echo "$cause"
    echo '```'
    echo
    echo "## Fase a completar"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de conserto cirurgico: o OPOSTO do fix. Nao carrega preambulo de
# contexto nem a fase — so a assinatura da falha. Prompt largo e o que faz o
# modelo reexplorar o projeto inteiro para consertar uma assertion.
build_repair_prompt() {
  local phase_file="$1" cycle="$2" round="$3" gate="$4" signature="$5"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.repair-${cycle}-${round}.txt"

  {
    cat <<'INTRO'
Voce e um desenvolvedor senior fazendo UMA correcao cirurgica.

Nao explore o projeto. Nao refatore. Nao reimplemente nada que ja funciona.
Corrija exatamente o erro abaixo e nada mais.
INTRO
    echo
    echo "## Erro ($gate)"
    echo '```'
    printf '%s\n' "$signature"
    echo '```'
    echo
    cat <<'RULES'
## Regras obrigatorias
- Mexa apenas nos arquivos necessarios para esse erro.
- Nao crie teste novo, nao apague nem pule teste existente, nao mude o comando
  de teste do projeto.
- Nao deixe TODO nem placeholder.
- Nao mude configuracao, dependencia ou versao de ferramenta para "fazer passar".
RULES
    if [ -n "$TEST_CMD" ]; then
      echo "- Rode \`$TEST_CMD\` ao final e confirme que passa antes de terminar."
    else
      echo "- Rode o comando de teste do projeto ao final e confirme que passa."
    fi
    guard_mandate
    cat <<'ABORT'
- Se a causa NAO estiver clara no erro acima, ou se o conserto exigir mudar
  varios arquivos ou reimplementar a funcionalidade, PARE sem editar nada e
  responda exatamente uma linha:
  REPAIR_ABORT: <motivo em uma frase>
  Desistir aqui e barato e correto — quem assume a fase depois recebe o
  contexto completo. Um patch as cegas custa mais caro do que desistir.
ABORT
  } > "$prompt_file"

  echo "$prompt_file"
}

# Prompt de resgate: o OPOSTO do conserto cirurgico. A fase travou justamente
# porque ninguem tinha contexto nem autoridade suficientes — entao aqui vai
# TUDO: preambulo, a fase inteira, o motivo do travamento, o veredito bruto do
# gate, a desistencia do conserto verbatim e o diff do trabalho parcial.
build_rescue_prompt() {
  local phase_file="$1" round="$2" reason="$3" gate="$4" cause="$5"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.rescue-${round}.txt"

  {
    echo "RALPH_RESCUE"
    echo
    echo "Voce e um engenheiro senior assumindo uma fase que TRAVOU."
    echo
    context_preamble "$phase_file"
    ui_design_brief "$phase_file"
    cat <<'INTRO'

## Situacao
Esta fase ja passou por ciclo(s) de correcao e por conserto(s) cirurgico(s) e
continua vermelha. Repetir o caminho das sessoes anteriores chega ao mesmo
veredito: elas trabalhavam com autoridade estreita — corrigir "o que falta" e
patchar o arquivo da assinatura. Voce tem autoridade maior (abaixo) e a
obrigacao de descobrir POR QUE aquele caminho nao fecha, antes de escrever
qualquer linha.

Voce esta numa sessao nova: nao tem memoria do que foi feito. Leia o codigo
atual e o diff do trabalho parcial antes de mudar qualquer coisa.
INTRO
    echo
    echo "## Por que a fase parou"
    printf '%s\n' "$reason"
    if [ -n "$REPAIR_ABORT_WHY" ]; then
      echo
      echo "## Desistencia do conserto cirurgico (verbatim)"
      echo '```'
      printf '%s\n' "$REPAIR_ABORT_WHY"
      echo '```'
      echo "Essa desistencia e uma PISTA, nao um veredito final: o conserto so"
      echo "podia mexer no arquivo da assinatura. Voce pode mexer em mais."
    fi
    if [ -n "$cause" ]; then
      echo
      echo "## Veredito do ultimo gate (${gate:-?})"
      echo '```'
      printf '%s\n' "$cause" | head -n 60
      echo '```'
    fi

    local dirty diff_txt
    dirty="$(git status --porcelain 2> /dev/null | head -n 40 || true)"
    if [ -n "$dirty" ]; then
      echo
      echo "## Trabalho parcial na arvore (nao commitado)"
      echo '```'
      printf '%s\n' "$dirty"
      echo '```'
      diff_txt="$(git --no-pager diff HEAD 2> /dev/null | head -n 400 || true)"
      if [ -n "$diff_txt" ]; then
        echo
        echo "### git diff HEAD (truncado em 400 linhas)"
        echo '```diff'
        printf '%s\n' "$diff_txt"
        echo '```'
      fi
      echo "Esse trabalho e seu ponto de partida, nao um contrato: mantenha o que"
      echo "estiver certo, reorganize ou descarte o que estiver no caminho."
    fi

    cat <<'RULES'

## O que voce PODE fazer (e as sessoes anteriores nao podiam)
- Reorganizar a implementacao entre arquivos e camadas: mover a regra para outro
  ponto do fluxo, trocar a ordem de validacao, extrair ou unir classe/metodo —
  desde que os acceptance criteria da fase continuem satisfeitos.
- Ajustar teste EXISTENTE que passou a contradizer o comportamento que a fase
  exige (ex.: teste que fixa a ordem antiga de um erro que a fase muda). Essa e
  a UNICA hipotese de encostar em teste que ja existia.

## O que continua PROIBIDO — sem excecao
- Afrouxar teste para ficar verde: apagar, pular (skip/incomplete/xfail/only),
  comentar, renomear para fora do runner, trocar assert por assert mais fraco,
  encolher dataset, ou mudar o comando/config de teste do projeto.
- Mudar dependencia, versao de ferramenta ou configuracao de ambiente para
  "fazer passar".
- Deixar TODO, placeholder, mock de conveniencia ou codigo morto.
- Criar teste que a fase nao pediu. Teste cobre regra de negocio com ramificacao,
  autorizacao (quem pode e quem NAO pode), contrato de borda, invariante de dado
  e bug corrigido — nunca getter, cast, relacao declarada, "a classe existe",
  label cosmetico, default de config ou o mesmo ramo reafirmado noutra camada.
  Task com `Testes: none` NAO leva teste.

## Se mexer em teste existente, e obrigatorio declarar
No fim da resposta, uma linha por teste alterado:
  TESTE ALTERADO: <arquivo> — <o que ele fixava> -> <o que a fase exige agora> — <por que o antigo ficou errado>
Alteracao de teste sem essa linha e lida como teste afrouxado e reprova a fase.
RULES
    guard_mandate
    cat <<'BLOCKED'

## Se a fase for impossivel como esta escrita
Se o bloqueio for contradicao da PROPRIA especificacao — a fase exige A, outra
regra ja acordada do projeto exige nao-A, e nenhuma implementacao honesta
satisfaz as duas — NAO force e NAO escolha um lado sozinho. Pare sem editar
nada e responda exatamente uma linha:
  RESCUE_BLOCKED: <o conflito em uma frase, citando os dois lados>
Essa decisao e humana. Desistir aqui encerra a fase na hora, sem gastar outra
sessao — e e a resposta certa quando o conflito e de especificacao.

Guarda obsoleta NAO e conflito de especificacao: e fatia deixada pela metade, e
o mandato acima manda voce fechar. So declare RESCUE_BLOCKED por guarda depois de
provar, com o commit na mao, que os dois lados sao decisoes VIVAS em conflito.
BLOCKED
    if [ -n "$TEST_CMD" ]; then
      echo "- Ao final, rode os testes desta fase e confirme que passam. A suite"
      echo "  inteira (\`$TEST_CMD\`) quem roda e o ralph, logo depois de voce."
    else
      echo "- Ao final, rode os testes desta fase e confirme que passam."
    fi
    echo
    echo "## Fase a entregar"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

build_verify_prompt() {
  local phase_file="$1" cycle="$2"
  local prompt_file="$PROMPT_DIR/${phase_file%.md}.verify-${cycle}${GATE_TAG}.txt"

  {
    cat <<'VERIFY'
RALPH_VERIFY

Voce e um verificador independente. NAO escreva, edite ou crie nenhum arquivo.
Seu unico trabalho e ler o codigo real e dizer o que esta feito e o que nao esta.

Para CADA task marcada com `- [ ]` ou `- [x]` na fase abaixo, na ordem em que
aparecem, confira os acceptance criteria contra o codigo real (arquivos, classes,
testes, rotas, migrations — o que a task exigir) e emita EXATAMENTE UMA linha:

TASK <n>: DONE — <evidencia: arquivo:linha[; arquivo:linha] ou caminho da captura .png>
TASK <n>: INCOMPLETE — <o que falta>

Regras:
- <n> e a POSICAO da task na fase: 1 para a primeira, 2 para a segunda, e assim
  por diante. Se a task tiver rotulo proprio no texto (ex.: `T33 —`), IGNORE o
  numero do rotulo — use sempre a posicao.
- Uma linha TASK para cada task, sem excecao, sem agrupar.
- Nao repita um indice e nao pule nenhum: exatamente uma linha por task, na
  ordem, sem resumo nem repeticao do bloco no final.
- Nao emita nenhum outro texto alem das linhas TASK.
- Todo DONE carrega prova: `TASK <n>: DONE — <arquivo:linha>` apontando o
  trecho que satisfaz o acceptance criteria (varios separados por `;`), ou o
  caminho da captura .png nas tasks com tela. DONE sem `— evidencia` e
  tratado como NAO verificado e reprova a fase.
- Codigo ausente, TODO ou placeholder => INCOMPLETE.
- Artefato derivado (CSS/JS compilado, bundle, asset versionado) citado nos
  acceptance criteria: confira que o artefato reflete a fonte — fonte alterada
  com artefato antigo => INCOMPLETE.
- Teste: cobre so o que a task LISTA no campo `Testes:`. Teste listado e que nao
  existe (ou nao passa) => INCOMPLETE. Task com `Testes: none` => verifique os
  acceptance criteria lendo o codigo real; ausencia de teste NAO e motivo de
  INCOMPLETE nela. Nunca exija teste que a task nao pediu.
- IGNORE o estado do checkbox. `- [x]` e declaracao de quem implementou, nao
  prova: uma task marcada pode estar incompleta e uma task nao marcada pode
  estar pronta. So o codigo real decide.
- Na duvida, INCOMPLETE.
VERIFY
    if [[ "$ENGINE" == "codex" ]]; then
      cat <<'CODEX_VERIFY'
- No Codex, inspecione somente com comandos de leitura (`rg`, `sed`, `git
  diff`, `git status`) dentro do sandbox read-only. Nao crie, edite, mova ou
  apague arquivos; nao rode testes nem comandos que alterem estado. A suite ja
  foi executada pelo orquestrador no gate 2.
CODEX_VERIFY
    else
      cat <<'CLAUDE_VERIFY'
- Voce NAO executa comandos: esta sessao so le (Read/Glob/Grep). A suite de
  testes ja foi executada pelo orquestrador antes de voce. Julgue pelo codigo
  real e pelos arquivos de evidencia listados — nunca pelo relato de quem
  implementou, nunca pelo checkbox, nunca por "parece completo".
CLAUDE_VERIFY
    fi
    # Verificacao escopada (revalidacao entre rounds de conserto cirurgico): as
    # POSICOES continuam as originais da fase. Renumerar de 1..k e o caminho
    # curto para o bug de indice que ja custou uma fase reprovada de graca.
    if [ -n "$VERIFY_ONLY_IDX" ]; then
      echo
      echo "## Escopo desta verificacao"
      echo "As demais tasks desta fase JA foram confirmadas nesta rodada e nao"
      echo "precisam ser reverificadas. Verifique APENAS as tasks nas posicoes:"
      echo "  $VERIFY_ONLY_IDX"
      echo "Esta instrucao SUBSTITUI a regra 'uma linha TASK para cada task':"
      echo "aqui e uma linha TASK para cada task DO ESCOPO, e nenhuma alem delas."
      echo "Use o numero da POSICAO ORIGINAL na fase — nao renumere, nao comece do 1."
    fi
    # Evidencia visual: capturas feitas pelo ralph (gate3_capture_ui_evidence)
    # antes desta sessao. O verificador le imagem com Read e compara com o
    # alvo — e a unica prova que nasce fora do relato do implementador.
    if [ -n "$UI_SCREEN_TASKS" ]; then
      echo
      echo "## Evidencia visual (produzida pelo orquestrador, fora da sessao de implementacao)"
      echo "Para cada task abaixo, abra com Read as DUAS CAPTURAS (computador e celular)"
      echo "e, quando houver, o ALVO. Compare estrutura, hierarquia, tokens (superficies,"
      echo "acento, tipografia), estados e textos visiveis. Divergencia que o usuario"
      echo "notaria => INCOMPLETE, dizendo O QUE difere. Task com tela so e DONE citando"
      echo "o caminho da captura."
      local pos route sel target theme
      while IFS='|' read -r pos route sel target theme; do
        [ -n "$pos" ] || continue
        echo "- TASK $pos — rota \`$route\`${theme:+ (tema: $theme)} — seletores confirmados na pagina pela captura: \`$sel\`"
        [ -n "$target" ] && echo "  Se a task disser que a tela NAO tem artboard proprio e segue o padrao de outra, compare com o alvo SO tokens, tipografia, cabecalho de tabela, selos e layout de coluna — nunca conteudo, abas ou dados do desenho."
        echo "  captura: \`$EVIDENCE_DIR/${phase_file%.md}/task-${pos}.png\`"
        echo "  captura celular: \`$EVIDENCE_DIR/${phase_file%.md}/task-${pos}-mobile.png\`"
        [ -n "$target" ] && echo "  alvo:    \`$target\`"
      done <<< "$UI_SCREEN_TASKS"
      echo
      ui_defect_rubric
      echo "Com ou sem alvo, qualquer defeito da regua visivel numa das capturas =>"
      echo "INCOMPLETE, nomeando o defeito e onde ele aparece. Duvida sobre GOSTO nao"
      echo "reprova; duvida sobre um defeito da regua, sim."
    fi
    echo
    echo "## Fase a verificar"
    cat "$PHASES_DIR/$phase_file"
  } > "$prompt_file"

  echo "$prompt_file"
}

# ---------------------------------------------------------------------------
# Logs do engine — stdout (resposta final) e stderr (progresso) SEPARADOS
# ---------------------------------------------------------------------------

# Caminho do log de stderr que acompanha um log de stdout.
stderr_log_for() {
  local log_file="$1"
  echo "${log_file%.log}.stderr.log"
}

# Caminho do texto legivel extraido de um log de stdout.
engine_text_for() {
  local log_file="$1"
  echo "${log_file%.log}.text"
}

# Materializa o texto da resposta do engine a partir do stdout.
#
# O claude emite NDJSON (--output-format stream-json): a resposta do modelo vive
# dentro de `.result` do evento final, com \n e aspas escapados. Todo consumidor
# semantico — `TASK <n>: DONE`, REPAIR_ABORT, RESCUE_BLOCKED, HEAL_ABORT — le o
# arquivo que esta funcao escreve, NUNCA o NDJSON cru: casar esses marcadores no
# JSON escapado e o que exigia os `[^"\\]*` de antes, que cortavam a mensagem
# no primeiro caractere escapado.
#
# Fallbacks em cascata, porque o log pode estar incompleto (engine morto no
# meio): evento result -> textos de assistant -> o proprio arquivo. O codex ja
# emite texto puro e so e copiado.
engine_materialize_text() {
  local log_file="$1"
  local out tmp
  out="$(engine_text_for "$log_file")"
  tmp="$out.tmp.$$"

  [ -f "$log_file" ] || { : > "$out" 2> /dev/null; return 0; }

  if [[ "$ENGINE" != "claude" ]]; then
    cp -f "$log_file" "$out" 2> /dev/null || : > "$out"
    return 0
  fi

  # -R + fromjson?: uma linha truncada (engine morto no meio da escrita) nao
  # pode abortar a extracao das linhas boas que vieram antes.
  jq -R -r 'fromjson? | select(.type == "result") | .result // empty' \
    "$log_file" > "$tmp" 2> /dev/null || : > "$tmp"

  if [ ! -s "$tmp" ]; then
    jq -R -r 'fromjson? | select(.type == "assistant")
              | .message.content[]? | select(.type == "text") | .text // empty' \
      "$log_file" > "$tmp" 2> /dev/null || : > "$tmp"
  fi

  # Nem result nem assistant: o log nao e o NDJSON esperado (CLI antiga, erro
  # de invocacao). Melhor entregar o bruto do que entregar vazio e cegar os
  # gates — quem julga formato e o gate 0.
  [ -s "$tmp" ] || cp -f "$log_file" "$tmp" 2> /dev/null || : > "$tmp"

  mv -f "$tmp" "$out" 2> /dev/null || rm -f "$tmp" 2> /dev/null
  return 0
}

# Ultima acao observavel do engine, lida AO VIVO do NDJSON enquanto a sessao
# roda. E o que o painel mostra em "AO VIVO": ferramenta + alvo, nao byte count.
engine_last_action() {
  local log_file="$1"
  [[ "$ENGINE" == "claude" ]] || return 0
  [ -s "$log_file" ] || return 0

  # So o rabo do arquivo: o log de uma fase longa chega a dezenas de MB, e
  # relê-lo inteiro a cada frame do painel (~3s) fritaria a CPU.
  tail -n 40 "$log_file" 2> /dev/null | jq -R -r '
    fromjson?
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use")
    | .name as $n
    | (.input.file_path // .input.path // .input.command // .input.pattern
       // .input.description // "") as $t
    | if ($t | length) > 0 then "\($n) \($t)" else $n end' 2> /dev/null \
    | tail -n 1 || true
}

# Quantas ferramentas o engine ja usou nesta sessao. Prova de vida honesta:
# substitui a contagem de bytes, que com --output-format json ficava em 0 do
# inicio ao fim e fazia o painel anunciar "engine em silencio".
engine_action_count() {
  local log_file="$1"
  [[ "$ENGINE" == "claude" ]] || { echo 0; return 0; }
  local n
  n=$(grep -c '"type":"tool_use"' "$log_file" 2> /dev/null) || true
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

# Arquivos que o engine ESCREVEU nesta sessao, extraidos do stream.
#
# Diferente de `git status`: aqui a prova e o ato de escrever, nao a existencia
# do arquivo. Era essa a confusao que fazia uma task marcar ~100% porque o
# arquivo que ela cita ja existia no repo antes do run comecar.
engine_written_files() {
  local log_file="$1"
  [[ "$ENGINE" == "claude" ]] || return 0
  [ -s "$log_file" ] || return 0

  jq -R -r '
    fromjson?
    | select(.type == "assistant")
    | .message.content[]?
    | select(.type == "tool_use")
    | select(.name == "Edit" or .name == "Write" or .name == "NotebookEdit"
             or .name == "MultiEdit")
    | .input.file_path // .input.notebook_path // empty' \
    "$log_file" 2> /dev/null | awk '!seen[$0]++' || true
}

# Tail para DIAGNOSTICO (GATE_CAUSE): junta os dois streams porque o erro real
# do engine costuma sair no stderr. Nunca use isto para decidir gate.
#
# Mostra o TEXTO extraido, nao o NDJSON: 40 linhas de eventos JSON nao dizem
# nada a quem le o relatorio, e era o que o prompt de correcao recebia.
engine_tail() {
  local log_file="$1" lines="${2:-40}"
  local err_log txt
  err_log="$(stderr_log_for "$log_file")"
  txt="$(engine_text_for "$log_file")"

  if [ -s "$txt" ]; then
    tail -n "$lines" "$txt" 2>/dev/null || true
  else
    tail -n "$lines" "$log_file" 2>/dev/null || true
  fi

  if [ -s "$err_log" ]; then
    echo "--- stderr do engine (progresso, nao e veredito) ---"
    tail -n "$lines" "$err_log" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Assinatura de falha — o insumo do conserto cirurgico
#
# GATE_CAUSE existe para o humano: leva `tail -n 200` do log de teste porque um
# dev precisa do contexto ao redor. Prompt de conserto e outra coisa: 200 linhas
# de saida de suite sao ruido que empurra o modelo a reexplorar o projeto.
#
# Agnostico de runner por construcao. Em vez de um ramo por framework (que
# quebra na proxima versao do pest/vitest/pytest), casa os MARCADORES que todos
# eles compartilham — cabecalho de falha, diff de assertion, referencia
# arquivo:linha — e deduplica. Sem marcador nenhum => sem assinatura => a falha
# NAO e reparavel (fail-closed), e o ciclo completo assume.
# ---------------------------------------------------------------------------

# Arquivos-fonte citados na assinatura. Serve de insumo e de medida de escopo:
# uma falha que aponta o projeto inteiro nao e conserto cirurgico.
REPAIR_FILES=""
REPAIR_SIGNATURE=""

# extract_failure_signature <log> [max_linhas]
#
# Publica em REPAIR_SIGNATURE e REPAIR_FILES (globais, nao stdout): command
# substitution roda em subshell e as duas variaveis morreriam com ela.
#   rc 0 = assinatura extraida   rc 1 = nada localizavel no log
extract_failure_signature() {
  local log="$1" max="${2:-30}"
  REPAIR_SIGNATURE=""
  REPAIR_FILES=""
  [ -s "$log" ] || return 1

  # -a: log de suite pode carregar byte binario (cor, progresso) e o grep
  # trataria o arquivo como binario, devolvendo nada.
  local marks
  marks=$(grep -aE \
    '(FAILED|FAILURES|--- FAIL:|^[[:space:]]*FAIL[[:space:]]|✕|⨯|×|●|panicked at|Failed asserting|Expected[[:space:]]*:|Received[[:space:]]*:|AssertionError|^[[:space:]]*E[[:space:]]{2,}|Error[[:space:]]*:|Exception)' \
    "$log" 2> /dev/null \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | sed 's/[[:space:]]*$//' \
    | grep -avE '^[[:space:]]*$' \
    | awk '!seen[$0]++' \
    | head -n "$max" || true)

  # Referencias arquivo:linha — o que transforma "falhou" em "falhou aqui".
  local refs
  refs=$(grep -aoE '[A-Za-z0-9_][A-Za-z0-9_./-]*\.(php|js|mjs|cjs|ts|tsx|jsx|vue|py|go|rs|rb|java|kt|cs|ex|exs)(:[0-9]+)+' \
    "$log" 2> /dev/null | awk '!seen[$0]++' | head -n 15 || true)

  REPAIR_FILES=$(printf '%s\n' "$refs" | sed 's/:[0-9]*$//' | awk 'NF && !seen[$0]++' || true)

  # Marcador sem localizacao ainda serve (a mensagem pode nomear o teste), mas
  # nenhum dos dois significa que nao ha o que apontar para o modelo.
  if [ -z "${marks//[[:space:]]/}" ] && [ -z "${refs//[[:space:]]/}" ]; then
    REPAIR_FILES=""
    return 1
  fi

  local out=""
  if [ -n "${marks//[[:space:]]/}" ]; then
    out="$marks"
  fi
  if [ -n "${refs//[[:space:]]/}" ]; then
    if [ -n "$out" ]; then
      out="$out"$'\n'
    fi
    out="${out}Referencias no log (arquivo:linha):"$'\n'"$(printf '%s\n' "$refs" | sed 's/^/  /')"
  fi

  REPAIR_SIGNATURE="$out"
  return 0
}

# Quantos arquivos distintos a assinatura aponta. 0 = sem localizacao.
repair_file_count() {
  printf '%s' "$REPAIR_FILES" | grep -c . || true
}

# Heartbeat do modo quiet: prova de vida enquanto o engine trabalha em silencio.
# Mostra o tempo decorrido e a ultima linha de progresso (truncada) — sem ele,
# uma fase longa e indistinguivel de um run travado.
HEARTBEAT_PID=""

start_heartbeat() {
  local err_log="$1" label="$2"
  HEARTBEAT_PID=""
  $VERBOSE && return 0
  [ "$HEARTBEAT_SECS" -gt 0 ] 2> /dev/null || return 0

  (
    local waited=0 last
    while true; do
      sleep "$HEARTBEAT_SECS"
      waited=$((waited + HEARTBEAT_SECS))
      last=$(grep -v '^[[:space:]]*$' "$err_log" 2> /dev/null | tail -n 1 | cut -c1-100 || true)
      if [ -n "$last" ]; then
        log "$label — $(format_duration "$waited") | $last"
      else
        log "$label — $(format_duration "$waited")"
      fi
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  [ -n "$HEARTBEAT_PID" ] || return 0
  kill "$HEARTBEAT_PID" 2> /dev/null || true
  wait "$HEARTBEAT_PID" 2> /dev/null || true
  HEARTBEAT_PID=""
}

# run_split <stdout_log> <stderr_log> <stdin_file> <cmd> [args...]
#
# Roda o comando com os streams separados:
#   stdout -> <stdout_log>   (resposta final; o que os gates parseiam)
#   stderr -> <stderr_log>   (progresso; so diagnostico)
#
# Quiet (default): nenhum dos dois vai para o terminal — os logs guardam tudo e
# o GATE_CAUSE ja imprime o tail dos dois quando um gate reprova. Redirect
# direto, sem FIFO: nada para sincronizar.
#
# Verbose: os dois saem ao vivo. O stderr passa por um FIFO com um `tee` de PID
# conhecido, e nao por process substitution: `wait` no PID garante que o arquivo
# esta completo antes de qualquer gate ler. Com >(...) havia corrida — o gate
# podia ler um stderr.log ainda pela metade.
run_split() {
  local out_log="$1" err_log="$2" stdin_file="$3"
  shift 3

  local rc=0

  if ! $VERBOSE; then
    "$@" < "$stdin_file" > "$out_log" 2> "$err_log" || rc=$?
    return "$rc"
  fi

  local fifo_dir fifo tee_pid
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/ralph-stderr.XXXXXX")"
  fifo="$fifo_dir/stderr"
  mkfifo "$fifo"

  tee "$err_log" < "$fifo" >&2 &
  tee_pid=$!

  "$@" < "$stdin_file" 2> "$fifo" | tee "$out_log" || rc=$?

  wait "$tee_pid" 2> /dev/null || true
  rm -rf "$fifo_dir"

  return "$rc"
}

# ---------------------------------------------------------------------------
# Limite de uso (item 5) — so olha o FIM do log, com padroes por engine
# ---------------------------------------------------------------------------

# Ecoa o epoch de reset se encontrado, "0" para limite sem horario.
# Retorna 0 quando detecta limite, 1 quando nao ha limite.
detect_usage_limit() {
  local log_file="$1"
  local tail_txt pattern epoch err_log

  err_log="$(stderr_log_for "$log_file")"

  # A mensagem de limite sai no FIM da execucao. Olhar o log inteiro faz output
  # de teste do projeto ("429", "Too Many Requests") disparar espera de 30min.
  # Le os DOIS streams: dependendo da CLI e da versao, o aviso de limite cai no
  # stdout (claude, dentro do JSON) ou no stderr (codex).
  # Em stream-json o aviso de limite chega de duas formas: como texto na
  # resposta final (que engine_materialize_text ja desescapou) e como campo
  # estruturado no evento `result`. Le as duas, mais o stderr do codex.
  local txt_log
  txt_log="$(engine_text_for "$log_file")"
  tail_txt=$(
    {
      tail -n 20 "$log_file" 2>/dev/null || true
      [ -s "$txt_log" ] && { tail -n 20 "$txt_log" 2>/dev/null || true; }
      [ -f "$err_log" ] && { tail -n 20 "$err_log" 2>/dev/null || true; }
    } || true
  )

  if [[ "$ENGINE" == "claude" ]]; then
    # CLI 2.x trocou o texto para "You've hit your session limit · resets 5:40am"
    # e expoe o sinal estruturado "api_error_status":429 no JSON de resultado.
    # A chave JSON e especifica do resultado do claude -p: nao casa com "429" solto
    # de output de teste do projeto.
    pattern='usage limit reached|hit your ([a-z]+ )?limit|"api_error_status": ?429'
  else
    pattern='rate limit reached|quota exceeded|usage limit reached'
  fi

  grep -qiE "$pattern" <<< "$tail_txt" || return 1

  epoch=$(grep -oiE 'usage limit reached[^0-9]*[0-9]{10,13}' <<< "$tail_txt" \
    | grep -oE '[0-9]{10,13}' | tail -1 || true)

  if [ -z "$epoch" ]; then
    epoch=$(grep -oiE 'reset[a-z ]*[0-9]{10,13}' <<< "$tail_txt" \
      | grep -oE '[0-9]{10,13}' | tail -1 || true)
  fi

  echo "${epoch:-0}"
  return 0
}

wait_for_reset() {
  local epoch="$1"
  local now wait_secs
  now=$(date +%s)

  LIMIT_WAITS=$((LIMIT_WAITS + 1))
  if [ "$LIMIT_WAITS" -gt "$MAX_LIMIT_WAITS" ]; then
    ST_RUN_STATUS="aborted"
    fail "Limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    fail "Abortando em vez de dormir indefinidamente."
    notify_and_record limit_abort \
      "Run abortado: limite de uso atingido $LIMIT_WAITS vezes seguidas nesta fase (cap: $MAX_LIMIT_WAITS)."
    ui_stop
    exit 1
  fi

  local reset_note
  if [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$epoch" -gt 0 ]; then
    if [ "${#epoch}" -ge 13 ]; then
      epoch=$((epoch / 1000))
    fi

    # Limite semanal: reset a dias de distancia. MAX_LIMIT_WAITS conta esperas,
    # nunca a duracao de cada uma — sem este corte o run dormiria ate o reset.
    local horizon=$((epoch - now))
    if [ "$WEEKLY_THRESHOLD" -gt 0 ] && [ "$horizon" -gt "$WEEKLY_THRESHOLD" ]; then
      ST_RUN_STATUS="aborted"
      ST_LIMIT_WAITING=0
      ST_LIMIT_UNTIL="$epoch"
      state_sync
      fail "Limite semanal de uso: reset so em $(date -d "@$epoch" '+%d/%m %H:%M') ($(format_duration "$horizon"))."
      fail "Acima do limiar de $(format_duration "$WEEKLY_THRESHOLD") (RALPH_WEEKLY_THRESHOLD) — encerrando em vez de dormir."
      fail "Progresso preservado. Retome depois com: ./ralph.sh $INPUT_FILE --from $ST_PHASE_NUM"
      notify_and_record limit_abort \
        "Run encerrado: limite semanal. Reset em $(date -d "@$epoch" '+%d/%m %H:%M'). Retome com: ./ralph.sh $INPUT_FILE --from $ST_PHASE_NUM"
      ui_stop
      exit 1
    fi

    wait_secs=$((epoch - now + LIMIT_BUFFER))
    if [ "$wait_secs" -lt "$LIMIT_BUFFER" ]; then
      wait_secs=$LIMIT_BUFFER
    fi
    reset_note="Reset previsto para $(date -d "@$epoch" '+%d/%m %H:%M')."
    warn "Limite de uso atingido. Reset previsto para $(date -d "@$epoch" '+%d/%m %H:%M:%S')."
  else
    wait_secs=$LIMIT_WAIT_DEFAULT
    reset_note="Sem horario de reset no output; usando espera fallback."
    warn "Limite de uso atingido. Sem horario de reset no output; aguardando fallback."
  fi

  warn "Espera $LIMIT_WAITS/$MAX_LIMIT_WAITS — aguardando $(format_duration "$wait_secs") ate retomar a MESMA fase..."

  ST_LIMIT_WAITING=1
  ST_LIMIT_UNTIL=$((now + wait_secs))
  set_activity "aguardando o reset do limite de uso"
  notify_and_record limit_hit \
    "Limite de uso atingido. $reset_note Dormindo $(format_duration "$wait_secs") e retomando a MESMA fase (espera $LIMIT_WAITS/$MAX_LIMIT_WAITS). Nenhuma acao necessaria."

  # Progresso so em marcos (4h/3h/2h/1h/30m/15m/5m/1m). Com o painel ativo,
  # a contagem ja aparece no cabecalho — nao polui o log com uma linha por minuto.
  local -a marks=(14400 10800 7200 3600 1800 900 300 60)
  local mi=0
  while [ "$mi" -lt "${#marks[@]}" ] && [ "$wait_secs" -le "${marks[$mi]}" ]; do
    mi=$((mi + 1))
  done

  local remaining=$wait_secs chunk
  while [ "$remaining" -gt 0 ]; do
    chunk=60
    [ "$remaining" -lt 60 ] && chunk=$remaining
    sleep "$chunk"
    remaining=$((remaining - chunk))
    [ "$remaining" -le 0 ] && break
    if [ "$mi" -lt "${#marks[@]}" ] && [ "$remaining" -le "${marks[$mi]}" ]; then
      while [ "$mi" -lt "${#marks[@]}" ] && [ "$remaining" -le "${marks[$mi]}" ]; do
        mi=$((mi + 1))
      done
      $UI_ACTIVE || log "Retomando em $(format_duration "$remaining")..."
    fi
  done

  ST_LIMIT_WAITING=0
  ST_LIMIT_UNTIL=0
  success "Reset provavelmente concluido. Retomando execucao."
  notify_and_record limit_over "Limite liberado. Retomando a fase automaticamente."
}

# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

# O plugin caveman grava o nivel ativo em ~/.claude/.caveman-active no
# SessionStart. O arquivo e GLOBAL: a sessao interativa do dev le o mesmo byte.
# Uma sessao headless do ralph pedindo `ultra` reescreveria esse arquivo e a
# proxima mensagem do dev no terminal dele viria comprimida sem ninguem ter
# pedido. Snapshot antes, restauracao depois: o run nao vaza o proprio nivel.
caveman_flag_snapshot() {
  CAVEMAN_FLAG_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
  CAVEMAN_FLAG_BEFORE=""

  # Symlink nao e nosso: nao le, nao escreve, nao restaura.
  if [ -L "$CAVEMAN_FLAG_FILE" ]; then
    CAVEMAN_FLAG_FILE=""
    return 0
  fi

  if [ -f "$CAVEMAN_FLAG_FILE" ]; then
    CAVEMAN_FLAG_BEFORE="$(cat "$CAVEMAN_FLAG_FILE" 2> /dev/null || true)"
  fi
}

caveman_flag_restore() {
  local flag="$CAVEMAN_FLAG_FILE"
  CAVEMAN_FLAG_FILE=""
  [ -n "$flag" ] || return 0
  if [ -L "$flag" ]; then
    return 0
  fi

  local now=""
  if [ -f "$flag" ]; then
    now="$(cat "$flag" 2> /dev/null || true)"
  fi

  if [ -n "$CAVEMAN_FLAG_BEFORE" ]; then
    if [ "$now" != "$CAVEMAN_FLAG_BEFORE" ]; then
      printf '%s' "$CAVEMAN_FLAG_BEFORE" > "$flag" 2> /dev/null || true
    fi
    return 0
  fi

  # Nao existia antes da sessao: so apaga o que ESTA sessao criou.
  if [ "$now" = "$CAVEMAN_MODE" ]; then
    rm -f "$flag" 2> /dev/null || true
  fi
}

# run_engine <prompt_file> <log_file> <mode: impl|verify>
# Loop de resiliencia a limite de uso: nao consome ciclo de correcao.
run_engine() {
  local prompt_file="$1" log_file="$2" mode="$3"

  export RALPH_ENGINE="$ENGINE"
  export RALPH_PHASE_MAX_ATTEMPTS="$MAX_CYCLES"

  local err_log
  err_log="$(stderr_log_for "$log_file")"
  # O painel mede o crescimento dos dois streams para provar que o engine esta
  # vivo mesmo quando ele nao escreve nada legivel no stderr.
  ST_STDERR_LOG="$err_log"
  ST_STDOUT_LOG="$log_file"

  # Expandido como ${model_args[@]+"..."}: sob `set -u`, "${arr[@]}" de array
  # VAZIO e "unbound variable" em bash < 4.4 (o bash 3.2 do macOS incluso).
  local model_args=()

  # Caveman so nas sessoes que escrevem codigo. O verificador emite contrato de
  # maquina (`TASK <n>: DONE|INCOMPLETE`), ja e minimo, e comprimir prosa la
  # arriscaria o gate 3 sem economizar nada. Quando o ralph NAO injeta nivel
  # (verificador ou RALPH_CAVEMAN=off), a variavel herdada do shell do dev e
  # removida: senao um `CAVEMAN_DEFAULT_MODE=ultra` exportado vaza para a sessao.
  local cave_env=(-u CAVEMAN_DEFAULT_MODE)
  if [[ "$ENGINE" == "claude" && "$mode" != "verify" && "$CAVEMAN_MODE" != "off" ]]; then
    cave_env=(CAVEMAN_DEFAULT_MODE="$CAVEMAN_MODE")
  fi
  if [[ "$mode" == "verify" ]]; then
    if [ -n "$VERIFY_MODEL" ]; then
      model_args=(--model "$VERIFY_MODEL")
    fi
  elif [[ "$mode" == "repair" ]]; then
    if [ -n "$REPAIR_MODEL" ]; then
      model_args=(--model "$REPAIR_MODEL")
    fi
  elif [[ "$mode" == "rescue" ]]; then
    if [ -n "$RESCUE_MODEL" ]; then
      model_args=(--model "$RESCUE_MODEL")
    fi
  elif [[ "$mode" == "heal" ]]; then
    # Saneamento precisa de arqueologia de git (qual commit mudou o texto
    # congelado, qual SPEC pediu) — o mesmo modelo forte do resgate.
    if [ -n "$RESCUE_MODEL" ]; then
      model_args=(--model "$RESCUE_MODEL")
    fi
  elif [ -n "$IMPL_MODEL" ]; then
    # Implementacao e correcao: sem --model o engine usa o default da CLI, e o
    # operador nao tem como saber qual modelo escreveu a fase. Fixar aqui evita
    # trocar o default global so para rodar o ralph.
    model_args=(--model "$IMPL_MODEL")
  fi

  local hb_label
  if [[ "$mode" == "verify" ]]; then
    hb_label="$ENGINE verificando a fase ${RALPH_PHASE_NUM:-?}"
  elif [[ "$mode" == "repair" ]]; then
    hb_label="$ENGINE consertando a fase ${RALPH_PHASE_NUM:-?} (round ${RALPH_PHASE_REPAIR:-1})"
  elif [[ "$mode" == "rescue" ]]; then
    hb_label="$ENGINE resgatando a fase ${RALPH_PHASE_NUM:-?} (round ${RALPH_PHASE_RESCUE:-1})"
  elif [[ "$mode" == "heal" ]]; then
    hb_label="$ENGINE saneando o vermelho herdado de HEAD"
  else
    hb_label="$ENGINE implementando a fase ${RALPH_PHASE_NUM:-?} (ciclo ${RALPH_PHASE_ATTEMPT:-1})"
  fi

  while true; do
    local rc=0

    : > "$err_log"
    start_heartbeat "$err_log" "$hb_label"

    if [[ "$ENGINE" == "claude" && "$mode" != "verify" && "$CAVEMAN_MODE" != "off" ]]; then
      caveman_flag_snapshot
    fi

    # stdout e stderr vao para arquivos DIFERENTES. Unir os dois (2>&1) fazia
    # o progresso do engine entrar no log parseado pelos gates — e no codex a
    # resposta final aparece nos dois streams, duplicando as linhas TASK.
    if [[ "$ENGINE" == "codex" ]]; then
      if [[ "$mode" == "verify" ]]; then
        run_split "$log_file" "$err_log" "$prompt_file" \
          codex exec --sandbox read-only ${model_args[@]+"${model_args[@]}"} - || rc=$?
      else
        # O conserto tambem escreve codigo: mesmo sandbox da implementacao, so
        # o modelo muda.
        run_split "$log_file" "$err_log" "$prompt_file" \
          codex exec --sandbox danger-full-access ${model_args[@]+"${model_args[@]}"} - || rc=$?
      fi
    else
      # stdin /dev/null: claude -p le stdin quando nao e TTY. Sem o redirect ele
      # consome o stream de quem chamou (ex: o manifest do loop de fases).
      # stream-json, nao json: `json` so imprime quando a sessao ACABA, entao o
      # log fica em 0 byte por minutos e o painel nao tem o que mostrar — era
      # dai que vinha o "engine em silencio (esta CLI nao streama progresso)".
      # Em NDJSON cada ferramenta usada vira um evento na hora.
      #
      # Sem --include-partial-messages de proposito: o delta token a token
      # multiplica o log por ~50x e nao acrescenta nada ao painel, que mostra
      # ferramenta + alvo. O veredito continua saindo do evento `result`.
      if [[ "$mode" == "verify" ]]; then
        run_split "$log_file" "$err_log" /dev/null \
          env -u CLAUDECODE ${cave_env[@]+"${cave_env[@]}"} \
          claude --dangerously-skip-permissions \
          ${model_args[@]+"${model_args[@]}"} \
          -p "$(cat "$prompt_file")" \
          --allowedTools "Read,Glob,Grep" \
          --output-format stream-json --verbose || rc=$?
      else
        # O exit code do CLI e sinal fraco; o gate 0 le is_error do evento final.
        run_split "$log_file" "$err_log" /dev/null \
          env -u CLAUDECODE ${cave_env[@]+"${cave_env[@]}"} \
          claude --dangerously-skip-permissions \
          ${model_args[@]+"${model_args[@]}"} \
          -p "$(cat "$prompt_file")" \
          --output-format stream-json --verbose || rc=$?
      fi
    fi

    stop_heartbeat
    caveman_flag_restore

    # Antes de qualquer leitura do log: detect_usage_limit, gate 0 e os gates
    # semanticos todos leem o TEXTO, nao o NDJSON.
    engine_materialize_text "$log_file"

    local reset_epoch
    if reset_epoch=$(detect_usage_limit "$log_file"); then
      wait_for_reset "$reset_epoch"
      continue
    fi

    return "$rc"
  done
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

# Gate 0 — o engine terminou de verdade?
# Preenche GATE_CAUSE quando vermelho.
GATE_CAUSE=""

gate0_engine_finished() {
  local log_file="$1" rc="$2"

  # O veredito sai SO do stdout (resposta final). O stderr entra apenas no
  # diagnostico: telemetria de progresso nao decide gate.
  if [[ "$ENGINE" == "claude" ]]; then
    # O veredito e o evento `result` do NDJSON, lido como JSON. Antes isso era
    # um grep por `"is_error": true` no arquivo inteiro — em stream-json esse
    # texto tambem aparece dentro de um tool_result que o proprio modelo leu
    # (a saida de um comando que falhou), e a sessao era reprovada por um erro
    # que ela ja tinha tratado.
    local verdict
    verdict="$(jq -R -r 'fromjson? | select(.type == "result")
               | if (.is_error == true) then "error" else "ok" end' \
               "$log_file" 2> /dev/null | tail -n 1 || true)"

    if [ -z "$verdict" ]; then
      GATE_CAUSE="O engine terminou sem emitir um resultado. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      return 1
    fi
    if [ "$verdict" = "error" ]; then
      GATE_CAUSE="O engine reportou is_error=true. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
      return 1
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    GATE_CAUSE="O engine saiu com codigo $rc. Ultimas linhas do output:"$'\n'"$(engine_tail "$log_file" 40)"
    return 1
  fi

  return 0
}

# Assinatura da arvore: rastreados (status + diff) e nao-rastreados (conteudo).
# Sem mutar o index.
tree_signature() {
  {
    git status --porcelain
    git diff HEAD
    git ls-files --others --exclude-standard -z | xargs -0 -r sha256sum 2> /dev/null
  } 2> /dev/null | sha256sum | cut -c1-16
}

# Assinatura da sessao: alem da arvore, inclui HEAD porque alguns engines
# concluem uma task com git commit. Nesse caso a arvore volta a limpa, mas a
# sessao escreveu codigo e o Gate 1 nao pode confundi-la com fase preexistente.
# Nao substitui tree_signature(): os caches do Gate 2 continuam interessados
# somente no conteudo atualmente testavel, nao na mensagem ou no hash do commit.
session_signature() {
  {
    git rev-parse HEAD 2> /dev/null || true
    tree_signature
  } | sha256sum | cut -c1-16
}

# Gate 1 — esta sessao escreveu codigo?
#
# SINAL, nao veredito. Uma fase pode ja estar implementada antes da sessao
# (tasks `[x]`, run anterior commitada, dev implementou a mao). Nesse caso o
# engine correto NAO escreve nada, e reprovar aqui seria um falso negativo:
# so os gates 2 e 3 sabem se o codigo esta completo.
#
# O retorno alimenta a causa do ciclo de correcao ("a sessao nao escreveu
# nada") quando algum gate posterior reprova.
gate1_session_wrote() {
  local sig_before="$1"
  [ "$(session_signature)" != "$sig_before" ]
}

# Identificadores dos testes vermelhos num log de suite, normalizados e unicos.
# Os runners truncam o detalhe da falha ("FAILED  Tests\\Meta\\MetaTemplateImportSe…"),
# mas o CABECALHO do arquivo/suite ("FAIL  Tests\\Meta\\MetaTemplateImportSecretsTest")
# vem inteiro — e ele que serve de identidade estavel entre duas rodadas.
gate2_failure_ids() {
  sed -e 's/\x1b\[[0-9;]*m//g' "$1" 2> /dev/null | awk '
    # phpunit / pest / jest / vitest: "FAIL  <suite ou arquivo>"
    /^[[:space:]]*FAIL[[:space:]]+[^[:space:]]/ { print $2; next }
    # pytest: "FAILED tests/test_x.py::test_y"
    /^[[:space:]]*FAILED[[:space:]]+[^[:space:]]+::/ { print $2; next }
    # go test: "--- FAIL: TestFoo"
    /^[[:space:]]*--- FAIL: / { print $3; next }
    # cargo test: "test foo::bar ... FAILED"
    /^test .* \.\.\. FAILED/ { print $2; next }
  ' | sort -u
}

# Quantos testes falharam, pela linha de resumo do runner. A contagem fecha o
# buraco da identidade por suite: um teste NOVO quebrando dentro de uma suite que
# ja estava vermelha nao muda o conjunto de ids, mas muda o total.
gate2_failure_count() {
  local n
  n=$(sed -e 's/\x1b\[[0-9;]*m//g' "$1" 2> /dev/null \
    | grep -oiE '[0-9]+ (failed|failures?|failing)' | head -n 1 | grep -oE '^[0-9]+' || true)
  if [ -n "$n" ]; then
    echo "$n"
  else
    gate2_failure_ids "$1" | wc -l | tr -d ' '
  fi
}

# Mede em HEAD o que ja esta vermelho ANTES da primeira fase. O preflight exige
# arvore limpa, entao esta medicao e exatamente o estado de HEAD — nada do que a
# fase escrever pode ser confundido com uma falha herdada.
measure_baseline() {
  [ -n "$TEST_CMD" ] || return 0
  # Duas razoes independentes para medir: herdar o vermelho como delta
  # (--baseline) ou sanea-lo antes da fase 1 (HEAL_MODE). Sem nenhuma das duas o
  # operador pediu o comportamento antigo — nao gasta a rodada.
  [ "$BASELINE_MODE" = "on" ] || [ "$HEAL_MODE" = "on" ] || return 0

  local log rc=0
  log="$LOG_DIR/baseline.log"
  BASELINE_FILE="$LOG_DIR/baseline.ids"

  set_activity "medindo o baseline da suite em HEAD"
  log "Baseline — medindo o que ja esta vermelho em HEAD: $TEST_CMD"
  bash -c "$TEST_CMD" < /dev/null > "$log" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    : > "$BASELINE_FILE"
    BASELINE_COUNT=0
    HEAD_RED=0
    [ "$BASELINE_MODE" = "on" ] && BASELINE_ACTIVE=true
    success "Baseline — suite verde em HEAD; qualquer vermelho daqui pra frente e da fase"
    return 0
  fi

  # Ambiente fora do ar na medicao nao e vermelho de codigo: a suite nao chegou
  # a julgar nada, e nenhuma sessao de saneamento levanta um servico morto.
  if $ENV_GUARD && gate2_infra_failure "$log"; then
    BASELINE_ACTIVE=false
    HEAD_RED=0
    warn "Baseline — a suite em HEAD caiu por ambiente fora do ar ($INFRA_SIGNATURE)."
    warn "Baseline e saneamento IGNORADOS: suba os servicos para medir HEAD de verdade."
    return 0
  fi

  gate2_failure_ids "$log" > "$BASELINE_FILE"
  BASELINE_COUNT=$(gate2_failure_count "$log")

  if [ ! -s "$BASELINE_FILE" ]; then
    # Suite vermelha e nenhum id extraido: o formato do runner nao e conhecido.
    # Herdar o vermelho as cegas mascararia regressao real, e sanear sem saber o
    # que esta vermelho viraria chute — melhor deixar os gates julgarem.
    BASELINE_ACTIVE=false
    HEAD_RED=0
    warn "Baseline — suite vermelha em HEAD, mas nao consegui identificar os testes."
    warn "Baseline DESLIGADO: o gate 2 vai exigir a suite inteira verde."
    return 0
  fi

  warn "Baseline — HEAD ja tem $BASELINE_COUNT teste(s) vermelho(s), alheios a este run:"
  sed 's/^/    /' "$BASELINE_FILE"

  # --baseline tem precedencia: o operador declarou que esse vermelho e
  # intencional (fase em TDD com o teste-alvo ja commitado vermelho). Sanear
  # seria consertar justamente o teste que a fase existe para fechar.
  if [ "$BASELINE_MODE" = "on" ]; then
    BASELINE_ACTIVE=true
    HEAD_RED=0
    warn "O gate 2 vai cobrar apenas o DELTA. Conserte-os fora do ralph."
    return 0
  fi

  HEAD_RED=1
}

# Mandato sobre guarda obsoleta. Vai no prompt do saneamento, do conserto
# cirurgico e do resgate: as tres sessoes ja desistiram de vermelho que era so
# uma guarda velha, tratando congelamento de outra feature como intocavel. E o
# oposto: quem mudou o texto congelado de proposito devia ter atualizado a
# guarda na mesma fatia, e nao atualizou — a divida e da guarda.
guard_mandate() {
  cat <<'MANDATE'

## Guarda obsoleta de OUTRA feature — voce TEM autoridade
Teste que congela o TEXTO de um arquivo (byte a byte, contagem de metodos,
superficie publica, ordem de itens), inclusive de outro repositorio, e guarda de
higiene de alguma feature. Vermelho ali e, na maioria das vezes, guarda OBSOLETA:
alguem mudou o texto congelado de proposito e nao atualizou a guarda na mesma
fatia. Nao desista antes de PROVAR qual dos dois lados esta velho:

- `git log -S'<trecho congelado>' --oneline -- <arquivo>` no repositorio DONO do
  arquivo, e leia a mensagem do commit que mudou o texto.
- Procure a SPEC/PLAN que pediu a mudanca (`.spec/features/*/`, `.spec/bugfixes/*/`).

Mudanca intencional e commitada => a guarda esta velha. ATUALIZE a guarda para o
shape novo, no MESMO nivel de congelamento, preservando a regra que ela protege,
e estenda o comentario nomeando a feature que mudou o texto. Isto NAO e afrouxar
contrato de outra feature: e terminar a fatia que a deixou pela metade.

Proibido: apagar a guarda, trocar o congelamento por assercao generica
(`toContain`, regex frouxa), marcar como skip, ou mudar codigo de PRODUCAO para
satisfazer guarda velha.

Se o texto congelado nao mudou por decisao registrada, o vermelho e defeito de
verdade: conserte o codigo.
MANDATE
}

# ---------------------------------------------------------------------------
# Saneamento do HEAD vermelho (ver o cabecalho)
#
# Roda entre a medicao do baseline e a fase 1. Sessao com mandato proprio: o
# alvo nao e nenhuma fase, e a suite. Verde => commit proprio, HEAD limpo e o
# run segue. Ainda vermelho => aborta antes de gastar a fase 1.
# ---------------------------------------------------------------------------

build_heal_prompt() {
  local round="$1"
  local prompt_file="$PROMPT_DIR/heal-head-${round}.txt"

  {
    echo "RALPH_HEAL"
    echo
    echo "Voce e um engenheiro senior fazendo o SANEAMENTO do HEAD, antes da"
    echo "primeira fase do plano. Nenhuma fase foi implementada ainda."
    echo
    cat <<'INTRO'
## Situacao
A suite do projeto ja esta VERMELHA em HEAD, com a arvore limpa, antes de
qualquer linha desta execucao. Esse vermelho nao e defeito de nenhuma fase: e
vermelho herdado, e ele prende o ciclo de TODAS as fases que vem depois.

Seu unico objetivo e deixar a suite VERDE em HEAD. Voce nao implementa fase
nenhuma, nao le o documento de fases e nao antecipa trabalho de feature.
INTRO
    echo
    echo "## Testes vermelhos em HEAD"
    sed 's/^/  - /' "$BASELINE_FILE"
    echo
    echo "## Saida da suite em HEAD"
    echo '```'
    tail -n 200 "$LOG_DIR/baseline.log"
    echo '```'
    guard_mandate
    echo
    cat <<'RULES'
## Regras obrigatorias
- Escopo: so o que deixa a suite verde. Nao refatore, nao renomeie, nao
  reorganize, nao deixe TODO nem placeholder.
- Nao apague, nao pule (`skip`/`only`/`xit`) e nao comente teste existente.
- Nao mude o comando de teste do projeto, nem configuracao, dependencia ou
  versao de ferramenta para "fazer passar".
- Nao toque em codigo de producao a menos que o vermelho seja defeito real de
  producao — e, nesse caso, corrija a causa, nao a assercao.
RULES
    if [ -n "$TEST_CMD" ]; then
      echo "- Rode \`$TEST_CMD\` ao final e confirme que a suite INTEIRA passa."
    fi
    cat <<'ABORT'
- Se o vermelho NAO se resolve assim — o teste cobra comportamento que ninguem
  implementou, ou os dois lados sao decisoes vivas em conflito real — PARE sem
  editar nada e responda exatamente uma linha:
  HEAL_ABORT: <o conflito em uma frase, citando os dois lados>
  Desistir aqui e barato: o run para antes da fase 1, e o operador decide.
ABORT
  } > "$prompt_file"

  echo "$prompt_file"
}

# heal_head
#   rc 0 = HEAD verde (ou nada a sanear); o run pode comecar
#   rc 1 = HEAD segue vermelho; o chamador aborta o run
heal_head() {
  [ "$HEAD_RED" -eq 1 ] || return 0

  if [ "$HEAL_MODE" != "on" ] || [ "$HEAL_ROUNDS" -lt 1 ] 2> /dev/null; then
    warn "Saneamento desligado: as fases vao comecar sobre gate vermelho."
    return 0
  fi

  local round=1
  while [ "$round" -le "$HEAL_ROUNDS" ]; do
    local prompt_file log_file
    prompt_file=$(build_heal_prompt "$round")
    log_file="$LOG_DIR/heal-head-${round}.log"

    set_activity "saneando o vermelho herdado de HEAD ($round/$HEAL_ROUNDS)"
    warn "Saneamento do HEAD $round/$HEAL_ROUNDS — nenhuma fase comeca sobre gate vermelho"

    HEAL_ABORT_WHY=""
    run_engine "$prompt_file" "$log_file" "heal" || true

    if grep -qa 'HEAL_ABORT:' "$(engine_text_for "$log_file")" 2> /dev/null; then
      HEAL_ABORT_WHY=$(grep -aoE 'HEAL_ABORT:.*' "$(engine_text_for "$log_file")" | head -n 1 | cut -c1-300 || true)
      warn "Saneamento abortado pelo modelo — $HEAL_ABORT_WHY"
      break
    fi

    local rc=0
    set_activity "revalidando a suite depois do saneamento"
    bash -c "$TEST_CMD" < /dev/null > "$LOG_DIR/heal-head-${round}.test.log" 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
      if [ -n "$(git status --porcelain)" ]; then
        git add -A
        git commit -q -m "test(baseline): sanea o vermelho herdado de HEAD" \
          -m "Suite verde antes da fase 1. Ver .phases/logs/heal-head-${round}.*"
        success "Saneamento — suite verde em HEAD; commit criado"
      else
        success "Saneamento — suite verde em HEAD sem edicao (vermelho intermitente)"
      fi
      : > "$BASELINE_FILE"
      BASELINE_COUNT=0
      HEAD_RED=0
      return 0
    fi

    # Piorou: ids novos depois do saneamento significam que a sessao quebrou
    # outra coisa. Insistir a partir daqui e cavar mais fundo.
    local ids_novos
    ids_novos="$(comm -13 "$BASELINE_FILE" <(gate2_failure_ids "$LOG_DIR/heal-head-${round}.test.log") || true)"
    if [ -n "$ids_novos" ]; then
      warn "Saneamento — a suite ficou PIOR; falhas novas:"
      printf '%s\n' "$ids_novos" | sed 's/^/    /'
      break
    fi

    warn "Saneamento $round/$HEAL_ROUNDS — HEAD segue vermelho"
    round=$((round + 1))
  done

  echo ""
  fail "HEAD vermelho nao sanado — o run NAO comeca sobre gate vermelho."
  warn "Testes vermelhos em HEAD:"
  sed 's/^/    /' "$BASELINE_FILE"
  [ -n "$HEAL_ABORT_WHY" ] && warn "Veredito da sessao: $HEAL_ABORT_WHY"
  warn "Saidas possiveis:"
  warn "  1. conserte a suite fora do ralph e re-rode (caminho normal)"
  warn "  2. --baseline: o vermelho e intencional; o gate 2 cobra so o DELTA"
  warn "  3. --no-heal-head: comeca sobre gate vermelho, por sua conta"
  if [ -n "$(git status --porcelain)" ]; then
    warn "A arvore tem o trabalho parcial do saneamento — revise antes de re-rodar."
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Ambiente fora do ar — veredito proprio do gate 2
#
# Um servico externo caido (banco, cache, fila, container derrubado por falta de
# memoria no host) nao e defeito de codigo: a suite nao chegou a julgar a fase.
# O run real que motivou isto: o MySQL de um projeto VIZINHO morreu no meio da
# fase, cinco testes cairam com `getaddrinfo ... Name or service not known`, e o
# ralph condenou a fase, gastou conserto cirurgico e descartou seis arquivos
# corretos. Nenhum patch faz um container morto voltar.
#
# Assinaturas agnosticas de stack: recusa de conexao, DNS que nao resolve,
# SQLSTATE de conexao. Elas nomeiam o SERVICO, nunca a assercao.
# ---------------------------------------------------------------------------

INFRA_SIGNATURE=""

# gate2_infra_failure <log>
#   rc 0 = a suite caiu por ambiente (INFRA_SIGNATURE publicada)
#   rc 1 = falha normal (assertion, erro de codigo) ou guard desligado
gate2_infra_failure() {
  local log="$1"
  INFRA_SIGNATURE=""
  $ENV_GUARD || return 1
  [ -s "$log" ] || return 1

  local hit
  hit=$(grep -aE '(SQLSTATE\[HY000\] \[200[0-9]\]|SQLSTATE\[08[0-9A-Z]{3}\]|[Cc]onnection refused|ECONNREFUSED|ENOTFOUND|could not connect to|getaddrinfo|Name or service not known|Temporary failure in name resolution|No route to host|server closed the connection unexpectedly|Cannot connect to the Docker daemon|Sail is not running|connect: connection refused|Connection timed out)' \
    "$log" 2> /dev/null \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | awk 'NF && !seen[$0]++' | head -n 5 || true)

  [ -n "${hit//[[:space:]]/}" ] || return 1
  INFRA_SIGNATURE="$hit"
  return 0
}

# Hosts citados na assinatura. Um container derrubado aparece pelo NOME no erro
# de DNS/conexao — e o nome do container e a chave para levanta-lo de volta,
# mesmo quando ele pertence a outro compose project.
infra_hosts() {
  printf '%s\n' "$INFRA_SIGNATURE" \
    | grep -aoE '(getaddrinfo for |Host: |host=|connect to |connecting to |[Cc]onnection to )[A-Za-z0-9_.-]+' \
    | sed -E 's/^(getaddrinfo for |Host: |host=|connect to |connecting to |[Cc]onnection to )//' \
    | awk 'NF && !seen[$0]++' \
    | grep -avE '^(localhost|127\.0\.0\.1|::1)$' || true
}

# Tenta devolver o ambiente ao ar. Duas receitas, ambas conservadoras: sobe o
# que ja existe e esta parado, nunca cria nem reconfigura nada.
#   rc 0 = algo foi levantado   rc 1 = nada a fazer / nao subiu
recover_env() {
  local acted=0 started="" h

  if command -v docker > /dev/null 2>&1; then
    local all up
    all=$(docker ps -a --format '{{.Names}}' 2> /dev/null || true)
    up=$(docker ps --format '{{.Names}}' 2> /dev/null || true)
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      grep -qxF "$h" <<< "$all" || continue
      grep -qxF "$h" <<< "$up" && continue
      log "Ambiente — container '$h' esta parado; subindo com docker start"
      docker start "$h" > "$LOG_DIR/env-recover.log" 2>&1 || true
      started="$started $h"
      acted=1
    done <<< "$(infra_hosts)"
  fi

  if [ -n "$SAIL_BIN" ] && test_cmd_uses_sail && [ -x "$SAIL_BIN" ] && ! sail_running; then
    log "Ambiente — containers do projeto parados; subindo: $SAIL_BIN up -d"
    "$SAIL_BIN" up -d < /dev/null >> "$LOG_DIR/env-recover.log" 2>&1 || true
    acted=1
  fi

  [ "$acted" -eq 1 ] || return 1

  # Esperar o servico ACEITAR conexao esta fora do alcance do ralph (cada stack
  # tem seu handshake). O que da para provar aqui e o container em execucao;
  # quem da o veredito final e a reexecucao da suite.
  local waited=0 pending
  while [ "$waited" -lt "$ENV_RECOVER_TIMEOUT" ]; do
    pending=0
    for h in $started; do
      docker ps --format '{{.Names}}' 2> /dev/null | grep -qxF "$h" || pending=1
    done
    if [ -n "$SAIL_BIN" ] && test_cmd_uses_sail && [ -x "$SAIL_BIN" ]; then
      sail_running || pending=1
    fi
    if [ "$pending" -eq 0 ]; then
      success "Ambiente — servicos de pe apos $(format_duration "$waited")"
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done

  warn "Ambiente — os servicos nao subiram em $(format_duration "$ENV_RECOVER_TIMEOUT")"
  return 1
}


# ---------------------------------------------------------------------------
# Escopo do gate 2
#
# A suite inteira e o gate da SPEC; a fase paga so pelo que ela mexeu. Ver
# "Escopo do gate 2" no cabecalho para a ordem das regras e o porque.
# ---------------------------------------------------------------------------

# Arquivos que ESTA fase alterou. A fase parte de arvore limpa (o preflight
# exige, e cada fase anterior fechou em commit), entao o diff contra HEAD e
# exatamente o trabalho da fase corrente.
phase_changed_files() {
  {
    git diff --name-only HEAD 2> /dev/null || true
    git ls-files --others --exclude-standard 2> /dev/null || true
  } | awk 'NF && !seen[$0]++'
}

phase_changed_tests() {
  phase_changed_files | grep -aE "$TEST_FILE_RE" || true
}

phase_changed_critical() {
  phase_changed_files | grep -aE "$CRITICAL_PATHS_RE" || true
}

# Arquivos de teste que o proprio documento da fase nomeia (campo `Testes:`).
# Entram no escopo mesmo sem aparecer no diff: um teste ja commitado que a fase
# precisa fazer passar continua sendo alvo dela.
phase_declared_tests() {
  local phase_file="$1"
  [ -n "$phase_file" ] && [ -f "$PHASES_DIR/$phase_file" ] || return 0
  # Crases delimitam caminhos no Markdown; nao sao substituicao de comando.
  # shellcheck disable=SC2016
  grep -aoE '`[^`]+`' "$PHASES_DIR/$phase_file" 2> /dev/null \
    | tr -d '`' | grep -aE "$TEST_FILE_RE" | awk 'NF && !seen[$0]++' || true
}

# A fase pede a suite completa? Escalada explicita do planejamento. So existe
# neste sentido: uma fase pode exigir MAIS rigor, nunca desligar a suite.
phase_declares_full_suite() {
  local phase_file="$1"
  [ -n "$phase_file" ] && [ -f "$PHASES_DIR/$phase_file" ] || return 1
  grep -aqiE '^[[:space:]]*Suite([[:space:]]+de[[:space:]]+testes)?:[[:space:]]*(completa|full|inteira)' \
    "$PHASES_DIR/$phase_file"
}

# Comando escopado para <paths>, ou VAZIO quando o runner nao aceita escopo por
# caminho. Vazio nunca significa "roda menos": quem chama cai na suite completa.
scoped_test_cmd() {
  [ $# -gt 0 ] || return 0
  # Comando composto (pipe, &&, ;) nao tem "ultimo argumento" previsivel:
  # anexar caminho ali muda o comando errado.
  case "$TEST_CMD" in
    *';'*|*'&&'*|*'||'*|*'|'*) return 0 ;;
  esac

  local paths="" p
  for p in "$@"; do
    paths="$paths \"$p\""
  done

  local exe base
  exe="${TEST_CMD%% *}"
  base="$(basename -- "$exe")"

  case "$base" in
    # Runners que recebem caminho como argumento posicional.
    sail|artisan|php|pest|phpunit|pytest|py.test|jest|vitest|bun|mocha|rspec|deno)
      printf '%s%s' "$TEST_CMD" "$paths"
      ;;
    # Wrappers de script: o caminho so chega ao runner depois de `--`.
    composer|npm|pnpm|yarn)
      printf '%s --%s' "$TEST_CMD" "$paths"
      ;;
    # go, cargo, make e desconhecidos: escopo por caminho nao e confiavel.
    *) return 0 ;;
  esac
}

# A ultima fase que este run vai executar de verdade — pulando as ja completas
# e as anteriores a --from. E nela que a suite COMPLETA roda: o fim da spec.
# Nenhuma fase pendente => nenhuma fase final; o run nao roda suite nenhuma e
# avisa, em vez de inventar um gate que ninguem pediu.
resolve_final_phase() {
  FINAL_PHASE_FILE=""
  local file num _title
  while IFS='|' read -r file num _title; do
    if [ "$num" -lt "$FROM_PHASE" ]; then
      continue
    fi
    if is_phase_done "$file"; then
      continue
    fi
    FINAL_PHASE_FILE="$file"
  done < <(manifest_entries)
}

# Numero da fase final, so para o log inicial.
final_phase_num() {
  [ -n "$FINAL_PHASE_FILE" ] || return 0
  local file num _title
  while IFS='|' read -r file num _title; do
    if [ "$file" = "$FINAL_PHASE_FILE" ]; then
      printf '%s' "$num"
      return 0
    fi
  done < <(manifest_entries)
}

# Resolve o escopo do gate 2 DESTA execucao. Roda depois da sessao do engine —
# so entao a arvore mostra o que a fase mexeu.
resolve_gate2_scope() {
  local phase_file="${1:-}"

  GATE2_SCOPE="full"
  GATE2_SCOPE_CMD="$TEST_CMD"
  GATE2_SCOPE_WHY=""
  GATE2_SCOPE_FILES=""

  if [ "$TEST_SCOPE_MODE" = "full" ]; then
    GATE2_SCOPE_WHY="modo suite completa (--full-suite / RALPH_TEST_SCOPE=full)"
    return 0
  fi

  if [ "$PHASE_IS_FINAL" -eq 1 ]; then
    GATE2_SCOPE_WHY="ultima fase do documento — gate final da spec"
    return 0
  fi

  # Sem gate 3 o gate 2 e a UNICA prova mecanica da fase. Escopar ou pular ali
  # deixaria a fase fechar e commitar sem validacao nenhuma.
  if [ "$VERIFY_MODE" = "off" ]; then
    GATE2_SCOPE_WHY="gate 3 desligado — a suite completa e a unica validacao restante"
    return 0
  fi

  if phase_declares_full_suite "$phase_file"; then
    GATE2_SCOPE_WHY="a fase declara 'Suite: completa'"
    return 0
  fi

  local crit
  crit="$(phase_changed_critical | head -n 3 | tr '\n' ' ' || true)"
  if [ -n "${crit//[[:space:]]/}" ]; then
    GATE2_SCOPE_WHY="mudanca critica na fase: ${crit% }"
    return 0
  fi

  local targets=() t
  while IFS= read -r t; do
    [ -n "$t" ] && [ -f "$t" ] && targets+=("$t")
  done < <( { phase_changed_tests; phase_declared_tests "$phase_file"; } | awk 'NF && !seen[$0]++' )

  if [ "${#targets[@]}" -eq 0 ]; then
    GATE2_SCOPE="skip"
    GATE2_SCOPE_CMD=""
    GATE2_SCOPE_WHY="a fase nao alterou nem citou arquivo de teste e nao tocou caminho critico"
    return 0
  fi

  local cmd
  cmd="$(scoped_test_cmd "${targets[@]}")"
  if [ -z "$cmd" ]; then
    GATE2_SCOPE_WHY="o runner ('$TEST_CMD') nao aceita escopo por caminho"
    return 0
  fi

  GATE2_SCOPE="scoped"
  GATE2_SCOPE_CMD="$cmd"
  GATE2_SCOPE_FILES="${targets[*]}"
  GATE2_SCOPE_WHY="${#targets[@]} arquivo(s) de teste desta fase"
}

# Gate 2 — os testes do projeto passam, rodados PELO ralph (fora da sessao do
# agente)? O ESCOPO e resolvido por fase: escopado no meio da spec, completo no
# fim dela e em toda mudanca critica.
gate2_tests_pass() {
  local test_log="$1"
  ST_TEST_LOG="$test_log"

  gate_start 2

  if [ -z "$TEST_CMD" ]; then
    GATE2_SCOPE=skip; GATE2_SCOPE_CMD=""; GATE2_SCOPE_WHY="comando de teste ausente"
    gate_end 2 skip
    return 0
  fi

  resolve_gate2_scope "${GATE2_PHASE_FILE:-}"

  if [ "$GATE2_SCOPE" = "skip" ]; then
    log "Gate 2 — nao executado: $GATE2_SCOPE_WHY"
    log "Gate 2 — a suite completa roda na ultima fase (gate final da spec); aqui quem julga e o gate 3"
    gate_end 2 skip
    return 0
  fi

  local run_cmd="$GATE2_SCOPE_CMD" scope_label="rodando a suite do projeto"
  [ "$GATE2_SCOPE" = "scoped" ] && scope_label="rodando os testes desta fase"

  # Arvore identica a da ultima execucao => a suite responderia a mesma coisa.
  # Foi exatamente isso que queimou 3 min por ciclo em quatro ciclos seguidos:
  # sessoes que nao escreveram nada, e a suite reexecutada para reafirmar o
  # mesmo veredito. So o VERDE e reaproveitado; o vermelho segue para o guarda
  # de ciclo improdutivo, que aborta a fase em vez de repetir a rodada.
  # O escopo entra na assinatura: um verde ESCOPADO nao pode ser reaproveitado
  # como veredito da suite COMPLETA na fase final.
  local sig
  sig="$(tree_signature)|$GATE2_SCOPE|$run_cmd"
  if [ -n "$GATE2_LAST_SIG" ] && [ "$sig" = "$GATE2_LAST_SIG" ] && [ "$GATE2_LAST_VERDICT" = "pass" ]; then
    log "Gate 2 — arvore identica a ultima execucao; veredito verde reaproveitado"
    gate_end 2 pass
    return 0
  fi

  set_activity "executando os testes do projeto"
  log "Gate 2 — $scope_label ($GATE2_SCOPE_WHY): $run_cmd"
  local rc=0
  # < /dev/null: sail test (docker compose exec) anexa stdin e consumiria o
  # stream de quem chamou, alem de poder travar esperando input.
  bash -c "$run_cmd" < /dev/null > "$test_log" 2>&1 || rc=$?

  # Ambiente fora do ar antes de qualquer outro julgamento: sem servico de pe a
  # suite nao mediu o codigo, e o baseline / o ponto fixo / o conserto estariam
  # todos raciocinando sobre um vermelho que nao e da fase.
  GATE2_INFRA=0
  if [ "$rc" -ne 0 ] && gate2_infra_failure "$test_log"; then
    warn "Gate 2 — a suite caiu por AMBIENTE, nao por codigo:"
    printf '%s\n' "$INFRA_SIGNATURE" | head -n 3 | sed 's/^/    /'
    if [ "$INFRA_RETRIED" -eq 0 ]; then
      INFRA_RETRIED=1
      recover_env || true
      log "Gate 2 — reexecutando a suite uma vez (unica reexecucao desta fase)"
      set_activity "reexecutando a suite apos recuperar o ambiente"
      rc=0
      bash -c "$run_cmd" < /dev/null > "$test_log" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ] && gate2_infra_failure "$test_log"; then
      GATE2_INFRA=1
      GATE2_LAST_SIG="$sig"; GATE2_LAST_VERDICT="fail"
      GATE_CAUSE="A suite NAO pode ser avaliada: servico externo fora do ar. Isto nao e veredito sobre o codigo da fase."$'\n'"$INFRA_SIGNATURE"
      gate_end 2 fail
      return 1
    fi
    # `[ ... ] && cmd` como ultima linha do bloco devolveria 1 e o `set -e`
    # mataria o run justamente no caminho em que o ambiente voltou.
    if [ "$rc" -eq 0 ]; then
      success "Gate 2 — ambiente recuperado; a suite rodou de verdade"
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    if gate2_within_baseline "$test_log"; then
      success "Gate 2 — sem regressao (as $BASELINE_COUNT falha(s) vermelhas ja existiam em HEAD)"
      GATE2_LAST_SIG="$sig"; GATE2_LAST_VERDICT="pass"
      gate_end 2 pass
      return 0
    fi
    # Mesmo vermelho, mesma arvore, duas vezes seguidas: a suite provou ser
    # funcao da arvore neste caso, entao insistir e ponto fixo. Medir DEPOIS de
    # rodar (e nao presumir antes) e o que preserva o caso legitimo da suite que
    # abre vermelha e fecha verde sobre a mesma arvore — migracao pendente,
    # cache frio, ordem de teste.
    if [ "$sig" = "$GATE2_LAST_SIG" ] && [ "$GATE2_LAST_VERDICT" = "fail" ]; then
      GATE2_STALE_RED=1
    else
      GATE2_STALE_RED=0
    fi
    GATE2_LAST_SIG="$sig"; GATE2_LAST_VERDICT="fail"
    local scope_note=""
    [ "$GATE2_SCOPE" = "scoped" ] && scope_note=" (escopo desta fase: $GATE2_SCOPE_WHY)"
    GATE_CAUSE="O comando de teste do projeto ('$run_cmd')$scope_note falhou com codigo $rc.${GATE2_DELTA_NOTE:- Saida:}"$'\n'"$(tail -n 200 "$test_log")"
    gate_end 2 fail
    return 1
  fi

  if [ "$GATE2_SCOPE" = "scoped" ]; then
    success "Gate 2 — testes da fase verdes (suite completa fica para a ultima fase)"
  else
    success "Gate 2 — suite verde"
  fi
  GATE2_LAST_SIG="$sig"; GATE2_LAST_VERDICT="pass"
  gate_end 2 pass
  return 0
}

# A suite voltou vermelha: e regressao DESTA fase ou o vermelho herdado de HEAD?
# Retorna 0 (sem regressao) so quando nenhum id novo aparece E o total de falhas
# nao subiu — a contagem cobre o caso de um teste novo quebrar dentro de uma
# suite que ja estava na linha de base.
gate2_within_baseline() {
  local test_log="$1"

  GATE2_DELTA_NOTE=""
  $BASELINE_ACTIVE || return 1
  [ -n "$BASELINE_FILE" ] && [ -f "$BASELINE_FILE" ] || return 1

  local atual_ids novos count
  atual_ids="$test_log.ids"
  gate2_failure_ids "$test_log" > "$atual_ids"
  novos="$(comm -13 "$BASELINE_FILE" "$atual_ids" || true)"
  count=$(gate2_failure_count "$test_log")

  if [ -z "$novos" ] && [ "$count" -le "$BASELINE_COUNT" ]; then
    return 0
  fi

  # Vermelho legitimo: o prompt do ciclo de correcao so precisa do DELTA. Mandar
  # as falhas herdadas junto ja custou ciclos inteiros com o engine tentando
  # consertar codigo que a fase nunca tocou.
  if [ -n "$novos" ]; then
    GATE2_DELTA_NOTE=" Falhas NOVAS em relacao a HEAD (as demais ja eram vermelhas antes do run e NAO sao desta fase — ignore-as):"$'\n'"  - ${novos//$'\n'/$'\n  - '}"$'\n'"Saida completa:"
  else
    GATE2_DELTA_NOTE=" O total de falhas subiu de $BASELINE_COUNT para $count sem suite nova vermelha: um teste novo quebrou dentro de uma suite que ja estava na linha de base. Saida:"
  fi
  return 1
}

# Gate 3 — sessao verificadora independente, read-only, task a task.
# O gate final: roda em toda fase por default (always). Modo auto economiza,
# rodando so quando o veredito do gate 2 nao basta:
#   - a sessao nao escreveu nada (claim "ja implementada" — so a verificacao
#     independente confirma isso sem confiar na palavra do engine)
#   - ciclo de correcao (a fase ja reprovou uma vez)
#   - gate 2 desabilitado (sem suite, o verificador e o unico gate)
# GATE3_RAN diz ao caminho "ja implementada" quais gates de fato validaram HEAD.
GATE3_RAN=0

# Posicoes das tasks que o verificador declarou INCOMPLETE na ultima reprovacao.
# Insumo do conserto cirurgico (o que reparar) e do escopo da revalidacao.
# Vazio quando o gate 3 reprovou por PROTOCOLO (nenhuma linha TASK, indice fora
# do intervalo, cobertura faltando) — isso nao e codigo faltando e nao e
# reparavel por patch.
GATE3_INCOMPLETE_IDX=""
GATE3_INCOMPLETE_LINES=""

# Tasks com campo `Tela:` da fase, uma por linha: pos|rota|seletores|alvo|tema.
# A posicao e a mesma que o verificador usa (indice do checkbox, a partir de 1).
phase_screen_tasks() {
  local phase_file="$1"
  [ -n "$phase_file" ] && [ -f "$PHASES_DIR/$phase_file" ] || return 0
  awk '
    /^[[:space:]]*- \[[ xX]\]/ { pos++; next }
    pos > 0 && /^[[:space:]]*(\*\*)?Tela(\*\*)?[[:space:]]*:/ {
      line = $0
      sub(/^[[:space:]]*(\*\*)?Tela(\*\*)?[[:space:]]*:[[:space:]]*/, "", line)
      n = split(line, f, /[[:space:]]*\|[[:space:]]*/)
      route = f[1]; sel = (n >= 2) ? f[2] : ""; target = (n >= 3) ? f[3] : ""; theme = (n >= 4) ? f[4] : ""
      gsub(/`/, "", route); gsub(/`/, "", sel); gsub(/`/, "", target); gsub(/`/, "", theme)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", route)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", sel)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", theme)
      print pos "|" route "|" sel "|" target "|" theme
    }
  ' "$PHASES_DIR/$phase_file"
}

# Comando de captura por convencao do repo. Vazio quando nao ha script.
detect_ui_shot_cmd() {
  local f
  for f in scripts/ralph-ui-shot.mjs scripts/ralph-ui-shot.js; do
    [ -f "$f" ] && { printf 'node %s' "$f"; return 0; }
  done
  [ -f scripts/ralph-ui-shot.sh ] && { printf 'bash scripts/ralph-ui-shot.sh'; return 0; }
  [ -f scripts/ralph-ui-shot.py ] && { printf 'python3 scripts/ralph-ui-shot.py'; return 0; }
  return 0
}

# Evidencia visual do gate 3: o RALPH fotografa cada task `Tela:` da fase
# antes de o verificador julgar. A prova nasce fora da sessao do engine — ele
# nao escreve, nao escolhe e nao edita o arquivo que o julga (o mesmo motivo
# pelo qual o gate 2 roda a suite fora da sessao). Fail-closed: fase com
# `Tela:` e sem comando de captura reprova, a menos que --no-ui-verify diga
# explicitamente que a prova visual nao e exigida.
# Retorna 1 com GATE_CAUSE preenchido quando a prova nao pode ser produzida.
gate3_capture_ui_evidence() {
  local phase_file="$1" cycle="$2"
  UI_SCREEN_TASKS="$(phase_screen_tasks "$phase_file")"
  [ -n "$UI_SCREEN_TASKS" ] || return 0

  local count
  count=$(printf '%s\n' "$UI_SCREEN_TASKS" | grep -c . || true)

  if [ "$UI_VERIFY_MODE" = "off" ]; then
    warn "Evidencia visual DESLIGADA (--no-ui-verify): $count task(s) com 'Tela:' serao julgadas so pelo codigo"
    UI_SCREEN_TASKS=""
    return 0
  fi
  # Convencao por repositorio: sem RALPH_UI_SHOT_CMD, um script
  # scripts/ralph-ui-shot.{mjs,js,sh,py} na raiz do projeto e o comando de
  # captura — a configuracao vive no repo, nunca no shell do operador.
  if [ -z "$UI_SHOT_CMD" ]; then
    UI_SHOT_CMD="$(detect_ui_shot_cmd)"
    [ -n "$UI_SHOT_CMD" ] && log "Evidencia visual — comando de captura detectado: $UI_SHOT_CMD"
  fi
  if [ -z "$UI_SHOT_CMD" ]; then
    GATE_CAUSE="A fase tem $count task(s) com campo 'Tela:' e nenhum comando de captura configurado (RALPH_UI_SHOT_CMD / --ui-shot-cmd) nem script scripts/ralph-ui-shot.{mjs,js,sh,py} no repo. Sem a foto da rota nao ha prova visual, e sem prova o gate 3 nao aceita DONE. Configure o comando ou desligue de proposito com --no-ui-verify."
    return 1
  fi

  local dir="$EVIDENCE_DIR/${phase_file%.md}"
  mkdir -p "$dir"
  log "Evidencia visual — fotografando $count tela(s) via: $UI_SHOT_CMD"

  local pos route sel target theme out shot_log rc viewport suffix
  while IFS='|' read -r pos route sel target theme; do
    [ -n "$pos" ] || continue
    if [ -z "$route" ] || [ -z "$sel" ]; then
      GATE_CAUSE="Task $pos: campo 'Tela:' malformado — esperado 'Tela: <rota> | <seletores CSS> | <png-alvo>' (rota e seletores obrigatorios)."
      return 1
    fi
    if [ -n "$target" ] && [ ! -f "$target" ]; then
      GATE_CAUSE="Task $pos: o PNG-alvo '$target' citado em 'Tela:' nao existe. Exporte o artboard antes de rodar a fase."
      return 1
    fi
    # Computador e celular: a regua visual cobre quebra de layout em 400px, que
    # a foto larga nunca mostra.
    for viewport in desktop mobile; do
      suffix=""
      [ "$viewport" = "mobile" ] && suffix="-mobile"
      out="$dir/task-${pos}${suffix}.png"
      shot_log="$dir/task-${pos}${suffix}.shot.log"
      rm -f "$out"
      rc=0
      if command -v timeout > /dev/null 2>&1; then
        RALPH_UI_VIEWPORT="$viewport" timeout "$UI_SHOT_TIMEOUT" bash -c "$UI_SHOT_CMD \"\$@\"" _ "$route" "$out" "$sel" "$theme" \
          < /dev/null > "$shot_log" 2>&1 || rc=$?
      else
        RALPH_UI_VIEWPORT="$viewport" bash -c "$UI_SHOT_CMD \"\$@\"" _ "$route" "$out" "$sel" "$theme" \
          < /dev/null > "$shot_log" 2>&1 || rc=$?
      fi
      if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
        GATE_CAUSE="Evidencia visual da task $pos falhou (rota '$route', seletores '$sel', viewport $viewport, exit $rc): a pagina nao renderizou ou um seletor obrigatorio nao existe. Saida da captura:"$'\n'"$(tail -n 40 "$shot_log" 2> /dev/null)"
        return 1
      fi
      log "  task $pos — $route${theme:+ ($theme)} [$viewport] -> $out"
    done
  done <<< "$UI_SCREEN_TASKS"

  return 0
}

# Fase verde => o ralph marca `[x]` nas tasks daquela fase no DOCUMENTO DE
# ENTRADA. Mecanico e pos-gate: o checkbox do PHASES.md vira registro do que
# os gates provaram, nunca declaracao do engine (que so marca a copia em
# .phases/). Roda antes do commit para entrar nele quando o arquivo e versionado.
sync_input_checkboxes() {
  local phase_num="$1"
  [ -n "$INPUT_FILE" ] && [ -f "$INPUT_FILE" ] || return 0
  local tmp="$INPUT_FILE.ralph.$$"
  if ! awk -v want="$phase_num" '
    /^## Phase [0-9]+: / { split($0, h, /[ :]+/); inside = (h[3] + 0 == want + 0); print; next }
    /^## / { inside = 0 }
    inside && /^[[:space:]]*- \[ \]/ { sub(/- \[ \]/, "- [x]") }
    { print }
  ' "$INPUT_FILE" > "$tmp" || ! mv -f "$tmp" "$INPUT_FILE"; then
    rm -f "$tmp"
  fi
}

gate3_independent_verify() {
  local phase_file="$1" cycle="$2" session_wrote="$3"
  local verify_log="$LOG_DIR/${phase_file%.md}.verify-${cycle}${GATE_TAG}.log"

  GATE3_RAN=0
  GATE3_INCOMPLETE_IDX=""
  GATE3_INCOMPLETE_LINES=""
  local remapped_labels=0
  gate_start 3

  case "$VERIFY_MODE" in
    off)
      log "Gate 3 pulado (--no-verify)"
      gate_end 3 skip
      return 0
      ;;
    auto)
      # Revalidacao escopada nunca e opcional: ela existe justamente porque o
      # gate 3 acabou de reprovar. Pular aqui daria verde sem verificar nada.
      #
      # `-n "$TEST_CMD"` nao servia como condicao: ele diz que o PROJETO tem
      # suite, nao que ESTA fase foi testada. Fase de fiacao, view ou config
      # nao altera nem cita arquivo de teste — o gate 2 resolve o escopo como
      # `skip` e nao executa nada. Pular o gate 3 ali fechava e commitava a
      # fase sem validacao mecanica nenhuma.
      #
      # A condicao certa e o veredito do gate 2 desta fase: ele rodou teste de
      # verdade e passou.
      if [ -z "$VERIFY_ONLY_IDX" ] && [ "$cycle" -eq 1 ] && [ "$session_wrote" -eq 1 ] \
        && [ -n "$TEST_CMD" ] && [ "${GATE2_SCOPE:-full}" != "skip" ]; then
        log "Gate 3 pulado: a suite cobriu esta fase e passou (RALPH_VERIFY=always para rodar sempre)"
        gate_end 3 skip
        return 0
      fi
      ;;
  esac

  local expected
  expected=$(grep -cE '^[[:space:]]*- \[[ x]\]' "$PHASES_DIR/$phase_file" || true)

  if [ "$expected" -eq 0 ]; then
    warn "Gate 3 pulado: a fase nao declara nenhuma task '- [ ]'"
    gate_end 3 skip
    return 0
  fi

  # Cobertura exigida. Normalmente e a fase inteira (1..expected). Na
  # revalidacao pos-conserto e so o escopo — mas nas POSICOES ORIGINAIS: o
  # intervalo valido continua 1..expected, nada e renumerado.
  local required scope_count
  if [ -n "$VERIFY_ONLY_IDX" ]; then
    required=$(printf '%s' "$VERIFY_ONLY_IDX" | tr ' ' '\n' | awk 'NF' | sort -n -u)
    scope_count=$(printf '%s' "$required" | grep -c . || true)
  else
    required=$(seq 1 "$expected")
    scope_count="$expected"
  fi

  GATE3_RAN=1
  if [ -n "$VERIFY_ONLY_IDX" ]; then
    set_activity "verificacao escopada ($scope_count de $expected tasks)"
    log "Gate 3 (escopado) — reverificando so a(s) task(s): $(printf '%s' "$required" | tr '\n' ' ')"
  else
    set_activity "verificacao independente ($expected tasks)"
    log "Gate 3 — sessao verificadora independente ($expected tasks${VERIFY_MODEL:+, modelo: $VERIFY_MODEL})"
  fi

  # A prova visual vem ANTES do verificador: se a captura nao existe, nao ha o
  # que julgar — e a fase reprova sem gastar uma sessao.
  if ! gate3_capture_ui_evidence "$phase_file" "$cycle"; then
    gate_end 3 fail
    return 1
  fi

  local prompt_file
  prompt_file=$(build_verify_prompt "$phase_file" "$cycle")
  run_engine "$prompt_file" "$verify_log" verify || true

  # SO o stdout do verificador (resposta final). O progresso vive no
  # .stderr.log e nunca e parseado: no codex a resposta final tambem sai no
  # stderr, e ler os dois duplicava toda linha TASK.
  # O TEXTO extraido, nao o NDJSON: em stream-json a resposta do verificador vem
  # escapada dentro de `.result`, e `^TASK` nunca casaria com ela.
  local task_lines
  task_lines=$(sed 's/^[[:space:]]*//' "$(engine_text_for "$verify_log")" 2> /dev/null \
    | grep -E '^TASK[[:space:]]+[0-9]+[[:space:]]*:[[:space:]]*(DONE|INCOMPLETE)' || true)

  local emitted
  emitted=$(printf '%s' "$task_lines" | grep -c . || true)

  if [ "$emitted" -eq 0 ]; then
    GATE_CAUSE="O verificador independente nao emitiu nenhuma linha 'TASK <n>: DONE|INCOMPLETE' — nao foi possivel confirmar que a fase esta completa. Ultimas linhas do verificador:"$'\n'"$(engine_tail "$verify_log" 40)"
    gate_end 3 fail
    return 1
  fi

  # DONE sem evidencia e linguagem confiante, nao veredito. Um verificador que
  # leu o codigo sabe apontar arquivo:linha; um que nao leu so sabe dizer DONE.
  # Reprova por protocolo (nao alimenta o conserto cirurgico: nao falta codigo,
  # falta prova).
  if [ "$VERIFY_EVIDENCE_MODE" = "required" ]; then
    local bare
    bare=$(printf '%s\n' "$task_lines" | grep -E 'DONE' \
      | grep -vE 'DONE[[:space:]]*[—–-]+.*([^[:space:]]+:[0-9]+|\.(png|jpe?g|webp))' || true)
    if [ -n "$bare" ]; then
      GATE_CAUSE="O verificador deu DONE sem evidencia (arquivo:linha ou captura .png) — veredito sem prova nao fecha task:"$'\n'"$bare"
      gate_end 3 fail
      return 1
    fi
  fi

  # Cobertura se mede em INDICES UNICOS, nao em linhas. O modelo repete linha
  # (retry, resumo no fim) e cada repeticao inflava a contagem: 2 tasks viravam
  # "4 de 2 — cobertura incompleta" com a fase inteira pronta.
  local indices parsed
  indices=$(printf '%s\n' "$task_lines" \
    | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*$/\1/p' \
    | sort -n -u)
  parsed=$(printf '%s' "$indices" | grep -c . || true)

  if [ "$emitted" -gt "$parsed" ]; then
    log "Gate 3 — $emitted linhas TASK emitidas, $parsed indice(s) unico(s) (duplicatas ignoradas)"
  fi

  # Indice fora de 1..expected: o verificador inventou task ou desalinhou a
  # numeracao. Contar isso como cobertura mascararia uma task real nao vista.
  local out_of_range
  out_of_range=$(printf '%s\n' "$indices" | awk -v max="$expected" 'NF && ($1 + 0 < 1 || $1 + 0 > max)' | tr '\n' ' ')

  # Fases fatiadas de um PHASES.md multi-fase carregam rotulos globais nas
  # tasks (ex.: 'T33'..'T35' na fase 9). Mesmo instruido a usar posicao, o
  # verificador tende a copiar o rotulo visivel. Se TODO indice emitido casa
  # com um rotulo da fase, a cobertura e verificavel do mesmo jeito:
  # remapeia rotulo -> posicao em vez de reprovar por "fora do intervalo".
  # Nao remapeia na verificacao escopada: o escopo ja e dado em posicoes, e
  # remapear rotulo -> posicao em cima de um subconjunto e como o falso verde
  # nasce.
  if [ -n "${out_of_range// /}" ] && [ -z "$VERIFY_ONLY_IDX" ]; then
    local labels label_count remapped
    labels=$(sed -nE 's/^[[:space:]]*- \[[ x]\][[:space:]]*\**T0*([0-9]+).*$/\1/p' "$PHASES_DIR/$phase_file")
    label_count=$(printf '%s' "$labels" | grep -c . || true)
    if [ "$label_count" -eq "$expected" ]; then
      remapped=$(awk '
        NR == FNR { if (NF) pos[$1 + 0] = ++n; next }
        NF { if (($1 + 0) in pos) print pos[$1 + 0]; else print "X" }
      ' <(printf '%s\n' "$labels") <(printf '%s\n' "$indices"))
      if ! printf '%s\n' "$remapped" | grep -qx 'X'; then
        indices=$(printf '%s\n' "$remapped" | sort -n -u)
        out_of_range=""
        remapped_labels=1
        log "Gate 3 — verificador emitiu rotulos das tasks em vez de posicoes; remapeado rotulo -> posicao (1..$expected)"
      fi
    fi
  fi

  if [ -n "${out_of_range// /}" ]; then
    GATE_CAUSE="O verificador emitiu indice(s) de task fora do intervalo 1..$expected: ${out_of_range%% }. A numeracao nao bate com a fase — nao da para confirmar cobertura. Linhas emitidas:"$'\n'"$task_lines"
    gate_end 3 fail
    return 1
  fi

  # Escopo. Um veredito fora do recorte nao e erro de protocolo: o verificador
  # so foi alem do pedido. DONE extra e ruido e vai fora. INCOMPLETE extra e
  # informacao NOVA sobre uma task que ja estava confirmada — o conserto
  # cirurgico quebrou algo que estava de pe. Isso reprova.
  if [ -n "$VERIFY_ONLY_IDX" ]; then
    local off_incomplete
    off_incomplete=$(awk 'FILENAME == ARGV[1] { if (NF) want[$1 + 0] = 1; next }
                          /INCOMPLETE/ { if (!(($2 + 0) in want)) print }' \
      <(printf '%s\n' "$required") <(printf '%s\n' "$task_lines"))

    if [ -n "$off_incomplete" ]; then
      GATE_CAUSE="O conserto cirurgico quebrou task(s) que ja estavam confirmadas:"$'\n'"$off_incomplete"
      gate_end 3 fail
      return 1
    fi

    task_lines=$(awk 'FILENAME == ARGV[1] { if (NF) want[$1 + 0] = 1; next }
                      NF && (($2 + 0) in want)' \
      <(printf '%s\n' "$required") <(printf '%s\n' "$task_lines"))
    indices=$(printf '%s\n' "$task_lines" \
      | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*$/\1/p' \
      | sort -n -u)
    parsed=$(printf '%s' "$indices" | grep -c . || true)
  fi

  # Duplicata nao pode esconder buraco: 'TASK 1' duas vezes e nenhum 'TASK 2'
  # da 2 linhas para 2 tasks, mas cobre so metade da fase.
  # Publica o veredito POR TASK para o painel e o dashboard. Apresentacao pura:
  # o gate ja decidiu abaixo; isto so torna visivel QUAL task travou.
  # Quando houve remapeamento rotulo -> posicao, os indices de `indices` estao
  # normalizados mas os de `task_lines` nao: misturar os dois pintaria de verde
  # uma task incompleta. Nesse caso nao publica nada — pendente e honesto.
  local vfile="$UI_DIR/verdicts-${ST_PHASE_NUM}.txt"
  if [ "$remapped_labels" -eq 0 ]; then
    local vtmp="$vfile.tmp.$$"
    if ! {
      # Verificacao escopada julga so um recorte: reescrever o arquivo inteiro
      # apagaria o veredito das tasks que continuam validas e o painel as
      # mostraria como pendentes. Preserva o que esta fora do escopo.
      if [ -n "$VERIFY_ONLY_IDX" ] && [ -f "$vfile" ]; then
        awk -F'|' 'FILENAME == ARGV[1] { if (NF) want[$1 + 0] = 1; next }
                   NF && !(($1 + 0) in want)' \
          <(printf '%s\n' "$required") "$vfile" 2> /dev/null || true
      fi
      printf '%s\n' "$indices"    | awk 'NF { print $1 "|DONE" }'
      printf '%s\n' "$task_lines" | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*INCOMPLETE.*/\1|INCOMPLETE/p'
    } > "$vtmp" 2> /dev/null || ! mv -f "$vtmp" "$vfile" 2> /dev/null; then
      rm -f "$vtmp" 2> /dev/null
    fi
  else
    rm -f "$vfile" 2> /dev/null || true
  fi

  # Cobertura contra o conjunto EXIGIDO (a fase inteira, ou so o escopo).
  local missing
  missing=$(awk 'FILENAME == ARGV[1] { if (NF) seen[$1 + 0] = 1; next }
                 NF && !(($1 + 0) in seen) { printf "%d ", $1 }' \
    <(printf '%s\n' "$indices") <(printf '%s\n' "$required"))

  if [ -n "${missing// /}" ]; then
    GATE_CAUSE="O verificador cobriu $parsed de $scope_count tasks — faltou veredito para a(s) task(s): ${missing%% }. Linhas emitidas:"$'\n'"$task_lines"
    gate_end 3 fail
    return 1
  fi

  # INCOMPLETE vence DONE no mesmo indice: se o verificador se contradisse
  # sobre a mesma task, o gate fica vermelho. Falso vermelho custa um ciclo de
  # correcao; falso verde commita codigo quebrado.
  local incomplete
  incomplete=$(printf '%s\n' "$task_lines" | grep 'INCOMPLETE' | awk '!seen[$2]++' || true)

  if [ -n "$incomplete" ]; then
    # Unica reprovacao do gate 3 que e "falta codigo" e nao "protocolo quebrado":
    # so ela alimenta o conserto cirurgico. Publicado apos o remapeamento, entao
    # os indices ja estao em posicao — exceto quando houve remap, caso em que
    # `task_lines` continua com rotulo e o escopo seria mentiroso.
    if [ "$remapped_labels" -eq 0 ]; then
      GATE3_INCOMPLETE_LINES="$incomplete"
      GATE3_INCOMPLETE_IDX=$(printf '%s\n' "$incomplete" \
        | sed -nE 's/^TASK[[:space:]]+([0-9]+)[[:space:]]*:.*$/\1/p' \
        | sort -n -u | tr '\n' ' ')
      GATE3_INCOMPLETE_IDX="${GATE3_INCOMPLETE_IDX%% }"
    fi
    GATE_CAUSE="O verificador independente encontrou tasks incompletas:"$'\n'"$incomplete"
    gate_end 3 fail
    return 1
  fi

  if [ -n "$VERIFY_ONLY_IDX" ]; then
    success "Gate 3 (escopado) — $parsed/$scope_count task(s) reverificada(s) e confirmada(s)"
  else
    success "Gate 3 — $parsed/$expected tasks confirmadas no codigo"
  fi
  gate_end 3 pass
  return 0
}

# O GATE_CAUSE carrega ate 200 linhas de saida de suite porque o prompt do ciclo
# de correcao precisa do contexto. Imprimir o `head` disso mostra o COMECO do
# tail — dezenas de linhas de teste VERDE — e esconde a falha do operador. Aqui
# a saida e para o humano: cabecalho + as linhas que marcam falha; sem marcador,
# as ultimas linhas.
print_gate_cause() {
  local max="${1:-20}" head_line body marks
  head_line=$(printf '%s\n' "$GATE_CAUSE" | head -n 1)
  body=$(printf '%s\n' "$GATE_CAUSE" | tail -n +2)
  printf '    %s\n' "$head_line"
  marks=$(printf '%s\n' "$body" \
    | grep -aE '(FAILED|FAILURES|--- FAIL:|^[[:space:]]*FAIL[[:space:]]|✕|⨯|×|●|Failed asserting|Expected[[:space:]]*:|Received[[:space:]]*:|AssertionError|Error[[:space:]]*:|Exception|^[[:space:]]*Tests:)' \
    | awk '!seen[$0]++' | head -n "$max" || true)
  if [ -n "${marks//[[:space:]]/}" ]; then
    printf '%s\n' "$marks" | sed 's/^/    /'
  else
    printf '%s\n' "$body" | tail -n "$max" | sed 's/^/    /'
  fi
}

# ---------------------------------------------------------------------------
# Execucao de fase
# ---------------------------------------------------------------------------

commit_phase() {
  local phase_num="$1" phase_title="$2" rescue_round="${3:-0}"
  git add -A
  if git diff --cached --quiet; then
    fail "Nada para commitar apos os gates — estado inesperado."
    return 1
  fi
  # Verde de resgate e verde igual — os gates foram os mesmos. Mas a fase que
  # precisou da sessao larga merece revisao humana com prioridade, e isso tem
  # que estar no historico, nao so no log que alguem apaga.
  if [ "$rescue_round" -gt 0 ] 2> /dev/null; then
    git commit -q -m "feat(phase-${phase_num}): ${phase_title}" \
      -m "Fechada pela sessao de resgate (round ${rescue_round}) apos gate vermelho. Ver .phases/logs/."
    log "Commit criado (resgate round ${rescue_round}): feat(phase-${phase_num}): ${phase_title}"
    return 0
  fi
  git commit -q -m "feat(phase-${phase_num}): ${phase_title}"
  log "Commit criado: feat(phase-${phase_num}): ${phase_title}"
}

commit_wip() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): incomplete — see .phases/logs/"
  warn "Commit wip criado para a fase $phase_num — a proxima fase parte de arvore limpa"
}

# Interrupcao por ambiente nao pode custar o trabalho da fase. O codigo pode
# estar inteiro e correto — foi o servico que caiu, e a suite nunca o julgou.
# Commit em vez de aviso: um `git checkout -- .` distraido apagaria tudo.
commit_wip_env() {
  local phase_num="$1"
  [ -n "$(git status --porcelain)" ] || return 0
  git add -A
  git commit -q -m "wip(phase-${phase_num}): interrompido por falha de ambiente — see .phases/logs/"
  warn "Trabalho da fase $phase_num salvo em commit wip."
  warn "Suba os servicos e re-rode o ralph: ele revalida a fase e segue de onde parou."
}

# ---------------------------------------------------------------------------
# Conserto cirurgico
#
# Acionamento independente entre o gate vermelho e o ciclo de correcao. Nunca
# commita, nunca decide gate: patch + devolve a fase para a MESMA cadeia.
# ---------------------------------------------------------------------------

REPAIR_SKIP_REASON=""

# repair_classify <gate2|gate3> <test_log>
#   rc 0 = reparavel (REPAIR_SIGNATURE pronta)
#   rc 1 = nao reparavel (REPAIR_SKIP_REASON explica; o ciclo completo assume)
#
# Fail-closed por desenho. Um conserto cirurgico so faz sentido com um alvo:
# sem alvo, o patch vira chute e sai mais caro que o ciclo que ele evitaria.
repair_classify() {
  local gate="$1" test_log="$2"
  REPAIR_SIGNATURE=""
  REPAIR_SKIP_REASON=""
  REPAIR_FILES=""

  case "$gate" in
    gate2)
      if ! extract_failure_signature "$test_log"; then
        REPAIR_SKIP_REASON="a saida da suite nao trouxe falha localizavel"
        return 1
      fi
      local files
      files=$(repair_file_count)
      if [ "$files" -gt "$REPAIR_MAX_FILES" ]; then
        REPAIR_SKIP_REASON="a falha atinge $files arquivos (limite: $REPAIR_MAX_FILES) — larga demais para conserto cirurgico"
        return 1
      fi
      return 0
      ;;
    gate3)
      # So INCOMPLETE alimenta conserto. Gate 3 vermelho por protocolo do
      # verificador (nenhuma linha TASK, indice fora do intervalo, cobertura
      # faltando) nao e codigo faltando: patch nenhum resolve.
      if [ -z "$GATE3_INCOMPLETE_IDX" ]; then
        REPAIR_SKIP_REASON="o gate 3 reprovou pelo protocolo do verificador, nao por task incompleta"
        return 1
      fi
      local tasks
      tasks=$(printf '%s' "$GATE3_INCOMPLETE_IDX" | tr ' ' '\n' | grep -c . || true)
      if [ "$tasks" -gt "$REPAIR_MAX_TASKS" ]; then
        REPAIR_SKIP_REASON="$tasks tasks incompletas (limite: $REPAIR_MAX_TASKS) — e reimplementacao, nao conserto"
        return 1
      fi
      REPAIR_SIGNATURE="Tasks reprovadas pelo verificador independente:"$'\n'"$GATE3_INCOMPLETE_LINES"
      return 0
      ;;
    *)
      REPAIR_SKIP_REASON="gate nao reparavel"
      return 1
      ;;
  esac
}

# run_repair <phase_file> <cycle> <round> <gate>
#   rc 0 = patch aplicado, revalidar
#   rc 1 = nao consertou — o ciclo de correcao assume agora. Insistir com outro
#          round depois de "nao sei" ou de zero escrita e desperdicio garantido.
run_repair() {
  local phase_file="$1" cycle="$2" round="$3" gate="$4"
  local prompt_file log_file rc=0 sig_before
  # GATE_CAUSE e o insumo do ciclo de correcao la na frente. gate0 sobrescreve
  # em caso de falha do engine do conserto: guarda a causa REAL da fase.
  local saved_cause="$GATE_CAUSE"

  log_file="$LOG_DIR/${phase_file%.md}.repair-${cycle}-${round}.log"
  prompt_file=$(build_repair_prompt "$phase_file" "$cycle" "$round" "$gate" "$REPAIR_SIGNATURE")

  export RALPH_PHASE_REPAIR="$round"
  ST_REPAIR="running"
  ST_REPAIR_ROUND="$round"
  set_activity "conserto cirurgico (round $round/$MAX_REPAIRS)"
  state_event repair_start "gate=$gate" "round=$round"
  log "Conserto cirurgico $round/$MAX_REPAIRS sobre o $gate${REPAIR_MODEL:+ (modelo: $REPAIR_MODEL)}"

  REPAIR_ABORTED=0
  REPAIR_ABORT_WHY=""
  sig_before=$(tree_signature)
  run_engine "$prompt_file" "$log_file" repair || rc=$?

  if ! gate0_engine_finished "$log_file" "$rc"; then
    ST_REPAIR="fail"
    state_event repair_end "round=$round" "verdict=engine_failed"
    warn "Conserto nao concluiu (engine); o ciclo de correcao assume."
    GATE_CAUSE="$saved_cause"
    return 1
  fi

  # A arvore e o veredito, nao o texto. Um log que MENCIONA REPAIR_ABORT depois
  # de ter editado arquivos nao e desistencia — quem decide e o diff. Checar a
  # arvore primeiro tambem tira o falso positivo do grep no JSON do claude.
  if [ "$(tree_signature)" = "$sig_before" ]; then
    ST_REPAIR="fail"
    if grep -qa 'REPAIR_ABORT:' "$(engine_text_for "$log_file")" 2> /dev/null; then
      local why
      why=$(grep -aoE 'REPAIR_ABORT:.*' "$(engine_text_for "$log_file")" | head -n 1 | cut -c1-200 || true)
      # O resgate recebe esse motivo verbatim: e a conclusao mais barata que o
      # harness produziu sobre a fase, e ate agora ela morria no log.
      REPAIR_ABORT_WHY="$why"
      state_event repair_end "round=$round" "verdict=abort"
      warn "Conserto abortado pelo modelo — $why"
      # REPAIR_ABORT nao e "nao consegui": e "isto nao se conserta escrevendo
      # codigo". Voltar ao ciclo de correcao so entrega o MESMO problema a um
      # modelo maior e mais caro, que vai chegar a mesma conclusao. O sinal mais
      # barato do harness era o unico ignorado.
      REPAIR_ABORTED=1
    else
      state_event repair_end "round=$round" "verdict=no_change"
      warn "Conserto nao alterou nenhum arquivo; o ciclo de correcao assume."
    fi
    GATE_CAUSE="$saved_cause"
    return 1
  fi

  ST_REPAIR="ok"
  state_event repair_end "round=$round" "verdict=patched"
  success "Conserto aplicado (round $round) — revalidando"
  return 0
}

# ---------------------------------------------------------------------------
# Sessao de resgate
#
# Ultima etapa antes de dar a fase por perdida. Nao substitui gate: entrega a
# fase de volta a MESMA cadeia (gate 2 inteiro + gate 3 de todas as tasks).
# ---------------------------------------------------------------------------

# rescue_should_run <round_ja_gasto>
#   rc 0 = ainda cabe uma sessao de resgate
#   rc 1 = nao cabe (desligado, orcamento no fim, ambiente caido, ou o proprio
#          resgate ja declarou bloqueio de especificacao)
rescue_should_run() {
  local round="$1"
  [ "$MAX_RESCUES" -gt 0 ] || return 1
  # Ambiente fora do ar nao e defeito de codigo: nenhuma sessao levanta um
  # servico morto, e a fase tem desfecho proprio (commit wip + exit 3).
  [ "$ENV_ABORT" -eq 0 ] || return 1
  # RESCUE_BLOCKED e decisao humana pendente, nao "tente de novo".
  [ "$RESCUE_BLOCKED" -eq 0 ] || return 1
  [ "$round" -lt "$MAX_RESCUES" ] || return 1
  return 0
}

# run_phase <phase_file> <phase_num> <phase_title> <seq> <total>
run_phase() {
  local phase_file="$1" phase_num="$2" phase_title="$3" seq="$4" total="$5"
  local phase_start
  phase_start=$(date +%s)

  export RALPH_PHASE_TITLE="$phase_title"
  export RALPH_PHASE_NUM="$phase_num"
  export RALPH_PHASE_TOTAL="$total"
  export RALPH_PROJECT="$PROJECT_NAME"

  LIMIT_WAITS=0
  GATE_CAUSE=""
  ST_LAST_ERROR=""
  ST_FAILURE_GATE=""; ST_FAILURE_CYCLE=0; ST_FAILURE_LOG=""; ST_TEST_LOG=""
  GATE2_SCOPE=""; GATE2_SCOPE_CMD=""; GATE2_SCOPE_WHY=""; GATE2_SCOPE_FILES=""
  ST_GATE0=pending; ST_GATE1=pending; ST_GATE2=pending; ST_GATE3=pending
  ST_PREV_GATE0=pending; ST_PREV_GATE1=pending; ST_PREV_GATE2=pending; ST_PREV_GATE3=pending
  # Memoria do gate 2 e abortos sao POR FASE: a fase seguinte parte de outra
  # arvore e nao pode herdar veredito nem desistencia da anterior.
  GATE2_LAST_SIG=""
  GATE2_LAST_VERDICT=""
  GATE2_STALE_RED=0
  GATE2_INFRA=0
  # A reexecucao pos-recuperacao e por FASE: cada fase tem direito a uma.
  INFRA_RETRIED=0
  # Escopo do gate 2: qual fase e esta, e se ela e a ultima do documento — a
  # unica em que a suite completa roda no fluxo normal.
  GATE2_PHASE_FILE="$phase_file"
  PHASE_IS_FINAL=0
  if [ -n "$FINAL_PHASE_FILE" ] && [ "$phase_file" = "$FINAL_PHASE_FILE" ]; then
    PHASE_IS_FINAL=1
  fi
  REPAIR_ABORTED=0
  REPAIR_ABORT_WHY=""
  PHASE_ABORT_REASON=""
  # Resgate tambem e por FASE: orcamento, bloqueio e motivo nao atravessam.
  RESCUE_BLOCKED=0
  RESCUE_BLOCK_WHY=""
  ST_RESCUE="idle"
  ST_RESCUE_ROUND=0

  ST_PHASE_NUM="$phase_num"
  ST_PHASE_SEQ="$seq"
  ST_PHASE_TOTAL="$total"
  ST_PHASE_TITLE="$phase_title"
  ST_PHASE_STATUS="running"
  ST_PHASE_START="$phase_start"
  ST_CYCLE=1
  state_event phase_start "title=$phase_title" "seq=$seq" "total=$total"

  $UI_ACTIVE || echo ""
  log "[$seq/$total] Phase $phase_num: $phase_title"

  # Uma tentativa e um ciclo OU uma sessao de resgate. O resgate nao consome
  # ciclo: ele so existe depois que os ciclos e os consertos ja falharam.
  local cycle=1 rescue_round=0 attempt_is_rescue=0
  local rescue_reason="" rescue_cause="" rescue_gate=""
  while true; do
    # Ciclos esgotados nao encerram mais a fase sozinhos: enquanto houver
    # orcamento de resgate, a fase ganha a sessao larga antes de ser reprovada.
    if [ "$attempt_is_rescue" -eq 0 ] && [ "$cycle" -gt "$MAX_CYCLES" ]; then
      if rescue_should_run "$rescue_round"; then
        rescue_reason="os $MAX_CYCLES ciclos de correcao terminaram com o gate vermelho."
        rescue_cause="$GATE_CAUSE"
        rescue_gate="$LAST_GATE"
        rescue_round=$((rescue_round + 1))
        attempt_is_rescue=1
      else
        break
      fi
    fi

    export RALPH_PHASE_ATTEMPT="$cycle"
    export RALPH_PHASE_REPAIR=0
    export RALPH_PHASE_RESCUE="$rescue_round"
    # O painel conta ciclos; a tentativa de resgate acontece depois do ultimo e
    # nao pode exibir "6/5". O round do resgate tem campo proprio.
    if [ "$cycle" -le "$MAX_CYCLES" ]; then
      ST_CYCLE="$cycle"
    else
      ST_CYCLE="$MAX_CYCLES"
    fi
    # Ciclo novo revalida tudo: gates do ciclo anterior nao valem mais.
    snapshot_gates
    ST_GATE0="pending"; ST_GATE1="pending"; ST_GATE2="pending"; ST_GATE3="pending"
    ST_REPAIR="idle"; ST_REPAIR_ROUND=0
    VERIFY_ONLY_IDX=""

    # Tentativa de resgate e uma rodada inteira de gates com nome proprio: os
    # logs dela nao podem sobrescrever os do ultimo ciclo.
    local prompt_file log_file rc=0 sig_before
    local cycle_label="$cycle" engine_mode="impl"
    if [ "$attempt_is_rescue" -eq 1 ]; then
      cycle_label="rescue${rescue_round}"
      engine_mode="rescue"
    fi
    GATE_TAG=""

    if [ "$attempt_is_rescue" -eq 1 ]; then
      log_file="$LOG_DIR/${phase_file%.md}.rescue-${rescue_round}.log"
      prompt_file=$(build_rescue_prompt "$phase_file" "$rescue_round" \
        "$rescue_reason" "$rescue_gate" "$rescue_cause")
      ST_RESCUE="running"
      ST_RESCUE_ROUND="$rescue_round"
      state_event rescue_start "round=$rescue_round" "gate=${rescue_gate:-?}"
      warn "Sessao de resgate $rescue_round/$MAX_RESCUES${RESCUE_MODEL:+ (modelo: $RESCUE_MODEL)} — $rescue_reason"
      set_activity "sessao de resgate (round $rescue_round/$MAX_RESCUES)"
    else
      log_file="$LOG_DIR/${phase_file%.md}.cycle-${cycle}.log"
      [ "$cycle" -gt 1 ] && warn "Ciclo de correcao $cycle/$MAX_CYCLES..."
      if [ "$cycle" -eq 1 ]; then
        prompt_file=$(build_impl_prompt "$phase_file" "$cycle")
        set_activity "implementando a fase"
      else
        prompt_file=$(build_fix_prompt "$phase_file" "$cycle" "$LAST_GATE" "$GATE_CAUSE")
        set_activity "corrigindo a fase (ciclo $cycle/$MAX_CYCLES)"
      fi
    fi

    sig_before=$(session_signature)
    run_engine "$prompt_file" "$log_file" "$engine_mode" || rc=$?

    # Registra o que a sessao tocou ANTES de qualquer gate. O pintor tambem
    # alimenta este acumulador, mas o ritmo dele e melhor esforco: se a ultima
    # varredura caiu antes do engine escrever o ultimo arquivo, so esta chamada
    # garante que a task correspondente seja contada.
    ui_touch_record "$phase_num" "$log_file"

    GATE_CAUSE=""

    # Gate 1 e sinal, nao veredito: uma fase ja implementada faz o engine
    # (corretamente) nao escrever nada. Quem decide sao os gates 2 e 3.
    # O sinal tambem alimenta o modo auto do gate 3: sessao sem escrita e
    # exatamente o caso em que a verificacao independente e obrigatoria.
    local no_change_note="" session_wrote=1
    gate_start 1
    if ! gate1_session_wrote "$sig_before"; then
      session_wrote=0
      no_change_note="A sessao anterior terminou sem alterar nenhum arquivo. "
      warn "Gate 1 — a sessao nao escreveu nada; validando o codigo existente"
      # Sinal, nao veredito: 'skip' e o unico rotulo honesto aqui. Marcar 'fail'
      # pintaria de vermelho o caso legitimo da fase ja implementada.
      gate_end 1 skip
    else
      gate_end 1 pass
    fi

    # Bloqueio de especificacao declarado pelo resgate. Mesma prova do
    # REPAIR_ABORT: a ARVORE decide, nao o texto — um log que menciona
    # RESCUE_BLOCKED depois de ter editado arquivos nao e desistencia.
    if [ "$attempt_is_rescue" -eq 1 ] && [ "$session_wrote" -eq 0 ] \
      && grep -qa 'RESCUE_BLOCKED:' "$(engine_text_for "$log_file")" 2> /dev/null; then
      RESCUE_BLOCK_WHY=$(grep -aoE 'RESCUE_BLOCKED:.*' "$(engine_text_for "$log_file")" | head -n 1 | cut -c1-240 || true)
      RESCUE_BLOCKED=1
      ST_RESCUE="blocked"
      state_event rescue_end "round=$rescue_round" "verdict=blocked"
      LAST_GATE="resgate — bloqueio de especificacao"
      # Conflito de especificacao nao se resolve gastando outra sessao: quem
      # decide qual dos dois lados cede e o humano.
      PHASE_ABORT_REASON="a sessao de resgate declarou bloqueio de especificacao — $RESCUE_BLOCK_WHY"
      fail "Resgate $rescue_round/$MAX_RESCUES: $RESCUE_BLOCK_WHY"
      break
    fi

    # Gate 0 fora da cadeia if/elif: precisa registrar o veredito no estado
    # ANTES de decidir o fluxo, e a cadeia so aceita um comando por ramo.
    local gate0_ok=1
    gate_start 0
    if gate0_engine_finished "$log_file" "$rc"; then
      gate_end 0 pass
    else
      gate_end 0 fail
      gate0_ok=0
    fi

    # Cadeia 2/3 com conserto cirurgico entre o vermelho e o proximo ciclo.
    # phase_green=1 so quando a cadeia COMPLETA (suite inteira + verificacao de
    # todas as tasks) fecha verde — escopo verde nunca commita.
    local phase_green=0 repair_round=0 gate2_fresh=0
    if [ "$gate0_ok" -eq 0 ]; then
      LAST_GATE="gate 0 — engine nao concluiu"
      ST_LAST_ERROR="$(gate_cause_summary)"
      ST_FAILURE_GATE=gate0; ST_FAILURE_CYCLE="$ST_CYCLE"; ST_FAILURE_LOG="$log_file"
      state_sync
      # Engine morto nao tem erro de codigo para apontar: nada a reparar.
      fail "Gate 0 vermelho"
    else
      while true; do
        local failed_gate="" test_log rrc=0
        test_log="$LOG_DIR/${phase_file%.md}.test-${cycle_label}${GATE_TAG}.log"
        GATE_CAUSE=""

        if [ "$gate2_fresh" -eq 1 ]; then
          # A arvore nao mudou desde a suite verde deste mesmo ciclo: rodar de
          # novo custaria minutos para reafirmar o que ja foi provado.
          log "Gate 2 — suite ja verde nesta arvore, nao reexecutada"
        elif gate2_tests_pass "$test_log"; then
          gate2_fresh=1
        else
          failed_gate="gate2"
          LAST_GATE="gate 2 — suite de testes do projeto"
        fi

        if [ -z "$failed_gate" ] && ! gate3_independent_verify "$phase_file" "$cycle_label" "$session_wrote"; then
          failed_gate="gate3"
          LAST_GATE="gate 3 — verificacao independente"
        fi

        if [ -z "$failed_gate" ]; then
          # Verde no escopo NAO fecha a fase. Antes de commitar, a verificacao
          # roda sobre TODAS as tasks — o conserto pode ter quebrado uma que ja
          # estava confirmada, e o escopo nunca olharia para ela.
          if [ -n "$VERIFY_ONLY_IDX" ]; then
            log "Escopo verde — revalidando a fase inteira antes do commit"
            GATE_TAG="${GATE_TAG}f"
            VERIFY_ONLY_IDX=""
            continue
          fi
          phase_green=1
          break
        fi

        GATE_CAUSE="${no_change_note}${GATE_CAUSE}"
        ST_LAST_ERROR="$(gate_cause_summary)"
        ST_FAILURE_GATE="$failed_gate"; ST_FAILURE_CYCLE="$ST_CYCLE"
        if [ "$failed_gate" = gate2 ]; then ST_FAILURE_LOG="$test_log"
        else ST_FAILURE_LOG="$LOG_DIR/${phase_file%.md}.verify-${cycle_label}${GATE_TAG}.log"; fi
        state_sync

        # Ambiente fora do ar nao e vermelho da fase: nao gasta ciclo, nao gasta
        # conserto cirurgico e nao condena o codigo ja escrito. O gate 2 ja
        # tentou levantar os servicos e reexecutou a suite uma vez.
        if [ "$GATE2_INFRA" -eq 1 ]; then
          LAST_GATE="ambiente fora do ar (gate 2)"
          fail "Gate 2 — ambiente fora do ar; a fase nao chegou a ser julgada"
          ENV_ABORT=1
          PHASE_ABORT_REASON="a suite nao pode ser avaliada: servico externo fora do ar. Ciclo nenhum e patch nenhum levantam um servico morto."
          break
        fi

        if [ "$failed_gate" = "gate2" ]; then
          fail "Gate 2 vermelho — testes do projeto falharam"
        else
          fail "Gate 3 vermelho — implementacao incompleta"
        fi

        # Ponto fixo provado: a sessao nao escreveu nada E o gate 2 devolveu o
        # mesmo vermelho sobre a mesma arvore. O proximo ciclo receberia prompt
        # identico e chegaria ao mesmo lugar — gastar o orcamento restante aqui
        # e desperdicio garantido, nao persistencia.
        if [ "$failed_gate" = "gate2" ] && [ "$GATE2_STALE_RED" -eq 1 ] && [ "$session_wrote" -eq 0 ]; then
          LAST_GATE="ciclo improdutivo (gate 2)"
          PHASE_ABORT_REASON="o engine nao alterou nenhum arquivo e o gate 2 repetiu o mesmo vermelho sobre a mesma arvore. Ciclos adicionais receberiam o mesmo prompt e o mesmo veredito."
          break
        fi

        if [ "$repair_round" -ge "$MAX_REPAIRS" ]; then
          [ "$MAX_REPAIRS" -gt 0 ] && log "Consertos cirurgicos esgotados ($MAX_REPAIRS) — indo para o ciclo de correcao"
          break
        fi

        if ! repair_classify "$failed_gate" "$test_log"; then
          log "Conserto cirurgico nao se aplica: $REPAIR_SKIP_REASON"
          break
        fi

        repair_round=$((repair_round + 1))
        run_repair "$phase_file" "$cycle_label" "$repair_round" "$failed_gate" || rrc=$?
        if [ "$REPAIR_ABORTED" -eq 1 ]; then
          PHASE_ABORT_REASON="o conserto cirurgico desistiu (REPAIR_ABORT): a causa do $failed_gate nao se resolve escrevendo codigo. Ciclos adicionais repetiriam o mesmo veredito."
          break
        fi
        [ "$rrc" -eq 0 ] || break

        # Revalidacao: logs proprios (nao sobrescreve o round anterior) e, no
        # gate 3, escopo nas tasks que travaram — nas posicoes ORIGINAIS.
        GATE_TAG="r${repair_round}"
        gate2_fresh=0
        snapshot_gates
        # O conserto escreveu — o modo auto do gate 3 nao pode mais tratar a
        # revalidacao como "sessao sem escrita". Ja `no_change_note` continua
        # valendo: ele fala da SESSAO DE IMPLEMENTACAO, e essa segue vazia; e o
        # sinal que o ciclo de correcao precisa receber.
        session_wrote=1
        if [ "$failed_gate" = "gate3" ]; then
          VERIFY_ONLY_IDX="$GATE3_INCOMPLETE_IDX"
        else
          VERIFY_ONLY_IDX=""
        fi
      done
    fi

    if [ "$phase_green" -eq 1 ]; then
      local phase_duration=$(($(date +%s) - phase_start))

      # Gates verdes e nada a commitar => a fase ja estava implementada em HEAD
      # (run anterior commitada, tasks [x], codigo escrito a mao).
      # Checkbox do documento de entrada = registro dos gates, nao do engine.
      # Sincroniza ANTES de olhar a arvore: se o PHASES.md e versionado, a
      # marcacao entra no commit da fase.
      # Fase ja implementada com input versionado: marcar agora criaria um
      # commit que o run nao teve — a marcacao fica para o proximo commit de
      # fase. Input fora do git (ex.: .spec ignorado) marca sempre.
      if [ -n "$(git status --porcelain)" ] || ! git ls-files --error-unmatch -- "$INPUT_FILE" > /dev/null 2>&1; then
        sync_input_checkboxes "$phase_num"
      fi
      if [ -z "$(git status --porcelain)" ]; then
        success "Phase $phase_num: $phase_title — JA IMPLEMENTADA (nada a commitar)"
        if [ "$GATE3_RAN" -eq 1 ] && [ "$ST_GATE2" = "skip" ]; then
          log "Gate 3 verde contra o codigo em HEAD; nenhum commit criado."
        elif [ "$GATE3_RAN" -eq 1 ]; then
          log "Gates 2 e 3 verdes contra o codigo em HEAD; nenhum commit criado."
        else
          log "Gate 2 verde contra o codigo em HEAD; nenhum commit criado."
        fi
        mark_phase_done "$phase_file"
        ST_PHASE_STATUS="done"
        notify_and_record phase_done \
          "Fase ja estava implementada em HEAD — gates verdes, nenhum commit criado."
        return 0
      fi

      if [ "$attempt_is_rescue" -eq 1 ]; then
        ST_RESCUE="ok"
        state_event rescue_end "round=$rescue_round" "verdict=green"
        success "Resgate $rescue_round/$MAX_RESCUES fechou a fase — gates completos verdes"
      fi
      success "Phase $phase_num: $phase_title — COMPLETA ($(format_duration "$phase_duration"))"
      # Ultima chance de registrar a arvore com a fase ainda suja: depois do
      # commit `git status` volta vazio e o acumulador nao teria mais fonte.
      ui_touch_record "$phase_num" "$log_file"
      if ! commit_phase "$phase_num" "$phase_title" "$rescue_round"; then
        LAST_GATE="commit"
        ST_PHASE_STATUS="failed"
        FAILED_NUMS+=" $phase_num"
        notify_and_record phase_failed \
          "Gates verdes, mas o commit da fase falhou. O run parou aqui."
        return 1
      fi
      mark_phase_done "$phase_file"
      ST_PHASE_STATUS="done"
      notify_and_record phase_done \
        "Fase COMPLETA em $(format_duration "$phase_duration") — commitada. Restam $((total - seq)) fase(s)."
      return 0
    fi

    # So se chega aqui com gate vermelho. No modo quiet o progresso do engine
    # nao passou pelo terminal: diga onde ele esta antes de gastar outro ciclo.
    if ! $VERBOSE; then
      log "Progresso do engine: $(stderr_log_for "$log_file")"
    fi

    # Fase travada (desistencia do conserto, ciclo improdutivo). Antes de
    # desistir dela, a sessao de resgate: e exatamente o caso que ela existe
    # para atender — mais um ciclo repetiria o veredito, o resgate nao.
    if [ -n "$PHASE_ABORT_REASON" ]; then
      if rescue_should_run "$rescue_round"; then
        rescue_reason="$PHASE_ABORT_REASON"
        rescue_cause="$GATE_CAUSE"
        rescue_gate="$LAST_GATE"
        PHASE_ABORT_REASON=""
        rescue_round=$((rescue_round + 1))
        attempt_is_rescue=1
        continue
      fi
      warn "Abortando a fase sem gastar os ciclos restantes — $PHASE_ABORT_REASON"
      break
    fi

    # Resgate vermelho: proximo round, se houver. Resgate NAO volta para ciclo
    # de correcao — o ciclo e a etapa mais estreita, ja falhou antes dele.
    if [ "$attempt_is_rescue" -eq 1 ]; then
      ST_RESCUE="fail"
      state_event rescue_end "round=$rescue_round" "verdict=red"
      if rescue_should_run "$rescue_round"; then
        rescue_reason="a sessao de resgate $rescue_round nao fechou os gates (${LAST_GATE:-?})."
        rescue_cause="$GATE_CAUSE"
        rescue_gate="$LAST_GATE"
        rescue_round=$((rescue_round + 1))
        continue
      fi
      warn "Sessoes de resgate esgotadas ($MAX_RESCUES) — a fase fica reprovada"
      break
    fi

    cycle=$((cycle + 1))
  done

  local phase_duration=$(($(date +%s) - phase_start))
  ST_PHASE_STATUS="failed"
  FAILED_NUMS+=" $phase_num"
  # O dump da causa tem ate 40 linhas — nao cabe na area de mensagens do painel.
  # Desmonta o quadro antes e deixa a saida rolar como sempre.
  ui_stop

  # Ambiente fora do ar: a fase nao foi reprovada — ela nao chegou a ser
  # julgada. Desfecho proprio, trabalho preservado, run encerrado.
  if [ "$ENV_ABORT" -eq 1 ]; then
    fail "Phase $phase_num: $phase_title — INTERROMPIDA pelo ambiente ($(format_duration "$phase_duration"))"
    fail "Servico externo fora do ar (nenhum veredito sobre o codigo):"
    printf '%s\n' "$INFRA_SIGNATURE" | head -n 5 | sed 's/^/    /'
    fail "Logs em: $LOG_DIR/${phase_file%.md}.*"
    commit_wip_env "$phase_num"
    notify_and_record phase_failed \
      "INTERROMPIDA pelo ambiente apos $(format_duration "$phase_duration"): servico externo fora do ar. Trabalho salvo em commit wip."
    return 1
  fi

  # O relatorio tem que dizer TUDO que foi gasto: um dev que le "5 ciclos" e nao
  # ve o resgate assume que a etapa larga nem rodou.
  local attempts_txt="$MAX_CYCLES ciclos"
  if [ "$rescue_round" -gt 0 ]; then
    attempts_txt="$attempts_txt + $rescue_round sessao(oes) de resgate"
  fi
  fail "Phase $phase_num: $phase_title — FALHOU apos $attempts_txt ($(format_duration "$phase_duration"))"
  fail "Ultima causa ($LAST_GATE):"
  print_gate_cause 20
  fail "Logs em: $LOG_DIR/${phase_file%.md}.*"

  # O trabalho parcial fica na arvore; o preflight da proxima execucao exige
  # arvore limpa. Diga o que fazer em vez de deixar o dev descobrir no abort.
  if [ -n "$(git status --porcelain)" ]; then
    warn "O trabalho parcial desta fase ficou na arvore. Antes de re-rodar o ralph:"
    warn "    commite (o ralph revalida a fase e segue) ou 'git checkout -- . && git clean -fd' (descarta)"
  fi

  # GATE_CAUSE carrega ate 40 linhas de log; a notificacao leva so o suficiente
  # para o dev decidir se vale abrir o terminal.
  local cause_summary
  cause_summary=$(printf '%s' "$GATE_CAUSE" | head -n 2 | cut -c1-240 || true)
  notify_and_record phase_failed \
    "FALHOU apos $attempts_txt ($(format_duration "$phase_duration")). Ultimo gate: ${LAST_GATE:-?}. ${cause_summary}"

  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LAST_GATE=""

main() {
  # --attach nao executa fase nenhuma: nao passa por preflight (nao exige
  # arvore limpa, nem engine no PATH, nem comando de teste) e nao toca no
  # documento de entrada. Sai antes de qualquer coisa que escreva.
  if $ATTACH; then
    attach_run
    exit 0
  fi

  # Ctrl-C ou abort do preflight nao pode deixar cursor escondido nem servidor
  # orfao segurando a porta.
  trap cleanup_ui EXIT
  trap 'on_interrupt INT' INT
  trap 'on_interrupt TERM' TERM

  preflight_checks
  split_phases
  apply_from_override
  serve_start
  # Depois de split_phases: ele faz `rm -rf .phases` e levaria junto o baseline.
  measure_baseline
  # Nenhuma fase comeca sobre gate vermelho: ou o HEAD fica verde aqui, ou o run
  # para antes de gastar a fase 1.
  if ! heal_head; then
    exit 1
  fi

  resolve_final_phase

  local total_phases
  total_phases=$(manifest_entries | wc -l)

  if [ "$total_phases" -eq 0 ]; then
    fail "Nenhuma fase extraida de $INPUT_FILE."
    exit 1
  fi

  if [ "$FROM_PHASE" -gt "$total_phases" ]; then
    fail "--from $FROM_PHASE excede o total de fases ($total_phases)."
    exit 1
  fi

  echo ""
  log "$total_phases fases para implementar (engine: $ENGINE, max-cycles: $MAX_CYCLES)"
  if [ -n "$TEST_CMD" ]; then
    if [ "$TEST_SCOPE_MODE" = "full" ]; then
      log "Gate 2 — suite completa em toda fase (--full-suite)"
    elif [ -n "$FINAL_PHASE_FILE" ]; then
      log "Gate 2 — escopado por fase; a suite completa roda na fase $(final_phase_num) (fim da spec)"
    else
      warn "Nenhuma fase pendente: a suite completa nao sera executada neste run."
      warn "Para rodar o gate final da spec por fora: $TEST_CMD"
    fi
  fi
  [ "$FROM_PHASE" -gt 1 ] && log "Iniciando a partir da fase $FROM_PHASE"
  [ -n "$SERVE_URL" ] && success "Dashboard web: $SERVE_URL"
  echo ""

  local file num title
  local pending=0
  while IFS='|' read -r file num title; do
    if [ "$num" -lt "$FROM_PHASE" ]; then
      echo -e "  ${BLUE}[$num] $title (pulada por --from)${NC}"
    elif is_phase_done "$file"; then
      echo -e "  ${GREEN}[$num] $title (ja completada)${NC}"
    else
      echo -e "  ${YELLOW}[$num] $title${NC}"
      pending=$((pending + 1))
    fi
  done < <(manifest_entries)

  local start_time
  start_time=$(date +%s)
  RUN_START_EPOCH=$start_time
  RUN_ID="run-$RALPH_PID"
  ST_RUN_STATUS="running"
  ST_ACTIVITY="preparando"
  ST_STAGE_START=$start_time
  ST_PHASE_TOTAL="$total_phases"
  echo ""
  log "Inicio: $(date '+%d/%m/%Y %H:%M:%S')"

  # A lista de fases fica fora da mensagem de proposito: um documento com dezenas
  # de fases estouraria o limite de 4096 chars do Telegram.
  notify_and_record run_start \
    "Run iniciado: $pending de $total_phases fase(s) a executar (engine: $ENGINE, max-cycles: $MAX_CYCLES). Input: $INPUT_FILE"

  # O painel sobe so aqui: preflight e a lista inicial de fases sao saida
  # normal, e o quadro tem que ficar sendo as ultimas linhas do terminal.
  ui_start

  local seq=0
  local failed_phases=() skipped_phases=() completed_phases=()

  # fd 3, nunca stdin: comandos do corpo (claude -p, sail test / docker compose
  # exec) leem stdin quando nao e TTY e engoliriam o resto do manifest — o run
  # pararia apos a primeira fase.
  while IFS='|' read -r -u 3 file num title; do
    seq=$((seq + 1))

    if [ "$num" -lt "$FROM_PHASE" ]; then
      log "Pulando Phase $num: $title (antes de --from $FROM_PHASE)"
      skipped_phases+=("$title")
      continue
    fi

    if is_phase_done "$file"; then
      log "Pulando Phase $num: $title (ja completada)"
      skipped_phases+=("$title")
      continue
    fi

    if run_phase "$file" "$num" "$title" "$seq" "$total_phases"; then
      completed_phases+=("$title")
    else
      failed_phases+=("$title")
      # Ambiente fora do ar para o run INTEIRO, mesmo com --keep-going: a
      # proxima fase encontraria o mesmo servico morto e morreria igual,
      # gastando sessao de engine para reafirmar o obvio.
      if [ "$ENV_ABORT" -eq 1 ]; then
        warn "Parando o run: o ambiente esta fora do ar (as proximas fases falhariam igual)."
        break
      fi
      if $KEEP_GOING; then
        warn "--keep-going: seguindo para a proxima fase"
        commit_wip "$num"
      else
        warn "Parando na primeira fase que falhou (use --keep-going para continuar)"
        break
      fi
    fi
  done 3< <(manifest_entries)

  local end_time total_duration
  end_time=$(date +%s)
  total_duration=$((end_time - start_time))

  ST_PHASE_STATUS="idle"
  ST_ACTIVITY="encerrado"
  ST_STAGE_START=$(date +%s)
  if [ ${#failed_phases[@]} -gt 0 ]; then ST_RUN_STATUS="failed"; else ST_RUN_STATUS="done"; fi
  # O relatorio final e saida longa e rolante: o painel sai de cena antes.
  ui_stop
  state_sync

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "RELATORIO FINAL (engine: $ENGINE)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local phase
  if [ ${#completed_phases[@]} -gt 0 ]; then
    echo ""
    success "Completadas (${#completed_phases[@]}):"
    for phase in "${completed_phases[@]}"; do printf '    %b%s%b\n' "$GREEN" "$phase" "$NC"; done
  fi

  if [ ${#skipped_phases[@]} -gt 0 ]; then
    echo ""
    log "Puladas (${#skipped_phases[@]}):"
    for phase in "${skipped_phases[@]}"; do printf '    %s\n' "$phase"; done
  fi

  if [ ${#failed_phases[@]} -gt 0 ]; then
    echo ""
    fail "Falharam (${#failed_phases[@]}):"
    for phase in "${failed_phases[@]}"; do printf '    %b%s%b\n' "$RED" "$phase" "$NC"; done
    echo ""
    fail "Verifique os logs em $LOG_DIR/"
  fi

  echo ""
  log "Inicio: $(date -d "@$start_time" '+%d/%m/%Y %H:%M:%S')"
  log "Fim:    $(date -d "@$end_time" '+%d/%m/%Y %H:%M:%S')"
  log "Duracao total: $(format_duration "$total_duration")"
  echo ""

  local run_summary
  run_summary="Run encerrado em $(format_duration "$total_duration"): ${#completed_phases[@]} completa(s), ${#failed_phases[@]} falharam, ${#skipped_phases[@]} pulada(s)."
  if [ "$ENV_ABORT" -eq 1 ]; then
    run_summary="Run interrompido pelo ambiente em $(format_duration "$total_duration"): ${#completed_phases[@]} completa(s), 1 fase interrompida sem veredito sobre o codigo, ${#skipped_phases[@]} pulada(s). Restabeleca os servicos e retome o Ralph."
  elif [ ${#failed_phases[@]} -gt 0 ]; then
    run_summary="$run_summary Falharam: $(printf '%s; ' "${failed_phases[@]}")"
  fi
  notify_and_record run_done "$run_summary"

  # O estado final fica em disco para inspecao depois do run; so o servidor cai.
  if [ -n "$SERVE_URL" ]; then
    log "Dashboard encerrado. Estado final em $STATE_FILE e $EVENTS_FILE."
  fi
  serve_stop

  # 3 = ambiente. Distingue "o codigo reprovou" de "o ralph nao pode julgar":
  # automacao em cima do exit code precisa reagir diferente aos dois.
  if [ "$ENV_ABORT" -eq 1 ]; then
    fail "Run encerrado por ambiente fora do ar. Suba os servicos e re-rode."
    exit 3
  fi
  [ ${#failed_phases[@]} -eq 0 ] || exit 1
}

main
