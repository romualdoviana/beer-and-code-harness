#!/usr/bin/env bash
#
# test-ralph.sh — suite red/green do scripts/ralph.sh com engine mock.
#
# Nenhuma chamada de rede, nenhum token gasto: binarios fake `claude` e `codex`
# entram no PATH e o comportamento e escolhido por MOCK_SCENARIO.
#
# Uso: scripts/test-ralph.sh [nome-do-caso]   (exit 0 = tudo verde)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# RALPH_BIN permite apontar para uma copia patchada (prova red dos testes).
RALPH="${RALPH_BIN:-$ROOT/scripts/ralph.sh}"
ONLY="${1:-}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
CURRENT=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { PASS=$((PASS + 1)); echo -e "  ${GREEN}ok${NC}   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1"; }

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then ok "$msg"; else bad "$msg (esperado '$expected', veio '$actual')"; fi
}

assert_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (nao achou '$needle')"; fi
}

assert_not_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF -- "$needle" "$haystack_file"; then bad "$msg (achou '$needle')"; else ok "$msg"; fi
}

# ---------------------------------------------------------------------------
# Mock engine — vale para claude e codex (dispatch por basename)
# ---------------------------------------------------------------------------

make_mocks() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/mock-engine" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

name=$(basename "$0")
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
prompt=""
verify=0

bump() {
  local f="$state/$1" n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  echo "$n" > "$f"
  echo "$n"
}

MOCK_WROTE=()

# NDJSON como o `claude -p --output-format stream-json` real: um evento por
# acao e o veredito no evento final. O ralph le o `result` para os gates e os
# `tool_use` para o painel e para o progresso por task.
emit_claude_ndjson() {
  local text="$1" err="${2:-false}" sub="${3:-success}"
  local f
  for f in "${MOCK_WROTE[@]:-}"; do
    [ -n "$f" ] || continue
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$f"
  done
  printf '{"type":"result","subtype":"%s","is_error":%s,"result":"%s"}\n' \
    "$sub" "$err" "$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//')"
}

model=""

if [ "$name" = "claude" ]; then
  # claude -p real le stdin quando nao e TTY: se o ralph nao redirecionar
  # < /dev/null, o mock engole o stream de quem chamou (ex: manifest do loop).
  [ -t 0 ] || cat > /dev/null
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --output-format) shift 2 ;;
      *) shift ;;
    esac
  done
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sandbox) [ "$2" = "read-only" ] && verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  prompt=$(cat)
fi

grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1

# Progresso/telemetria SEMPRE no stderr, como as CLIs reais. Se o ralph unir os
# streams, esse ruido vaza para o log parseado pelos gates.
echo "[mock] progresso: lendo o prompt" >&2
echo "[mock] progresso: 100%" >&2

# Grava o modelo pedido para a sessao verificadora (assert do teste de modelo).
if [ "$verify" -eq 1 ] && [ -n "$model" ]; then
  echo "$model" > "$state/verify_model"
fi

# Nivel de caveman pedido, por tipo de sessao. `-` = variavel ausente.
if [ "$name" = "claude" ]; then
  if [ "$verify" -eq 1 ]; then
    echo "${CAVEMAN_DEFAULT_MODE:--}" >> "$state/caveman_verify"
  else
    echo "${CAVEMAN_DEFAULT_MODE:--}" >> "$state/caveman_impl"
  fi

  # Simula o hook SessionStart do plugin: ele reescreve o flag GLOBAL
  # ~/.claude/.caveman-active com o nivel ativo. O ralph tem que devolver o
  # arquivo ao valor anterior para nao arrastar a sessao interativa do dev.
  if [ -n "${CAVEMAN_DEFAULT_MODE:-}" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    printf '%s' "$CAVEMAN_DEFAULT_MODE" > "$CLAUDE_CONFIG_DIR/.caveman-active"
  fi
fi

# --- verificador independente ------------------------------------------------
# Verifica o CODIGO REAL, como o verificador de verdade: sem arquivo de
# implementacao no repo, a fase esta incompleta.
if [ "$verify" -eq 1 ]; then
  # O bloco inteiro roda num subshell e a saida e capturada: o claude real
  # devolve a resposta do verificador dentro do `result` do NDJSON, nunca como
  # texto solto. Os `exit 0` internos encerram o subshell, nao o mock.
  verify_out=$(
  n=$(bump verify_calls)
  printf '%s' "$prompt" > "$state/verify_prompt"
  tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")

  implemented=0
  compgen -G "src/impl-*.txt" > /dev/null 2>&1 && implemented=1

  if [ "$implemented" -eq 0 ]; then
    for i in $(seq 1 "$tasks"); do echo "TASK $i: INCOMPLETE — nenhum codigo encontrado"; done
    exit 0
  fi

  # Cenarios de duplicacao da resposta final do verificador.
  case "$scenario" in
    verify-echo-both)
      # codex 0.145: a resposta final sai no stdout E no stderr. Com 2>&1 o
      # parser via 4 linhas para 2 tasks e acusava cobertura incompleta.
      for i in $(seq 1 "$tasks"); do
        echo "TASK $i: DONE — src/impl-$i.txt:1"
        echo "TASK $i: DONE — src/impl-$i.txt:1" >&2
      done
      exit 0
      ;;
    verify-dup-stdout)
      # O modelo repete o bloco como resumo, no mesmo stream.
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
      echo "Resumo final:"
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
      exit 0
      ;;
    verify-dup-hides-gap)
      # 2 linhas para 2 tasks, mas so a task 1 foi julgada: contar linhas daria
      # verde com metade da fase sem veredito.
      echo "TASK 1: DONE — src/impl-1.txt:1"
      echo "TASK 1: DONE — src/impl-1.txt:1"
      exit 0
      ;;
    verify-bare-done)
      # Linguagem confiante sem prova: o gate 3 reprova por protocolo.
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE"; done
      exit 0
      ;;
    verify-index-out-of-range)
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
      echo "TASK 9: DONE — src/impl-9.txt:1"
      exit 0
      ;;
  esac

  if [ "$scenario" = "rescue-fix" ]; then
    # A task 1 so fica pronta depois que a SESSAO DE RESGATE roda: e o cenario
    # do travamento real — nem o ciclo nem o conserto davam conta.
    if [ -f "$state/rescue_calls" ]; then
      for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
    else
      echo "TASK 1: INCOMPLETE — a regra nasce no lugar errado do fluxo"
      for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
    fi
    exit 0
  fi

  if [ "$scenario" = "verify-incomplete-always" ] \
    || [ "$scenario" = "repair-abort" ] || [ "$scenario" = "repair-nochange" ] \
    || [ "$scenario" = "rescue-blocked" ]; then
    # Task 1 nunca fica pronta: da o gate 3 vermelho que aciona o conserto e
    # exercita o esgotamento / a desistencia.
    echo "TASK 1: INCOMPLETE — o arquivo nao foi criado"
    for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  elif [ "$scenario" = "verify-incomplete-once" ] && [ "$n" -eq 1 ]; then
    echo "TASK 1: INCOMPLETE — o arquivo nao foi criado"
    for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  else
    for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  fi
  )
  if [ "$name" = "claude" ]; then
    emit_claude_ndjson "$verify_out"
  else
    printf '%s\n' "$verify_out"
  fi
  exit 0
fi

emit_claude_ok()    { emit_claude_ndjson "implementado"; }
emit_claude_limit() { emit_claude_ndjson "Claude AI usage limit reached|$1" true error; }

# --- saneamento do HEAD ------------------------------------------------------
# Vem antes de todas: e a unica sessao que roda ANTES da fase 1, e o prompt dela
# carrega o mandato de guarda obsoleta que tambem vai no conserto e no resgate.
if grep -q '^RALPH_HEAL' <<< "$prompt"; then
  n=$(bump heal_calls)
  [ -n "$model" ] && echo "$model" > "$state/heal_model"
  printf '%s' "$prompt" > "$state/heal_prompt_$n.txt"

  case "$scenario" in
    heal-blocked)
      # Os dois lados sao decisoes vivas: a sessao para sem editar nada.
      if [ "$name" = "claude" ]; then
        emit_claude_ndjson "HEAL_ABORT: a guarda cobra comportamento que ninguem implementou"
      else
        echo "HEAL_ABORT: a guarda cobra comportamento que ninguem implementou"
      fi
      exit 0
      ;;
    *)
      # Atualiza a guarda obsoleta: o arquivo que a suite mock olha.
      mkdir -p tests
      echo "guarda atualizada" > "tests/GuardaVelhaTest.txt"
      touch "$state/healed"
      ;;
  esac

  if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
  exit 0
fi

# --- sessao de resgate -------------------------------------------------------
# TEM que vir antes do conserto: o prompt de resgate carrega a desistencia do
# conserto verbatim, e com ela a string REPAIR_ABORT. Classificar pelo conserto
# primeiro faria o mock (e qualquer parser) trocar as duas etapas.
if grep -q '^RALPH_RESCUE' <<< "$prompt"; then
  n=$(bump rescue_calls)
  [ -n "$model" ] && echo "$model" > "$state/rescue_model"
  printf '%s' "$prompt" > "$state/rescue_prompt_$n.txt"

  case "$scenario" in
    rescue-blocked)
      # Contradicao de especificacao: o resgate para sem editar nada.
      if [ "$name" = "claude" ]; then
        emit_claude_ndjson "RESCUE_BLOCKED: a fase exige recusar no comando e a importacao da WABA exige aceitar o mesmo nome"
      else
        echo "RESCUE_BLOCKED: a fase exige recusar no comando e a importacao da WABA exige aceitar o mesmo nome"
      fi
      exit 0
      ;;
    rescue-fix)
      # A autoridade que faltou ao conserto: reorganiza e entrega.
      mkdir -p src
      echo "rescue $n" > "src/rescue-$n.txt"
      ;;
    *)
      : # nao resolve nada: a fase segue vermelha e o orcamento se esgota
      ;;
  esac

  if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
  exit 0
fi

# --- conserto cirurgico ------------------------------------------------------
# O prompt de conserto e o unico que carrega a clausula REPAIR_ABORT. Grava o
# prompt para os asserts de escopo (o que ele NAO pode conter e o que importa).
if grep -q 'REPAIR_ABORT' <<< "$prompt"; then
  n=$(bump repair_calls)
  [ -n "$model" ] && echo "$model" > "$state/repair_model"
  printf '%s' "$prompt" > "$state/repair_prompt_$n.txt"

  case "$scenario" in
    repair-abort|rescue-fix|rescue-blocked)
      # Desistencia explicita, sem tocar em arquivo nenhum.
      if [ "$name" = "claude" ]; then
        emit_claude_ndjson "REPAIR_ABORT: causa nao localizavel no erro"
      else
        echo "REPAIR_ABORT: causa nao localizavel no erro"
      fi
      exit 0
      ;;
    repair-nochange)
      : # termina bem, mas nao escreve: conserto inutil
      ;;
    *)
      mkdir -p src
      echo "repair $n" > "src/repair-$n.txt"
      ;;
  esac

  if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
  exit 0
fi

# --- sessao de implementacao -------------------------------------------------
# O modelo da impl nao pode vazar do verificador nem do conserto: cada modo tem
# o seu, e o teste de modelo confere os tres.
[ -n "$model" ] && echo "$model" > "$state/impl_model"
n=$(bump impl_calls)

case "$scenario" in
  limit-epoch)
    if [ "$n" -eq 1 ]; then
      emit_claude_limit "$(date +%s)"
      exit 1
    fi
    ;;
  limit-generic)
    if [ "$n" -eq 1 ]; then
      echo "Rate limit reached. Try again later."
      exit 1
    fi
    ;;
  limit-weekly)
    # reset a 3 dias: limite semanal, nao o de sessao (<= 5h)
    if [ "$n" -eq 1 ]; then
      emit_claude_limit "$(( $(date +%s) + 259200 ))"
      exit 1
    fi
    ;;
esac

# stall-after-red: escreve no 1o ciclo (teste vermelho), depois trava sem
# escrever nada. already-done: o codigo ja existe em HEAD, o engine nao escreve.
write=1
[ "$scenario" = "empty-diff" ] && write=0
[ "$scenario" = "already-done" ] && write=0
[ "$scenario" = "stall-after-red" ] && [ "$n" -gt 1 ] && write=0
# stall-red-forever: escreve no 1o ciclo e depois trava, com a suite vermelha
# para sempre. E o ponto fixo que o ralph tem que reconhecer.
[ "$scenario" = "stall-red-forever" ] && [ "$n" -gt 1 ] && write=0

# slow-engine: sessao longa o bastante para o teste mandar o sinal no meio dela.
[ "$scenario" = "slow-engine" ] && sleep 5

if [ "$write" -eq 1 ]; then
  mkdir -p src
  echo "impl $n" > "src/impl-$n.txt"
  MOCK_WROTE+=("src/impl-$n.txt")
fi

# O Codex pode concluir uma task com um commit proprio. O Gate 1 precisa
# reconhecer esse HEAD novo como escrita da sessao, mesmo com a arvore limpa.
if [ "$scenario" = "self-commit" ] && [ "$write" -eq 1 ]; then
  git add "src/impl-$n.txt"
  git commit -q -m "feat: mock implementa fase $n"
fi

# scoped-tests: so a fase 2 (2a sessao de implementacao) cria arquivo de teste.
# critical-change: so a fase 2 mexe em migration — caminho critico.
if [ "$scenario" = "scoped-tests" ] && [ "$n" -eq 2 ]; then
  mkdir -p tests/Feature
  echo "teste da fase 2" > tests/Feature/AlvoTest.py
fi
if [ "$scenario" = "critical-change" ] && [ "$n" -eq 2 ]; then
  mkdir -p database/migrations
  echo "migration da fase 2" > database/migrations/2026_01_01_000000_cria_tabela.php
fi

if [ "$scenario" = "false-429" ]; then
  # 429 no MEIO do log: e output de teste do projeto, nao limite de uso.
  echo "FAIL tests/HttpClientTest: expected 429 Too Many Requests, got 200"
  for i in $(seq 1 25); do echo "linha de ruido $i"; done
  echo "Suite corrigida. Done."
  exit 0
fi

if [ "$name" = "claude" ]; then emit_claude_ok; else echo "Done."; fi
exit 0
MOCK

  chmod +x "$bin/mock-engine"
  cp "$bin/mock-engine" "$bin/claude"
  cp "$bin/mock-engine" "$bin/codex"
}

make_testcmd() {
  cat > "$1" <<'TESTCMD'
#!/usr/bin/env bash
set -uo pipefail
state="${MOCK_STATE:?}"
scenario="${MOCK_SCENARIO:-ok}"
# sail test real (docker compose exec) anexa stdin: mesmo risco do claude -p.
[ -t 0 ] || cat > /dev/null
f="$state/test_calls"; n=0
[ -f "$f" ] && n=$(cat "$f")
n=$((n + 1)); echo "$n" > "$f"
# Argumentos de cada execucao: e assim que o teste prova se o gate 2 rodou
# escopado (caminho de teste) ou completo (sem argumento nenhum).
printf '%s\n' "$*" >> "$state/test_args"

if [ "$scenario" = "test-red-once" ] || [ "$scenario" = "stall-after-red" ]; then
  if [ "$n" -eq 1 ]; then
    echo "1 failing test: ExpectedFooTest"
    exit 1
  fi
fi

# Vermelho permanente e SEM arquivo:linha: o conserto cirurgico nao se aplica,
# entao o caso isola o ciclo de correcao.
if [ "$scenario" = "stall-red-forever" ]; then
  echo "1 failing test: ExpectedFooTest"
  exit 1
fi

# baseline-*: vermelho que ja existe em HEAD. A 1a chamada e a medicao do
# baseline; dai em diante a suite devolve o MESMO vermelho.
if [ "$scenario" = "baseline-inherited" ] || [ "$scenario" = "baseline-regression" ]; then
  echo "   FAIL  Tests\\Feature\\HerdadoTest"
  if [ "$scenario" = "baseline-regression" ] && [ "$n" -gt 1 ]; then
    echo "   FAIL  Tests\\Feature\\NovoTest"
    echo "  Tests:    2 failed, 3 passed"
    exit 1
  fi
  echo "  Tests:    1 failed, 3 passed"
  exit 1
fi

# heal-*: vermelho herdado de HEAD, o gatilho do saneamento. A 1a chamada e a
# medicao em HEAD; heal-head fica verde depois que a sessao de saneamento escreve
# (o proprio arquivo que ela cria e a chave), heal-blocked nunca fecha.
if [ "$scenario" = "heal-head" ] || [ "$scenario" = "heal-blocked" ]; then
  if [ "$scenario" = "heal-head" ] && [ -f "$state/healed" ]; then
    echo "  Tests:    4 passed"
    exit 0
  fi
  echo "   FAIL  Tests\\Feature\\GuardaVelhaTest"
  echo "  Tests:    1 failed, 3 passed"
  exit 1
fi

# infra-*: a suite NAO chegou a julgar o codigo — servico externo fora do ar.
# Forma real do runner (SQLSTATE de conexao nomeando o container que caiu).
#   infra-recovered: so a 1a chamada cai; a reexecucao do gate 2 acha tudo verde
#   infra-forever:   o servico nunca volta
if [ "$scenario" = "infra-recovered" ] || [ "$scenario" = "infra-forever" ]; then
  if [ "$scenario" = "infra-forever" ] || [ "$n" -le 1 ]; then
    echo "   FAILED  Tests\\Feature\\SubjectTest > projeta o assunto"
    echo "  SQLSTATE[HY000] [2002] php_network_getaddresses: getaddrinfo for ralph-fixture-db-1 failed: Name or service not known (Connection: mysql_vizinho, Host: ralph-fixture-db-1, Port: 3306)"
    echo "  Tests:    5 failed, 100 passed"
    exit 1
  fi
fi

# Vermelho de verdade, enterrado sob centenas de linhas verdes. E a forma real
# de uma suite grande: a falha sai no FIM, e o `head` do tail so mostra verde.
if [ "$scenario" = "red-noisy" ]; then
  i=1
  while [ "$i" -le 240 ]; do echo "  ✓ teste verde $i"; i=$((i + 1)); done
  echo "   FAILED  Tests\\Feature\\AlvoTest > soma dois valores"
  echo "  Failed asserting that 3 matches expected 4."
  echo "  at tests/Feature/AlvoTest.php:22"
  echo "  Tests:    1 failed, 240 passed"
  exit 1
fi

# Falha com a forma que um runner real produz: cabecalho de falha, diff de
# assertion e arquivo:linha. E disso que o conserto cirurgico se alimenta.
if [ "$scenario" = "test-red-repairable" ] && [ "$n" -eq 1 ]; then
  cat <<'REDOUT'
   FAILED  Tests\Feature\SomaTest > soma dois valores
  Failed asserting that 3 matches expected 4.

  at tests/Feature/SomaTest.php:22
REDOUT
  exit 1
fi
echo "all green"
exit 0
TESTCMD
  chmod +x "$1"
}

PHASES_FIXTURE='# Test Project — Project Phases

