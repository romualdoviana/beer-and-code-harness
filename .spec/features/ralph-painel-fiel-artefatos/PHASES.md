# Phases: ralph-painel-fiel-artefatos

Gerado por /plan a partir de PLAN.md — view executável para `./ralph.sh .spec/features/ralph-painel-fiel-artefatos/PHASES.md`.

## Phase 1: Contrato de estado aditivo

Suite: completa

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos

- [x] T01 — Publicar os campos aditivos do estado (RF-14) (PLAN: T01)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`
      Mudança: em `state_sync`/`ui_state_cache`/`ui_load_state`, acrescentar sem tocar chave existente as chaves `failure {gate, cycle, headline, name, message, log}`, `test {scope, file, log}`, `tasks [{idx, title, subtitle, status}]` da fase corrente, `task_active`, `correction {title}`, `previous_gates`, `display {status_word, status_tone, phases_done, phases_total, percent}`; helper `ui_failure_digest` reusando `gate2_failure_ids` e `extract_failure_signature`; snapshot de gates antes de cada novo ciclo/round; subtítulo = texto após o primeiro ` — `/`: ` do rótulo sem `TNN —` e sem `(PLAN: TNN)`; mesmos valores espelhados em `state.env`; `events.jsonl` inalterado.
      Cobre: RF-14, RF-10, CT-01, CT-02
      Acceptance criteria: numa falha de gate 2 cujo log tem linha `FAIL`, `state.json` traz `failure.name`, `failure.message` e `failure.headline` extraídos do log, `test.scope`, `tasks[]` e `display.percent`; toda chave listada em CT-01 mantém nome, tipo e valor de um run sem a feature; `schema` continua `1`; o JSON é válido; `state.env` carrega os mesmos valores.
      Testes: `scripts/test-ralph.sh` — caso novo `state-additive` (roteiro `test-red-repairable`: campos novos preenchidos a partir do log e chaves de CT-01 iguais às de um run `ok` baseline), provado vermelho via `RALPH_BIN`

## Phase 2: Telas do terminal e adaptação de tamanho

Suite: completa

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos
3. `.spec/features/ralph-painel-fiel-artefatos/artboards/01-visao-geral.png`, `02-foco.png`, `03-diagnostico.png` — referência das regiões

- [ ] T01 — Primitivas de desenho: tokens, fundo de célula, mapa de cliques, listas roláveis (PLAN: T02)
      Arquivos: `scripts/ralph.sh`
      Mudança: paleta dos 11 tokens da SPEC em truecolor quando `COLORTERM` indica suporte, fallback 256; helpers de linha com fundo de célula, faixa vertical, régua e barra segmentada; glifos `✓ ▶ ● × —` como default das telas novas com `RALPH_UI_GLYPHS=ascii` mantido de recuo e 1 coluna de folga; `ui_hit` gravando `.phases/ui/.hitmap` (`.hitmap.attach` no attach) atômico no formato `linha|col_ini|col_fim|ação`; viewport por lista e estado `UI_SCROLL_<lista>`, `UI_SEL_PHASE`, `UI_SEL_TASK`.
      Cobre: RNF-03, UI-01, UI-02, UI-03, CT-04
      Acceptance criteria: os helpers existem e são usados pelas telas de T02–T05 desta fase; `.hitmap` é escrito por tmp+mv a cada frame; nenhuma cor é emitida sem símbolo ou palavra ao lado; `scripts/check-shell.sh` passa.
      Testes: none — fiação de apresentação; os ramos alimentados são cobertos por `ui-layouts` (T05 desta fase) e pelas fases 3 e 4
- [ ] T02 — Tela "1 Visão geral" (UI-01) e barra de abas (PLAN: T03)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`
      Mudança: `ui_screen_overview` com as 7 regiões do artboard 01 (cabeçalho `RALPH` · projeto · ENGINE · `● STATUS` + régua; 4 métricas; barra segmentada; jornada `✓/▶/· NN Título`; caixas EM ANDAMENTO e VALIDAÇÃO DA FASE com fundo `#101923`; ÚLTIMOS EVENTOS; abas `1 Visão geral`/`2 Foco`/`3 Diagnóstico` + `f Seguir`/`q Sair`), com `ui_hit` em aba, Seguir, Sair, fase e tarefa; tabela FASES E TASKS sai da Visão geral; campo vazio = `—`; `RALPH_UI_LAYOUT=cockpit` continua aceito. Reescrever (aprovado pelo desenvolvedor, nenhum caso apagado) as asserções de `ui-tty`, `ui-painter-exit` e `ui-locale-ranges` que citam `FASES E TASKS`, `PROGRESSO`, `AO VIVO`, `RALPH / COCKPIT`, `1 Cockpit` para as regiões novas (prova de vida = linha `› …` da caixa EM ANDAMENTO).
      Cobre: UI-01, RF-14, RNF-03
      Acceptance criteria: o frame 144×40 da Visão geral mostra as 7 regiões na ordem do artboard 01, a aba `1 Visão geral` com fundo `#233b48`, `f Seguir` e `q Sair` à direita, e não contém `FASES E TASKS`; as asserções reescritas afirmam as regiões novas com o mesmo propósito das antigas e nenhum caso foi apagado.
      Testes: `scripts/test-ralph.sh` — asserções existentes de `ui-tty`, `ui-painter-exit` e `ui-locale-ranges` atualizadas para as regiões novas; regiões por tela afirmadas em `ui-layouts` (T05 desta fase)
      Sem `Tela:`: o terminal não é rota HTTP; a evidência é o dump 144×40 de `ui-layouts` comparado com `artboards/01-visao-geral.png`.
