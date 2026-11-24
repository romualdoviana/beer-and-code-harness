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
  if grep -qF "$needle" "$haystack_file"; then ok "$msg"; else bad "$msg (nao achou '$needle')"; fi
}

assert_not_contains() {
  local haystack_file="$1" needle="$2" msg="$3"
  if grep -qF "$needle" "$haystack_file"; then bad "$msg (achou '$needle')"; else ok "$msg"; fi
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

model=""
outfmt=""

if [ "$name" = "claude" ]; then
  # claude -p real le stdin quando nao e TTY: se o ralph nao redirecionar
  # < /dev/null, o mock engole o stream de quem chamou (ex: manifest do loop).
  [ -t 0 ] || cat > /dev/null
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p) prompt="$2"; shift 2 ;;
      --allowedTools) verify=1; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --output-format) outfmt="$2"; shift 2 ;;
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

# Grava o modelo pedido para a sessao verificadora (assert do teste de modelo).
if [ "$verify" -eq 1 ] && [ -n "$model" ]; then
  echo "$model" > "$state/verify_model"
fi

# --- verificador independente ------------------------------------------------
# Verifica o CODIGO REAL, como o verificador de verdade: sem arquivo de
# implementacao no repo, a fase esta incompleta.
if [ "$verify" -eq 1 ]; then
  n=$(bump verify_calls)
  tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")

  implemented=0
  compgen -G "src/impl-*.txt" > /dev/null 2>&1 && implemented=1

  if [ "$implemented" -eq 0 ]; then
    for i in $(seq 1 "$tasks"); do echo "TASK $i: INCOMPLETE — nenhum codigo encontrado"; done
    exit 0
  fi

  if [ "$scenario" = "verify-incomplete-once" ] && [ "$n" -eq 1 ]; then
    echo "TASK 1: INCOMPLETE — o arquivo nao foi criado"
    for i in $(seq 2 "$tasks"); do echo "TASK $i: DONE"; done
  else
    for i in $(seq 1 "$tasks"); do echo "TASK $i: DONE"; done
  fi
  exit 0
fi

# --- sessao de implementacao -------------------------------------------------
n=$(bump impl_calls)

emit_claude_ok()    { echo '{"type":"result","subtype":"success","is_error":false,"result":"implementado"}'; }
emit_claude_limit() { echo "{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$1\"}"; }

# Reproduz o stream-json real do claude para a lista de tarefas do agente:
# TaskCreate (sem id) -> tool_result com o id -> TaskUpdate por transicao.
# E disso que o ralph tira o progresso por task em tempo real.
emit_stream_tasks() {
  local total="$1" complete_up_to="$2" i
  echo '{"type":"system","subtype":"init","session_id":"mock"}'
  for i in $(seq 1 "$total"); do
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskCreate\",\"input\":{\"subject\":\"task $i\"}}]}}"
    echo "{\"type\":\"user\",\"tool_use_result\":{\"task\":{\"id\":\"$i\",\"subject\":\"task $i\"}}}"
  done
  for i in $(seq 1 "$total"); do
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"$i\",\"status\":\"in_progress\"}}]}}"
    echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"run\",\"description\":\"rodando os testes da task $i\"}}]}}"
    if [ "$i" -le "$complete_up_to" ]; then
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"$i\",\"status\":\"completed\"}}]}}"
    fi
  done
}

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
    # reset a dias (default 3): limite semanal, nao o de sessao (<= 5h)
    if [ "$n" -eq 1 ]; then
      emit_claude_limit "$(( $(date +%s) + ${MOCK_RESET_IN:-259200} ))"
      exit 1
    fi
    ;;
  limit-always)
    # o limite nunca libera: so o teto de esperas tira o run do loop
    echo "Rate limit reached. Try again later."
    exit 1
    ;;
  limit-stream)
    # stream-json real: conversa antes, limite no evento result com is_error
    if [ "$n" -eq 1 ]; then
      echo '{"type":"system","subtype":"init","session_id":"mock"}'
      echo '{"type":"assistant","message":{"content":[{"type":"text","text":"vou implementar a fase"}]}}'
      echo '{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You have hit your session limit"}'
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

if [ "$write" -eq 1 ]; then
  mkdir -p src
  echo "impl $n" > "src/impl-$n.txt"
fi

if [ "$scenario" = "false-429" ]; then
  # 429 no MEIO do log: e output de teste do projeto, nao limite de uso.
  echo "FAIL tests/HttpClientTest: expected 429 Too Many Requests, got 200"
  for i in $(seq 1 25); do echo "linha de ruido $i"; done
  echo "Suite corrigida. Done."
  exit 0
fi

if [ "$scenario" = "false-limit-claude" ]; then
  # A sessao escreveu um rate limiter, LEU uma fixture que cita o aviso de
  # limite e terminou bem: "429"/"rate limit"/"usage limit reached" aparecem em
  # mensagem do assistente, em tool_result e na resposta final — nunca num
  # evento result com is_error:true.
  emit_stream_tasks 2 2
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Rate limit reached responde 429 Too Many Requests; o teste cobre usage limit reached"}]}}'
  echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"12\tassertSee(\"Claude AI usage limit reached\")\n13\tassertSee(\"hit your session limit\")","is_error":false}]}}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"implementado; o teste cobre usage limit reached e 429"}'
  exit 0
fi

if [ "$name" = "claude" ]; then
  if [ "$outfmt" = "stream-json" ]; then
    n_tasks=$(grep -cE '^[[:space:]]*- \[[ x]\]' <<< "$prompt")
    if [ "$scenario" = "tool-error" ]; then
      # Uma ferramenta falhou no meio da sessao (grep sem match, teste
      # vermelho, arquivo inexistente): o tool_result vem com is_error=true.
      # E trabalho normal do agente — o engine terminou bem.
      emit_stream_tasks "$n_tasks" "$n_tasks"
      echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"grep: sail: No such file","is_error":true,"tool_use_id":"toolu_x"}]}}'
    elif [ "$scenario" = "stream-slow" ]; then
      # Para o exterior a sessao e uma caixa preta que demora: emite a 1a task
      # concluida e a 2a em andamento, SEGURA, e so entao termina. E a janela em
      # que o teste observa o painel a meio caminho.
      emit_stream_tasks 1 1
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskCreate\",\"input\":{\"subject\":\"task 2\"}}]}}"
      echo "{\"type\":\"user\",\"tool_use_result\":{\"task\":{\"id\":\"2\",\"subject\":\"task 2\"}}}"
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"2\",\"status\":\"in_progress\"}}]}}"
      touch "$state/slow_midpoint"
      sleep "${MOCK_SLOW_SECS:-4}"
      echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"TaskUpdate\",\"input\":{\"taskId\":\"2\",\"status\":\"completed\"}}]}}"
    else
      emit_stream_tasks "$n_tasks" "$n_tasks"
    fi
  fi
  emit_claude_ok
else
  echo "Done."
fi
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

if [ "$scenario" = "test-red-once" ] || [ "$scenario" = "stall-after-red" ]; then
  if [ "$n" -eq 1 ]; then
    echo "1 failing test: ExpectedFooTest"
    exit 1
  fi
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

  (
    cd "$dir/repo" || exit 1
    git init -q
    git config user.email "test@ralph"
    git config user.name "Ralph Test"
    mkdir -p .spec/init
    printf '%s' "$PHASES_FIXTURE" > .spec/init/project-phases.md
    git add -A
    git commit -q -m "chore: fixture"
  )
  echo "$dir"
}

