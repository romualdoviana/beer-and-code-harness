#!/usr/bin/env bash
#
# test-sail-guard.sh — casos do hook scripts/sail-guard.sh.
#
# Uso:
#   scripts/test-sail-guard.sh            # todos os casos
#   scripts/test-sail-guard.sh <caso>     # um caso pelo nome
#   SAIL_GUARD_BIN=/caminho/sail-guard.sh scripts/test-sail-guard.sh
#                                         # aponta para outra copia (prova o vermelho)
#
# Cada caso monta um projeto Sail falso (vendor/bin/sail) num mktemp -d e
# alimenta o hook com o JSON do PreToolUse. Exit 2 = bloqueado; 0 = passa.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SAIL_GUARD_BIN:-$HERE/sail-guard.sh}"
ONLY="${1:-}"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/sail-project/vendor/bin" "$SANDBOX/plain-project"
touch "$SANDBOX/sail-project/vendor/bin/sail"

PASS=0
FAIL=0

run_guard() {
  local cwd="$1" cmd="$2"
  jq -n --arg cwd "$cwd" --arg cmd "$cmd" '{cwd: $cwd, tool_input: {command: $cmd}}' \
    | bash "$GUARD" > /dev/null 2>&1
  echo $?
}

expect() {
  local name="$1" expected="$2" cwd="$3" cmd="$4"
  if [ -n "$ONLY" ] && [ "$ONLY" != "$name" ]; then
    return
  fi
  local got
  got="$(run_guard "$cwd" "$cmd")"
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FALHOU %-34s esperado=%s obtido=%s\n  comando: %s\n' "$name" "$expected" "$got" "$cmd"
  fi
}

S="$SANDBOX/sail-project"

# --- bloqueia: PHP/DB no host de um projeto Sail
expect bloqueia-php-artisan        2 "$S" 'php artisan migrate'
expect bloqueia-apos-cd            2 "$S" 'cd app && php artisan test'
expect bloqueia-composer           2 "$S" 'composer install'
expect bloqueia-psql               2 "$S" 'psql -U sail -c "select 1"'
expect bloqueia-com-variavel       2 "$S" 'FOO=1 php -v'
expect bloqueia-vendor-bin         2 "$S" 'ls; vendor/bin/pint --dirty'
expect bloqueia-bash-c-local       2 "$S" "bash -c 'php artisan migrate'"
expect bloqueia-segunda-linha      2 "$S" $'echo inicio\nphp artisan migrate'

# --- passa: ja roda no Sail, no container ou no servidor remoto
expect passa-sail                  0 "$S" 'vendor/bin/sail artisan test'
expect passa-docker-exec           0 "$S" 'docker exec app php -v'
expect passa-docker-exec-sh-c      0 "$S" "docker exec db sh -c 'psql -c \"select 1\" || psql -c \"create database x\"'"
expect passa-docker-compose-exec   0 "$S" 'docker compose exec -T php bash -lc "cd /var/www && php8.4 tests/x.php"'
expect passa-ssh-remoto            0 "$S" "ssh prod 'cd /var/www/app && php artisan tinker --execute \"echo 1;\"'"
expect passa-ssh-bash-s            0 "$S" 'ssh prod bash -s < scripts/diag.sh'

# --- passa: texto que so cita o comando
expect passa-git-commit-msg        0 "$S" 'git commit -m "fix: php artisan || psql no host"'
expect passa-echo                  0 "$S" 'echo "rode php artisan migrate"'
expect passa-grep                  0 "$S" "grep -rn 'php artisan' docs"
expect passa-heredoc               0 "$S" $'cat > /tmp/x.sh <<\'EOF\'\ncd /app && php artisan migrate\nEOF'

# --- passa: projeto sem Sail
expect passa-sem-sail              0 "$SANDBOX/plain-project" 'php artisan migrate'

printf 'sail-guard: %d ok, %d falha(s)\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