<!-- inputs: project-description.md@sha256:000000000000 -->

## Overview

Projeto de teste.

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A
  - **Acceptance criteria:**
    - o arquivo existe
- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 2: Feature

- [ ] **Task:** cria o arquivo C
  - **Acceptance criteria:**
    - o arquivo existe

## Open Questions

- nenhuma
'

# Documento de 3 fases: a 2 e intermediaria de verdade (nem primeira, nem
# ultima), que e onde o escopo do gate 2 aparece.
PHASES_FIXTURE_3='# Test Project — Project Phases

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 2: Feature

- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 3: Wrap up

- [ ] **Task:** cria o arquivo C
  - **Acceptance criteria:**
    - o arquivo existe
'

# Igual ao de 3 fases, mas a fase 2 DECLARA que quer a suite inteira.
PHASES_FIXTURE_DECLARED='# Test Project — Project Phases

## Phase 1: Foundation

- [ ] **Task:** cria o arquivo A
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 2: Feature

Suite: completa

- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 3: Wrap up

- [ ] **Task:** cria o arquivo C
  - **Acceptance criteria:**
    - o arquivo existe
'

# Fixture de projeto Laravel + Sail. `sail ps` responde conforme SAIL_UP.
make_sail_fixture() {
  local repo="$1" up="$2"

  touch "$repo/artisan"
  cat > "$repo/composer.json" <<'JSON'
{
  "require-dev": { "laravel/sail": "^1.0" },
  "scripts": { "test": "phpunit" }
}
JSON

  mkdir -p "$repo/vendor/bin"
  cat > "$repo/vendor/bin/sail" <<SAILMOCK
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = "ps" ]; then
  if [ "$up" = "up" ]; then
    echo "NAME                IMAGE            STATUS"
    echo "proj-laravel.test-1 sail-8.3/app     Up 2 hours"
    exit 0
  fi
  echo "Sail is not running."
  exit 1
fi
if [ "\${1:-}" = "test" ]; then
  exec "\$MOCK_TEST_CMD"
fi
exit 0
SAILMOCK
  chmod +x "$repo/vendor/bin/sail"
}

# new_case <nome> -> ecoa o diretorio do repo fixture
new_case() {
  local name="$1"
  local dir="$TMP/$name"
  mkdir -p "$dir/repo" "$dir/state" "$dir/bin"
  make_mocks "$dir/bin"
  make_testcmd "$dir/test.sh"
  # Mesmo runner, com nome que o ralph reconhece como escopavel por caminho.
  # `test.sh` cai no ramo "runner desconhecido" e forca suite completa — os dois
  # comportamentos precisam de fixture propria.
  make_testcmd "$dir/pytest"

  (
    cd "$dir/repo" || exit 1
    git init -q
    git config user.email "test@ralph"
    git config user.name "Ralph Test"
    mkdir -p .spec/init
    printf '%s' "${CASE_PHASES:-$PHASES_FIXTURE}" > .spec/init/project-phases.md
    git add -A
    git commit -q -m "chore: fixture"
  )
  echo "$dir"
}

# run_ralph <dir> <scenario> [args...] -> ecoa o exit code; log em <dir>/out.log
# Os casos testam o MECANISMO (conserto, resgate, gate 3), nao a POLITICA de
# quanto gastar. Por isso o helper fixa o orcamento antigo e generoso: gate 3
# em toda fase, conserto ligado, 2 consertos, 2 resgates. Os defaults de
# producao sao curtos e tem caso proprio (`budget-defaults`).
#
# Expansao com `-` e nao `:-`: assim um caso que quer o default REAL do ralph
# passa a variavel VAZIA (CASE_VERIFY=) e o helper nao injeta nada.
run_ralph() {
  local dir="$1" scenario="$2"; shift 2
  local rc=0
  (
    cd "$dir/repo" || exit 1
    [ -n "${CASE_CLAUDE_CONFIG_DIR:-}" ] && export CLAUDE_CONFIG_DIR="$CASE_CLAUDE_CONFIG_DIR"
    PATH="$dir/bin:$PATH" \
    MOCK_STATE="$dir/state" \
    MOCK_SCENARIO="$scenario" \
    MOCK_TEST_CMD="$dir/test.sh" \
    RALPH_LIMIT_WAIT_DEFAULT=1 \
    RALPH_LIMIT_BUFFER=1 \
    RALPH_VERBOSE="${CASE_VERBOSE:-0}" \
    RALPH_HEARTBEAT="${CASE_HEARTBEAT:-0}" \
    RALPH_VERIFY="${CASE_VERIFY-always}" \
    RALPH_REPAIR="${CASE_REPAIR-on}" \
    RALPH_MAX_REPAIRS="${CASE_MAX_REPAIRS-2}" \
    RALPH_MAX_RESCUES="${CASE_MAX_RESCUES-2}" \
    RALPH_VERIFY_MODEL="${CASE_VERIFY_MODEL:-}" \
    RALPH_UI_SHOT_CMD="${CASE_UI_SHOT_CMD:-}" \
    RALPH_UI_VERIFY="${CASE_UI_VERIFY:-}" \
    RALPH_REPAIR_MODEL="${CASE_REPAIR_MODEL:-}" \
    RALPH_RESCUE="${CASE_RESCUE-off}" \
    RALPH_HEAL_HEAD="${CASE_HEAL_HEAD:-off}" \
    RALPH_RESCUE_MODEL="${CASE_RESCUE_MODEL:-}" \
    RALPH_CAVEMAN="${CASE_CAVEMAN:-}" \
    RALPH_NOTIFY_CMD="${CASE_NOTIFY_CMD:-}" \
      bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

commits() { git -C "$1/repo" rev-list --count HEAD; }

# make_notify_recorder <script_path> <events_file> [exit_code]
#
# Adaptador de notificacao fake: grava "<evento>|<projeto>|<fase>|<mensagem>"
# por linha. exit_code != 0 simula adaptador quebrado (rede fora, token errado),
# que o ralph precisa ignorar.
make_notify_recorder() {
  local script="$1" events="$2" rc="${3:-0}"
  cat > "$script" <<RECORDER
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\$1" "\${RALPH_PROJECT:-}" "\${RALPH_PHASE_NUM:-}" "\${2:-}" >> "$events"
exit $rc
RECORDER
  chmod +x "$script"
  : > "$events"
}

events_of() { grep -oE '^[a-z_]+' "$1" | tr '\n' ' '; }

count_event() { grep -cE "^$2\|" "$1" || true; }

case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

header() { CURRENT="$1"; echo -e "\n${YELLOW}== $1${NC}"; }

# ---------------------------------------------------------------------------
# 1. Fase ok de primeira -> 1 commit por fase, progresso gravado
# ---------------------------------------------------------------------------
if case_enabled ok-first; then
  header "1. fase ok de primeira"
  d=$(new_case ok-first)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "2 commits de fase (1 fixture + 2)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progresso registra phase-01"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progresso registra phase-02"
  assert_eq "feat(phase-2): Feature" "$(git -C "$d/repo" log -1 --pretty=%s)" "mensagem de commit da ultima fase"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "1 sessao de implementacao por fase (2 fases)"
  assert_eq 2 "$(cat "$d/state/verify_calls")" "gate 3 (default always) rodou em toda fase"
fi

# ---------------------------------------------------------------------------
# 2. Gate 2 vermelho 1x -> ciclo de correcao -> verde -> 1 commit so
# ---------------------------------------------------------------------------
if case_enabled test-red-once; then
  header "2. gate 2 vermelho uma vez -> ciclo de correcao"
  d=$(new_case test-red-once)
  # --full-suite: o alvo do caso e o gate 2 rodando na PRIMEIRA fase. No default
  # (escopo por fase) a suite so roda na ultima — isso e o caso "gate2-escopado".
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --full-suite)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase (ciclo intermediario nao commita)"
  assert_contains "$d/out.log" "Gate 2 vermelho" "gate 2 reportado vermelho"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "entrou em ciclo de correcao"
  # o prompt de correcao carrega a causa REAL, nao "os testes falharam" generico
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "ExpectedFooTest" "prompt de correcao carrega a saida do teste"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "## Fase a completar" "prompt de correcao e auto-contido (fase inteira)"
  # logs por ciclo, nunca sobrescritos
  test -f "$d/repo/.phases/logs/phase-01.cycle-1.log" && test -f "$d/repo/.phases/logs/phase-01.cycle-2.log" \
    && ok "logs por ciclo preservados" || bad "logs por ciclo preservados"
fi

# ---------------------------------------------------------------------------
# 3. Engine nao escreve nada e a fase esta incompleta -> falha sem commit
#    (gate 1 sinaliza; quem reprova e o verificador, contra o codigo real)
# ---------------------------------------------------------------------------
if case_enabled empty-diff; then
  header "3. engine nao escreve nada + fase incompleta -> falha sem commit"
  d=$(new_case empty-diff)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "nenhum commit criado (sem --allow-empty)"
  assert_contains "$d/out.log" "a sessao nao escreveu nada" "gate 1 sinalizou a sessao vazia"
  assert_contains "$d/out.log" "Gate 3 vermelho" "verificador reprovou contra o codigo real"
  assert_contains "$d/out.log" "Parando na primeira fase que falhou" "politica default = parar"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "sem alterar nenhum arquivo" "causa do ciclo cita a sessao vazia"
fi

# ---------------------------------------------------------------------------
# 4. Verificador INCOMPLETE 1x -> conserto cirurgico -> DONE -> commit
#    (com --no-repair o mesmo cenario cai no ciclo de correcao: caso 4b)
# ---------------------------------------------------------------------------
if case_enabled verify-incomplete; then
  header "4. verificador INCOMPLETE uma vez -> conserto cirurgico -> DONE"
  d=$(new_case verify-incomplete)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reportado vermelho"
  assert_contains "$d/out.log" "Conserto cirurgico 1/2" "o conserto entrou antes do ciclo"
  assert_not_contains "$d/out.log" "Ciclo de correcao" "nenhum ciclo de correcao gasto"
  assert_eq 1 "$(cat "$d/state/repair_calls")" "um unico conserto"
  test -f "$d/repo/.phases/logs/phase-01.verify-1.log" && ok "log do verificador por ciclo" || bad "log do verificador por ciclo"

  # O prompt do conserto e o oposto do prompt de correcao: leva o erro e SO ele.
  assert_contains "$d/state/repair_prompt_1.txt" "TASK 1: INCOMPLETE" "conserto recebe as tasks incompletas verbatim"
  assert_not_contains "$d/state/repair_prompt_1.txt" "Descubra a stack" "conserto nao carrega o preambulo de contexto"
  assert_not_contains "$d/state/repair_prompt_1.txt" "Acceptance criteria" "conserto nao carrega a fase inteira"

  # Revalidacao escopada entre rounds; cadeia completa antes do commit.
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1r1.txt" "Escopo desta verificacao" "revalidacao pos-conserto e escopada"
  test -f "$d/repo/.phases/prompts/phase-01.verify-1r1f.txt" \
    && ok "a verificacao completa pre-commit tem prompt proprio" \
    || bad "a verificacao completa pre-commit tem prompt proprio"
  assert_not_contains "$d/repo/.phases/prompts/phase-01.verify-1r1f.txt" "Escopo desta verificacao" "antes do commit o gate 3 roda sobre a fase inteira"
  assert_contains "$d/out.log" "revalidando a fase inteira antes do commit" "escopo verde nao fecha a fase sozinho"
fi

# ---------------------------------------------------------------------------
# 4b. O MESMO cenario com --no-repair: o ciclo de correcao volta a ser o unico
#     caminho, e o prompt dele continua auto-contido (fase inteira + causa).
# ---------------------------------------------------------------------------
if case_enabled verify-incomplete-no-repair; then
  header "4b. --no-repair devolve o cenario ao ciclo de correcao"
  d=$(new_case verify-incomplete-no-repair)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --no-repair)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "entrou em ciclo de correcao"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "TASK 1: INCOMPLETE" "prompt de correcao carrega as tasks incompletas verbatim"
  test -f "$d/state/repair_calls" && bad "nenhuma sessao de conserto gasta" || ok "nenhuma sessao de conserto gasta"
fi