# run_ralph <dir> <scenario> [args...] -> ecoa o exit code; log em <dir>/out.log
run_ralph() {
  local dir="$1" scenario="$2"; shift 2
  local rc=0
  # CASE_TIMEOUT: casos cuja regressao e dormir/loopar para sempre (limite
  # semanal, teto de esperas) viram vermelho em segundos em vez de travar.
  local wrap=()
  [ -n "${CASE_TIMEOUT:-}" ] && wrap=(timeout "$CASE_TIMEOUT")
  (
    cd "$dir/repo" || exit 1
    # -u RALPH_TEST_CMD / RALPH_MAX_CYCLES: o dev pode ter essas exportadas no
    # shell (ex: RALPH_TEST_CMD no .zshrc). Herda-las aqui sobrepoe a deteccao
    # por manifest e quebra os casos 13/16 com uma falha que nao existe no ralph.
    # RALPH_NOTIFY_CMD idem, e pior: um adaptador real exportado no shell
    # mandaria notificacao de verdade a cada caso. So CASE_NOTIFY_CMD liga.
    env -u RALPH_TEST_CMD -u RALPH_MAX_CYCLES -u RALPH_MAX_LIMIT_WAITS \
      -u RALPH_UI_SHOT_CMD -u RALPH_UI_VERIFY \
    PATH="$dir/bin:$PATH" \
    MOCK_STATE="$dir/state" \
    MOCK_SCENARIO="$scenario" \
    MOCK_TEST_CMD="$dir/test.sh" \
    RALPH_LIMIT_WAIT_DEFAULT="${CASE_LIMIT_WAIT:-1}" \
    RALPH_LIMIT_BUFFER=1 \
    RALPH_MAX_LIMIT_WAITS="${CASE_MAX_LIMIT_WAITS:-}" \
    RALPH_WEEKLY_THRESHOLD="${CASE_WEEKLY_THRESHOLD:-}" \
    RALPH_VERIFY="${CASE_VERIFY:-}" \
    RALPH_VERIFY_MODEL="${CASE_VERIFY_MODEL:-}" \
    RALPH_NOTIFY_CMD="${CASE_NOTIFY_CMD:-}" \
    RALPH_NOTIFY_TIMEOUT="${CASE_NOTIFY_TIMEOUT:-}" \
      ${wrap[@]+"${wrap[@]}"} bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

# Igual ao run_ralph, mas PRESERVA RALPH_TEST_CMD do chamador — para exercitar
# de proposito o caso em que a variavel do ambiente vence a deteccao.
run_ralph_env() {
  local dir="$1" scenario="$2"; shift 2
  local rc=0
  (
    cd "$dir/repo" || exit 1
    PATH="$dir/bin:$PATH" \
    MOCK_STATE="$dir/state" \
    MOCK_SCENARIO="$scenario" \
    MOCK_TEST_CMD="$dir/test.sh" \
    RALPH_LIMIT_WAIT_DEFAULT=1 \
    RALPH_LIMIT_BUFFER=1 \
    RALPH_NOTIFY_CMD='' \
      bash "$RALPH" "$@" > "$dir/out.log" 2>&1
  ) || rc=$?
  echo "$rc"
}

commits() { git -C "$1/repo" rev-list --count HEAD; }

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
  rc=$(run_ralph "$d" test-red-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
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
# 4. Verificador INCOMPLETE 1x -> ciclo -> DONE -> commit
# ---------------------------------------------------------------------------
if case_enabled verify-incomplete; then
  header "4. verificador INCOMPLETE uma vez -> ciclo -> DONE"
  d=$(new_case verify-incomplete)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "1 commit por fase"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reportado vermelho"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "TASK 1: INCOMPLETE" "prompt de correcao carrega as tasks incompletas verbatim"
  test -f "$d/repo/.phases/logs/phase-01.verify-1.log" && ok "log do verificador por ciclo" || bad "log do verificador por ciclo"
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
  # CASE_TIMEOUT: sem o corte semanal o ralph dormiria 3 dias
  rc=$(CASE_TIMEOUT=60 run_ralph "$d" limit-weekly --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (run encerrado, nao dormindo)"
  assert_contains "$d/out.log" "Limite semanal de uso" "classificou como semanal"
  assert_contains "$d/out.log" "Retome depois com: ./ralph.sh .spec/init/project-phases.md --engine claude --from 1" "devolveu o comando de retomada"
  assert_eq 1 "$(cat "$d/state/impl_calls")" "nao re-executou a fase"
  # commits() conta o commit de fixture: 1 = nenhuma fase commitada
  assert_eq 1 "$(commits "$d")" "nenhuma fase commitada — parou na primeira"

  # O limiar vem de RALPH_WEEKLY_THRESHOLD: reset a 10min com limiar de 1min
  # tambem encerra (com o default de 6h, dormiria).
  d=$(new_case limit-weekly-threshold)
  rc=$(MOCK_RESET_IN=600 CASE_WEEKLY_THRESHOLD=60 CASE_TIMEOUT=60 \
    run_ralph "$d" limit-weekly --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "limiar configurado: exit 1"
  assert_contains "$d/out.log" "Acima do limiar de 1m 0s" "limiar configurado respeitado"
fi

# ---------------------------------------------------------------------------
# 5c. Limite que nunca libera -> teto de esperas aborta (nao dorme para sempre)
# ---------------------------------------------------------------------------
if case_enabled limit-cap; then
  header "5c. teto de esperas por limite -> aborta com motivo"
  d=$(new_case limit-cap)
  rc=$(CASE_MAX_LIMIT_WAITS=2 CASE_TIMEOUT=60 \
    run_ralph "$d" limit-always --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (abortou, sem timeout)"
  assert_contains "$d/out.log" "Limite de uso atingido 3 vezes seguidas nesta fase (cap: 2)" "motivo do abort com o teto"
  assert_contains "$d/out.log" "Abortando em vez de dormir indefinidamente" "mensagem de abort"
  assert_eq 3 "$(cat "$d/state/impl_calls")" "2 esperas + a 3a sessao que estourou o teto"
  assert_eq 1 "$(commits "$d")" "nenhuma fase commitada"
fi

# ---------------------------------------------------------------------------
# 5d. claude stream-json: limite no result com is_error -> espera -> mesma fase
# ---------------------------------------------------------------------------
if case_enabled limit-stream; then
  header "5d. limite no evento result (is_error:true) apos conversa -> espera"
  d=$(new_case limit-stream)
  rc=$(run_ralph "$d" limit-stream --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (limite nao consome ciclo)"
  assert_contains "$d/out.log" "Limite de uso atingido" "limite detectado no result"
  assert_contains "$d/out.log" "Espera 1/" "esperou uma vez"
  assert_eq 3 "$(cat "$d/state/impl_calls")" "fase 1 re-executada (2) + fase 2 (1)"
  assert_eq 3 "$(commits "$d")" "fases commitadas apos a espera"
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
  # Espera de fallback longa SO neste caso: com o default de 1s do helper, uma
  # espera falsa custava 1s e o limite de tempo media overhead de processo, nao
  # espera (flake em maquina carregada). Com 60s, uma espera falsa estoura o
  # limite de 30s com folga e o overhead normal nunca chega perto.
  start=$(date +%s)
  rc=$(CASE_LIMIT_WAIT=60 CASE_TIMEOUT=90 run_ralph "$d" false-429 --engine codex --test-cmd "$d/test.sh" --max-cycles 1)
  elapsed=$(($(date +%s) - start))
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Limite de uso atingido" "nao interpretou 429 de teste como limite"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "429 Too Many Requests" "o 429 realmente estava no log"
  [ "$elapsed" -lt 30 ] && ok "sem espera (${elapsed}s)" || bad "sem espera (${elapsed}s)"
fi

# ---------------------------------------------------------------------------
# 7b. claude: aviso de limite em conversa/tool_result/result ok -> NAO espera
# ---------------------------------------------------------------------------
if case_enabled false-limit-claude; then
  header "7b. claude: limite citado fora de result is_error nao dispara espera"
  d=$(new_case false-limit-claude)
  rc=$(run_ralph "$d" false-limit-claude --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0"
  assert_not_contains "$d/out.log" "Limite de uso atingido" "nao interpretou texto da sessao como limite"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "usage limit reached" "o aviso realmente estava no log"
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" "429 Too Many Requests" "o 429 realmente estava no log"
  assert_eq 2 "$(cat "$d/state/impl_calls")" "1 sessao por fase, sem re-execucao"
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
# 18. Fase falhou -> avisa que o trabalho parcial ficou na arvore
# ---------------------------------------------------------------------------
if case_enabled dirty-after-fail; then
  header "18. fase falhou com trabalho na arvore -> instrui o dev"
  d=$(new_case dirty-after-fail)
  # verify-incomplete-once com 1 ciclo: escreve, testes verdes, verificador reprova
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
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
  header "20. RALPH_VERIFY=auto pula o gate 3 no caminho feliz"
  d=$(new_case verify-auto)
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq 3 "$(commits "$d")" "fases commitadas"
  assert_contains "$d/out.log" "Gate 3 pulado: a sessao escreveu codigo" "skip logado com a causa"
  test -f "$d/state/verify_calls" && bad "nenhuma sessao verificadora gasta" || ok "nenhuma sessao verificadora gasta"
fi

# ---------------------------------------------------------------------------
# 21. Verificador roda com modelo barato: sonnet por default no claude,
#     RALPH_VERIFY_MODEL sobrepoe.
# ---------------------------------------------------------------------------
if case_enabled verify-model; then
  header "21. verificador usa modelo barato (sonnet default, env sobrepoe)"
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
  rc=$(run_ralph "$d" ok --engine claude)   # sem --test-cmd: exercita a deteccao
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
# 22. Estado observavel publicado: fases E tasks, com os titulos reais
# ---------------------------------------------------------------------------
if case_enabled state-published; then
  header "22. estado publicado em .phases/state/run.tsv"
  d=$(new_case state-published)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  s="$d/repo/.phases/state/run.tsv"
  test -f "$s" && ok "run.tsv criado" || bad "run.tsv criado"
  assert_contains "$s" "$(printf 'META\tstatus\tfinished')" "status final do run"
  assert_contains "$s" "$(printf 'META\tengine\tclaude')" "engine no estado"
  assert_contains "$s" "$(printf 'PHASE\t1\tdone')" "fase 1 concluida"
  assert_contains "$s" "$(printf 'PHASE\t2\tdone')" "fase 2 concluida"
  # o titulo da task vem do item `- [ ]`, sem o ruido de markdown
  assert_contains "$s" "$(printf 'TASK\t1\t1\tdone\tcria o arquivo A')" "task 1 da fase 1 com titulo limpo"
  assert_contains "$s" "$(printf 'TASK\t1\t2\tdone\tcria o arquivo B')" "task 2 da fase 1"
  assert_contains "$s" "$(printf 'TASK\t2\t1\tdone\tcria o arquivo C')" "task da fase 2"
  assert_not_contains "$s" '**Task:**' "markdown removido do titulo"
fi

# ---------------------------------------------------------------------------
# 23. Watcher do stream traduz a lista de tarefas do agente (teste de unidade)
#     E o mecanismo que da progresso por task: sem ele o painel so sabe
#     "fase em execucao".
# ---------------------------------------------------------------------------
if case_enabled stream-watch; then
  header "23. watcher traduz TaskCreate/TaskUpdate do stream em estado por task"
  d="$TMP/stream-watch"
  mkdir -p "$d"

  # Stream com 3 tarefas: a 1a concluida, a 2a em andamento, a 3a intocada.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"alfa"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"1","subject":"alfa"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"beta"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"2","subject":"beta"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"gama"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"3","subject":"gama"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test","description":"rodando a suite"}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    stream_watch "$d/live.tsv" 7 1 < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'PHASE\t7')" "live.tsv aponta a fase corrente"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 concluida"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 em execucao"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\tpending')" "task 3 ainda pendente"
  assert_contains "$d/live.tsv" "rodando a suite" "atividade corrente vem do tool_use"
fi

# ---------------------------------------------------------------------------
# 24. Veredito do gate 3 sobrepoe o que a sessao achou que fez: a task que o
#     verificador reprovou fica INCOMPLETE no estado, nao "concluida".
# ---------------------------------------------------------------------------
if case_enabled state-verify-truth; then
  header "24. gate 3 corrige o status por task no estado"
  d=$(new_case state-verify-truth)
  rc=$(run_ralph "$d" verify-incomplete-once --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 (fase reprovada pelo gate 3)"
  s="$d/repo/.phases/state/run.tsv"
  assert_contains "$s" "$(printf 'TASK\t1\t1\tincomplete')" "task reprovada pelo verificador"
  assert_contains "$s" "$(printf 'TASK\t1\t2\tdone')" "task aprovada pelo verificador"
  assert_contains "$s" "$(printf 'PHASE\t1\tfailed')" "fase marcada como falha"
  assert_contains "$s" "$(printf 'META\tstatus\tfailed')" "run marcado como falho"
fi

# ---------------------------------------------------------------------------
# 25. ralph-watch.sh --once renderiza o estado de um run real
# ---------------------------------------------------------------------------
if case_enabled watch-render; then
  header "25. ralph-watch.sh --once renderiza o painel"
  d=$(new_case watch-render)
  run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" > /dev/null
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1
  assert_eq 0 "$?" "renderizou sem erro"
  assert_contains "$d/panel.txt" "RALPH" "cabecalho"
  assert_contains "$d/panel.txt" "Foundation" "titulo da fase 1"
  assert_contains "$d/panel.txt" "cria o arquivo A" "titulo da task"
  assert_contains "$d/panel.txt" "Concluída" "status por linha"
  assert_contains "$d/panel.txt" "G0" "coluna de gates"

  # sem estado nenhum -> erro claro, nao stack trace
  mkdir -p "$TMP/empty-repo"
  "$ROOT/scripts/ralph-watch.sh" --once --no-color "$TMP/empty-repo" > "$d/empty.txt" 2>&1
  rc=$?
  assert_eq 1 "$rc" "sai 1 sem estado"
  assert_contains "$d/empty.txt" "Nenhum estado" "mensagem de estado ausente"
fi

# ---------------------------------------------------------------------------
# 26. --dashboard sem o ralph-watch.sh ao lado -> degrada com aviso, nao morre
#     (o ralph.sh continua sendo copiavel sozinho para outro repo)
# ---------------------------------------------------------------------------
if case_enabled dashboard-degrade; then
  header "26. --dashboard sem ralph-watch.sh -> aviso e segue"
  d=$(new_case dashboard-degrade)
  cp "$RALPH" "$d/ralph-solo.sh"
  rc=$(RALPH="$d/ralph-solo.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --dashboard)
  assert_eq 0 "$rc" "exit 0 (run completo mesmo sem o painel)"
  assert_contains "$d/out.log" "nao existe" "avisou que o painel nao esta disponivel"
  assert_contains "$d/out.log" "estado continua publicado" "apontou o caminho alternativo"
  assert_eq 3 "$(commits "$d")" "fases commitadas normalmente"
fi

# ---------------------------------------------------------------------------
# 27. O requisito central: DURANTE a fase, com a sessao ainda aberta, a task 1
#     aparece concluida, a task 2 em execucao e a FASE em execucao. Sem isto o
#     progresso so apareceria de uma vez, no fim da fase.
# ---------------------------------------------------------------------------
if case_enabled live-progress; then
  header "27. progresso por task visivel com a fase ainda em execucao"
  d=$(new_case live-progress)

  (
    cd "$d/repo" || exit 1
    env -u RALPH_TEST_CMD -u RALPH_MAX_CYCLES -u RALPH_NOTIFY_CMD \
    PATH="$d/bin:$PATH" MOCK_STATE="$d/state" MOCK_SCENARIO=stream-slow \
    MOCK_TEST_CMD="$d/test.sh" MOCK_SLOW_SECS=6 RALPH_VERIFY=off \
      bash "$RALPH" --engine claude --test-cmd "$d/test.sh" > "$d/out.log" 2>&1
  ) &
  ralph_pid=$!

  # Espera o mock anunciar que esta no meio da fase, entao fotografa o estado.
  snap=""
  for _ in $(seq 1 100); do
    if [ -f "$d/state/slow_midpoint" ]; then
      sleep 0.5
      snap=$(cat "$d/repo/.phases/state/live.tsv" 2>/dev/null)
      break
    fi
    sleep 0.2
  done

  phase_snap=$(grep -E '^PHASE[[:space:]]+1[[:space:]]' "$d/repo/.phases/state/run.tsv" 2>/dev/null || true)
  panel=$(RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" 2>&1 || true)

  wait "$ralph_pid" 2>/dev/null
  ralph_rc=$?

  printf '%s\n' "$snap" > "$d/snap.tsv"
  printf '%s\n' "$panel" > "$d/panel-live.txt"

  assert_contains "$d/snap.tsv" "$(printf 'LIVE\t1\tdone')" "no meio da fase: task 1 ja concluida"
  assert_contains "$d/snap.tsv" "$(printf 'LIVE\t2\trunning')" "no meio da fase: task 2 em execucao"
  case "$phase_snap" in
    *running*) ok "no meio da fase: a fase segue em execucao" ;;
    *)         bad "no meio da fase: a fase segue em execucao (veio '$phase_snap')" ;;
  esac
  # o painel renderizado no mesmo instante mostra os tres estados juntos
  assert_contains "$d/panel-live.txt" "Em execução" "painel mostra algo em execucao"
  assert_contains "$d/panel-live.txt" "Concluída" "painel mostra a task ja concluida"
  assert_eq 0 "$ralph_rc" "o run terminou verde depois disso"
fi

# ---------------------------------------------------------------------------
# 28. REGRESSAO: ferramenta que falha DENTRO da sessao nao pode reprovar o
#     gate 0. Com stream-json o log carrega a conversa inteira, e um
#     tool_result de comando que retornou != 0 traz "is_error":true — varrer o
#     log todo reprovava a fase por causa de um grep sem match.
# ---------------------------------------------------------------------------
if case_enabled gate0-tool-error; then
  header "28. tool_result com is_error nao reprova o gate 0"
  d=$(new_case gate0-tool-error)
  rc=$(run_ralph "$d" tool-error --engine claude --test-cmd "$d/test.sh" --max-cycles 1)
  assert_eq 0 "$rc" "exit 0 (o engine terminou bem)"
  assert_not_contains "$d/out.log" "Gate 0 vermelho" "gate 0 nao reprovou"
  assert_eq 3 "$(commits "$d")" "fases commitadas"
  # o log realmente continha o is_error da ferramenta
  assert_contains "$d/repo/.phases/logs/phase-01.cycle-1.log" '"is_error":true' "o tool_result com erro estava no log"
fi

# ---------------------------------------------------------------------------
# 29. Comando de teste inexistente -> abort no preflight, zero tokens.
#     Caso real: RALPH_TEST_CMD com sail exportado no shell do dev vence a
#     deteccao em QUALQUER projeto; sem este check, todo gate 2 falhava e
#     queimava os 3 ciclos de cada fase.
# ---------------------------------------------------------------------------
if case_enabled test-cmd-missing; then
  header "29. comando de teste inexistente -> abort no preflight"
  d=$(new_case test-cmd-missing)
  rc=$(RALPH_TEST_CMD="vendor/bin/sail composer test:parallel" \
       run_ralph_env "$d" ok --engine claude)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "nao executavel" "abortou com a causa"
  assert_contains "$d/out.log" "RALPH_TEST_CMD" "identificou a origem do comando"
  assert_contains "$d/out.log" "env -u RALPH_TEST_CMD" "deu a saida"
  assert_eq 1 "$(commits "$d")" "nenhum commit de fase"
  test -f "$d/state/impl_calls" && bad "nenhuma sessao de engine iniciada" || ok "nenhuma sessao de engine iniciada"
fi

# ---------------------------------------------------------------------------
# 30. Modelo que NAO usa a lista de tarefas: o painel ainda mostra progresso,
#     inferido dos arquivos que o agente escreve. Sem a reserva, uma fase
#     inteira ficava com todas as tasks "pendentes".
# ---------------------------------------------------------------------------
if case_enabled task-fallback; then
  header "30. progresso inferido quando o agente nao usa a lista de tarefas"
  d="$TMP/task-fallback"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-07.md" <<'PH'
## Phase 7: Exemplo

- [ ] **Task:** criar `src/Money.php` com a classe Money
- [ ] **Task:** criar `tests/MoneyTest.php` cobrindo Money
- [ ] **Task:** atualizar o README
PH

  # Stream sem NENHUM TaskCreate/TaskUpdate — so escrita de arquivos.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"system","subtype":"init","session_id":"x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/tests/MoneyTest.php","content":"..."}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 7 1 phase-07.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 dada por concluida ao passar para a seguinte"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 em execucao (arquivo sendo escrito)"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t3\t')" "task 3 intocada continua fora do estado"

  # E quando o agente USA a lista, ela manda: a inferencia e descartada.
  cat > "$d/stream2.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"criar Money"}}]}}
{"type":"user","tool_use_result":{"task":{"id":"1","subject":"criar Money"}}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live2.tsv" 7 1 phase-07.md < "$d/stream2.jsonl" > /dev/null
  )
  assert_contains "$d/live2.tsv" "$(printf 'LIVE\t1\trunning')" "a lista do agente sobrepoe a inferencia"
fi

# ---------------------------------------------------------------------------
# 31. REGRESSAO: task do MEIO que nao cita arquivo nenhum. Caso real — "adicionar
#     as operacoes plus/minus/times a App\Money" acontece dentro do arquivo da
#     task anterior. Ela nao pode ficar pendente ate o fim da fase e depois
#     saltar direto para concluida, como se nunca tivesse rodado.
# ---------------------------------------------------------------------------
if case_enabled task-fallback-middle; then
  header "31. task do meio sem arquivo proprio nao fica para tras"
  d="$TMP/task-fallback-middle"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-09.md" <<'PH'
## Phase 9: Money

- [ ] **Task:** criar `src/Money.php` com a classe `App\Money`
- [ ] **Task:** adicionar as operações `plus`, `minus` e `times` a `App\Money`
- [ ] **Task:** criar `tests/MoneyTest.php` cobrindo `App\Money`
PH

  # O agente escreveu 2 arquivos para 3 tasks — exatamente o run real.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/src/Money.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/tests/MoneyTest.php","content":"..."}}]}}
{"type":"result","subtype":"success","is_error":false}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 9 1 phase-09.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 concluida"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\tdone')" "task 2 (sem arquivo proprio) NAO ficou pendente"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 em execucao"
fi

# ---------------------------------------------------------------------------
# 32. A barra de tasks mede o run inteiro, nao so a fase corrente.
# ---------------------------------------------------------------------------
if case_enabled watch-task-total; then
  header "32. barra de tasks conta todas as fases"
  d=$(new_case watch-task-total)
  run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" > /dev/null
  # fixture: fase 1 com 2 tasks + fase 2 com 1 task = 3 no total
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1
  assert_contains "$d/panel.txt" "Tasks  3/3" "total soma as tasks de todas as fases"
  assert_contains "$d/panel.txt" "Fases  2/2" "total de fases"
fi

# ---------------------------------------------------------------------------
# 33. Plano grande: o painel cabe na altura do terminal, o topo NAO some e a
#     janela da tabela segue a fase corrente.
#     Estado sintetico: o painel e um leitor puro, entao basta escrever o TSV.
# ---------------------------------------------------------------------------
if case_enabled watch-scroll; then
  header "33. janela rolante mantem o cabecalho e segue a fase corrente"
  d="$TMP/watch-scroll"
  mkdir -p "$d/repo/.phases/state"
  {
    printf 'META\tproject\tbig\n'
    printf 'META\tengine\tclaude\n'
    printf 'META\tstatus\trunning\n'
    printf 'META\tstarted\t%s\n' "$(date +%s)"
    printf 'META\trun\ttest-run\n'
    printf 'META\tpid\t1\n'
    printf 'META\tphase_cur\t8\n'
    for p in $(seq 1 12); do
      st=pending; gates="pending pending pending pending"
      [ "$p" -lt 8 ] && { st=done; gates="pass pass pass pass"; }
      [ "$p" -eq 8 ] && { st=running; gates="pass pass run pending"; }
      printf 'PHASE\t%s\t%s\t1\t%s\tFase numero %s\n' "$p" "$st" "$gates" "$p"
      for t in $(seq 1 4); do
        tst=pending
        [ "$p" -lt 8 ] && tst=done
        printf 'TASK\t%s\t%s\t%s\tTask %s da fase %s\n' "$p" "$t" "$tst" "$t" "$p"
      done
    done
  } > "$d/repo/.phases/state/run.tsv"

  RALPH_WATCH_COLS=110 RALPH_WATCH_LINES=30 \
    "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/panel.txt" 2>&1

  lines=$(wc -l < "$d/panel.txt")
  if [ "$lines" -le 30 ]; then ok "painel cabe em 30 linhas ($lines)"
  else bad "painel estourou a altura ($lines linhas para 30)"; fi

  assert_contains "$d/panel.txt" "RALPH" "cabecalho continua visivel"
  assert_contains "$d/panel.txt" "Fases  7/12" "barra de progresso continua visivel"
  assert_contains "$d/panel.txt" "Fase numero 8" "fase corrente dentro da janela"
  assert_contains "$d/panel.txt" "acima" "rodape indica o que ficou fora"
  assert_not_contains "$d/panel.txt" "Fase numero 1 " "fase distante ficou fora da janela"

  # sem altura fixada, --once segue sendo dump completo (contrato dos scripts)
  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/full.txt" 2>&1
  assert_contains "$d/full.txt" "Fase numero 1 " "dump completo mantem a primeira fase"
  assert_contains "$d/full.txt" "Fase numero 12" "dump completo mantem a ultima fase"

  # plano curto: sem corte, sem rodape de rolagem
  RALPH_WATCH_COLS=110 RALPH_WATCH_LINES=80 \
    "$ROOT/scripts/ralph-watch.sh" --once --no-color "$d/repo" > "$d/tall.txt" 2>&1
  assert_contains "$d/tall.txt" "Fase numero 1 " "terminal alto mostra tudo"
  assert_not_contains "$d/tall.txt" "acima ·" "sem rodape de rolagem quando tudo cabe"
fi

# ---------------------------------------------------------------------------
# 34. A linha em execucao fica realcada de ponta a ponta.
#     \033[0m zera tambem o fundo: sem reinjetar o realce depois de cada reset,
#     o destaque pintava so o primeiro separador e sumia na pratica.
# ---------------------------------------------------------------------------
if case_enabled watch-hilite; then
  header "34. realce da linha em execucao cobre a linha inteira"
  d="$TMP/watch-hilite"
  mkdir -p "$d/repo/.phases/state"
  {
    printf 'META\tproject\thl\n'
    printf 'META\tstatus\trunning\n'
    printf 'META\tstarted\t%s\n' "$(date +%s)"
    printf 'META\tphase_cur\t2\n'
    printf 'PHASE\t1\tdone\t1\tpass pass pass pass\tFase pronta\n'
    printf 'TASK\t1\t1\tdone\tTask pronta\n'
    printf 'PHASE\t2\trunning\t1\tpass pass run pending\tFase viva\n'
    printf 'TASK\t2\t1\tdone\tTask pronta da fase viva\n'
    printf 'TASK\t2\t2\trunning\tTask em execucao agora\n'
    printf 'PHASE\t3\tpending\t0\tpending pending pending pending\tFase futura\n'
  } > "$d/repo/.phases/state/run.tsv"

  RALPH_WATCH_COLS=110 "$ROOT/scripts/ralph-watch.sh" --once --color "$d/repo" > "$d/color.txt" 2>&1

  # Cada reset dentro da linha e seguido de um novo realce; o unico reset sem
  # realce depois e o do fim da linha. Logo: #realces == #resets.
  # tail -1: "Fase viva" tambem aparece no painel TRABALHO ATUAL, acima da
  # tabela — a linha que interessa e a ultima.
  hl_balanced() { # <trecho da linha> -> "resets realces"
    grep -a "$1" "$d/color.txt" | tail -1 \
      | awk 'BEGIN{esc=sprintf("%c",27)}
             { r=gsub(esc"\\[0m",""); h=gsub(esc"\\[48;5;53m",""); print r" "h }'
  }

  assert_eq "$(echo "$(hl_balanced 'Fase viva')" | cut -d' ' -f1)" \
            "$(echo "$(hl_balanced 'Fase viva')" | cut -d' ' -f2)" \
            "fase em execucao: realce reaplicado apos cada reset"
  assert_eq "$(echo "$(hl_balanced 'Task em execucao agora')" | cut -d' ' -f1)" \
            "$(echo "$(hl_balanced 'Task em execucao agora')" | cut -d' ' -f2)" \
            "task em execucao: realce reaplicado apos cada reset"

  # o realce nao vaza para as linhas paradas
  assert_eq "0" "$(echo "$(hl_balanced 'Fase futura')" | cut -d' ' -f2)" \
            "linha pendente sem realce"
  assert_eq "0" "$(echo "$(hl_balanced 'Task pronta da fase viva')" | cut -d' ' -f2)" \
            "task concluida sem realce"

  # mais de um caractere realcado: o bug antigo pintava so o separador inicial
  wide=$(grep -a "Task em execucao agora" "$d/color.txt" | tail -1 \
    | awk 'BEGIN{esc=sprintf("%c",27)} { print gsub(esc"\\[48;5;53m","") }')
  if [ "${wide:-0}" -ge 4 ]; then ok "realce atravessa as colunas da linha ($wide trechos)"
  else bad "realce cobriu poucos trechos da linha (${wide:-0})"; fi
fi

# ---------------------------------------------------------------------------
# 35. REGRESSAO (run real): sessao headless sem NENHUMA ferramenta de lista de
#     tarefas — o agente tenta carregar TaskCreate/TodoWrite com ToolSearch e
#     elas nao existem. O progresso tem que sair dos arquivos que a propria
#     task declara em "Arquivos:", senao a fase inteira fica "Pendente" e so
#     muda no gate 3.
# ---------------------------------------------------------------------------
if case_enabled live-declared-files; then
  header "35. progresso pelos arquivos declarados, sem lista de tarefas"
  d="$TMP/live-declared-files"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-02.md" <<'PH'
## Phase 2: Schema, model e escrita

Espelhar `app/Models/ProductFiscalSetting.php` e `app/Services/Catalog/SaveProductFiscalSettingsService.php`.

- [ ] T03 — Migração `service_fiscal_settings` (aditiva)
      Arquivos: `database/migrations/tenant/2026_08_15_120000_create_service_fiscal_settings_table.php`
      Mudança: `iss_rate` `decimal(5,2)` como em `services.iss_rate`
- [ ] T04 — Model `ServiceFiscalSetting`, factory e relação
      Arquivos: `app/Models/ServiceFiscalSetting.php`, `database/factories/ServiceFiscalSettingFactory.php`
      Mudança: espelha `app/Models/ProductFiscalSetting.php`
- [ ] T05 — `SaveServiceFiscalSettingsService`
      Arquivos: `app/Services/Catalog/SaveServiceFiscalSettingsService.php`
- [ ] T06 — Testes
      Arquivos: `tests/Feature/Catalog/ServiceFiscalSettingsTest.php`
PH

  # Stream do run real: ToolSearch nao acha lista de tarefas; so Read/Edit/Write.
  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:TaskCreate,TaskUpdate"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"ToolSearch","input":{"query":"select:TodoWrite"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/repo/app/Models/ProductFiscalSetting.php"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/database/migrations/tenant/2026_08_15_120000_create_service_fiscal_settings_table.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Models/ServiceFiscalSetting.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Services/Catalog/SaveServiceFiscalSettingsService.php","content":"..."}}]}}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 2 1 phase-02.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 (migração) concluida"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\tdone')" "task 2 (model) concluida"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 (service) em execucao"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t4\tdone')" "task 4 (testes) ainda nao concluida"

  # o Read do arquivo-espelho citado no preambulo nao pode empurrar o progresso
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    head -3 "$d/stream.jsonl" | stream_watch "$d/early.tsv" 2 1 phase-02.md > /dev/null
  )
  assert_contains "$d/early.tsv" "$(printf 'LIVE\t1\trunning')" "antes da 1a escrita: task 1 em execucao"
  assert_not_contains "$d/early.tsv" "$(printf 'LIVE\t2\t')" "leitura de arquivo-espelho nao promove task"
fi

# ---------------------------------------------------------------------------
# 36. Protocolo textual: o agente anuncia a task em linhas RALPH-TASK. Nao
#     depende de ferramenta nenhuma, entao funciona em sessao headless — e tem
#     precedencia sobre o palpite baseado em arquivo.
# ---------------------------------------------------------------------------
if case_enabled live-markers; then
  header "36. marcadores RALPH-TASK comandam o progresso"
  d="$TMP/live-markers"
  mkdir -p "$d/.phases"

  cat > "$d/.phases/phase-03.md" <<'PH'
## Phase 3: API

- [ ] T01 — Endpoint de leitura
      Arquivos: `app/Http/Controllers/ReadController.php`
- [ ] T02 — Endpoint de escrita
      Arquivos: `app/Http/Controllers/WriteController.php`
- [ ] T03 — Testes de contrato
      Arquivos: `tests/Feature/ApiContractTest.php`
PH

  cat > "$d/stream.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"Vou começar.\n\nRALPH-TASK 1 START"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/app/Http/Controllers/ReadController.php","content":"..."}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 1 DONE"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 2 START"}]}}
STREAM

  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/live.tsv" 3 1 phase-03.md < "$d/stream.jsonl" > /dev/null
  )

  assert_contains "$d/live.tsv" "$(printf 'LIVE\t1\tdone')" "task 1 fechada pelo marcador DONE"
  assert_contains "$d/live.tsv" "$(printf 'LIVE\t2\trunning')" "task 2 aberta pelo marcador START"
  assert_not_contains "$d/live.tsv" "$(printf 'LIVE\t3\t')" "task 3 intocada"

  # marcador de START pula tasks: as anteriores contam como feitas
  cat > "$d/jump.jsonl" <<'STREAM'
{"type":"assistant","message":{"content":[{"type":"text","text":"RALPH-TASK 3 START"}]}}
STREAM
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/jump.tsv" 3 1 phase-03.md < "$d/jump.jsonl" > /dev/null
  )
  assert_contains "$d/jump.tsv" "$(printf 'LIVE\t2\tdone')" "START da task 3 fecha as anteriores"
  assert_contains "$d/jump.tsv" "$(printf 'LIVE\t3\trunning')" "task 3 em execucao"

  # o texto do PROMPT usa <n> literal: nunca pode virar um marcador
  cat > "$d/prompt.jsonl" <<'STREAM'
{"type":"user","message":{"content":"    RALPH-TASK <n> START     antes de comecar o item n"}}
STREAM
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY
    # shellcheck disable=SC1090
    source "$RALPH" 2>/dev/null
    set +e
    PHASES_DIR="$d/.phases"
    stream_watch "$d/prompt.tsv" 3 1 phase-03.md < "$d/prompt.jsonl" > /dev/null
  )
  assert_contains "$d/prompt.tsv" "$(printf 'LIVE\t1\trunning')" "eco do prompt nao move o progresso"
  assert_not_contains "$d/prompt.tsv" "$(printf 'LIVE\t2\t')" "eco do prompt nao cria tasks"