- [ ] T03 — Tela "2 Foco" (UI-02) com seleção de fase/tarefa (PLAN: T04)
      Arquivos: `scripts/ralph.sh`
      Mudança: `ui_screen_focus` com as 8 regiões do artboard 02 (cabeçalho; `FASE NN / NN` · título · `TOTAL`; destaque com faixa ciano, `TAREFA NN / NN · ESTADO`, título negrito, subtítulo ou linha em branco, `› Editando …`; CONFIRMAÇÃO INDEPENDENTE; caixa TAREFAS DA FASE com palavras `verificada`/`em andamento`/`declarada`/`incompleta`/`pendente` e `ui_hit task:F:I`; pipeline com etapa ativa `[ … ]`; `Ciclo N/M` + `Próximo:`; abas). Com `UI_SEL_PHASE` ≠ fase corrente, tarefas derivadas de `extract_task_labels` daquela fase: todas `verificada` se `done`, todas `pendente` se futura; nada gravado.
      Cobre: UI-02, RF-05, RF-14
      Acceptance criteria: o frame 144×40 do Foco mostra as 8 regiões na ordem do artboard 02 com a tarefa corrente destacada no bloco principal e na caixa; com `UI_SEL_PHASE=1` (fase concluída) o cabeçalho é `FASE 01 / NN` e todas as tarefas da fase 1 aparecem `verificada`; com fase futura, todas `pendente`; tarefa sem subtítulo deixa a linha em branco sem `—`.
      Testes: `scripts/test-ralph.sh` — em `ui-layouts` (T05 desta fase): seleção de fase concluída/futura e subtítulo vazio
      Sem `Tela:`: o terminal não é rota HTTP; a evidência é o dump 144×40 de `ui-layouts` comparado com `artboards/02-foco.png`.
- [ ] T04 — Tela "3 Diagnóstico" (UI-03) e estado sem falha (PLAN: T05)
      Arquivos: `scripts/ralph.sh`
      Mudança: `ui_screen_diag` com as 8 regiões do artboard 03 (cabeçalho com `● CORRIGINDO` âmbar em correção; `FASE NN / NN  título` + `CICLO NN / NN` âmbar; banner `GN / <GATE> FALHARAM` com faixa vermelha e fundo `#291c25`, headline, `Escopo executado: … · …`; TENTATIVA ANTERIOR de `previous_gates`; CORREÇÃO ATUAL `▶ <correction.title>`, `Atividade:`, `Depois: reavaliar os gates`; LINHA DO TEMPO; SAÍDA DO TESTE `FAIL  <nome>`, mensagem, `Log:` só sob `$LOG_DIR/`; abas). Sem falha: faixa verde `● Nenhum gate falhou`, `—` nos campos vazios, mesmas regiões e posições. Texto de log sempre por `ui_clean_text`.
      Cobre: UI-03, RF-16, RF-14
      Acceptance criteria: com falha no G2, o frame 144×40 mostra as 8 regiões na ordem do artboard 03 com `G2 / TESTES FALHARAM`, a headline e a linha `FAIL`; sem falha, contém `● Nenhum gate falhou`, não contém `FALHARAM`, contém `LINHA DO TEMPO` e `—` em cada campo vazio, com as mesmas 8 regiões na mesma ordem.
      Testes: `scripts/test-ralph.sh` — em `ui-layouts` (T05 desta fase): fixture de falha G2 e fixture sem falha
      Sem `Tela:`: o terminal não é rota HTTP; a evidência é o dump 144×40 de `ui-layouts` comparado com `artboards/03-diagnostico.png`.