# ---------------------------------------------------------------------------
# 5. Limite com epoch -> espera -> re-executa a MESMA fase sem consumir ciclo
# ---------------------------------------------------------------------------
if case_enabled limit-epoch; then
  header "5. limite com epoch -> espera -> mesma fase"
  d=$(new_case limit-epoch)
  # --max-cycles 1: se a espera consumisse um ciclo, a fase falharia
  rc=$(run_ralph "$d" limit-epoch --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (limite nao consome ciclo)"
  assert_eq 3 "$(commits "$d")" "fases commitadas apos a espera"
  assert_contains "$d/out.log" "Limite de uso atingido" "limite detectado"
  assert_contains "$d/out.log" "Reset previsto para" "epoch de reset extraido do log"
fi

# ---------------------------------------------------------------------------
# 5b. Limite semanal (reset a dias) -> encerra em vez de dormir
# ---------------------------------------------------------------------------
if case_enabled limit-weekly; then
  header "5b. limite semanal -> encerra com motivo e comando de retomada"
  d=$(new_case limit-weekly)
  rc=$(run_ralph "$d" limit-weekly --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (run encerrado, nao dormindo)"
  assert_contains "$d/out.log" "Limite semanal de uso" "classificou como semanal"
  assert_contains "$d/out.log" "--from" "devolveu o comando de retomada"
  # commits() conta o commit de fixture: 1 = nenhuma fase commitada
  assert_eq 1 "$(commits "$d")" "nenhuma fase commitada — parou na primeira"
fi

# ---------------------------------------------------------------------------
# 6. Limite generico sem epoch -> fallback wait
# ---------------------------------------------------------------------------
if case_enabled limit-generic; then
  header "6. limite generico sem epoch -> fallback"
  d=$(new_case limit-generic)
  rc=$(run_ralph "$d" limit-generic --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Sem horario de reset no output" "usou o fallback de espera"
  assert_eq 3 "$(commits "$d")" "fases commitadas apos a espera"
fi

# ---------------------------------------------------------------------------
# 7. "429 Too Many Requests" no MEIO do log -> NAO dispara espera (regressao)
# ---------------------------------------------------------------------------
if case_enabled false-429; then
  header "7. 429 no meio do log nao dispara espera"
  d=$(new_case false-429)
  start=$(date +%s)
  rc=$(run_ralph "$d" false-429 --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  elapsed=$(($(date +%s) - start))
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Limite de uso atingido" "nao interpretou 429 de teste como limite"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "429 Too Many Requests" "o 429 realmente estava no log"
  [ "$elapsed" -lt 5 ] && ok "sem espera (${elapsed}s)" || bad "sem espera (${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# 8. Segunda execucao com mesmo input -> fases feitas puladas (resume vivo)
# ---------------------------------------------------------------------------
if case_enabled resume; then
  header "8. resume: segunda execucao pula fases feitas"
  d=$(new_case resume)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "primeira execucao verde"
  before=$(commits "$d")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "segunda execucao verde"
  assert_eq "$before" "$(commits "$d")" "nenhum commit novo"
  assert_contains "$d/out.log" "Progresso anterior preservado" "progresso preservado (input inalterado)"
  assert_contains "$d/out.log" "(ja completada)" "fases puladas"
fi

# ---------------------------------------------------------------------------
# 9. Input mutado entre execucoes -> progresso invalidado com aviso
# ---------------------------------------------------------------------------
if case_enabled resume-invalidated; then
  header "9. input mutado -> progresso invalidado"
  d=$(new_case resume-invalidated)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "primeira execucao verde"
  before=$(commits "$d")
  (
    cd "$d/repo" || exit 1
    printf '\n## Phase 3: Extra\n\n- [ ] **Task:** cria o arquivo D\n  - **Acceptance criteria:**\n    - o arquivo existe\n' >> .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: nova fase"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "segunda execucao verde"
  assert_contains "$d/out.log" "progresso zerado" "progresso invalidado com aviso"
  assert_eq $((before + 4)) "$(commits "$d")" "3 fases re-executadas + commit da mutacao"
fi

# ---------------------------------------------------------------------------
# 10. Arvore suja no preflight -> abort antes de qualquer sessao
# ---------------------------------------------------------------------------
if case_enabled dirty-tree; then
  header "10. arvore suja -> abort no preflight"
  d=$(new_case dirty-tree)
  echo "trabalho nao commitado" > "$d/repo/rascunho.txt"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Arvore de trabalho suja" "abortou com instrucao"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 11. Contrato de formato do input -> abort antes de gastar token
# ---------------------------------------------------------------------------
if case_enabled bad-format; then
  header "11. heading de fase torto -> abort no preflight"
  d=$(new_case bad-format)
  (
    cd "$d/repo" || exit 1
    sed -i 's/^## Phase 2: Feature$/## Phase Two — Feature/' .spec/init/project-phases.md
    git add -A && git commit -q -m "chore: heading torto"
  )
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  # "## Phase Two" nao casa com '^## Phase [0-9]+: ' -> heading malformado
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Contrato de formato violado" "abortou por formato invalido"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 12. Ciclo de correcao que nao escreve nada, mas o codigo do ciclo anterior
#     esta completo e verde -> a fase passa (o verificador manda, nao o diff)
# ---------------------------------------------------------------------------
if case_enabled stall-after-red; then
  header "12. ciclo sem escrita + codigo completo -> gate 3 decide, fase passa"
  d=$(new_case stall-after-red)
  rc=$(run_ralph "$d" stall-after-red --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  # o mock so escreve na 1a sessao: fase 1 commita apos o ciclo 2; fase 2 cai
  # no caminho "ja implementada" (o verificador ve o codigo e aprova)
  assert_eq 2 "$(commits "$d")" "1 commit (fase 1); fase 2 nao tinha o que commitar"
  assert_contains "$d/out.log" "Gate 2 vermelho" "o ciclo comecou por um gate 2 vermelho"
  assert_contains "$d/out.log" "a sessao nao escreveu nada" "gate 1 sinalizou a sessao vazia do ciclo 2"
  assert_contains "$d/out.log" "feat(phase-1)" "fase 1 commitada apos o ciclo de correcao"
fi

# ---------------------------------------------------------------------------
# 17. Fase JA implementada em HEAD (run anterior commitada) -> reconhecida
#     sem commit, sem falhar. Regressao do bug real: o engine nao escreve
#     porque nao ha o que escrever, e o gate 1 reprovava isso.
# ---------------------------------------------------------------------------
if case_enabled already-done; then
  header "17. fase ja implementada em HEAD -> reconhecida sem commit"
  d=$(new_case already-done)
  # simula a run anterior: codigo implementado e commitado a mao, progress vazio
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho da run anterior"
  before=$(commits "$d")

  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (nao reprova fase ja implementada)"
  assert_contains "$d/out.log" "JA IMPLEMENTADA" "reconheceu a fase como feita"
  assert_eq "$before" "$(commits "$d")" "nenhum commit criado (nada a commitar)"
  assert_contains "$d/repo/.phases/.progress" "phase-01.md" "progresso registra a fase"
  assert_contains "$d/repo/.phases/.progress" "phase-02.md" "progresso registra a fase seguinte"
fi

# ---------------------------------------------------------------------------
# 17b. Engine que commita dentro da propria sessao ainda escreveu codigo: o
#      Gate 1 compara tambem o HEAD, nao apenas a arvore que ficou limpa.
# ---------------------------------------------------------------------------
if case_enabled gate1-self-commit; then
  header "17b. commit do engine conta como escrita da sessao"
  d=$(new_case gate1-self-commit)
  rc=$(run_ralph "$d" self-commit --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Gate 1 — a sessao nao escreveu nada" "gate 1 reconheceu o commit do engine"
  assert_eq 3 "$(commits "$d")" "fixture e dois commits do engine, sem commit duplicado do ralph"
fi

# ---------------------------------------------------------------------------
# 17c. Monorepo sem manifesto na raiz pode declarar o comando no cabecalho do
#      plano; ele e o fallback explicito depois de flag e variavel de ambiente.
# ---------------------------------------------------------------------------
if case_enabled gate2-plan-command; then
  header "17c. comando RALPH_TEST_CMD declarado no plano alimenta o gate 2"
  d=$(new_case gate2-plan-command)
  cat > "$d/repo/ralph-test" <<'TESTCMD'
#!/usr/bin/env bash
exec "${MOCK_TEST_CMD:?}" "$@"
TESTCMD
  chmod +x "$d/repo/ralph-test"
  sed -i "1iRALPH_TEST_CMD='./ralph-test'" "$d/repo/.spec/init/project-phases.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "test: declara comando no plano"

  rc=$(run_ralph "$d" ok --engine codex --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "comando de teste (declarado no plano): ./ralph-test" "gate 2 leu o comando declarado"
  assert_eq 1 "$(cat "$d/state/test_calls")" "suite executada na fase final"
fi

# ---------------------------------------------------------------------------
# 17d. O Codex recebe shell em sandbox read-only, nao as ferramentas nomeadas
#      Read/Glob/Grep do Claude. O prompt precisa permitir essa inspecao.
# ---------------------------------------------------------------------------
if case_enabled verify-codex-readonly; then
  header "17d. verificador Codex recebe instrucoes de leitura compativeis"
  d=$(new_case verify-codex-readonly)
  mkdir -p "$d/repo/src"
  echo "implementacao previa" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "test: fase ja implementada"

  rc=$(run_ralph "$d" already-done --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/state/verify_prompt" "No Codex, inspecione somente com comandos de leitura" "prompt Codex libera leitura no sandbox"
  assert_not_contains "$d/state/verify_prompt" "Voce NAO executa comandos: esta sessao so le (Read/Glob/Grep)" "prompt nao exige ferramentas ausentes no Codex"
fi

# ---------------------------------------------------------------------------
# 18. Fase falhou -> avisa que o trabalho parcial ficou na arvore
# ---------------------------------------------------------------------------
if case_enabled dirty-after-fail; then
  header "18. fase falhou com trabalho na arvore -> instrui o dev"
  d=$(new_case dirty-after-fail)
  # verify-incomplete-once com 1 ciclo: escreve, testes verdes, verificador
  # reprova. --no-repair porque aqui o alvo e a INSTRUCAO de arvore suja: com
  # o conserto ligado esse cenario fecha verde (caso 4) e nunca chega ao aviso.
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(commits "$d")" "nenhum commit"
  assert_contains "$d/out.log" "trabalho parcial desta fase ficou na arvore" "avisou sobre a arvore suja"
  assert_contains "$d/out.log" "git clean -fd" "deu a saida de descarte"
fi

# ---------------------------------------------------------------------------
# 19. --no-verify desliga o gate 3 mesmo no caminho suspeito (sessao sem
#     escrita). Escolha explicita do dev: o ralph confia no gate 2 sozinho.
# ---------------------------------------------------------------------------
if case_enabled no-verify; then
  header "19. --no-verify desliga o gate 3 ate no caminho suspeito"
  d=$(new_case no-verify)
  rc=$(run_ralph "$d" empty-diff --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-verify)
  assert_eq 0 "$rc" "exit 0 (gate 2 verde decide sozinho)"
  assert_contains "$d/out.log" "Gate 3 pulado (--no-verify)" "skip explicito logado"
  assert_contains "$d/out.log" "Gate 2 verde contra o codigo em HEAD" "mensagem nao menciona gate 3 (nao rodou)"
  test -f "$d/state/verify_calls" && bad "nenhuma sessao verificadora gasta" || ok "nenhuma sessao verificadora gasta"
fi

# ---------------------------------------------------------------------------
# 20. RALPH_VERIFY=auto (opt-in): caminho feliz (sessao escreveu + suite verde)
#     pula o gate 3; a fase ainda commita.
# ---------------------------------------------------------------------------
if case_enabled verify-auto; then
  header "20. RALPH_VERIFY=auto pula o gate 3 quando a suite cobriu a fase"
  d=$(new_case verify-auto)
  # --full-suite: a condicao do `auto` e o gate 2 ter julgado ESTA fase. Sem
  # isso o escopo do gate 2 e `skip` e o gate 3 passa a ser obrigatorio.
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --full-suite)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "fases commitadas"
  assert_contains "$d/out.log" "Gate 3 pulado: a suite cobriu esta fase" "skip logado com a causa"
  test -f "$d/state/verify_calls" && bad "nenhuma sessao verificadora gasta" || ok "nenhuma sessao verificadora gasta"
fi

# ---------------------------------------------------------------------------
# 20b. RALPH_VERIFY=auto NAO pula o gate 3 quando a suite nao cobriu a fase.
#
# Fase de fiacao/view/config nao altera nem cita arquivo de teste: o gate 2
# resolve o escopo como `skip` e nao executa nada. Pular o gate 3 ali fechava e
# commitava a fase sem validacao mecanica nenhuma — o `auto` olhava para
# "o projeto TEM suite", nao para "esta fase foi testada".
#
# Fica vermelho se a condicao do `auto` voltar a depender so de $TEST_CMD.
# ---------------------------------------------------------------------------
if case_enabled verify-auto-uncovered; then
  header "20b. auto NAO pula o gate 3 em fase que a suite nao cobriu"
  d=$(new_case verify-auto-uncovered)
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Gate 2 — nao executado" "o gate 2 nao cobriu a fase"
  # Duas fases: a ultima e o gate final da spec (suite completa -> gate 3
  # pulado); a primeira nao foi coberta e TEM que gastar o verificador.
  # Exatamente 1 sessao prova as duas metades da regra de uma vez.
  assert_eq 1 "$(cat "$d/state/verify_calls" 2>/dev/null || echo 0)" \
    "gate 3 gasto so na fase que a suite nao cobriu"
fi

# ---------------------------------------------------------------------------
# 21. Verificador roda com modelo proprio: sonnet por default no claude,
#     RALPH_VERIFY_MODEL sobrepoe.
# ---------------------------------------------------------------------------
if case_enabled verify-model; then
  header "21. verificador usa modelo proprio (sonnet default, env sobrepoe)"
  d=$(new_case verify-model)
  # fase ja implementada em HEAD: sessao nao escreve -> gate 3 roda em auto
  mkdir -p "$d/repo/src"
  echo "impl previo" > "$d/repo/src/impl-1.txt"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "feat: trabalho previo"
  rc=$(run_ralph "$d" already-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "sonnet" "$(cat "$d/state/verify_model" 2>/dev/null)" "verify chamado com --model sonnet"
  assert_contains "$d/out.log" "modelo: sonnet" "log do gate 3 informa o modelo"

  d2=$(new_case verify-model-override)
  mkdir -p "$d2/repo/src"
  echo "impl previo" > "$d2/repo/src/impl-1.txt"
  git -C "$d2/repo" add -A && git -C "$d2/repo" commit -q -m "feat: trabalho previo"
  rc=$(CASE_VERIFY_MODEL=haiku run_ralph "$d2" already-done --engine claude --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (override)"
  assert_eq "haiku" "$(cat "$d2/state/verify_model" 2>/dev/null)" "RALPH_VERIFY_MODEL sobrepoe o default"
fi

# ---------------------------------------------------------------------------
# 13. Laravel Sail com containers de pe -> gate 2 usa `vendor/bin/sail test`
#     (e NAO `composer test`, que rodaria no host sem PHP nem banco)
# ---------------------------------------------------------------------------
if case_enabled sail-up; then
  header "13. Laravel Sail up -> gate 2 roda sail test"
  d=$(new_case sail-up)
  make_sail_fixture "$d/repo" up
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude --full-suite)   # sem --test-cmd: exercita a deteccao
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "comando de teste (detectado): vendor/bin/sail test" "detectou sail test"
  assert_not_contains "$d/out.log" "composer test" "composer test nao foi escolhido"
  assert_contains "$d/out.log" "Sail: containers de pe" "checou containers no preflight"
  # base = 2 commits (fixture + chore: sail) + 2 fases
  assert_eq 4 "$(commits "$d")" "fases commitadas (gate 2 rodou de verdade)"
  assert_eq 2 "$(cat "$d/state/test_calls")" "a suite rodou 1x por fase, via sail"
  # o agente precisa saber qual runner usar, senao roda php artisan test no host
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "vendor/bin/sail test" "prompt informa o comando de teste"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Nunca rode essas ferramentas no host" "prompt avisa sobre o container"
fi

# ---------------------------------------------------------------------------
# 14. Sail com containers parados -> abort no preflight, zero tokens
# ---------------------------------------------------------------------------
if case_enabled sail-down; then
  header "14. Laravel Sail down -> abort no preflight"
  d=$(new_case sail-down)
  make_sail_fixture "$d/repo" down
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "containers nao estao de pe" "abortou com a causa"
  assert_contains "$d/out.log" "vendor/bin/sail up -d" "instruiu como subir o ambiente"
  assert_eq 2 "$(commits "$d")" "nenhum commit de fase"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 15. --test-cmd sobrepoe a deteccao de Sail
# ---------------------------------------------------------------------------
if case_enabled sail-override; then
  header "15. --test-cmd sobrepoe a deteccao de Sail"
  d=$(new_case sail-override)
  make_sail_fixture "$d/repo" down   # containers parados, mas o cmd nao usa sail
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: sail"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (nao checa containers para cmd sem sail)"
  assert_contains "$d/out.log" "comando de teste (--test-cmd)" "override respeitado"
  assert_eq 4 "$(commits "$d")" "fases commitadas"
fi

# ---------------------------------------------------------------------------
# 16. Laravel sem Sail -> composer test (regressao: nao vira sail test)
# ---------------------------------------------------------------------------
if case_enabled laravel-no-sail; then
  header "16. Laravel sem Sail -> composer test"
  d=$(new_case laravel-no-sail)
  touch "$d/repo/artisan"
  printf '{ "scripts": { "test": "phpunit" } }\n' > "$d/repo/composer.json"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: laravel"
  # nao roda ate o fim: so precisamos do preflight resolvendo o comando
  run_ralph "$d" empty-diff --engine claude --max-cycles 1 > /dev/null
  assert_contains "$d/out.log" "comando de teste (detectado): composer test" "sem sail -> composer test"
  assert_not_contains "$d/out.log" "Sail" "nao mencionou Sail"
fi

# ---------------------------------------------------------------------------
# 22. RALPH_NOTIFY_CMD — run verde emite phase_done por fase + run_done
# ---------------------------------------------------------------------------
if case_enabled notify-green; then
  header "22. notify — run verde"
  d=$(new_case notify-green)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 1 "$(count_event "$d/events.txt" run_start)" "1 run_start no inicio"
  assert_eq run_start "$(head -1 "$d/events.txt" | cut -d'|' -f1)" "run_start e o primeiro evento"
  assert_contains "$d/events.txt" "2 de 2 fase(s)" "run_start conta as fases pendentes"
  assert_eq 2 "$(count_event "$d/events.txt" phase_done)" "1 phase_done por fase"
  assert_eq 1 "$(count_event "$d/events.txt" run_done)" "1 run_done no fim"
  assert_eq 0 "$(count_event "$d/events.txt" phase_failed)" "nenhum phase_failed"
  assert_contains "$d/events.txt" "|repo|1|" "RALPH_PROJECT e RALPH_PHASE_NUM chegam ao adaptador"
  assert_contains "$d/events.txt" "run_done|" "run_done carrega o resumo"
  assert_contains "$d/events.txt" "completa(s)" "resumo do run tem a contagem"
fi

# ---------------------------------------------------------------------------
# 23. RALPH_NOTIFY_CMD — limite de uso emite limit_hit e limit_over
# ---------------------------------------------------------------------------
if case_enabled notify-limit; then
  header "23. notify — limite de uso"
  d=$(new_case notify-limit)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" limit-epoch --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (retomou depois do reset)"
  assert_eq 1 "$(count_event "$d/events.txt" limit_hit)" "limit_hit emitido"
  assert_eq 1 "$(count_event "$d/events.txt" limit_over)" "limit_over emitido na retomada"
  assert_contains "$d/events.txt" "Nenhuma acao necessaria" "limit_hit diz que nao precisa intervir"
  assert_eq 2 "$(count_event "$d/events.txt" phase_done)" "as 2 fases seguiram verdes"
fi

# ---------------------------------------------------------------------------
# 24. RALPH_NOTIFY_CMD — fase reprovada emite phase_failed com a causa
# ---------------------------------------------------------------------------
if case_enabled notify-failed; then
  header "24. notify — fase reprovada"
  d=$(new_case notify-failed)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" empty-diff --engine claude --max-cycles 1 --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_eq 1 "$(count_event "$d/events.txt" phase_failed)" "phase_failed emitido"
  assert_contains "$d/events.txt" "Ultimo gate:" "phase_failed nomeia o gate"
  assert_eq 1 "$(count_event "$d/events.txt" run_done)" "run_done emitido mesmo com falha"
fi

# ---------------------------------------------------------------------------
# 25. Notificacao e efeito colateral: adaptador quebrado nao altera o run
# ---------------------------------------------------------------------------
if case_enabled notify-broken; then
  header "25. notify — adaptador quebrado nao derruba o run"
  d=$(new_case notify-broken)
  make_notify_recorder "$d/notify.sh" "$d/events.txt" 1   # exit 1 sempre
  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 apesar do adaptador falhar"
  assert_eq 3 "$(commits "$d")" "fases commitadas normalmente"

  # comando inexistente: nem `timeout` resolvendo o binario pode vazar erro
  d2=$(new_case notify-missing)
  CASE_NOTIFY_CMD="$d2/nao-existe.sh" \
    rc=$(run_ralph "$d2" ok --engine claude --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "exit 0 com RALPH_NOTIFY_CMD inexistente"
  assert_eq 3 "$(commits "$d2")" "fases commitadas normalmente"
  assert_not_contains "$d2/out.log" "nao-existe.sh" "nenhum erro do adaptador no log do run"
fi

# ---------------------------------------------------------------------------
# 26. run_start conta o que FALTA, nao o total: no resume as fases feitas ficam
#     de fora, senao a notificacao de inicio mente sobre o tamanho do run.
# ---------------------------------------------------------------------------
if case_enabled notify-resume; then
  header "26. notify — run_start conta so as fases pendentes"
  d=$(new_case notify-resume)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"

  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "1a execucao: exit 0"
  assert_contains "$d/events.txt" "2 de 2 fase(s)" "1a execucao: 2 pendentes"

  : > "$d/events.txt"
  CASE_NOTIFY_CMD="$d/notify.sh" \
    rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "2a execucao: exit 0"
  assert_contains "$d/events.txt" "0 de 2 fase(s)" "2a execucao: nada pendente"
  assert_eq 0 "$(count_event "$d/events.txt" phase_done)" "nenhuma fase reexecutada"

  # --from tambem nao deve inflar a contagem
  d2=$(new_case notify-from)
  make_notify_recorder "$d2/notify.sh" "$d2/events.txt"
  CASE_NOTIFY_CMD="$d2/notify.sh" \
    rc=$(run_ralph "$d2" ok --engine claude --from 2 --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "--from 2: exit 0"
  assert_contains "$d2/events.txt" "1 de 2 fase(s)" "--from 2: so 1 pendente"
fi

# ---------------------------------------------------------------------------
# 27. Streams separados: o log parseado pelos gates so tem a resposta final;
#     o progresso do engine vive no .stderr.log.
# ---------------------------------------------------------------------------
if case_enabled split-streams; then
  header "27. stdout e stderr do engine em arquivos separados"
  # Os dois caminhos de run_split: quiet (redirect direto) e verbose (FIFO).
  for eng in claude codex; do
    for verb in 0 1; do
      d=$(new_case "split-streams-$eng-$verb")
      # O prefixo vai DENTRO da substituicao: `VAR=x rc=$(cmd)` nao tem palavra
      # de comando, entao bash trata os dois como atribuicao ao shell corrente
      # e CASE_VERBOSE=1 vaza para todos os casos seguintes.
      rc=$(CASE_VERBOSE="$verb" run_ralph "$d" ok --engine "$eng" --test-cmd "$d/test.sh")
      tag="$eng verbose=$verb"
      assert_eq 0 "$rc" "$tag: exit 0"

      logs="$d/repo/.phases/logs"
      assert_not_contains "$logs/phase-01.cycle-1.log" "[mock] progresso" \
        "$tag: stdout da implementacao sem progresso do engine"
      assert_contains "$logs/phase-01.cycle-1.stderr.log" "[mock] progresso" \
        "$tag: progresso da implementacao no .stderr.log"
      assert_not_contains "$logs/phase-01.verify-1.log" "[mock] progresso" \
        "$tag: stdout do verificador sem progresso do engine"
      assert_contains "$logs/phase-01.verify-1.stderr.log" "[mock] progresso" \
        "$tag: progresso do verificador no .stderr.log"
    done
  done
fi

# ---------------------------------------------------------------------------
# 28. REGRESSAO do falso gate 3 vermelho: o codex ecoa a resposta final no
#     stdout E no stderr. Com 2>&1 o parser contava 4 TASK para 2 tasks e
#     reprovava uma fase inteiramente implementada.
# ---------------------------------------------------------------------------
if case_enabled verify-echo-both; then
  header "28. resposta final ecoada nos dois streams -> gate 3 verde"
  d=$(new_case verify-echo-both)
  rc=$(run_ralph "$d" verify-echo-both --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (eco no stderr nao conta como cobertura)"
  assert_eq 3 "$(commits "$d")" "2 commits de fase (1 fixture + 2)"
  assert_contains "$d/out.log" "2/2 tasks confirmadas" "gate 3 contou 2 de 2, nao 4 de 2"
  assert_not_contains "$d/out.log" "cobertura incompleta" "sem falso vermelho de cobertura"
  assert_contains "$d/repo/.phases/logs/phase-01.verify-1.stderr.log" "TASK 1: DONE" \
    "o eco ficou no .stderr.log"
fi

# ---------------------------------------------------------------------------
# 29. Duplicata no MESMO stream (modelo repete o bloco como resumo): cobertura
#     se mede em indices unicos, nao em linhas.
# ---------------------------------------------------------------------------
if case_enabled verify-dup-stdout; then
  header "29. bloco TASK repetido no stdout -> indices unicos"
  d=$(new_case verify-dup-stdout)
  rc=$(run_ralph "$d" verify-dup-stdout --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "2/2 tasks confirmadas" "gate 3 verde com 2 indices unicos"
  assert_contains "$d/out.log" "duplicatas ignoradas" "ralph reporta a deduplicacao"
fi

# ---------------------------------------------------------------------------
# 30. O reverso: duplicata NAO pode esconder buraco. 'TASK 1' duas vezes e
#     nenhum 'TASK 2' da 2 linhas para 2 tasks — contar linhas daria verde com
#     metade da fase sem veredito.
# ---------------------------------------------------------------------------
if case_enabled verify-dup-hides-gap; then
  header "30. duplicata escondendo task sem veredito -> gate 3 vermelho"
  d=$(new_case verify-dup-hides-gap)
  rc=$(run_ralph "$d" verify-dup-hides-gap --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "faltou veredito para a(s) task(s): 2" "aponta a task nao coberta"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase"
fi

# ---------------------------------------------------------------------------
# 31. Indice fora de 1..N: numeracao desalinhada nao vira cobertura.
# ---------------------------------------------------------------------------
if case_enabled verify-index-out-of-range; then
  header "31. indice de task fora do intervalo -> gate 3 vermelho"
  d=$(new_case verify-index-out-of-range)
  rc=$(run_ralph "$d" verify-index-out-of-range --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "fora do intervalo 1..2: 9" "nomeia o indice invalido"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase"
fi

# ---------------------------------------------------------------------------
# 32. Terminal silencioso por default: o progresso do engine (48KB de stderr por
#     sessao no codex 0.146) fica so no log. --verbose devolve o stream ao vivo.
# ---------------------------------------------------------------------------
if case_enabled quiet-terminal; then
  header "32. quiet e o default; --verbose streama o progresso"
  d=$(new_case quiet-default)
  rc=$(run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "quiet: exit 0"
  assert_not_contains "$d/out.log" "[mock] progresso" "quiet: progresso fora do terminal"
  assert_contains "$d/out.log" "Phase 1: Foundation" "quiet: placar do ralph preservado"
  assert_contains "$d/out.log" "2/2 tasks confirmadas" "quiet: veredito dos gates preservado"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.stderr.log" "[mock] progresso" \
    "quiet: progresso integral no log"

  d2=$(new_case verbose-flag)
  rc=$(run_ralph "$d2" ok --engine codex --verbose --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "--verbose: exit 0"
  assert_contains "$d2/out.log" "[mock] progresso" "--verbose: progresso no terminal"

  # Gate vermelho no modo quiet precisa dizer onde esta o progresso escondido.
  d3=$(new_case quiet-red)
  rc=$(run_ralph "$d3" empty-diff --engine codex --test-cmd "$d3/test.sh")
  assert_eq 1 "$rc" "gate vermelho: exit 1"
  assert_contains "$d3/out.log" "Progresso do engine: .phases/logs/phase-01.cycle-1.stderr.log" \
    "gate vermelho: aponta o log de progresso"
fi

# ---------------------------------------------------------------------------
# 33. RALPH_HEARTBEAT invalido aborta no preflight (nao vira sleep infinito).
# ---------------------------------------------------------------------------
if case_enabled bad-heartbeat; then
  header "33. RALPH_HEARTBEAT invalido -> abort no preflight"
  d=$(new_case bad-heartbeat)
  rc=$(CASE_HEARTBEAT="abc" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Valor invalido para RALPH_HEARTBEAT" "mensagem de preflight"
  assert_eq 1 "$(commits "$d")" "nenhuma fase executada"
fi

# ---------------------------------------------------------------------------
# 34. Estado estruturado: state.json valido + events.jsonl com os gates.
# ---------------------------------------------------------------------------
if case_enabled state-files; then
  header "34. .phases/state.json + .phases/events.jsonl"
  d=$(new_case state-files)
  rc=$(run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"

  st="$d/repo/.phases/state.json"
  ev="$d/repo/.phases/events.jsonl"

  if [ -f "$st" ]; then ok "state.json existe"; else bad "state.json existe"; fi
  if [ -f "$ev" ]; then ok "events.jsonl existe"; else bad "events.jsonl existe"; fi

  # JSON valido de verdade, nao "parece JSON": um snapshot quebrado derruba o
  # dashboard sem derrubar o run, e o bug so aparece no navegador.
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$st" 2> /dev/null; then
    ok "state.json e JSON valido"
  else
    bad "state.json e JSON valido"
  fi

  if python3 - "$ev" <<'PY' 2> /dev/null
import json, sys
for line in open(sys.argv[1]):
    if line.strip():
        json.loads(line)
PY
  then ok "toda linha do events.jsonl e JSON valido"
  else bad "toda linha do events.jsonl e JSON valido"; fi

  assert_contains "$st" '"run_status": "done"' "state final marca o run como done"
  assert_contains "$st" '"status": "done"' "fases concluidas marcadas no snapshot"

  # Os 4 gates precisam de veredito em toda fase executada: sem isso o painel
  # mostra gate parado e a timeline do dashboard fica com buraco.
  for g in 0 1 2 3; do
    if grep -E '"event": "gate_end"' "$ev" | grep -q "\"gate\": $g,"; then
      ok "gate $g emitiu gate_end"
    else
      bad "gate $g emitiu gate_end"
    fi
  done
  assert_contains "$ev" '"event": "gate_start"' "gate_start registrado"
  assert_contains "$ev" '"duration":' "gate_end carrega duracao"

  # Os 7 eventos do notify tambem entram na corrente, com os mesmos nomes.
  assert_contains "$ev" '"event": "run_start"' "run_start no events.jsonl"
  assert_contains "$ev" '"event": "phase_done"' "phase_done no events.jsonl"
  assert_contains "$ev" '"event": "run_done"' "run_done no events.jsonl"
fi

# ---------------------------------------------------------------------------
# 35. Painel: sem TTY nenhuma sequencia de escape pode sair — nem com
#     RALPH_UI=panel. Redirecionar um painel para arquivo produz lixo.
# ---------------------------------------------------------------------------
if case_enabled ui-non-tty; then
  header "35. sem TTY o painel nunca desenha"
  d=$(new_case ui-non-tty)
  rc=$(run_ralph "$d" ok --engine codex --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "auto: exit 0"
  assert_not_contains "$d/out.log" $'\033[?25l' "auto: nao esconde o cursor"
  assert_not_contains "$d/out.log" "┌─ ralph" "auto: nenhum quadro desenhado"
  assert_contains "$d/out.log" "Phase 1: Foundation" "auto: placar em linha corrida preservado"

  d2=$(new_case ui-forced)
  rc=$(RALPH_UI=panel run_ralph "$d2" ok --engine codex --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "RALPH_UI=panel: exit 0"
  assert_not_contains "$d2/out.log" $'\033[?25l' "RALPH_UI=panel sem TTY: nao esconde o cursor"
  assert_not_contains "$d2/out.log" "┌─ ralph" "RALPH_UI=panel sem TTY: nenhum quadro"
  assert_contains "$d2/out.log" "2/2 tasks confirmadas" "RALPH_UI=panel sem TTY: veredito preservado"

  # O placar do modo plain e o contrato de compatibilidade: quem roda em
  # nohup/CI nao pode ver diferenca nenhuma entre auto e plain.
  d3=$(new_case ui-plain)
  rc=$(RALPH_UI=plain run_ralph "$d3" ok --engine codex --test-cmd "$d3/test.sh")
  assert_eq 0 "$rc" "RALPH_UI=plain: exit 0"
  # Normaliza o que muda entre duas execucoes quaisquer: relogio, caminho do
  # caso e duracao. O que sobra e o placar em si — o contrato de compatibilidade.
  norm() { sed -E 's/[0-9]{2}:[0-9]{2}:[0-9]{2}//g; s#/tmp/[^ ]*##g; s/[0-9]+(h|m|s)\b/N\1/g' "$1"; }
  if diff <(norm "$d/out.log") <(norm "$d3/out.log") > /dev/null; then
    ok "auto sem TTY produz a mesma saida que plain"
  else
    bad "auto sem TTY produz a mesma saida que plain"
  fi
fi

# ---------------------------------------------------------------------------
# 36. RALPH_UI invalido aborta no preflight (antes de gastar token).
# ---------------------------------------------------------------------------
if case_enabled bad-ui; then
  header "36. RALPH_UI invalido -> abort no preflight"
  d=$(new_case bad-ui)
  rc=$(RALPH_UI=fancy run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Valor invalido para RALPH_UI" "mensagem de preflight"
  assert_eq 1 "$(commits "$d")" "nenhuma fase executada"
fi

# ---------------------------------------------------------------------------
# 37. --serve: sem python3 avisa e o run segue; com python3 sobe, imprime a URL
#     e nao deixa servidor vivo no fim.
# ---------------------------------------------------------------------------
if case_enabled serve; then
  header "37. --serve"

  # PATH espelhado por symlink, menos python*: `command -v python3` precisa
  # falhar de verdade. Um stub que sai 127 nao serve — o ralph checa presenca,
  # nao exit code.
  d=$(new_case serve-no-python)
  mkdir -p "$d/nopy"
  for p in /usr/bin/* /bin/*; do
    b=$(basename "$p")
    case "$b" in python|python3|python3.*) continue ;; esac
    ln -sf "$p" "$d/nopy/$b" 2> /dev/null || true
  done

  rc=0
  (
    cd "$d/repo" || exit 1
    PATH="$d/bin:$d/nopy" \
    MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
    RALPH_HEARTBEAT=0 \
      bash "$RALPH" --serve --engine codex --test-cmd "$d/test.sh" > "$d/out.log" 2>&1
  ) || rc=$?
  assert_eq 0 "$rc" "sem python3: run completa normalmente"
  assert_contains "$d/out.log" "python3 nao esta no PATH" "sem python3: aviso alto"
  assert_not_contains "$d/out.log" "Dashboard web: http" "sem python3: nenhuma URL prometida"
  assert_contains "$d/out.log" "2/2 tasks confirmadas" "sem python3: gates seguem valendo"

  if command -v python3 > /dev/null 2>&1; then
    d2=$(new_case serve-up)
    rc=$(run_ralph "$d2" ok --engine codex --serve --test-cmd "$d2/test.sh")
    assert_eq 0 "$rc" "com python3: exit 0 (o dashboard nunca muda o veredito)"
    assert_contains "$d2/out.log" "Dashboard web: http://127.0.0.1:" "URL impressa no topo"

    if [ -f "$d2/repo/.phases/ui/index.html" ]; then
      ok "index.html escrito"
    else
      bad "index.html escrito"
    fi
    # Auto-contido: uma referencia externa quebra a pagina em maquina sem rede.
    assert_not_contains "$d2/repo/.phases/ui/index.html" "https://" "html sem referencia externa"

    port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$d2/out.log" | head -1 | cut -d: -f2)
    if [ -n "$port" ] && ! (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null; then
      ok "servidor morto no fim do run (porta $port livre)"
    else
      bad "servidor morto no fim do run (porta ${port:-?} ainda ocupada)"
    fi
  else
    echo "  (python3 ausente: casos de servidor ativo pulados)"
  fi
fi

# ---------------------------------------------------------------------------
# 38. Com TTY o painel desenha, e desmonta antes do relatorio final.
#     `script` da um pty de verdade — sem isso o caminho do painel nunca roda
#     em teste, porque a suite escreve em arquivo.
# ---------------------------------------------------------------------------
if case_enabled ui-tty; then
  header "38. com TTY o painel desenha e desmonta"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso do painel pulado)"
  else
    d=$(new_case ui-tty)
    rc=0
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 \
        script -qec "bash '$RALPH' --engine codex --test-cmd '$d/test.sh'" /dev/null
    ) > "$d/out.log" 2>&1 || rc=$?

    assert_eq 0 "$rc" "exit 0"
    assert_contains "$d/out.log" "RALPH" "cabecalho do painel desenhado"
    assert_contains "$d/out.log" "FASES E TASKS" "tabela de fases e tasks desenhada"
    assert_contains "$d/out.log" "PROGRESSO" "painel de progresso desenhado"
    # Buffer alternado: sem o par 1049h/1049l o scrollback do dev e destruido.
    assert_contains "$d/out.log" $'\033[?1049h' "entrou no buffer alternado"
    assert_contains "$d/out.log" $'\033[?1049l' "saiu do buffer alternado"
    assert_contains "$d/out.log" $'\033[?25l' "cursor escondido durante o painel"
    # Cursor nao restaurado deixa o terminal do dev inutilizavel depois do run.
    assert_contains "$d/out.log" $'\033[?25h' "cursor restaurado no fim"
    assert_contains "$d/out.log" "AO VIVO" "secao de atividade ao vivo desenhada"
    # Prova de vida medida pelo pintor: sem isso a tela fica estatica durante a
    # sessao do engine, que e justamente a etapa mais longa do run.
    assert_contains "$d/out.log" "Ações do engine:" "contador de acoes do engine no painel"
    assert_contains "$d/out.log" "Etapa:" "etapa corrente com tempo proprio"
    assert_contains "$d/out.log" "RELATORIO FINAL" "relatorio final impresso apos desmontar"
    # O painel viveu numa tela descartada: sem reimprimir, o placar do run some.
    assert_contains "$d/out.log" "Commit criado: feat(phase-1)" "placar reimpresso na tela normal"
    assert_contains "$d/repo/.phases/ui/messages.log" "Gate 3" \
      "placar desviado para o messages.log"
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
        "$d/repo/.phases/state.json" 2> /dev/null; then
      ok "state.json valido tambem no modo painel"
    else
      bad "state.json valido tambem no modo painel"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 39. Painel AO VIVO durante a sessao do engine.
#     O mock dos outros casos responde instantaneamente, entao nenhum frame cai
#     no meio da implementacao. Aqui o engine demora de proposito: e a unica
#     forma de provar que o painel nao congela na etapa mais longa do run.
# ---------------------------------------------------------------------------
if case_enabled ui-live; then
  header "39. painel ao vivo durante a sessao do engine"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso do painel ao vivo pulado)"
  else
    d=$(new_case ui-live)

    # Engine lento que escreve progresso no stderr aos poucos e cria arquivos:
    # alimenta as tres fontes que a secao AO VIVO mede (bytes, tail, arvore).
    cat > "$d/bin/codex" <<'SLOWMOCK'
#!/usr/bin/env bash
set -uo pipefail
prompt=$(cat)
verify=0
grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1
for i in 1 2 3 4 5 6; do
  echo "[mock] lendo app/Services/Arquivo$i.php" >&2
  sleep 0.4
done
if [ "$verify" -eq 1 ]; then
  n=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")
  for i in $(seq 1 "$n"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  exit 0
fi
mkdir -p src app/Services
echo impl > app/Services/Novo.php
echo impl > "src/impl-1.txt"
echo "Done."
SLOWMOCK
    chmod +x "$d/bin/codex"

    rc=0
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 RALPH_UI_FPS=2 \
        script -qec "stty rows 40 cols 130; bash '$RALPH' --engine codex --test-cmd '$d/test.sh'" /dev/null
    ) > "$d/out.log" 2>&1 || rc=$?

    assert_eq 0 "$rc" "exit 0"
    # A etapa muda durante a fase: sem state_sync a cada troca, o painel
    # congelava em "preparando" pelo run inteiro — foi o bug reportado.
    assert_contains "$d/out.log" "implementando a fase" \
      "atividade republicada durante a sessao do engine"
    assert_contains "$d/out.log" "verificacao independente" \
      "atividade muda de novo no gate 3"
    assert_not_contains "$d/repo/.phases/ui/state.env" "activity=preparando" \
      "estado final nao ficou preso em 'preparando'"
    # Tail do stderr lido pelo PINTOR, nao publicado pelo processo principal:
    # durante run_split o principal esta bloqueado e nao republica nada.
    assert_contains "$d/out.log" "[mock] lendo app/Services/Arquivo" \
      "tail do stderr do engine aparece no painel"
    assert_contains "$d/out.log" "arquivo(s) tocado(s)" "contagem da arvore no painel"
    assert_contains "$d/out.log" "Etapa:" "etapa com tempo proprio"
  fi
fi

# ---------------------------------------------------------------------------
# 40. Inferencia de task: qual task esta sendo trabalhada e quanto dela apareceu.
#     Precisa de um documento cujas tasks NOMEIEM identificadores de codigo — e
#     o unico elo entre o texto da task e a arvore. Task sem ancora nao gera
#     palpite nenhum, e isso tambem e verificado.
# ---------------------------------------------------------------------------
if case_enabled ui-task-infer; then
  header "40. inferencia de task pela arvore de trabalho"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso de inferencia pulado)"
  else
    d=$(new_case ui-task-infer)

    cat > "$d/repo/.spec/init/project-phases.md" <<'PHASES'
# Fases

## Phase 1: Import de templates

- [ ] **Task:** Job assincrono de import, `ImportWhatsappTemplatesJob`
  - **Acceptance criteria:**
    - o job existe
- [ ] **Task:** Migration aditiva em `meta_official_template_origins`
  - **Acceptance criteria:**
    - a migration existe
- [ ] **Task:** Passo sem identificador nenhum no texto
  - **Acceptance criteria:**
    - nada a casar
PHASES
    (cd "$d/repo" && git add -A && git commit -q -m "fixture ancoras")

    # Cria os artefatos das duas primeiras tasks, em ordem e com pausa: a task
    # ativa e decidida pelo arquivo de mtime mais recente.
    cat > "$d/bin/codex" <<'ANCHORMOCK'
#!/usr/bin/env bash
set -uo pipefail
prompt=$(cat)
verify=0
grep -q '^RALPH_VERIFY' <<< "$prompt" && verify=1
if [ "$verify" -eq 1 ]; then
  n=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")
  for i in $(seq 1 "$n"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  exit 0
fi
mkdir -p app/Jobs database/migrations
sleep 1; echo x > app/Jobs/ImportWhatsappTemplatesJob.php
sleep 2; echo x > database/migrations/2026_01_01_add_meta_official_template_origins.php
sleep 2; echo "Done."
ANCHORMOCK
    chmod +x "$d/bin/codex"

    rc=0
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 RALPH_UI_FPS=2 \
        script -qec "stty rows 42 cols 132; bash '$RALPH' --engine codex --test-cmd '$d/test.sh'" /dev/null
    ) > "$d/out.log" 2>&1 || rc=$?

    assert_eq 0 "$rc" "exit 0"

    tp="$d/repo/.phases/ui/taskprog.txt"
    if [ -f "$tp" ]; then ok "taskprog.txt gerado"; else bad "taskprog.txt gerado"; fi
    assert_contains "$tp" "1|100|" "task 1 casou a ancora ImportWhatsappTemplatesJob"
    assert_contains "$tp" "2|100|" "task 2 casou a ancora meta_official_template_origins"
    # Task sem identificador no texto nao produz ancora: 0%, nunca um palpite
    # inventado a partir de arquivo alheio.
    assert_not_contains "$tp" "3|" "task sem ancora nao entra no palpite"

    # O `~` e o contrato visual: distingue palpite de veredito do gate 3.
    assert_contains "$d/out.log" "~100%" "percentual inferido marcado com ~"
    assert_contains "$d/out.log" "Task ativa" "task ativa nomeada no painel"
    # Fechada a fase, o veredito do gate 3 substitui a inferencia.
    assert_contains "$d/out.log" "Concluída" "gate 3 sobrepoe o palpite no fim"
  fi
fi

# ---------------------------------------------------------------------------
# 41. Checkbox marcado pelo engine aparece como Declarada DURANTE a sessao.
#     Era a janela cega: os gates so falam no fim da fase, entao a tabela
#     ficava Pendente do inicio ao fim enquanto o run trabalhava.
# ---------------------------------------------------------------------------
if case_enabled ui-task-declared; then
  header "41. checkbox do engine vira 'Declarada' durante a sessao"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso pulado)"
  else
    d=$(new_case ui-task-declared)

    # Marca a primeira task de cada fase e SEGUE trabalhando: o painel tem que
    # mostrar o progresso antes do gate 3 existir.
    cat > "$d/bin/codex" <<'DECLMOCK'
#!/usr/bin/env bash
set -uo pipefail
prompt=$(cat)
if grep -q '^RALPH_VERIFY' <<< "$prompt"; then
  n=$(grep -cE '^[[:space:]]*- \[[ xX]\]' <<< "$prompt")
  for i in $(seq 1 "$n"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  exit 0
fi
mkdir -p src
echo a > src/a.txt
for f in .phases/phase-*.md; do
  awk 'BEGIN { hit = 0 }
       { if (!hit && $0 ~ /^[[:space:]]*- \[ \]/) { sub(/\[ \]/, "[x]"); hit = 1 } print }' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
sleep 5
echo b > src/b.txt
echo "Done."
DECLMOCK
    chmod +x "$d/bin/codex"

    rc=0
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 RALPH_UI_FPS=2 \
        script -qec "stty rows 42 cols 132; bash '$RALPH' --engine codex --test-cmd '$d/test.sh'" /dev/null
    ) > "$d/out.log" 2>&1 || rc=$?

    assert_eq 0 "$rc" "exit 0"
    assert_contains "$d/out.log" "Declarada" "task marcada pelo engine aparece na tabela durante a sessao"
    assert_contains "$d/out.log" "Concluída" "no fim o veredito do gate 3 assume"
    # Marcar checkbox mexe so em .phases/ (que esta em .git/info/exclude): nao
    # pode virar prova de que a sessao escreveu codigo.
    assert_not_contains "$d/repo/.phases/phase-01.md" "- [ ] **Task:** cria o arquivo A" \
      "o engine realmente marcou o checkbox no arquivo da fase"
  fi
fi

# ---------------------------------------------------------------------------
# 42. Checkbox NAO e veredito: task marcada e reprovada pelo gate 3 aparece
#     Incompleta, nunca verde.
# ---------------------------------------------------------------------------
if case_enabled ui-declared-not-verdict; then
  header "42. veredito do gate 3 sobrescreve o checkbox"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso pulado)"
  else
    d=$(new_case ui-declared-not-verdict)

    cat > "$d/bin/codex" <<'LIARMOCK'
#!/usr/bin/env bash
set -uo pipefail
state="${MOCK_STATE:?}"
prompt=$(cat)
if grep -q '^RALPH_VERIFY' <<< "$prompt"; then
  f="$state/verify_n"; n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1)); echo "$n" > "$f"
  total=$(grep -cE '^[[:space:]]*- \[[ xX]\]' <<< "$prompt")
  if [ "$n" -eq 1 ]; then
    echo "TASK 1: INCOMPLETE — o arquivo A nao existe"
    for i in $(seq 2 "$total"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
    exit 0
  fi
  for i in $(seq 1 "$total"); do echo "TASK $i: DONE — src/impl-$i.txt:1"; done
  exit 0
fi
mkdir -p src
echo a > "src/impl-$RANDOM.txt"
for f in .phases/phase-*.md; do
  sed -i 's/- \[ \]/- [x]/g' "$f"
done
sleep 4
echo "Done."
LIARMOCK
    chmod +x "$d/bin/codex"

    rc=0
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 RALPH_UI_FPS=2 \
        script -qec "stty rows 42 cols 132; bash '$RALPH' --engine codex --test-cmd '$d/test.sh' --max-cycles 2" /dev/null
    ) > "$d/out.log" 2>&1 || rc=$?

    assert_eq 0 "$rc" "exit 0"
    assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reprovou a fase mesmo com tudo marcado"
    assert_contains "$d/out.log" "Incompleta" "task marcada e reprovada aparece Incompleta"
  fi
fi

# ---------------------------------------------------------------------------
# 43. --attach: acompanha um run existente sem escrever nada dele.
#     Tambem cobre a regressao do awk de duas passadas — fase sem ancora
#     nenhuma nao pode produzir taskprog com o universo de caminhos dentro.
# ---------------------------------------------------------------------------
if case_enabled attach-readonly; then
  header "43. --attach republica sem tocar no run"
  d=$(new_case attach-readonly)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "run base terminou verde"

  ui="$d/repo/.phases/ui"
  before_state=$(sha256sum "$ui/state.env" | cut -d' ' -f1)
  before_msgs=$(sha256sum "$ui/messages.log" | cut -d' ' -f1)
  before_commits=$(commits "$d")

  arc=0
  (
    cd "$d/repo" || exit 1
    PATH="$d/bin:$PATH" MOCK_STATE="$d/state" MOCK_SCENARIO=ok \
      bash "$RALPH" --attach --no-ui > "$d/attach.log" 2>&1
  ) || arc=$?

  assert_eq 0 "$arc" "attach sai 0 quando o run ja terminou"
  assert_contains "$d/attach.log" "attach: run" "attach identificou o run"
  assert_eq "$before_state" "$(sha256sum "$ui/state.env" | cut -d' ' -f1)" "attach nao reescreveu state.env"
  assert_eq "$before_msgs" "$(sha256sum "$ui/messages.log" | cut -d' ' -f1)" "attach nao truncou messages.log"
  assert_eq "$before_commits" "$(commits "$d")" "attach nao criou commit"

  # Arquivo proprio: o pintor do run original continua dono do taskprog.txt.
  test -f "$ui/taskprog.attach.txt" && ok "attach usa taskprog proprio" \
    || bad "attach usa taskprog proprio"
  # As tasks do fixture nao nomeiam artefato nenhum. Com o awk quebrado o
  # universo de caminhos vazava para dentro do taskprog (60 KB de `caminho|0|0`
  # num run real) e a tabela ficava Pendente para sempre.
  assert_eq 0 "$(grep -c . "$ui/taskprog.attach.txt" || true)" \
    "fase sem ancora gera taskprog VAZIO (regressao do awk de duas passadas)"
  assert_not_contains "$ui/taskprog.attach.txt" ".spec/init" "nenhum caminho do repo vazou para o taskprog"
fi

# ---------------------------------------------------------------------------
# 44. --attach sem run neste diretorio: erro claro, exit 1, nada criado.
# ---------------------------------------------------------------------------
if case_enabled attach-no-run; then
  header "44. --attach sem run existente"
  d=$(new_case attach-no-run)
  arc=0
  (
    cd "$d/repo" || exit 1
    bash "$RALPH" --attach --no-ui > "$d/attach.log" 2>&1
  ) || arc=$?
  assert_eq 1 "$arc" "exit 1 sem run para acompanhar"
  assert_contains "$d/attach.log" "nao ha run neste diretorio" "mensagem aponta a causa"
  test -d "$d/repo/.phases" && bad "attach nao pode criar .phases" || ok "attach nao criou .phases"
fi

# ---------------------------------------------------------------------------
# 45. Navegacao por teclado na tabela do painel.
#
# Precisa de TTY: sem ele o painel nem ativa (ui_should_activate) e nada disso
# existe. `script` da o pty; sem `script` no PATH o caso e pulado, nunca falha.
#
# Fixture de --attach, e nao run completo: o painel so precisa de manifest,
# fases e state.env: assim o caso mede a rolagem, e nao o mock do engine.
# ---------------------------------------------------------------------------
if case_enabled ui-keys; then
  header "45. navegacao por teclado na tabela do painel"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (pulado: 'script' nao esta no PATH, sem pty para simular o terminal)"
  else
    d=$(new_case ui-keys)
    mkdir -p "$d/repo/.phases/ui"
    # 8 fases x 3 tasks = 32 linhas, muito acima do orcamento de um terminal de
    # 30 linhas: sem isso nao ha o que rolar e o caso passaria por vacuidade.
    for n in 1 2 3 4 5 6 7 8; do
      printf 'phase-0%s.md|%s|Fase numero %s\n' "$n" "$n" "$n" >> "$d/repo/.phases/manifest.txt"
      {
        echo "## Fase $n"
        echo "- [ ] T1 — task um da fase $n"
        echo "- [ ] T2 — task dois da fase $n"
        echo "- [ ] T3 — task tres da fase $n"
      } > "$d/repo/.phases/phase-0$n.md"
      st=pending; [ "$n" -lt 5 ] && st=done; [ "$n" = 5 ] && st=running
      printf '%s|%s|Fase numero %s\n' "$n" "$st" "$n" >> "$d/repo/.phases/ui/phases.txt"
    done
    # PID vivo: o attach encerra sozinho quando o processo do run some, e sao
    # varias sessoes de pty em sequencia — a ancora tem que durar todas elas.
    sleep 600 & keeper=$!
    cat > "$d/repo/.phases/ui/state.env" <<UISTATE
run_status=running
phase_num=5
phase_seq=5
phase_total=8
phase_title=Fase numero 5
phase_status=running
cycle=1
gate0=pending
gate1=pending
gate2=pending
gate3=pending
activity=teste
stage_start=$(date +%s)
limit_waiting=0
stderr_log=
stdout_log=
pid=$keeper
run_id=uikeys
started=$(date +%s)
engine=claude
project=uikeys
UISTATE

    # ui_keys_run <arquivo-de-saida> <teclas> [env...]
    ui_keys_run() {
      local out="$1" keys="$2"; shift 2
      ( sleep 2; printf '%b' "$keys"; sleep 2 ) \
        | timeout 15 script -qec \
          "cd '$d/repo' && stty rows 30 cols 150 && $* RALPH_ATTACH_INTERVAL=1 RALPH_UI=panel bash '$RALPH' --attach" \
          /dev/null > "$out" 2>&1 || true
    }
    # A janela desenhada em cada frame, sem os escapes de cor.
    ui_keys_windows() {
      sed -r 's/\x1B\[[0-9;?]*[A-Za-z]//g' "$1" \
        | grep -oE 'mostrando [0-9]+[-–][0-9]+' | sed 's/–/-/' | uniq | tr '\n' ' ' | sed 's/ *$//'
    }

    ui_keys_run "$d/down.raw" '\033[B\033[B\033[B'
    assert_eq "mostrando 14-19 mostrando 15-20 mostrando 16-21 mostrando 17-22" \
      "$(ui_keys_windows "$d/down.raw")" \
      "cada seta para baixo anda UMA linha (rajada de CSI nao pode virar uma tecla so)"

    ui_keys_run "$d/end.raw" 'G'
    assert_eq "mostrando 14-19 mostrando 27-32" "$(ui_keys_windows "$d/end.raw")" \
      "G vai para o fim e para na ultima linha (sem linha vazia no rodape)"

    # `uniq` colapsa frames iguais: subir no topo NAO pode gerar janela nova.
    ui_keys_run "$d/top.raw" 'gk'
    assert_eq "mostrando 14-19 mostrando 1-6" "$(ui_keys_windows "$d/top.raw")" \
      "g vai para o topo e subir dali nao move a janela"

    ui_keys_run "$d/auto.raw" 'Ga'
    assert_eq "mostrando 14-19 mostrando 27-32 mostrando 14-19" "$(ui_keys_windows "$d/auto.raw")" \
      "'a' devolve a janela ao modo automatico, centrada na fase corrente"

    assert_contains "$d/end.raw" "manual" "rodape avisa que a janela esta no modo manual"

    ui_keys_run "$d/off.raw" 'jjjG' RALPH_UI_KEYS=0
    assert_eq "mostrando 14-19" "$(ui_keys_windows "$d/off.raw")" \
      "RALPH_UI_KEYS=0 desliga a rolagem"
    assert_not_contains "$d/off.raw" "↑↓ rolar" "sem teclado o rodape nao promete navegacao"

    # O painel desliga o eco para ler tecla; sair tem que devolver o terminal.
    ( sleep 2; printf 'jj'; sleep 1; printf '\003'; sleep 3 ) \
      | timeout 15 script -qec \
        "cd '$d/repo' && stty rows 30 cols 150 && RALPH_ATTACH_INTERVAL=1 RALPH_UI=panel bash '$RALPH' --attach; stty -a | tr ' ,' '\n\n' | grep -cx echo > '$d/echo.txt'" \
        /dev/null > "$d/int.raw" 2>&1 || true
    assert_eq "1" "$(cat "$d/echo.txt" 2> /dev/null || echo 0)" \
      "Ctrl-C durante o painel devolve o eco do terminal"

    kill "$keeper" 2> /dev/null || true
    wait "$keeper" 2> /dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# 46. O pintor morre no ui_stop: nenhum frame depois do fim do run.
#     Regressao real: ui_painter_loop abria um `( )` DENTRO da funcao, que ja
#     rodava com `&`. Dois forks: `$!` guardava o wrapper, nao o laco. ui_stop
#     matava o wrapper, o laco virava orfao e seguia repintando por cima da
#     tela normal ja restaurada — o run terminava, o relatorio final era
#     apagado a cada frame e o painel ficava congelado na tela do dev.
#
#     O `sleep` depois do ralph e o microscopio: da ao orfao (se existir) tempo
#     de pintar mais frames no MESMO pty, com o run ja encerrado.
# ---------------------------------------------------------------------------
if case_enabled ui-painter-exit; then
  header "46. pintor morre no ui_stop (nenhum frame depois do run)"
  if ! command -v script > /dev/null 2>&1; then
    echo "  (util-linux 'script' ausente: caso do pintor orfao pulado)"
  else
    d=$(new_case ui-painter-exit)
    painter_probe="ralph.sh --engine codex --test-cmd $d/test.sh"
    (
      cd "$d/repo" || exit 1
      PATH="$d/bin:$PATH" \
      MOCK_STATE="$d/state" MOCK_SCENARIO=ok MOCK_TEST_CMD="$d/test.sh" \
      RALPH_HEARTBEAT=0 \
        timeout 120 script -qec \
          "bash '$RALPH' --engine codex --test-cmd '$d/test.sh'; echo RALPH_SAIU; sleep 2" \
          /dev/null
    ) > "$d/out.log" 2>&1 || true

    assert_contains "$d/out.log" "RALPH_SAIU" "o run terminou dentro do pty"
    assert_contains "$d/out.log" "FASES E TASKS" "o painel chegou a desenhar"

    # Tudo que saiu DEPOIS do marcador. Com pintor orfao, mais frames caem aqui.
    sed -n '/RALPH_SAIU/,$p' "$d/out.log" > "$d/depois.log"
    assert_not_contains "$d/depois.log" "FASES E TASKS" \
      "nenhuma tabela repintada depois do fim do run"
    assert_not_contains "$d/depois.log" "PROGRESSO" \
      "nenhuma barra de progresso repintada depois do fim do run"

    # Varredura de seguranca, nao assert: sob `script` o pty morre junto com o
    # run e leva o orfao a tiracolo, entao a checagem de processo nunca ficaria
    # vermelha aqui — no terminal do dev, que segue aberto, o orfao vive para
    # sempre. Se sobrou algo desta suite, mata antes de seguir.
    pkill -f "$painter_probe" 2> /dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# 47. Gate 2 vermelho com falha localizavel -> conserto cirurgico -> verde,
#     sem gastar ciclo de correcao. O caminho que a mudanca existe para criar.
# ---------------------------------------------------------------------------
if case_enabled repair-gate2; then
  header "47. gate 2 vermelho localizavel -> conserto cirurgico, sem ciclo"
  d=$(new_case repair-gate2)
  rc=$(run_ralph "$d" test-red-repairable --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --full-suite)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase"
  assert_contains "$d/out.log" "Gate 2 vermelho" "gate 2 reportado vermelho"
  assert_contains "$d/out.log" "Conserto cirurgico 1/2 sobre o gate2" "conserto acionado pelo gate 2"
  assert_not_contains "$d/out.log" "Ciclo de correcao" "nenhum ciclo de correcao gasto"
  assert_eq 1 "$(cat "$d/state/repair_calls")" "um unico conserto"
  # uma sessao de implementacao por fase, nenhuma a mais
  assert_eq 2 "$(cat "$d/state/impl_calls")" "nenhuma sessao de implementacao extra"

  # A assinatura da falha chega ao prompt; a fase e o preambulo nao.
  assert_contains "$d/state/repair_prompt_1.txt" "tests/Feature/SomaTest.php:22" "conserto recebe o arquivo:linha da falha"
  assert_contains "$d/state/repair_prompt_1.txt" "Failed asserting that 3 matches expected 4." "conserto recebe a mensagem da assertion"
  assert_not_contains "$d/state/repair_prompt_1.txt" "Descubra a stack" "conserto nao carrega o preambulo de contexto"
  assert_not_contains "$d/state/repair_prompt_1.txt" "Acceptance criteria" "conserto nao carrega a fase inteira"
  # logs por round, nunca sobrescritos
  test -f "$d/repo/.phases/logs/phase-01.repair-1-1.log" && ok "log do conserto por round" || bad "log do conserto por round"
  test -f "$d/repo/.phases/logs/phase-01.test-1r1.log" && ok "revalidacao da suite tem log proprio" || bad "revalidacao da suite tem log proprio"
fi

# ---------------------------------------------------------------------------
# 48. --no-repair devolve o gate 2 vermelho ao ciclo de correcao.
# ---------------------------------------------------------------------------
if case_enabled repair-off; then
  header "48. --no-repair devolve o gate 2 ao ciclo de correcao"
  d=$(new_case repair-off)
  rc=$(run_ralph "$d" test-red-repairable --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --no-repair)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "entrou em ciclo de correcao"
  test -f "$d/state/repair_calls" && bad "nenhuma sessao de conserto gasta" || ok "nenhuma sessao de conserto gasta"

  # --max-repairs 0 e o mesmo desligamento por outra porta
  d2=$(new_case repair-zero)
  rc=$(run_ralph "$d2" test-red-repairable --engine claude --test-cmd "$d2/test.sh" --max-cycles 2 --max-repairs 0)
  assert_eq 0 "$rc" "exit 0 com --max-repairs 0"
  test -f "$d2/state/repair_calls" && bad "--max-repairs 0 nao gasta conserto" || ok "--max-repairs 0 nao gasta conserto"
fi

# ---------------------------------------------------------------------------
# 49. REPAIR_ABORT: o modelo desiste. Escalar na hora e mais barato que gastar
#     o round seguinte depois de um "nao sei".
# ---------------------------------------------------------------------------
if case_enabled repair-abort; then
  header "49. REPAIR_ABORT escala na hora, sem gastar o round seguinte"
  d=$(new_case repair-abort)
  rc=$(run_ralph "$d" repair-abort --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2)
  assert_eq 1 "$rc" "exit 1 (a fase nao foi resolvida)"
  assert_contains "$d/out.log" "Conserto abortado pelo modelo" "a desistencia foi reportada"
  assert_eq 1 "$(cat "$d/state/repair_calls")" "so um round gasto, mesmo com orcamento de 2"
fi

# ---------------------------------------------------------------------------
# 50. Conserto que termina bem mas nao escreve nada tambem escala: sem diff
#     nao houve conserto, e o proximo round repetiria o mesmo nada.
# ---------------------------------------------------------------------------
if case_enabled repair-nochange; then
  header "50. conserto sem diff escala em vez de repetir"
  d=$(new_case repair-nochange)
  rc=$(run_ralph "$d" repair-nochange --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Conserto nao alterou nenhum arquivo" "sem diff, sem conserto"
  assert_eq 1 "$(cat "$d/state/repair_calls")" "so um round gasto"
fi

# ---------------------------------------------------------------------------
# 51. Orcamento de consertos esgotado -> o ciclo de correcao assume. O conserto
#     e tentativa EXTRA: nao pode consumir nem substituir os ciclos.
# ---------------------------------------------------------------------------
if case_enabled repair-exhausted; then
  header "51. consertos esgotados -> ciclo de correcao assume"
  d=$(new_case repair-exhausted)
  rc=$(run_ralph "$d" verify-incomplete-always --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --max-repairs 2)
  assert_eq 1 "$rc" "exit 1 (task 1 nunca fica pronta)"
  assert_contains "$d/out.log" "Consertos cirurgicos esgotados" "o esgotamento foi reportado"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "os ciclos continuaram disponiveis"
  # 2 rounds por ciclo x 2 ciclos: o orcamento e POR ciclo, nao por fase
  assert_eq 4 "$(cat "$d/state/repair_calls")" "orcamento de conserto renova a cada ciclo"
fi

# ---------------------------------------------------------------------------
# 52. Gate 3 vermelho por PROTOCOLO do verificador nao e reparavel: nao ha
#     codigo faltando para apontar, e um patch as cegas so gastaria sessao.
# ---------------------------------------------------------------------------
if case_enabled repair-not-applicable; then
  header "52. gate 3 quebrado por protocolo nao aciona conserto"
  d=$(new_case repair-not-applicable)
  rc=$(run_ralph "$d" verify-dup-hides-gap --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Conserto cirurgico nao se aplica" "o ralph explicou por que nao reparou"
  assert_contains "$d/out.log" "protocolo do verificador" "a razao e o protocolo, nao codigo faltando"
  test -f "$d/state/repair_calls" && bad "nenhuma sessao de conserto gasta" || ok "nenhuma sessao de conserto gasta"
fi

# ---------------------------------------------------------------------------
# 53. O conserto usa modelo proprio (barato), como o verificador.
# ---------------------------------------------------------------------------
if case_enabled repair-model; then
  header "53. conserto usa RALPH_REPAIR_MODEL"
  d=$(new_case repair-model)
  rc=$(CASE_REPAIR_MODEL=haiku run_ralph "$d" test-red-repairable --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "haiku" "$(cat "$d/state/repair_model")" "modelo do conserto repassado ao engine"
  assert_contains "$d/out.log" "sobre o gate2 (modelo: haiku)" "modelo do conserto logado"
fi

# ---------------------------------------------------------------------------
# 54. Ponto fixo do gate 2: sessao que nao escreve nada + o MESMO vermelho sobre
#     a MESMA arvore. O proximo ciclo receberia prompt identico e chegaria ao
#     mesmo lugar — o orcamento restante e desperdicio garantido.
#     Regressao do run real que queimou 5 ciclos (1h) sobre um vermelho que
#     nenhuma linha escrita pela fase podia consertar.
# ---------------------------------------------------------------------------
if case_enabled stall-red-forever; then
  header "54. ciclo improdutivo sobre gate 2 vermelho aborta a fase"
  d=$(new_case stall-red-forever)
  rc=$(run_ralph "$d" stall-red-forever --engine claude --test-cmd "$d/test.sh" --max-cycles 5 --full-suite)
  assert_eq 1 "$rc" "exit 1 (a fase nao foi resolvida)"
  assert_contains "$d/out.log" "Abortando a fase sem gastar os ciclos restantes" "o abort foi reportado"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "so 2 sessoes gastas, com orcamento de 5"
  assert_eq 2 "$(cat "$d/state/test_calls")" "so 2 suites rodadas, com orcamento de 5"
  assert_not_contains "$d/out.log" "Ciclo de correcao 3/5" "nenhum ciclo alem do que provou o ponto fixo"
fi

# ---------------------------------------------------------------------------
# 55. REPAIR_ABORT nao e "nao consegui", e "isto nao se conserta escrevendo
#     codigo". Entregar o mesmo problema ao ciclo de correcao so paga um modelo
#     maior para chegar a mesma conclusao.
# ---------------------------------------------------------------------------
if case_enabled repair-abort-cycles; then
  header "55. REPAIR_ABORT encerra a fase, nao so o round"
  d=$(new_case repair-abort-cycles)
  rc=$(run_ralph "$d" repair-abort --engine claude --test-cmd "$d/test.sh" --max-cycles 3 --max-repairs 2)
  assert_eq 1 "$rc" "exit 1 (a fase nao foi resolvida)"
  assert_contains "$d/out.log" "Conserto abortado pelo modelo" "a desistencia foi reportada"
  assert_contains "$d/out.log" "Abortando a fase sem gastar os ciclos restantes" "a fase parou na desistencia"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "nenhum ciclo de correcao gasto depois do REPAIR_ABORT"
  assert_not_contains "$d/out.log" "Ciclo de correcao 2/3" "o ciclo seguinte nao foi gasto"
fi

# ---------------------------------------------------------------------------
# 56. --baseline: o vermelho que ja existia em HEAD e alheio a fase. Sem isso
#     ele prende o loop ate esgotar os ciclos. Com ele, o gate 2 cobra o DELTA.
# ---------------------------------------------------------------------------
if case_enabled baseline-inherited; then
  header "56. --baseline: falha pre-existente nao reprova a fase"
  d=$(new_case baseline-inherited)
  rc=$(run_ralph "$d" baseline-inherited --engine claude --test-cmd "$d/test.sh" --baseline --max-cycles 2)
  assert_eq 0 "$rc" "exit 0 (a falha herdada nao e da fase)"
  assert_contains "$d/out.log" "HerdadoTest" "o baseline nomeou o teste ja vermelho"
  assert_contains "$d/out.log" "Gate 2 — sem regressao" "o gate 2 cobrou so o delta"
  assert_eq 3 "$(commits "$d")" "1 commit por fase, apesar da suite vermelha"

  # Sem a flag E sem saneamento, o mesmo cenario reprova: o default nao perdoa.
  d2=$(new_case baseline-off)
  rc=$(run_ralph "$d2" baseline-inherited --engine claude --test-cmd "$d2/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 sem --baseline (default nao perdoa vermelho)"
  assert_contains "$d2/out.log" "Gate 2 vermelho" "sem a flag o gate 2 reprova"

  # --baseline tem precedencia sobre o saneamento: quem declara "herde o
  # vermelho" esta dizendo que ele e intencional, e sanear consertaria justamente
  # o teste que a fase existe para fechar.
  d3=$(new_case baseline-precedencia)
  rc=$(CASE_HEAL_HEAD=on run_ralph "$d3" baseline-inherited --engine claude \
    --test-cmd "$d3/test.sh" --baseline --max-cycles 2)
  assert_eq 0 "$rc" "exit 0 (herdou o vermelho, como pedido)"
  test -f "$d3/state/heal_calls" && bad "--baseline nao dispara saneamento" || ok "--baseline nao dispara saneamento"
fi

# ---------------------------------------------------------------------------
# 57. O baseline perdoa o herdado, nunca a regressao. Um teste NOVO vermelho
#     tem que reprovar mesmo com a flag ligada.
# ---------------------------------------------------------------------------
if case_enabled baseline-regression; then
  header "57. --baseline nao esconde regressao nova"
  d=$(new_case baseline-regression)
  rc=$(run_ralph "$d" baseline-regression --engine claude --test-cmd "$d/test.sh" --baseline --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (regressao nova reprova)"
  assert_contains "$d/out.log" "Gate 2 vermelho" "gate 2 reprovou"
  assert_contains "$d/out.log" "Falhas NOVAS em relacao a HEAD" "a causa separa o delta do herdado"
  assert_contains "$d/out.log" "NovoTest" "a causa nomeia a falha NOVA"
fi

# ---------------------------------------------------------------------------
# 58. Ctrl-C encerra o run. Com `trap cleanup_ui INT` (sem exit) o handler
#     limpava a UI e o loop SEGUIA: cada sinal matava o engine, o log saia
#     vazio, o gate 0 dava vermelho e o ciclo era consumido em menos de um
#     segundo. Regressao do run real em que 4 Ctrl-C torraram o orcamento.
# ---------------------------------------------------------------------------
if case_enabled interrupt; then
  header "58. SIGINT encerra o run em vez de queimar os ciclos"
  d=$(new_case interrupt)
  # `exec`: sem ele o sinal pararia no subshell e nunca chegaria ao ralph.
  (
    cd "$d/repo" || exit 1
    PATH="$d/bin:$PATH" \
    MOCK_STATE="$d/state" \
    MOCK_SCENARIO="slow-engine" \
    RALPH_HEARTBEAT=0 \
      exec bash "$RALPH" --engine claude --test-cmd "$d/test.sh" --max-cycles 5
  ) > "$d/out.log" 2>&1 &
  rpid=$!
  sleep 2
  kill -INT "$rpid" 2> /dev/null || true
  rc=0
  wait "$rpid" || rc=$?
  assert_eq 130 "$rc" "exit 130 (encerrado por sinal)"
  assert_contains "$d/out.log" "Interrompido pelo operador" "o encerramento foi reportado"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "nenhum ciclo gasto depois do sinal"
  assert_eq 1 "$(commits "$d")" "nada commitado a meio caminho (so o commit da fixture)"
fi

# ---------------------------------------------------------------------------
# 59. Servico externo fora do ar que VOLTA: o gate 2 reconhece o ambiente,
#     reexecuta a suite uma vez e o run segue normal. Sem isso, a fase morria
#     por um vermelho que nao era dela.
# ---------------------------------------------------------------------------
if case_enabled infra-recovered; then
  header "59. ambiente cai e volta: gate 2 reexecuta a suite uma vez"
  d=$(new_case infra-recovered)
  rc=$(run_ralph "$d" infra-recovered --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0 (o ambiente voltou; a fase nao tem culpa)"
  assert_contains "$d/out.log" "caiu por AMBIENTE" "o gate 2 classificou como ambiente"
  assert_contains "$d/out.log" "ralph-fixture-db-1" "a causa nomeia o servico fora do ar"
  assert_contains "$d/out.log" "reexecutando a suite uma vez" "houve exatamente uma reexecucao"
  assert_contains "$d/out.log" "ambiente recuperado" "a reexecucao fechou verde"
  assert_eq 3 "$(commits "$d")" "1 commit por fase (1 fixture + 2)"
  assert_eq 0 "$(cat "$d/state/repair_calls" 2> /dev/null || echo 0)" "nenhum conserto cirurgico gasto com ambiente"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "nenhum ciclo de correcao gasto (1 sessao por fase)"
fi

# ---------------------------------------------------------------------------
# 60. Servico que NAO volta: veredito de ambiente, nao de fase. O run inteiro
#     encerra com exit 3, o trabalho ja escrito vira commit wip e nenhum ciclo
#     ou conserto e gasto. Regressao do run real em que o MySQL de um projeto
#     vizinho caiu no meio da fase e o ralph descartou 6 arquivos corretos.
# ---------------------------------------------------------------------------
if case_enabled infra-abort; then
  header "60. ambiente fora do ar encerra o run e preserva o trabalho"
  d=$(new_case infra-abort)
  rc=$(run_ralph "$d" infra-forever --engine claude --test-cmd "$d/test.sh" --max-cycles 5 --keep-going --full-suite)
  assert_eq 3 "$rc" "exit 3 (ambiente, nao falha de codigo)"
  assert_contains "$d/out.log" "INTERROMPIDA pelo ambiente" "a fase nao foi declarada reprovada"
  assert_contains "$d/out.log" "ralph-fixture-db-1" "o servico fora do ar foi nomeado"
  assert_not_contains "$d/out.log" "Gate 2 vermelho" "ambiente nao vira vermelho da fase"
  assert_eq "wip(phase-1): interrompido por falha de ambiente — see .phases/logs/" \
    "$(git -C "$d/repo" log -1 --pretty=%s)" "trabalho da fase salvo em commit wip"
  assert_eq 0 "$(cat "$d/state/repair_calls" 2> /dev/null || echo 0)" "nenhum conserto cirurgico"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "nenhum ciclo extra e nenhuma fase seguinte (--keep-going nao continua)"
fi

# ---------------------------------------------------------------------------
# 61. --no-env-guard devolve o comportamento antigo: quem ASSERTA mensagem de
#     conexao na propria suite nao pode ficar refem do guard.
# ---------------------------------------------------------------------------
if case_enabled infra-guard-off; then
  header "61. --no-env-guard trata ambiente como gate 2 vermelho comum"
  d=$(new_case infra-guard-off)
  rc=$(run_ralph "$d" infra-forever --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-env-guard --no-repair)
  assert_eq 1 "$rc" "exit 1 (falha de fase, como antes)"
  assert_contains "$d/out.log" "Gate 2 vermelho" "sem o guard o gate 2 reprova"
  assert_not_contains "$d/out.log" "INTERROMPIDA pelo ambiente" "nenhum veredito de ambiente"
fi

# ---------------------------------------------------------------------------
# 62. A causa impressa no fim tem que conter a FALHA. GATE_CAUSE carrega o tail
#     de 200 linhas da suite; imprimir o `head` disso mostrava so teste verde e
#     escondia o erro — o operador via "PASS PASS PASS" numa fase reprovada.
# ---------------------------------------------------------------------------
if case_enabled cause-shows-failure; then
  header "62. a causa impressa mostra a falha, nao o verde de cima"
  d=$(new_case cause-shows-failure)
  rc=$(run_ralph "$d" red-noisy --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "AlvoTest" "a causa nomeia o teste que falhou"
  assert_contains "$d/out.log" "Failed asserting that 3 matches expected 4." "a causa traz a assercao"
fi

# ---------------------------------------------------------------------------
# 63. --model fixa o modelo da implementacao sem contaminar o verificador nem
#     o conserto, que tem modelo proprio e barato.
# ---------------------------------------------------------------------------
if case_enabled impl-model; then
  header "63. --model vale so para implementacao/correcao"
  d=$(new_case impl-model)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --model modelo-grande)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "modelo-grande" "$(cat "$d/state/impl_model" 2> /dev/null || echo vazio)" "a impl recebeu --model"
  assert_eq "sonnet" "$(cat "$d/state/verify_model" 2> /dev/null || echo vazio)" "o verificador manteve o modelo proprio"
  assert_contains "$d/out.log" "conserto: opus" "o conserto usa o modelo forte"
  assert_contains "$d/out.log" "implementacao: modelo-grande" "o run reporta os modelos usados"
fi

# ---------------------------------------------------------------------------
# 65. Caveman no run headless: nivel maximo nas sessoes que ESCREVEM codigo,
#     nunca no verificador (cujo output e contrato de maquina), e o flag global
#     do plugin volta ao valor que tinha antes do run.
# ---------------------------------------------------------------------------
if case_enabled caveman; then
  header "65. caveman ultra so nas sessoes de implementacao/conserto"
  d=$(new_case caveman)
  mkdir -p "$d/cfg"
  printf 'full' > "$d/cfg/.caveman-active"
  rc=$(CASE_CLAUDE_CONFIG_DIR="$d/cfg" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/state/caveman_impl" "ultra" "a implementacao pediu caveman ultra"
  assert_not_contains "$d/state/caveman_verify" "ultra" "o verificador ficou no formato normal"
  assert_eq "full" "$(cat "$d/cfg/.caveman-active" 2> /dev/null || echo ausente)" "o flag global do plugin voltou ao nivel de antes"
  assert_contains "$d/out.log" "Caveman — nivel 'ultra'" "o run reporta o nivel usado"

  d2=$(new_case caveman-off)
  rc=$(CASE_CAVEMAN=off run_ralph "$d2" ok --engine claude --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "exit 0 (off)"
  assert_not_contains "$d2/state/caveman_impl" "ultra" "RALPH_CAVEMAN=off nao injeta nivel nenhum"
fi

# ---------------------------------------------------------------------------
# Escopo do gate 2 — a suite inteira e o gate da SPEC, nao o de cada fase
# ---------------------------------------------------------------------------

# Argumentos da n-esima execucao do comando de teste ("" = suite completa).
test_args_line() { sed -n "${2}p" "$1/state/test_args" 2> /dev/null || true; }

# 66. Fase intermediaria que altera arquivo de teste -> o gate 2 roda SO esse
#     arquivo. A suite completa fica para a ultima fase.
if case_enabled gate2-escopado; then
  header "66. fase intermediaria roda so os testes que ela alterou"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-escopado)
  unset CASE_PHASES
  rc=$(run_ralph "$d" scoped-tests --engine claude --test-cmd "$d/pytest")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 4 "$(commits "$d")" "1 commit por fase (1 fixture + 3)"
  assert_eq 2 "$(cat "$d/state/test_calls")" "2 execucoes: a fase 2 (escopada) e a fase 3 (completa)"
  assert_eq "tests/Feature/AlvoTest.py" "$(test_args_line "$d" 1)" "a fase 2 rodou so o teste que ela criou"
  assert_eq "" "$(test_args_line "$d" 2)" "a ultima fase rodou a suite inteira, sem escopo"
  assert_contains "$d/out.log" "rodando os testes desta fase" "o log separa escopo de suite"
  assert_contains "$d/out.log" "ultima fase do documento — gate final da spec" "a suite completa e o gate da spec"
  assert_contains "$d/out.log" "a suite completa roda na fase 3" "o run anuncia onde a suite inteira roda"
fi

# 67. Fase mecanica (nenhum teste alterado, nada critico) -> gate 2 nao executa.
#     E aqui que nascia o teste inutil: fase sem comportamento novo precisando
#     de "algo verde" para fechar o gate.
if case_enabled gate2-skip; then
  header "67. fase sem teste e sem mudanca critica nao roda suite"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-skip)
  unset CASE_PHASES
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/pytest")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 4 "$(commits "$d")" "as fases fecharam pelo gate 3 (1 fixture + 3)"
  assert_eq 1 "$(cat "$d/state/test_calls")" "a suite rodou UMA vez no run inteiro (fim da spec)"
  assert_contains "$d/out.log" "Gate 2 — nao executado" "o gate 2 explica que nao rodou"
  assert_contains "$d/out.log" "nao alterou nem citou arquivo de teste" "o motivo aparece no log"
  assert_eq 3 "$(cat "$d/state/verify_calls")" "o gate 3 continua rodando em toda fase"
fi

# 68. Mudanca critica (migration) na fase intermediaria -> suite completa ali
#     mesmo. Escopo nao protege contra schema quebrado.
if case_enabled gate2-critico; then
  header "68. mudanca critica na fase forca a suite completa"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-critico)
  unset CASE_PHASES
  rc=$(run_ralph "$d" critical-change --engine claude --test-cmd "$d/pytest")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 2 "$(cat "$d/state/test_calls")" "a fase 2 (critica) e a fase 3 (final) rodaram a suite"
  assert_eq "" "$(test_args_line "$d" 1)" "a fase critica rodou sem escopo"
  assert_contains "$d/out.log" "mudanca critica na fase: database/migrations/" "o log nomeia o arquivo critico"
fi

# 69. A fase pode DECLARAR que quer a suite inteira. Escalada, nunca o contrario.
if case_enabled gate2-declarado; then
  header "69. fase que declara 'Suite: completa' roda a suite inteira"
  CASE_PHASES="$PHASES_FIXTURE_DECLARED"
  d=$(new_case gate2-declarado)
  unset CASE_PHASES
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/pytest")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 2 "$(cat "$d/state/test_calls")" "a fase declarada e a final rodaram a suite"
  assert_contains "$d/out.log" "a fase declara 'Suite: completa'" "o log cita a declaracao da fase"
fi

# 70. Runner que nao aceita caminho (nome desconhecido, go, cargo) -> suite
#     completa. Fail-safe: escopo duvidoso vira suite inteira, nunca menos teste.
if case_enabled gate2-runner-cego; then
  header "70. runner que nao aceita escopo cai na suite completa"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-runner-cego)
  unset CASE_PHASES
  rc=$(run_ralph "$d" scoped-tests --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 2 "$(cat "$d/state/test_calls")" "fase 2 e fase 3 rodaram a suite"
  assert_eq "" "$(test_args_line "$d" 1)" "nenhum caminho foi anexado ao runner cego"
  assert_contains "$d/out.log" "nao aceita escopo por caminho" "o log explica a queda para suite completa"
fi

# 71. Sem gate 3, o gate 2 e a unica prova mecanica: nao escopa e nao pula.
if case_enabled gate2-sem-verify; then
  header "71. --no-verify mantem a suite completa em toda fase"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-sem-verify)
  unset CASE_PHASES
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/pytest" --no-verify)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(cat "$d/state/test_calls")" "a suite rodou em toda fase (1 por fase)"
  assert_contains "$d/out.log" "gate 3 desligado" "o log justifica a suite completa"
fi

# 72. --full-suite restaura o comportamento anterior integralmente.
if case_enabled gate2-full-suite; then
  header "72. --full-suite roda a suite completa em toda fase"
  CASE_PHASES="$PHASES_FIXTURE_3"
  d=$(new_case gate2-full-suite)
  unset CASE_PHASES
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/pytest" --full-suite)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(cat "$d/state/test_calls")" "1 execucao por fase"
  assert_contains "$d/out.log" "suite completa em toda fase" "o modo aparece no log"
  assert_not_contains "$d/out.log" "Gate 2 — nao executado" "nenhuma fase pulou o gate 2"
fi

# 73. O prompt de implementacao nao manda mais rodar a suite completa.
if case_enabled prompt-sem-suite; then
  header "73. prompt manda rodar so os testes da fase"
  d=$(new_case prompt-sem-suite)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/pytest")
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "NAO rode a suite completa" "o prompt proibe a suite completa"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "so no fim da spec" "o prompt diz quem roda a suite e quando"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Nao invente teste para ter o que" "o prompt corta o teste de fachada"
fi

# ---------------------------------------------------------------------------
# Gate 3 com prova: DONE nu reprova; `Tela:` exige captura feita pelo ralph
# ---------------------------------------------------------------------------
PHASES_FIXTURE_UI='# Test Project — Project Phases

## Phase 1: Tela

- [ ] **Task:** cria o arquivo A
  - **Acceptance criteria:**
    - o arquivo existe
  Tela: /admin | .fi-header, [data-x="y"] | | claro
- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe
'

if case_enabled verify-bare-done; then
  header "G3-A. verificador responde DONE sem evidencia -> gate 3 vermelho por protocolo"
  d=$(new_case verify-bare-done)
  rc=$(run_ralph "$d" verify-bare-done --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "DONE sem evidencia" "a causa nomeia a falta de prova"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "Voce NAO executa comandos" "o prompt do verificador nao promete o que a ferramenta proibe"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "DONE — <evidencia" "o contrato de saida pede evidencia"
fi

if case_enabled ui-shot-missing; then
  header "G3-B. fase com 'Tela:' e sem comando de captura -> reprova fail-closed"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-shot-missing)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "RALPH_UI_SHOT_CMD" "a causa aponta o comando ausente"
  assert_eq 0 "$(cat "$d/state/verify_calls" 2> /dev/null || echo 0)" "verificador nem roda sem a prova"
fi

if case_enabled ui-shot-ok; then
  header "G3-C. captura feita pelo ralph vira evidencia do verificador"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-shot-ok)
  cat > "$d/shot.sh" <<'SHOT'
#!/usr/bin/env bash
echo "$1|$2|$3|$4|${RALPH_UI_VIEWPORT:-}" >> "${MOCK_STATE}/shot_args"
printf 'PNG-FAKE' > "$2"
SHOT
  chmod +x "$d/shot.sh"
  rc=$(CASE_UI_SHOT_CMD="$d/shot.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  test -s "$d/repo/.phases/evidence/phase-01/task-1.png" && ok "captura gravada em .phases/evidence/<fase>/task-1.png" || bad "captura gravada em .phases/evidence/<fase>/task-1.png"
  test -s "$d/repo/.phases/evidence/phase-01/task-1-mobile.png" && ok "captura de celular gravada em task-1-mobile.png" || bad "captura de celular gravada em task-1-mobile.png"
  test -e "$d/repo/.phases/evidence/phase-01/task-2.png" && bad "task sem 'Tela:' nao e fotografada" || ok "task sem 'Tela:' nao e fotografada"
  assert_contains "$d/state/shot_args" '/admin|' "o comando recebe a rota"
  assert_contains "$d/state/shot_args" '|.fi-header, [data-x="y"]|claro' "o comando recebe os seletores e o tema (4o campo)"
  assert_contains "$d/state/shot_args" 'task-1.png|.fi-header, [data-x="y"]|claro|desktop' "a captura principal roda com RALPH_UI_VIEWPORT=desktop"
  assert_contains "$d/state/shot_args" 'task-1-mobile.png|.fi-header, [data-x="y"]|claro|mobile' "a captura de celular roda com RALPH_UI_VIEWPORT=mobile"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "(tema: claro)" "o verificador sabe em que tema a captura foi feita"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "Evidencia visual" "o verificador recebe a secao de evidencia"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "evidence/phase-01/task-1.png" "o verificador recebe o caminho da captura"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "evidence/phase-01/task-1-mobile.png" "o verificador recebe a captura de celular"
  assert_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "Defeitos visuais objetivos" "o verificador recebe a regua de defeitos visuais"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Tasks de tela desta fase" "o executor recebe a secao de design da tela"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Defeitos visuais objetivos" "o executor recebe a mesma regua do verificador"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "RALPH_UI_VIEWPORT=mobile" "o executor sabe se fotografar no celular"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" ".phases/selfcheck/" "a autocaptura vai para selfcheck, nunca para a evidencia do gate"
fi

if case_enabled ui-design-brief-absent; then
  header "G3-C3. fase sem 'Tela:' -> prompts sem secao de design nem regua visual"
  d=$(new_case ui-design-brief-absent)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/repo/.phases/prompts/phase-01.cycle-1.txt" "Tasks de tela desta fase" "fase de logica nao recebe secao de design"
  assert_not_contains "$d/repo/.phases/prompts/phase-01.verify-1.txt" "Defeitos visuais objetivos" "verificador de fase sem tela nao recebe regua visual"
fi

if case_enabled ui-design-brief-fix; then
  header "G3-C4. ciclo de correcao de fase com 'Tela:' mantem a secao de design"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-design-brief-fix)
  printf '#!/usr/bin/env bash\necho "seletor .fi-header nao encontrado" >&2\nexit 3\n' > "$d/shot.sh"
  chmod +x "$d/shot.sh"
  rc=$(CASE_UI_SHOT_CMD="$d/shot.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "Tasks de tela desta fase" "o prompt de correcao carrega a secao de design"
fi

if case_enabled ui-shot-autodetect; then
  header "G3-C2. sem RALPH_UI_SHOT_CMD, scripts/ralph-ui-shot.sh do repo e o comando de captura"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-shot-autodetect)
  mkdir -p "$d/repo/scripts"
  printf '#!/usr/bin/env bash\nprintf PNG > "$2"\n' > "$d/repo/scripts/ralph-ui-shot.sh"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m "chore: shot script"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "comando de captura detectado: bash scripts/ralph-ui-shot.sh" "o ralph anuncia o comando detectado"
  test -s "$d/repo/.phases/evidence/phase-01/task-1.png" && ok "captura gravada pelo script do repo" || bad "captura gravada pelo script do repo"
fi

if case_enabled ui-shot-fails; then
  header "G3-D. captura falha (seletor ausente / pagina nao renderiza) -> fase reprova"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-shot-fails)
  printf '#!/usr/bin/env bash\necho "seletor .fi-header nao encontrado" >&2\nexit 3\n' > "$d/shot.sh"
  chmod +x "$d/shot.sh"
  rc=$(CASE_UI_SHOT_CMD="$d/shot.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-repair)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Evidencia visual da task 1 falhou" "a causa nomeia a task e a captura"
  assert_contains "$d/out.log" "seletor .fi-header nao encontrado" "a saida do comando de captura vai para a causa"
fi

if case_enabled ui-verify-off; then
  header "G3-E. --no-ui-verify desliga a prova visual de proposito"
  d=$(CASE_PHASES="$PHASES_FIXTURE_UI" new_case ui-verify-off)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --no-ui-verify)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/out.log" "Evidencia visual DESLIGADA" "o desligamento e anunciado, nao silencioso"
fi

if case_enabled checkbox-sync; then
  header "G3-F. fase verde -> ralph marca [x] no documento de entrada (mecanico, nao o engine)"
  d=$(new_case checkbox-sync)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(grep -c -- '- \[x\]' "$d/repo/.spec/init/project-phases.md")" "as 3 tasks do documento marcadas"
  assert_eq 0 "$(grep -c -- '- \[ \]' "$d/repo/.spec/init/project-phases.md")" "nenhum checkbox aberto sobrou"
  assert_eq 0 "$(git -C "$d/repo" status --porcelain | wc -l)" "a marcacao entrou no commit da fase (arvore limpa)"
fi

# ---------------------------------------------------------------------------
# R1. Sessao de resgate: a fase travou (conserto desistiu) e a etapa larga
#     assume, fecha os gates COMPLETOS e commita. E o caso que antes terminava
#     em "FALHOU" com o dev lendo log.
# ---------------------------------------------------------------------------
if case_enabled rescue-green; then
  header "R1. resgate assume a fase travada, fecha os gates e commita"
  d=$(new_case rescue-green)
  rc=$(CASE_RESCUE=on run_ralph "$d" rescue-fix --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2)
  assert_eq 0 "$rc" "exit 0 — a fase que travava agora fecha"
  assert_eq 1 "$(cat "$d/state/rescue_calls")" "uma sessao de resgate gasta"
  assert_contains "$d/out.log" "Sessao de resgate 1/2" "o resgate foi anunciado"
  assert_contains "$d/out.log" "fechou a fase — gates completos verdes" "resgate nao substitui gate"
  test -f "$d/repo/.phases/logs/phase-01.rescue-1.log" && ok "log proprio do resgate" || bad "log proprio do resgate"
  test -f "$d/repo/.phases/logs/phase-01.verify-rescue1.log" && ok "gate 3 do resgate com log proprio (nao sobrescreve o do ciclo)" || bad "gate 3 do resgate com log proprio (nao sobrescreve o do ciclo)"
  test -f "$d/repo/.phases/logs/phase-01.verify-1.log" && ok "o log do ciclo anterior continua la" || bad "o log do ciclo anterior continua la"
  git -C "$d/repo" log --format=%B > "$d/commitmsg.txt"
  assert_contains "$d/commitmsg.txt" "sessao de resgate (round 1)" "o commit registra a origem do verde"
  assert_contains "$d/repo/.phases/events.jsonl" "rescue_start" "evento de inicio do resgate"
  assert_contains "$d/repo/.phases/events.jsonl" '"verdict": "green"' "evento de desfecho do resgate"
fi

# ---------------------------------------------------------------------------
# R2. O prompt de resgate e o OPOSTO do conserto: carrega contexto, a fase
#     inteira, a desistencia verbatim e as regras de teste. Sem isso a sessao
#     larga repete o caminho da estreita.
# ---------------------------------------------------------------------------
if case_enabled rescue-prompt; then
  header "R2. prompt de resgate carrega contexto, fase e a desistencia verbatim"
  d=$(new_case rescue-prompt)
  rc=$(CASE_RESCUE=on run_ralph "$d" rescue-fix --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2)
  assert_eq 0 "$rc" "exit 0"
  pf="$d/state/rescue_prompt_1.txt"
  assert_contains "$pf" "Acceptance criteria" "o resgate recebe a fase inteira"
  assert_contains "$pf" "REPAIR_ABORT: causa nao localizavel no erro" "recebe a desistencia do conserto verbatim"
  assert_contains "$pf" "Por que a fase parou" "recebe o motivo do travamento"
  assert_contains "$pf" "TASK 1: INCOMPLETE" "recebe o veredito bruto do ultimo gate"
  assert_contains "$pf" "Afrouxar teste para ficar verde" "proibicao de afrouxar teste no prompt"
  assert_contains "$pf" "TESTE ALTERADO:" "exige justificativa escrita para mexer em teste"
  assert_contains "$pf" "RESCUE_BLOCKED:" "oferece a saida honesta do conflito de spec"
  assert_contains "$pf" "Task com \`Testes: none\` NAO leva teste" "politica de teste minimo no prompt"
fi

# ---------------------------------------------------------------------------
# R3. --no-rescue devolve exatamente o comportamento anterior: a fase trava e
#     o run para. A etapa nova e opcional, nao obrigatoria.
# ---------------------------------------------------------------------------
if case_enabled rescue-off; then
  header "R3. --no-rescue devolve o comportamento anterior"
  d=$(new_case rescue-off)
  rc=$(CASE_RESCUE=on run_ralph "$d" rescue-fix --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2 --no-rescue)
  assert_eq 1 "$rc" "exit 1 (a fase continua travada)"
  test -f "$d/state/rescue_calls" && bad "nenhuma sessao de resgate gasta" || ok "nenhuma sessao de resgate gasta"
  assert_contains "$d/out.log" "Abortando a fase" "o abort de hoje continua valendo"

  # --max-rescues 0 e a mesma porta
  d2=$(new_case rescue-zero)
  rc=$(CASE_RESCUE=on run_ralph "$d2" rescue-fix --engine claude --test-cmd "$d2/test.sh" --max-cycles 1 --max-repairs 2 --max-rescues 0)
  assert_eq 1 "$rc" "exit 1 com --max-rescues 0"
  test -f "$d2/state/rescue_calls" && bad "--max-rescues 0 nao gasta resgate" || ok "--max-rescues 0 nao gasta resgate"
fi

# ---------------------------------------------------------------------------
# R4. O resgate vem LIGADO por default: quem nao souber que a etapa existe
#     ainda assim recebe a fase salva.
# ---------------------------------------------------------------------------
if case_enabled rescue-default-on; then
  header "R4. resgate ligado por default"
  d=$(new_case rescue-default-on)
  rc=$(CASE_RESCUE= run_ralph "$d" rescue-fix --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2)
  assert_eq 0 "$rc" "exit 0 sem passar flag nenhuma de resgate"
  assert_eq 1 "$(cat "$d/state/rescue_calls")" "o resgate rodou por default"
fi

# ---------------------------------------------------------------------------
# R5. RESCUE_BLOCKED: contradicao de especificacao nao se resolve gastando
#     outra sessao. Encerra na hora, com o conflito no relatorio.
# ---------------------------------------------------------------------------
if case_enabled rescue-blocked; then
  header "R5. RESCUE_BLOCKED encerra a fase sem gastar o round seguinte"
  d=$(new_case rescue-blocked)
  rc=$(CASE_RESCUE=on run_ralph "$d" rescue-blocked --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 2 --max-rescues 2)
  assert_eq 1 "$rc" "exit 1 (decisao humana pendente)"
  assert_eq 1 "$(cat "$d/state/rescue_calls")" "so um round gasto, mesmo com orcamento de 2"
  assert_contains "$d/out.log" "bloqueio de especificacao" "o bloqueio foi reportado"
  assert_contains "$d/out.log" "a importacao da WABA exige aceitar o mesmo nome" "o conflito sai verbatim no relatorio"
  assert_contains "$d/repo/.phases/events.jsonl" '"verdict": "blocked"' "evento de bloqueio no log de eventos"
fi

# ---------------------------------------------------------------------------
# R6. Resgate vermelho gasta o orcamento e reprova a fase: verde de resgate
#     e verde de gate, nunca de insistencia.
# ---------------------------------------------------------------------------
if case_enabled rescue-exhausted; then
  header "R6. resgate que nao resolve esgota o orcamento e reprova"
  d=$(new_case rescue-exhausted)
  rc=$(CASE_RESCUE=on run_ralph "$d" verify-incomplete-always --engine claude --test-cmd "$d/test.sh" --max-cycles 1 --max-repairs 1)
  assert_eq 1 "$rc" "exit 1"
  assert_eq 2 "$(cat "$d/state/rescue_calls")" "os 2 rounds de resgate foram gastos"
  assert_contains "$d/out.log" "Sessoes de resgate esgotadas" "o esgotamento foi reportado"
  assert_contains "$d/out.log" "sessao(oes) de resgate" "o relatorio final conta o que foi gasto"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase com gate vermelho"
fi

# ---------------------------------------------------------------------------
# R7. Modelo proprio: o resgate e a sessao de maior autoridade do harness e nao
#     pode herdar o modelo da implementacao por acidente.
# ---------------------------------------------------------------------------
if case_enabled rescue-model; then
  header "R7. --rescue-model vale so para a sessao de resgate"
  d=$(new_case rescue-model)
  rc=$(CASE_RESCUE=on run_ralph "$d" rescue-fix --engine claude --test-cmd "$d/test.sh" \
    --max-cycles 1 --max-repairs 2 --model modelo-impl --rescue-model modelo-resgate)
  assert_eq 0 "$rc" "exit 0"
  assert_eq "modelo-resgate" "$(cat "$d/state/rescue_model")" "o resgate usa o modelo proprio"
  assert_eq "modelo-impl" "$(cat "$d/state/impl_model")" "a implementacao mantem o dela"
fi

# ---------------------------------------------------------------------------
# H1. Vermelho herdado de HEAD e saneado ANTES da fase 1. O run real: duas
#     guardas de higiene de features antigas estavam vermelhas em HEAD, a fase em
#     curso nao tocava nenhuma, e o ralph gastou 5 ciclos + 2 consertos + 2
#     resgates (16 min) para concluir "isto nao se conserta escrevendo codigo".
# ---------------------------------------------------------------------------
if case_enabled heal-head; then
  header "H1. HEAD vermelho e saneado antes da fase 1"
  d=$(new_case heal-head)
  rc=$(CASE_HEAL_HEAD=on run_ralph "$d" heal-head --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (HEAD saneado, fases seguiram)"
  assert_contains "$d/out.log" "GuardaVelhaTest" "o baseline nomeou o teste vermelho em HEAD"
  assert_contains "$d/out.log" "Saneamento do HEAD 1/1" "a sessao de saneamento rodou"
  assert_contains "$d/out.log" "suite verde em HEAD" "a suite fechou verde antes da fase 1"
  assert_eq 1 "$(cat "$d/state/heal_calls")" "exatamente 1 sessao de saneamento"
  assert_eq "test(baseline): sanea o vermelho herdado de HEAD" \
    "$(git -C "$d/repo" log --pretty=%s | tail -n 2 | head -n 1)" \
    "o saneamento tem commit proprio, antes do commit da fase 1"
  # Nenhum ciclo de correcao foi gasto com o vermelho alheio.
  assert_not_contains "$d/out.log" "Ciclo de correcao" "nenhum ciclo gasto com vermelho herdado"
  test -f "$d/state/repair_calls" && bad "nenhum conserto cirurgico gasto" || ok "nenhum conserto cirurgico gasto"
fi

# ---------------------------------------------------------------------------
# H2. O saneamento que nao fecha PARA o run antes da fase 1. O custo do erro
#     passa a ser uma rodada de suite, nao uma fase inteira.
# ---------------------------------------------------------------------------
if case_enabled heal-blocked; then
  header "H2. saneamento bloqueado aborta antes da fase 1"
  d=$(new_case heal-blocked)
  rc=$(CASE_HEAL_HEAD=on run_ralph "$d" heal-blocked --engine claude --test-cmd "$d/test.sh" --max-cycles 3)
  assert_eq 1 "$rc" "exit 1 (o run nao comeca sobre gate vermelho)"
  assert_contains "$d/out.log" "HEAL_ABORT" "a desistencia da sessao aparece no log"
  assert_contains "$d/out.log" "HEAD vermelho nao sanado" "o motivo do abort e explicito"
  assert_contains "$d/out.log" "GuardaVelhaTest" "o abort nomeia o teste vermelho"
  assert_contains "$d/out.log" "--baseline" "o abort oferece a saida de herdar o vermelho"
  assert_eq 1 "$(commits "$d")" "so o commit da fixture: nenhuma fase comecou"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de fase foi gasta" || ok "nenhuma sessao de fase foi gasta"
fi

# ---------------------------------------------------------------------------
# H3. --no-heal-head devolve o comportamento anterior: mede, avisa e segue.
# ---------------------------------------------------------------------------
if case_enabled heal-off; then
  header "H3. --no-heal-head nao mede nem sanea"
  d=$(new_case heal-off)
  rc=$(CASE_HEAL_HEAD=on run_ralph "$d" heal-blocked --engine claude --test-cmd "$d/test.sh" \
    --max-cycles 1 --no-heal-head)
  assert_eq 1 "$rc" "exit 1 (o gate 2 da fase reprova, como antes)"
  assert_not_contains "$d/out.log" "Saneamento do HEAD" "nenhuma sessao de saneamento"
  assert_contains "$d/out.log" "Gate 2 vermelho" "o vermelho volta a ser julgado pela fase"
fi

# ---------------------------------------------------------------------------
# H4. Mandato de guarda obsoleta nos tres prompts que ja desistiram dele. O
#     conserto e o resgate declararam "afrouxar contrato de outra feature e
#     decisao humana" sobre guarda que so estava velha.
# ---------------------------------------------------------------------------
if case_enabled heal-mandate; then
  header "H4. o mandato de guarda obsoleta vai nos 3 prompts"
  d=$(new_case heal-mandate)
  rc=$(CASE_HEAL_HEAD=on run_ralph "$d" heal-head --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d/state/heal_prompt_1.txt" "Guarda obsoleta de OUTRA feature" \
    "o prompt de saneamento carrega o mandato"
  assert_contains "$d/state/heal_prompt_1.txt" "git log -S" \
    "o mandato manda provar pelo commit que mudou o texto"
  assert_contains "$d/state/heal_prompt_1.txt" "Proibido: apagar a guarda" \
    "o mandato proibe apagar a guarda"

  # Conserto e resgate: mesmo mandato, num cenario que chega aos dois.
  d2=$(new_case heal-mandate-repair)
  rc=$(CASE_RESCUE=on run_ralph "$d2" rescue-fix --engine claude --test-cmd "$d2/test.sh" \
    --max-cycles 1 --max-repairs 1)
  assert_eq 0 "$rc" "exit 0"
  assert_contains "$d2/state/repair_prompt_1.txt" "Guarda obsoleta de OUTRA feature" \
    "o conserto cirurgico recebeu o mandato"
  assert_contains "$d2/state/rescue_prompt_1.txt" "Guarda obsoleta NAO e conflito de especificacao" \
    "o resgate recebeu o limite do RESCUE_BLOCKED por guarda"
fi

# ---------------------------------------------------------------------------
# Painel: toda linha de caixa fecha na largura da janela.
#
# `${#s}` conta CARACTERE, o terminal desenha COLUNA. Marca East-Asian
# Ambiguous que a fonte do terminal nao tem (▶ U+25B6, ◐ U+25D0, █ U+2588,
# … U+2026, — U+2014) cai em fallback de emoji e ocupa 2 colunas: a borda
# direita anda para fora da janela e a caixa aparece cortada.
#
# Fica vermelho se alguem devolver marca de largura ambigua para uma CELULA do
# painel. A moldura (U+2500-2524) e isenta: se ela medisse 2 o painel inteiro
# colapsaria, nao so a linha com a marca.
# ---------------------------------------------------------------------------
if case_enabled ui-box-width; then
  header "painel: largura das caixas em toda janela"

  ub="$TMP/uibox"
  mkdir -p "$ub/.phases/ui"
  # ralph.sh sem a ultima linha (`main`): da para sourcear so as funcoes.
  sed '$d' "$RALPH" > "$ub/ui.sh"

  cat > "$ub/.phases/manifest.txt" <<'MAN'
phase-01.md|1|Estrutura e exposição do dado legado
phase-02.md|2|Download de lote e recusa de exclusão
MAN
  cat > "$ub/.phases/ui/phases.txt" <<'PH'
1|running|Estrutura e exposição do dado legado
2|pending|Download de lote e recusa de exclusão
PH
  cat > "$ub/.phases/ui/tasks.txt" <<'TK'
1|1|pending|Migrations de estrutura: marca de origem, data aproximada e disco
1|2|pending|Flags de origem e disponibilidade no model `RemittanceBatch`
1|3|declared|Eager loading de `uploads` na listagem administrativa
2|1|pending|VO e resolver de arquivo de lote (`payload` ou metadado)
TK
  printf '1|0|0\n2|75|0\n3|100|1\n' > "$ub/.phases/ui/taskprog.txt"
  cat > "$ub/.phases/ui/state.env" <<ENV
run_status=running
phase_num=1
phase_seq=1
phase_total=2
phase_title=Estrutura e exposição do dado legado
cycle=1
max_cycles=5
phase_start=$(($(date +%s) - 37))
gate0=pass
gate1=pass
gate2=running
gate3=pending
activity=implementando a fase
last_error=
pid=$$
run_id=run-$$
started=$(($(date +%s) - 37))
stage_start=$(($(date +%s) - 36))
engine=claude
project=bench
ENV

  cat > "$ub/render.sh" <<'REN'
W="$2"; H="$3"
source "$1" > /dev/null 2>&1
set +eu
ui_term_cols()  { echo "$W"; }
ui_term_lines() { echo "$H"; }
ui_frame 0 2> /dev/null
REN

  # Mede a largura RENDERIZADA: ambiguo fora da moldura conta 2 colunas, que e
  # o pior caso real (Windows Terminal sobre WSL com fallback de fonte).
  cat > "$ub/check.py" <<'CHK'
import re, sys, unicodedata as u
FRAME = set('─│┌┐└┘├┤')
ESC = re.compile(r'\x1b\[[0-9;]*m')
W = int(sys.argv[1])

def cols(p):
    n = 0
    for c in p:
        o = ord(c)
        # ASCII, moldura, meio-ponto e Latin-1 acentuado: 1 coluna em qualquer
        # fonte monoespacada — sao os que o terminal sempre tem.
        if o < 128 or c in FRAME or o == 0xB7 or 0xC0 <= o <= 0xFF:
            n += 1
        elif u.east_asian_width(c) in ('A', 'W', 'F'):
            n += 2
        else:
            n += 1
    return n

bad = []
for raw in sys.stdin.read().split('\n'):
    p = ESC.sub('', raw)
    if not p.strip() or p[0] not in FRAME:
        continue
    if len(p) != W or cols(p) != W:
        bad.append('%d/%d %s' % (len(p), cols(p), p[:50]))
print(len(bad))
for b in bad[:3]:
    print('    ' + b, file=sys.stderr)
CHK

  (
    cd "$ub" || exit 1
    for w in 74 80 96 100 120 160 200; do
      printf '%s\n' "$(bash "$ub/render.sh" "$ub/ui.sh" "$w" 45 | python3 "$ub/check.py" "$w")" \
        > "$ub/out-$w.txt" 2> "$ub/err-$w.txt"
    done
    # Prova red: com o conjunto antigo de marcas o mesmo painel estoura.
    RALPH_UI_GLYPHS=unicode bash "$ub/render.sh" "$ub/ui.sh" 120 45 \
      | python3 "$ub/check.py" 120 > "$ub/out-legacy.txt" 2> /dev/null
  )

  for w in 74 80 96 100 120 160 200; do
    assert_eq 0 "$(cat "$ub/out-$w.txt")" "painel fecha em $w colunas"
  done
  # Sem isso o teste passaria mesmo se o medidor estivesse quebrado.
  if [ "$(cat "$ub/out-legacy.txt")" -gt 0 ]; then
    ok "o medidor pega o conjunto antigo de marcas (prova red)"
  else
    bad "o medidor NAO pega o conjunto antigo: o teste nao prova nada"
  fi
fi

# ---------------------------------------------------------------------------
# Defaults de producao do orcamento de recuperacao.
#
# O helper run_ralph fixa o orcamento antigo e generoso para todos os outros
# casos — eles testam o MECANISMO. Este testa a POLITICA: o que acontece com o
# ralph recem-instalado, sem env nenhuma. As variaveis vao VAZIAS de proposito
# (expansao com `-` no helper), e ai o ralph usa os proprios defaults.
#
# Fica vermelho se alguem mexer nos defaults sem decidir mexer.
# ---------------------------------------------------------------------------
if case_enabled budget-defaults; then
  header "defaults de producao: 2 ciclos, sem conserto, 1 resgate, gate 3 auto"

  d=$(new_case budget-defaults)
  # Cenario que nunca fecha: exercita o orcamento inteiro ate a reprovacao.
  rc=$(CASE_VERIFY='' CASE_REPAIR='' CASE_MAX_REPAIRS='' CASE_MAX_RESCUES='' CASE_RESCUE='' \
    run_ralph "$d" verify-incomplete-always --engine claude --test-cmd "$d/test.sh")

  assert_eq 1 "$rc" "a fase reprova depois de esgotar o orcamento"
  assert_contains "$d/out.log" "max-cycles: 2" "2 ciclos por fase"
  assert_contains "$d/out.log" "Ciclo de correcao 2/2" "o segundo ciclo e o ultimo"
  assert_not_contains "$d/out.log" "Ciclo de correcao 3" "nao existe terceiro ciclo"
  assert_not_contains "$d/out.log" "Conserto cirurgico" "conserto cirurgico fora do default"
  assert_contains "$d/out.log" "Sessao de resgate 1/1" "um unico resgate"
  assert_not_contains "$d/out.log" "Sessao de resgate 2" "nao existe segundo resgate"

  # O teto de sessoes por fase e o numero que motivou o corte: o orcamento
  # antigo chegava a ~29 no pior caso. Os contadores do mock sao separados —
  # ciclo e resgate nao caem no mesmo balde.
  assert_eq 2 "$(cat "$d/state/impl_calls" 2>/dev/null || echo 0)" \
    "2 sessoes de ciclo por fase, nao 5"
  assert_eq 1 "$(cat "$d/state/rescue_calls" 2>/dev/null || echo 0)" \
    "1 sessao de resgate por fase, nao 2"
  assert_eq 0 "$(cat "$d/state/repair_calls" 2>/dev/null || echo 0)" \
    "nenhuma sessao de conserto cirurgico"
fi

# ---------------------------------------------------------------------------
# Stream do engine: NDJSON real, capturado do `claude -p --output-format
# stream-json --verbose`.
#
# O mock nao serve aqui. Ele emite o NDJSON que o ralph espera, entao um erro
# de premissa sobre o formato passaria despercebido nos dois lados. A fixture
# abaixo tem a forma que a CLI de verdade produz — eventos system/hook, um
# rate_limit_event no meio, tool_use dentro de message.content, e o veredito so
# no evento final.
#
# Fica vermelho se alguem voltar a ler o stream com grep em vez de jq, ou
# mudar a extracao sem acertar todos os consumidores.
# ---------------------------------------------------------------------------
if case_enabled engine-stream; then
  header "stream do engine: NDJSON real"

  es="$TMP/engine-stream"
  mkdir -p "$es"
  sed '$d' "$RALPH" > "$es/ui.sh"

  # Fixture: a forma real, com o texto do verificador dentro de `.result` —
  # \n e aspas escapados, que e o que quebrava o `^TASK` do gate 3.
  cat > "$es/ok.log" <<'NDJSON'
{"type":"system","subtype":"hook_started","hook":"SessionStart"}
{"type":"system","subtype":"init","session_id":"abc","tools":["Bash","Edit"]}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"app/Models/RemittanceBatch.php"}}]}}
{"type":"rate_limit_event","status":"allowed"}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"app/Models/RemittanceBatch.php"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"database/migrations/2026_01_01_add_origin.php"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"php artisan test","description":"Run tests"}}]}}
{"type":"result","subtype":"success","is_error":false,"result":"TASK 1: DONE — app/Models/RemittanceBatch.php:12\nTASK 2: DONE — database/migrations/2026_01_01_add_origin.php:1","usage":{"input_tokens":4,"output_tokens":111},"total_cost_usd":0.26}
NDJSON

  cat > "$es/err.log" <<'NDJSON'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"user","message":{"content":[{"type":"tool_result","content":"bash: is_error: true — o comando do projeto falhou"}]}}
{"type":"result","subtype":"error_during_execution","is_error":true,"result":"a sessao terminou com erro"}
NDJSON

  # Engine morto no meio: ultima linha truncada, nenhum evento result.
  printf '%s\n' \
    '{"type":"system","subtype":"init"}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.php"}}]}}' \
    '{"type":"result","subtype":"suc' > "$es/trunc.log"

  cat > "$es/probe.sh" <<'PROBE'
# Os posicionais TEM que ser lidos antes do source: o ralph faz o proprio
# parse de "$@" e $2 deixa de ser o diretorio depois que ele roda.
es="$2"
source "$1" > /dev/null 2>&1
set +eu
ENGINE=claude
engine_materialize_text "$es/ok.log"
engine_materialize_text "$es/err.log"
engine_materialize_text "$es/trunc.log"
{
  echo "=text="
  cat "$(engine_text_for "$es/ok.log")" 2>/dev/null
  echo "=last="
  engine_last_action "$es/ok.log"
  echo "=written="
  engine_written_files "$es/ok.log"
  echo "=count="
  engine_action_count "$es/ok.log"
  echo "=gate_ok="
  GATE_CAUSE=""; gate0_engine_finished "$es/ok.log" 0 && echo PASS || echo FAIL
  echo "=gate_err="
  GATE_CAUSE=""; gate0_engine_finished "$es/err.log" 0 && echo PASS || echo FAIL
  echo "=gate_trunc="
  GATE_CAUSE=""; gate0_engine_finished "$es/trunc.log" 0 && echo PASS || echo FAIL
  echo "=trunc_written="
  engine_written_files "$es/trunc.log"
}
PROBE

  bash "$es/probe.sh" "$es/ui.sh" "$es" > "$es/out.txt" 2>&1

  sec() { awk -v s="=$1=" '$0 == s { f = 1; next } /^=[a-z_]+=$/ { f = 0 } f' "$es/out.txt"; }

  # O texto sai desescapado, com as linhas TASK separadas de verdade.
  assert_eq "TASK 1: DONE — app/Models/RemittanceBatch.php:12" \
    "$(sec text | sed -n 1p)" "o texto do result vira linha propria"
  assert_eq 2 "$(sec text | grep -c '^TASK ')" "as 2 linhas TASK saem separadas por \\n"

  # Painel: ultima acao e contagem.
  assert_eq "Bash php artisan test" "$(sec last)" "ultima acao e o tool_use mais recente"
  assert_eq 4 "$(sec count)" "conta todas as ferramentas usadas"

  # Progresso por task: so Edit/Write contam, nunca Read nem Bash.
  assert_eq "app/Models/RemittanceBatch.php database/migrations/2026_01_01_add_origin.php" \
    "$(sec written | tr '\n' ' ' | sed 's/ *$//')" "so Edit/Write entram nos arquivos escritos"

  # Gate 0 le o evento final, nao o arquivo inteiro.
  assert_eq PASS "$(sec gate_ok)"    "gate 0 verde quando is_error=false"
  assert_eq FAIL "$(sec gate_err)"   "gate 0 vermelho quando is_error=true"
  assert_eq FAIL "$(sec gate_trunc)" "gate 0 vermelho quando nao ha evento result"

  # `is_error: true` DENTRO de um tool_result e saida que o modelo leu e
  # tratou, nao o veredito da sessao. O grep antigo reprovava por isso.
  assert_eq "a sessao terminou com erro" "$(cat "$es/err.text" 2>/dev/null)" \
    "o texto vem do result, nao do tool_result"

  # Linha truncada nao pode abortar a extracao das linhas boas.
  assert_eq "a.php" "$(sec trunc_written)" "log truncado ainda entrega os eventos completos"
fi

# ---------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}TODOS VERDES: $PASS asserts${NC}"
else
  echo -e "${RED}FALHAS: $FAIL${NC} / verdes: $PASS"
fi
exit $((FAIL > 0 ? 1 : 0))