fi

# ---------------------------------------------------------------------------
# 37. REGRESSAO do desenho: o quadro nunca pode rolar a tela nem deixar pedaco
#     do quadro anterior por baixo do novo.
#
#     Os dois defeitos eram um mecanismo em cadeia. Primeiro o quadro estourava
#     a altura (o piso de 3 linhas de tabela mantinha 20 linhas de painel mesmo
#     numa tela de 12) e o terminal ROLAVA. Dali em diante o \033[H escrevia numa
#     tela deslocada, e como o \033[J so limpa do fim do quadro para baixo, as
#     tres linhas em branco do cabecalho e o "RALPH" — curto — nao apagavam o que
#     havia embaixo: o topo ficava com um "RALPHks 19/32", metade quadro novo e
#     metade quadro velho, ate alguem redimensionar a janela.
# ---------------------------------------------------------------------------
if case_enabled watch-frame; then
  header "37. o quadro respeita a altura da tela e limpa cada linha"
  WATCH="$ROOT/scripts/ralph-watch.sh"

  # -- unidade: clamp_lines nunca devolve mais linhas do que o teto ------------
  (
    RALPH_LIB_ONLY=1
    export RALPH_LIB_ONLY RALPH_WATCH_COLS=110
    # shellcheck disable=SC1090
    source "$WATCH" 2>/dev/null
    out=""
    clamp_lines out "$(printf 'a\nb\nc\nd\ne')" 3
    printf '%s' "$out" > "$TMP/clamp3.txt"
    clamp_lines out "$(printf 'a\nb')" 9
    printf '%s' "$out" > "$TMP/clamp9.txt"
  )
  n=$(wc -l < "$TMP/clamp3.txt")
  # 3 linhas sem \n final = 2 quebras: e o que ocupa exatamente 3 linhas da tela
  if [ "$n" -eq 2 ]; then ok "clamp_lines corta no teto de linhas"
  else bad "clamp_lines devolveu $n quebras, esperado 2"; fi
  assert_contains "$TMP/clamp3.txt" "c" "clamp_lines mantem as linhas de cima"
  assert_not_contains "$TMP/clamp3.txt" "d" "clamp_lines descarta o excedente"
  assert_contains "$TMP/clamp9.txt" "b" "clamp_lines nao mexe no que ja cabe"

  # -- integracao: painel real num terminal baixo -----------------------------
  # tmux e o unico jeito de ver a tela como o terminal a monta (rolagem inclusa).
  # Ausencia nao falha o check, mesma politica do shellcheck no check-shell.sh.
  if command -v tmux > /dev/null 2>&1; then
    d="$TMP/watch-frame"
    mkdir -p "$d/repo/.phases/state"
    {
      printf 'META\tproject\tframe\n'
      printf 'META\tengine\tclaude\n'
      printf 'META\tstatus\trunning\n'
      printf 'META\tstarted\t%s\n' "$(date +%s)"
      printf 'META\trun\tframe-run\n'
      printf 'META\tpid\t1\n'
      printf 'META\tphase_cur\t1\n'
      for p in $(seq 1 10); do
        printf 'PHASE\t%s\trunning\t1\tpass pass run pending\tFase numero %s\n' "$p" "$p"
        for t in $(seq 1 3); do
          printf 'TASK\t%s\t%s\tpending\tTask %s da fase %s\n' "$p" "$t" "$t" "$p"
        done
      done
    } > "$d/repo/.phases/state/run.tsv"

    # --embedded desenha na tela normal, sem tela alternativa: e o modo do
    # --dashboard e o unico onde o pane guarda o que foi realmente desenhado.
    tmux kill-session -t ralph-frame-test 2>/dev/null || true
    tmux new-session -d -s ralph-frame-test -x 120 -y 16 \
      "bash '$WATCH' --embedded --interval 1 '$d/repo'" 2>/dev/null || true
    sleep 4
    tmux capture-pane -p -t ralph-frame-test > "$d/pane.txt" 2>/dev/null || true
    tmux kill-session -t ralph-frame-test 2>/dev/null || true

    # O topo do painel tem de estar no topo da TELA. Rolagem empurra o "RALPH"
    # para fora e a primeira linha passa a ser um trecho do meio do quadro.
    if [ -s "$d/pane.txt" ]; then
      head_txt=$(head -3 "$d/pane.txt")
      if printf '%s' "$head_txt" | grep -q 'RALPH'; then
        ok "tela baixa: o topo do painel nao rolou para fora"
      else
        bad "tela baixa: o topo rolou (primeiras linhas: $(head -1 "$d/pane.txt" | cut -c1-40))"
      fi
      lines=$(grep -c '' "$d/pane.txt")
      if [ "$lines" -le 16 ]; then ok "tela baixa: painel dentro das 16 linhas ($lines)"
      else bad "tela baixa: painel ocupou $lines linhas de 16"; fi
    else
      ok "tmux nao devolveu pane (ambiente sem tty) — integracao pulada"
    fi
  else
    ok "tmux ausente — integracao do quadro pulada"
  fi