- [ ] T05 — Adaptação de tamanho (RF-15) e caso de regiões por tela (PLAN: T06)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`
      Mudança: `ui_frame` escolhe a tela e aplica: ≥144×40 caixas lado a lado; entre 100×24 e 144×40 caixas empilhadas; sem altura, corta primeiro ÚLTIMOS EVENTOS (Visão geral), depois LINHA DO TEMPO e SAÍDA DO TESTE (Diagnóstico); abaixo de 100 colunas ou 24 linhas só `aumente para 100×24`; nunca mais que `h-1` linhas nem mais largo que `w`; hitmap e viewports só do que foi desenhado. Reescrever `ui-layouts` e `ui-box-width` para as telas novas (aprovado pelo desenvolvedor, nenhum caso apagado).
      Cobre: RF-15, UI-01, UI-02, UI-03, RF-14
      Acceptance criteria: em 144×40 todas as regiões de cada tela aparecem lado a lado; em 120×40 empilhadas sem perda; em 100×24 a Visão geral omite só ÚLTIMOS EVENTOS e o Diagnóstico omite só LINHA DO TEMPO e SAÍDA DO TESTE; em 99×24 e 100×23 o frame contém `aumente para 100×24` e nenhuma região; fixture com campos novos vazios mostra `—` nas mesmas posições; nenhum frame passa de `h-1` linhas ou `w` colunas nem contém ESC residual.
      Testes: `scripts/test-ralph.sh` — caso `ui-layouts` reescrito (regiões e ordem por tela, ordem de corte, limiar do aviso, campo vazio, geometria) e `ui-box-width` ajustado, provados vermelhos via `RALPH_BIN`

## Phase 3: Mouse e seleção

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos

- [x] T01 — Mouse SGR, mapa de cliques e seleção (PLAN: T07)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`
      Mudança: `ui_start` emite `ESC[?1000h ESC[?1006h` só no ramo `UI_KEYS=1 && -r /dev/tty`; `ui_read_key` lê CSI `<b;x;y(M|m)` byte a byte até 16 bytes e descarta sequência truncada/desconhecida; `ui_apply_key` resolve o press contra `.hitmap`: `tab:1..3` = teclas `1/2/3`, `follow` = `f/a` (zera seleção e rolagens), `phase:N`/`task:F:I` abrem Foco com seleção e suspendem o seguir, botões 64/65 rolam 1 linha a lista sob o ponteiro, fora de lista nada, release ignorado; teclas atuais agem sobre a lista primária da tela com o mesmo efeito de hoje.
      Cobre: RF-01, RF-02, RF-04, RF-05, RF-06, RF-07, RF-11, CT-04, RNF-01
      Acceptance criteria: clique em "2 Foco" troca para Foco no próximo frame com a aba ativa; roda para baixo sobre TAREFAS DA FASE (12 tarefas, 5 visíveis) muda a primeira visível de 01 para 02 e sobre o cabeçalho não muda nada; clique em "✓ 01" mostra `FASE 01 / NN` e a seleção sobrevive ao frame seguinte; clique em "f Seguir" volta à fase corrente; sequência truncada + `↓` rola uma linha sem bytes da sequência no frame; saída não-TTY e `RALPH_UI_KEYS=0` não contêm `ESC[?1000h`, `ESC[?1002h`, `ESC[?1003h`, `ESC[?1006h` nem `ESC[?1015h`.
      Testes: `scripts/test-ralph.sh` — `ui-keys` estendido (clique em aba, roda dentro/fora de lista, clique em fase + Seguir, sequência truncada, teclas antigas) e `ui-non-tty` estendido (nenhum DECSET de mouse), provados vermelhos via `RALPH_BIN`