fi

# ---------------------------------------------------------------------------
# Notificacao externa (RALPH_NOTIFY_CMD)
# ---------------------------------------------------------------------------

# make_notify_recorder <script> <events_file> -> adaptador fake que grava uma
# linha por evento: evento|projeto|fase|total|ciclo|max|g0|g2|g3|outcome|run|log|msg
make_notify_recorder() {
  cat > "$1" <<RECORDER
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "\$1" "\${RALPH_PROJECT:-}" \
  "\${RALPH_PHASE_NUM:-}" "\${RALPH_PHASE_TOTAL:-}" "\${RALPH_PHASE_ATTEMPT:-}" \
  "\${RALPH_PHASE_MAX_ATTEMPTS:-}" "\${RALPH_GATE0:-}" "\${RALPH_GATE2:-}" \
  "\${RALPH_GATE3:-}" "\${RALPH_OUTCOME:-}" "\${RALPH_RUN_ID:-}" \
  "\${RALPH_LOG_PATH:-}" "\${2:-}" >> "$2"
RECORDER
  chmod +x "$1"
  : > "$2"
}

# Mensagem pode ter mais de uma linha (causa do phase_failed): so as linhas que
# abrem com <evento>| contam.
event_seq() { grep -oE '^[a-z_]+\|' "$1" | tr -d '|' | tr '\n' ' ' | sed 's/ $//'; }

# ---------------------------------------------------------------------------
# 38. Sem RALPH_NOTIFY_CMD nada e chamado. Sonda: um `timeout` fake no PATH —
#     o notify so o invoca quando ha comando configurado.
# ---------------------------------------------------------------------------
if case_enabled notify-off; then
  header "38. notify desligado por default"
  real_timeout=$(command -v timeout)
  d=$(new_case notify-off)
  cat > "$d/bin/timeout" <<PROBE
#!/usr/bin/env bash
echo call >> "$d/state/timeout_calls"
exec "$real_timeout" "\$@"
PROBE
  chmod +x "$d/bin/timeout"
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  if [ -f "$d/state/timeout_calls" ]; then bad "nenhuma notificacao sem RALPH_NOTIFY_CMD (houve chamada)"
  else ok "nenhuma notificacao sem RALPH_NOTIFY_CMD"; fi

  # Controle: a mesma sonda dispara quando o comando existe — sem isto o
  # assert acima passaria ate com a sonda quebrada.
  d2=$(new_case notify-off-control)
  cp "$d/bin/timeout" "$d2/bin/timeout"
  sed -i "s#$d/state#$d2/state#" "$d2/bin/timeout"
  make_notify_recorder "$d2/notify.sh" "$d2/events.txt"
  rc=$(CASE_NOTIFY_CMD="$d2/notify.sh" run_ralph "$d2" ok --engine claude --test-cmd "$d2/test.sh")
  assert_eq 0 "$rc" "controle: exit 0"
  if [ -s "$d2/state/timeout_calls" ]; then ok "controle: a sonda ve o notify ligado"
  else bad "controle: a sonda ve o notify ligado"; fi