## Phase 4: "q Sair" e restauração do terminal

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos

- [x] T01 — "q Sair" e restauração em todo caminho de saída (PLAN: T08)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`
      Mudança: `q` e clique em `quit` fazem o pintor desligar o mouse, emitir `ESC[0m ESC[?25h ESC[?1049l`, restaurar `stty`, reimprimir o `messages.log`, gravar `.phases/ui/.panel-closed` (`.panel-closed.attach` no attach) com a contagem reimpressa e sair; `ui_panel_gone` (flag OU pintor morto) checado em `log/success/warn/fail` e `ui_stop` passa o run para placar corrido, reimprime o restante e não reemite `1049l`; `ui_stop`/`on_interrupt` desligam o mouse antes de `ESC[?1049l`; no `--attach`, `q` encerra o attach sem tocar no run; nenhum veredito, commit ou exit code muda.
      Cobre: RF-03, RF-08, RF-12, RNF-04, RNF-06
      Acceptance criteria: `q` durante a fase 1 mantém o processo com o mesmo PID, a saída seguinte é placar corrido e o run termina com o mesmo exit code, mesmos vereditos `gate_end` em `events.jsonl` e mesmo número de commits de um run `--no-ui` do mesmo roteiro; em fim normal, SIGINT e `q`, `ESC[?1000l` aparece antes do último `ESC[?1049l` e `stty -g` depois é igual ao de antes; nenhum frame é pintado após o fim do run.
      Testes: `scripts/test-ralph.sh` — caso novo `ui-quit-panel` (paridade de exit code/vereditos/commits com `--no-ui`, placar após `q`, ordem das sequências, stty) e `ui-painter-exit` estendido (desligamento de mouse no fim normal e no SIGINT), provados vermelhos via `RALPH_BIN`

## Phase 5: Watch com o mesmo painel do run

Suite: completa

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos

- [x] T01 — `ralph-watch.sh` = mesmo painel do run (PLAN: T09)
      Arquivos: `scripts/ralph.sh`, `scripts/ralph-watch.sh`, `scripts/test-ralph.sh`
      Mudança: última linha do `ralph.sh` vira `[ "${RALPH_LIB_ONLY:-0}" = "1" ] || main`; bloco de medição do pintor extraído para `ui_measure_live`; `ralph-watch.sh` resolve `ralph.sh` (`RALPH_BIN` ou irmão; ausente → erro e exit 1), faz `cd` no repo, no modo ao vivo faz `exec bash ralph.sh --attach`, no `--once` carrega o lib com `RALPH_LIB_ONLY=1` (com `$@` limpo), usa `RALPH_WATCH_COLS/LINES`, chama `ui_frame` uma vez sem escrever em `.phases/`; `--no-color` remove ANSI; sai o contrato `run.tsv`/`live.tsv` e a menção a `--dashboard`.
      Cobre: RF-09, RNF-05, RF-03
      Acceptance criteria: para o mesmo `.phases/`, largura, altura e aba, `ralph-watch.sh --once` produz frame idêntico, sem ANSI, ao `ui_frame` do run; o checksum de `.phases/` não muda com `--once`; o `ralph-watch.sh` não contém mais `run.tsv` nem `--dashboard`; os testes que usam `sed '$d'` continuam verdes.
      Testes: `scripts/test-ralph.sh` — caso novo `watch-parity` (frame idêntico ao do run e `.phases/` intocado), provado vermelho via `RALPH_BIN`

## Phase 6: Dashboard fiel aos artboards e documentação

Suite: completa

Antes de implementar, leia:
1. `.spec/features/ralph-painel-fiel-artefatos/SPEC.md` — requisitos RIGID que esta fase cobre
2. `.spec/features/ralph-painel-fiel-artefatos/PLAN.md` — decomposição completa, dependências e riscos
3. `.spec/features/ralph-painel-fiel-artefatos/artboards/` — os três PNGs-alvo da captura

Captura: esta fase roda com `RALPH_UI_SHOT_CMD` local do desenvolvedor (Playwright chromium em `~/.cache/ms-playwright`) servindo `.spec/features/ralph-painel-fiel-artefatos/` em `127.0.0.1`; o repo não ganha script nem dependência de captura.

- [ ] T01 — Fixtures de estado para captura do dashboard (PLAN: T10)
      Arquivos: `.spec/features/ralph-painel-fiel-artefatos/fixtures/01-visao-geral/`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/02-foco/`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/03-diagnostico/`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/03-diagnostico-ok/`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/build.sh`
      Mudança: quatro diretórios no formato de `.phases/` (`state.json`, `events.jsonl`, `logs/`) com os dados ilustrativos dos artboards e só as chaves publicadas na fase 1; `03-diagnostico-ok` sem falha; `build.sh` gera `ui/index.html` de cada fixture carregando `scripts/ralph.sh` com `RALPH_LIB_ONLY=1` e chamando `write_dashboard_html` com `UI_HTML` na fixture.
      Cobre: UI-04, UI-05, UI-06, RF-16
      Acceptance criteria: cada `state.json` é JSON válido com só chaves de CT-01 mais as da fase 1; `bash .spec/features/ralph-painel-fiel-artefatos/fixtures/build.sh` gera os quatro `ui/index.html` sem erro; as rotas `/fixtures/01-visao-geral/ui/`, `/fixtures/02-foco/ui/`, `/fixtures/03-diagnostico/ui/` servidas a partir de `.spec/features/ralph-painel-fiel-artefatos/` resolvem `../state.json`.
      Testes: none — dado de demonstração; o contrato de estado é testado na fase 1
- [ ] T02 — Fonte DejaVu Sans Mono embutida no dashboard (PLAN: T11)
      Arquivos: `scripts/ralph.sh`
      Mudança: função `ui_dashboard_font_css` com `@font-face` `data:font/ttf;base64` para DejaVu Sans Mono regular e bold, embutidos como heredoc base64 no `ralph.sh` (arquivo único, ~900 KB aceito pelo desenvolvedor), com aviso de licença Bitstream Vera/DejaVu em comentário; chamada por `write_dashboard_html`.
      Cobre: UI-04, UI-05, UI-06, CT-03, RNF-02
      Acceptance criteria: o `index.html` gerado contém os dois `@font-face` com `data:` e nenhuma URL de fonte externa; `font-family` das regiões é DejaVu Sans Mono; `scripts/check-shell.sh` passa.
      Testes: none — asset; ausência de origem externa afirmada no caso `serve` (T03 desta fase)
- [ ] T03 — Dashboard: shell, abas, cliques e aba "1 Visão geral" (PLAN: T12)
      Arquivos: `scripts/ralph.sh`, `scripts/test-ralph.sh`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/*/ui/index.html`
      Mudança: reescrever `write_dashboard_html`: CSS custom properties dos 11 tokens, painel interno 1440×1000 sem moldura, abas por estado em memória + `location.hash` (troca imediata), `f Seguir` que zera seleção e rolagem, nenhum "Sair", `cursor:pointer` só em aba/Seguir/fase/tarefa, `wheel` em listas `overflow:auto`, poll de `../state.json` e `../events.jsonl` a cada 1,5 s como único fetch, valores de `display.*`/`phase`/`gates`/`tasks` sem recálculo; aba 1 com as 7 regiões de UI-01 marcadas por `data-region`; abaixo de 900 px caixas empilham sem rolagem horizontal; `serve_start` segue reescrevendo o HTML a cada run; fixtures regeneradas com `build.sh`.
      Cobre: UI-04, UI-07, RF-01, RF-02, RF-03, RF-10, RF-13, CT-03, RNF-01
      Acceptance criteria: a captura da rota mostra as 7 regiões do artboard 01 na mesma posição relativa, cores só dos tokens da SPEC, fonte DejaVu Sans Mono, aba `1 Visão geral` ativa com fundo `#233b48`, `f Seguir` à direita e nenhum "Sair"; clique em aba troca a tela sem esperar o poll; `index.html` antigo semeado antes do run é substituído; a página não referencia origem fora de `127.0.0.1`; os `ui/index.html` das fixtures estão regenerados e em sincronia com o heredoc.
      Testes: `scripts/test-ralph.sh` — caso `serve` estendido (HTML antigo substituído, sem origem externa, sem "Sair", fetch só de `../state.json` e `../events.jsonl`), provado vermelho via `RALPH_BIN`
      Tela: /fixtures/01-visao-geral/ui/#visao-geral | [data-region="header"], [data-region="metrics"], [data-region="journey"], [data-tab="1"][aria-selected="true"] | .spec/features/ralph-painel-fiel-artefatos/artboards/01-visao-geral.png
- [ ] T04 — Dashboard: aba "2 Foco" com seleção (PLAN: T13)
      Arquivos: `scripts/ralph.sh`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/*/ui/index.html`
      Mudança: 8 regiões de UI-02 com `data-region`; clique em fase ou tarefa abre Foco com a seleção e suspende o seguir; fase não corrente com a regra M6 (concluída = `verificada`, futura = `pendente`); subtítulo vazio = linha em branco; `wheel` na lista de tarefas rola uma linha; fixtures regeneradas com `build.sh`.
      Cobre: UI-05, RF-04, RF-05, RF-14
      Acceptance criteria: a captura da rota mostra as 8 regiões do artboard 02 na mesma posição relativa, a tarefa corrente destacada no bloco principal com faixa ciano e na caixa TAREFAS DA FASE, pipeline com `[ IMPLEMENTAÇÃO ]` ativo e aba `2 Foco` ativa; os `ui/index.html` das fixtures estão em sincronia com o heredoc.
      Testes: none — seleção do navegador espelha a do terminal já coberta nas fases 2 e 3; evidência é a captura
      Tela: /fixtures/02-foco/ui/#foco | [data-region="task-highlight"], [data-region="phase-tasks"], [data-region="pipeline"], [data-tab="2"][aria-selected="true"] | .spec/features/ralph-painel-fiel-artefatos/artboards/02-foco.png
- [ ] T05 — Dashboard: aba "3 Diagnóstico" e estado sem falha (PLAN: T14)
      Arquivos: `scripts/ralph.sh`, `.spec/features/ralph-painel-fiel-artefatos/fixtures/*/ui/index.html`
      Mudança: 8 regiões de UI-03 com `data-region`; banner vermelho com `failure.*` ou faixa verde `● Nenhum gate falhou` quando `failure.gate` vazio; `—` em campo vazio; linha do tempo e saída do teste roláveis; mesmas regiões e posições nas fixtures com e sem falha; fixtures regeneradas com `build.sh`.
      Cobre: UI-06, RF-16, RF-14
      Acceptance criteria: a captura da rota mostra as 8 regiões do artboard 03 na mesma posição relativa, banner `G2 / TESTES FALHARAM` com faixa vermelha e fundo `#291c25`, `FAIL  rejects insufficient stock` em vermelho e aba `3 Diagnóstico` ativa; a fixture `03-diagnostico-ok` mostra `● Nenhum gate falhou` em verde, sem `FALHARAM`, com `—` nos campos vazios e as mesmas regiões; os `ui/index.html` das fixtures estão em sincronia.
      Testes: none — renderização; a regra de estado sem falha é testada no terminal (fase 2) e a evidência web é a captura
      Tela: /fixtures/03-diagnostico/ui/#diagnostico | [data-region="failure-banner"], [data-region="previous-attempt"], [data-region="test-output"], [data-tab="3"][aria-selected="true"] | .spec/features/ralph-painel-fiel-artefatos/artboards/03-diagnostico.png
- [ ] T06 — Documentação: mouse, Shift+arrastar, "q Sair", watch (PLAN: T15)
      Arquivos: `scripts/ralph.sh`, `README.md`, `README.pt-BR.md`
      Mudança: no cabeçalho do `--help` e nos dois READMEs, documentar: mouse segue `RALPH_UI_KEYS` + `/dev/tty`; copiar texto com mouse ativo exige Shift+arrastar; `q`/"q Sair" fecha só o painel e o run segue em placar corrido, reabrível com `--attach`; `ralph-watch.sh` delega ao `ralph.sh`; nomes das abas; aviso `aumente para 100×24`. Inglês no README.md, português no README.pt-BR.md e no `--help`.
      Cobre: RF-03, RF-07
      Acceptance criteria: `ralph.sh --help` e os dois READMEs mencionam Shift+arrastar, o efeito do `q` e o `--attach` para reabrir; nenhuma menção a `ralph.sh --dashboard` resta nos READMEs.
      Testes: none — documentação