fi

# ---------------------------------------------------------------------------
# 39. Run verde: sequencia de eventos e contexto vindo do estado do run
# ---------------------------------------------------------------------------
if case_enabled notify-green; then
  header "39. notify — sequencia de um run verde"
  d=$(new_case notify-green)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  rc=$(CASE_NOTIFY_CMD="$d/notify.sh" run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  assert_eq "run_start phase_done phase_done run_done" "$(event_seq "$d/events.txt")" "sequencia de eventos"
  assert_contains "$d/events.txt" "2 de 2 fase(s)" "run_start conta as fases pendentes"
  assert_contains "$d/events.txt" "phase_done|repo|1|2|1|3|pass|pass|pass|running|run-" \
    "phase_done leva fase, total, ciclo, gates, status e run id"
  assert_contains "$d/events.txt" "run_done|repo||2||3||||finished|run-" \
    "run_done nao herda fase/ciclo/gates e traz o desfecho"
  assert_contains "$d/events.txt" "2 completa(s), 0 falharam" "run_done carrega o resumo"
fi

# ---------------------------------------------------------------------------
# 40. Fase reprovada: phase_failed com o gate, a causa e o log do gate
# ---------------------------------------------------------------------------
if case_enabled notify-failed; then
  header "40. notify — fase reprovada"
  d=$(new_case notify-failed)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  rc=$(CASE_NOTIFY_CMD="$d/notify.sh" run_ralph "$d" empty-diff --engine claude --max-cycles 1 --test-cmd "$d/test.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_eq "run_start phase_failed run_done" "$(event_seq "$d/events.txt")" "sequencia de eventos"
  assert_contains "$d/events.txt" "Ultimo gate: gate 3" "phase_failed nomeia o gate"
  assert_contains "$d/events.txt" "phase_failed|repo|1|2|1|1|pass|pass|fail|running|" "phase_failed leva os gates reais"
  assert_contains "$d/events.txt" "|.phases/logs/phase-01.verify-1.log|" "phase_failed aponta o log do gate que reprovou"
  assert_contains "$d/events.txt" "|failed|run-" "run_done traz o desfecho failed"
fi

# ---------------------------------------------------------------------------
# 41. Adaptador travado e morto pelo timeout; o run segue e passa
# ---------------------------------------------------------------------------
if case_enabled notify-timeout; then
  header "41. notify — adaptador travado nao segura o run"
  d=$(new_case notify-timeout)
  printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$d/hang.sh"
  chmod +x "$d/hang.sh"
  t0=$SECONDS
  rc=$(CASE_NOTIFY_CMD="$d/hang.sh" CASE_NOTIFY_TIMEOUT=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  elapsed=$((SECONDS - t0))
  assert_eq 0 "$rc" "exit 0 com o adaptador travado"
  assert_eq 3 "$(commits "$d")" "fases commitadas normalmente"
  # 4 eventos x 30s sem timeout; com RALPH_NOTIFY_TIMEOUT=1 cabe com folga em 20s
  if [ "$elapsed" -lt 20 ]; then ok "timeout matou o adaptador (${elapsed}s)"
  else bad "timeout matou o adaptador (run levou ${elapsed}s)"; fi
fi

# ---------------------------------------------------------------------------
# 42. Limite de uso: limit_hit/limit_over na espera, limit_abort no cap
# ---------------------------------------------------------------------------
if case_enabled notify-limit; then
  header "42. notify — limite de uso"
  d=$(new_case notify-limit)
  make_notify_recorder "$d/notify.sh" "$d/events.txt"
  rc=$(CASE_NOTIFY_CMD="$d/notify.sh" run_ralph "$d" limit-epoch --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0 (retomou depois do reset)"
  assert_eq "run_start limit_hit limit_over phase_done phase_done run_done" "$(event_seq "$d/events.txt")" \
    "limit_hit e limit_over em volta da espera"

  d2=$(new_case notify-limit-abort)
  make_notify_recorder "$d2/notify.sh" "$d2/events.txt"
  rc=$(CASE_NOTIFY_CMD="$d2/notify.sh" CASE_MAX_LIMIT_WAITS=0 run_ralph "$d2" limit-epoch --engine claude --test-cmd "$d2/test.sh")
  assert_eq 1 "$rc" "exit 1 ao estourar o cap de esperas"
  assert_eq "run_start limit_abort" "$(event_seq "$d2/events.txt")" "limit_abort antes de abortar"

  # Limite semanal tambem encerra o run: o aviso precisa sair antes do exit.
  d3=$(new_case notify-limit-weekly)
  make_notify_recorder "$d3/notify.sh" "$d3/events.txt"
  rc=$(CASE_TIMEOUT=60 CASE_NOTIFY_CMD="$d3/notify.sh" run_ralph "$d3" limit-weekly --engine claude --test-cmd "$d3/test.sh" --max-cycles 1)
  assert_eq 1 "$rc" "exit 1 no limite semanal"
  assert_eq "run_start limit_abort" "$(event_seq "$d3/events.txt")" "limit_abort antes de encerrar pelo limite semanal"
fi

# ---------------------------------------------------------------------------
# 43. notify-telegram.sh monta a mensagem a partir do ambiente, sem rede:
#     curl fake no PATH captura URL e texto; RALPH_NOTIFY_API_BASE aponta para
#     uma base fake. RALPH_NOTIFY_BIN permite apontar para uma copia patchada.
# ---------------------------------------------------------------------------
if case_enabled telegram-render; then
  header "43. notify-telegram.sh renderiza a partir do ambiente"
  tg="$TMP/telegram"
  mkdir -p "$tg/bin"
  cat > "$tg/bin/curl" <<'CURL'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    http*) printf '%s\n' "$arg" > "$TG_CAPTURE.url" ;;
    text=*) printf '%s' "${arg#text=}" > "$TG_CAPTURE" ;;
  esac
done
printf '%s' "${MOCK_HTTP:-200}"
CURL
  chmod +x "$tg/bin/curl"
  telegram="${RALPH_NOTIFY_BIN:-$ROOT/scripts/notify-telegram.sh}"
  # env -i: nada do shell do dev (token real, RALPH_* de outro run) vaza.
  tg_send() {
    local name="$1"; shift
    env -i PATH="$tg/bin:$PATH" HOME="$tg" TG_CAPTURE="$tg/$name.txt" \
      RALPH_NOTIFY_ENV_FILE="$tg/nao-existe.env" \
      RALPH_NOTIFY_API_BASE="http://fake-api.invalid" \
      TELEGRAM_BOT_TOKEN=fake-token TELEGRAM_CHAT_ID=42 \
      "$@"
  }

  tg_send failed RALPH_PROJECT='Loja <A&B>' RALPH_ENGINE=claude RALPH_RUN_ID=run-1117-120000 \
    RALPH_OUTCOME=running RALPH_PHASE_NUM=2 RALPH_PHASE_TOTAL=6 RALPH_PHASE_TITLE='API <pedidos>' \
    RALPH_PHASE_ATTEMPT=3 RALPH_PHASE_MAX_ATTEMPTS=3 RALPH_GATE0=pass RALPH_GATE1=pass \
    RALPH_GATE2=pass RALPH_GATE3=fail RALPH_LOG_PATH=.phases/logs/phase-02.verify-3.log \
    bash "$telegram" phase_failed 'FALHOU apos 3 ciclos.'
  assert_eq "http://fake-api.invalid/botfake-token/sendMessage" "$(cat "$tg/failed.txt.url" 2>/dev/null)" \
    "RALPH_NOTIFY_API_BASE sobrepoe a API"
  assert_contains "$tg/failed.txt" "<b>Loja &lt;A&amp;B&gt;</b>" "projeto com HTML escapado"
  assert_contains "$tg/failed.txt" "Fase 2/6 · API &lt;pedidos&gt;" "linha da fase"
  assert_contains "$tg/failed.txt" "Ciclo: 3/3" "ciclo/orcamento"
  assert_contains "$tg/failed.txt" "G2: aprovado · G3: falhou" "gates em texto"
  assert_contains "$tg/failed.txt" "Log: <code>.phases/logs/phase-02.verify-3.log</code>" "log do gate"
  assert_contains "$tg/failed.txt" "run-1117-120000" "run id"

  # So o minimo: evento + mensagem. Linha sem dado some, nunca sai quebrada.
  tg_send bare bash "$telegram" phase_failed 'sem contexto'
  assert_contains "$tg/bare.txt" "Fase falhou" "titulo do evento sem contexto"
  assert_contains "$tg/bare.txt" "sem contexto" "mensagem sem contexto"
  if grep -qE '^Fase [0-9?]' "$tg/bare.txt"; then bad "sem RALPH_PHASE_NUM, sem linha de fase"
  else ok "sem RALPH_PHASE_NUM, sem linha de fase"; fi
  assert_not_contains "$tg/bare.txt" "Ciclo:" "sem ciclo, sem linha de ciclo"
  assert_not_contains "$tg/bare.txt" "G2:" "sem gates, sem linha de gates"
  assert_not_contains "$tg/bare.txt" "Log:" "sem log, sem linha de log"

  tg_send done_ok RALPH_OUTCOME=finished RALPH_PHASE_NUM=2 RALPH_GATE2=pass \
    bash "$telegram" run_done 'Run encerrado.'
  assert_contains "$tg/done_ok.txt" "Execução concluída" "run_done finished"
  assert_not_contains "$tg/done_ok.txt" "Fase 2" "run_done nao herda fase"
  tg_send done_bad RALPH_OUTCOME=failed bash "$telegram" run_done 'Uma fase falhou.'
  assert_contains "$tg/done_bad.txt" "Execução encerrada com falhas" "run_done failed nao anuncia sucesso"

  rc=0
  tg_send http500 MOCK_HTTP=500 bash "$telegram" phase_done 'x' > "$tg/err.txt" 2>&1 || rc=$?
  assert_eq 0 "$rc" "erro HTTP nao muda o exit code"
  assert_not_contains "$tg/err.txt" "fake-token" "erro nao expoe o token"
  rc=0
  env -i PATH="$tg/bin:$PATH" HOME="$tg" RALPH_NOTIFY_ENV_FILE="$tg/nao-existe.env" \
    bash "$telegram" phase_done 'x' > /dev/null 2>&1 || rc=$?
  assert_eq 0 "$rc" "sem credencial: exit 0"
fi

# ---------------------------------------------------------------------------
# 44. Evidencia visual (Tela:) — o ralph fotografa a rota antes do gate 3.
#     Captura fake: grava os argumentos e escreve um PNG; MOCK_SHOT_FAIL=1 sai 1.
# ---------------------------------------------------------------------------

# ui_case <nome> <alvo> [auto] -> fixture com `Tela:` na task 1 da fase 1.
# auto: o script de captura vai para scripts/ralph-ui-shot.sh (deteccao).
ui_case() {
  local name="$1" target="$2" auto="${3:-}" extra_tela="${4:-}" d
  d=$(new_case "$name")
  cat > "$d/shot.sh" <<'SHOT'
#!/usr/bin/env bash
echo "${RALPH_UI_VIEWPORT:-}|$1|$2|$3|$4" >> "$MOCK_STATE/shot_calls"
if [ "${MOCK_SHOT_FAIL:-0}" = 1 ]; then echo "seletor .kpi nao encontrado"; exit 1; fi
printf 'PNG' > "$2"
SHOT
  chmod +x "$d/shot.sh"
  (
    cd "$d/repo" || exit 1
    mkdir -p design
    printf '<html></html>' > design/dashboard.html
    if [ -n "$auto" ]; then mkdir -p scripts && cp "$d/shot.sh" scripts/ralph-ui-shot.sh; fi
    cat > .spec/init/project-phases.md <<PHASES
# UI — Project Phases

## Phase 1: Dashboard

- [ ] **Task:** cria o dashboard
  - Tela: \`/dashboard\` | \`.kpi, .chart\` | $target | dark
$extra_tela
  - **Acceptance criteria:**
    - a tela existe
- [ ] **Task:** cria o arquivo B
  - **Acceptance criteria:**
    - o arquivo existe

## Phase 2: Feature

- [ ] **Task:** cria o arquivo C
PHASES
    git add -A && git commit -q -m "chore: fixture ui"
  )
  echo "$d"
}

if case_enabled ui-evidence; then
  header "44a. Tela: + captura detectada no repo -> PNGs e prompt do verificador"
  d=$(ui_case ui-evidence design/dashboard.html auto)
  rc=$(CASE_VERIFY=auto run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  ev="$d/repo/.phases/evidence/phase-01"
  test -s "$ev/task-1.png" && test -s "$ev/task-1-mobile.png" \
    && ok "PNGs desktop e mobile gravados" || bad "PNGs desktop e mobile gravados"
  assert_contains "$d/state/shot_calls" "desktop|/dashboard|.phases/evidence/phase-01/task-1.png|.kpi, .chart|dark" "captura recebe rota, saida, seletores e tema"
  assert_contains "$d/state/shot_calls" "mobile|/dashboard|.phases/evidence/phase-01/task-1-mobile.png" "segunda captura em mobile"
  vp="$d/repo/.phases/prompts/phase-01.verify-1.txt"
  assert_contains "$vp" ".phases/evidence/phase-01/task-1.png" "prompt do verificador cita o PNG desktop"
  assert_contains "$vp" ".phases/evidence/phase-01/task-1-mobile.png" "prompt do verificador cita o PNG mobile"
  assert_contains "$vp" "alvo: design/dashboard.html" "prompt do verificador cita o alvo"
  assert_not_contains "$d/repo/.phases/prompts/phase-02.verify-1.txt" "Evidencia visual" "fase sem Tela: -> prompt inalterado"
  assert_eq 1 "$(cat "$d/state/verify_calls")" "auto: fase com Tela: nao pula o gate 3 (a sem Tela: pula)"
fi

if case_enabled ui-multi-tela; then
  header "44f. task com 2 linhas Tela: -> 2 fotos distintas, ambas no prompt"
  d=$(ui_case ui-multi-tela "" auto "  - Tela: \`/relatorio\` | \`.table\` |  | dark")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh")
  assert_eq 0 "$rc" "exit 0"
  ev="$d/repo/.phases/evidence/phase-01"
  test -s "$ev/task-1.png" && test -s "$ev/task-1-2.png" && test -s "$ev/task-1-2-mobile.png" \
    && ok "segunda tela da mesma task nao sobrescreve a primeira" || bad "segunda tela da mesma task nao sobrescreve a primeira"
  assert_contains "$d/state/shot_calls" "desktop|/relatorio|.phases/evidence/phase-01/task-1-2.png" "captura da 2a tela grava task-1-2"
  vp="$d/repo/.phases/prompts/phase-01.verify-1.txt"
  assert_contains "$vp" ".phases/evidence/phase-01/task-1.png" "prompt cita a 1a foto"
  assert_contains "$vp" ".phases/evidence/phase-01/task-1-2.png" "prompt cita a 2a foto"
fi

if case_enabled ui-shot-fail; then
  header "44b. captura sai 1 -> gate 3 vermelho citando a task"
  d=$(ui_case ui-shot-fail "")
  rc=$(MOCK_SHOT_FAIL=1 run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --ui-shot-cmd "$d/shot.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reprovou"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "Evidencia visual da task 1 falhou" "causa cita a task"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "seletor .kpi nao encontrado" "causa traz o fim do log da captura"
  # 2 = os dois commits de fixture (new_case + ui_case): nenhuma fase commitada
  assert_eq 2 "$(commits "$d")" "nenhuma fase commitada"
fi

if case_enabled ui-no-cmd; then
  header "44c. Tela: sem comando de captura -> fail-closed"
  d=$(ui_case ui-no-cmd "")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 2)
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reprovou sem prova visual"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "nenhum comando de captura" "causa explica a falta do comando"
  test -f "$d/state/verify_calls" && bad "verificador nao roda sem prova" || ok "verificador nao roda sem prova"
fi

if case_enabled ui-off; then
  header "44d. --no-ui-verify / --no-verify -> passa sem captura"
  d=$(ui_case ui-off "")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --no-ui-verify)
  assert_eq 0 "$rc" "--no-ui-verify: exit 0"
  assert_contains "$d/out.log" "Evidencia visual DESLIGADA" "aviso de evidencia desligada"
  test -f "$d/state/shot_calls" && bad "--no-ui-verify: sem captura" || ok "--no-ui-verify: sem captura"
  d=$(ui_case ui-off-gate3 "")
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --no-verify --ui-shot-cmd "$d/shot.sh")
  assert_eq 0 "$rc" "--no-verify: exit 0"
  assert_contains "$d/out.log" "Evidencia visual nao capturada: o gate 3 esta desligado" "gate 3 off registra a captura pulada"
  test -f "$d/state/shot_calls" && bad "--no-verify: sem captura" || ok "--no-verify: sem captura"
fi

if case_enabled ui-missing-target; then
  header "44e. alvo citado em Tela: nao existe -> gate 3 vermelho"
  d=$(ui_case ui-missing-target design/nao-existe.png)
  rc=$(run_ralph "$d" ok --engine claude --test-cmd "$d/test.sh" --max-cycles 2 --ui-shot-cmd "$d/shot.sh")
  assert_eq 1 "$rc" "exit 1"
  assert_contains "$d/out.log" "Gate 3 vermelho" "gate 3 reprovou"
  assert_contains "$d/repo/.phases/prompts/phase-01.cycle-2.txt" "o alvo 'design/nao-existe.png' citado em 'Tela:' nao existe" "causa cita o alvo ausente"
  test -f "$d/state/shot_calls" && bad "alvo ausente: nao fotografa" || ok "alvo ausente: nao fotografa"
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
