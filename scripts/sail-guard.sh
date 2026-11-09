#!/usr/bin/env bash
#
# sail-guard.sh — hook PreToolUse (Bash) do bc-harness.
#
# Se o projeto atual usa Laravel Sail (vendor/bin/sail presente), bloqueia
# comandos que rodariam PHP/DB no host — onde geralmente nao ha PHP instalado
# ou o banco/redis so existe dentro do container — e devolve ao agente o
# comando equivalente via Sail. Evita o loop de "php artisan migrate" falhando
# repetidamente por connection refused.
#
# So julga o que roda NESTA maquina, fora de container: o comando e quebrado
# respeitando aspas, e segmentos que entregam o payload a outro lugar (ssh,
# docker/podman, kubectl, sail) passam inteiros. `bash -c '...'` local tem o
# payload inspecionado. Corpo de heredoc e texto entre aspas nunca contam.
#
# Entrada: JSON do hook no stdin ({ cwd, tool_input.command, ... }).
# Saida:   exit 0 = deixa passar; exit 2 = bloqueia (stderr vai para o agente).
# Sem python3 (parser do comando), falha aberto: nao bloqueia nada.
#
# Testes: scripts/test-sail-guard.sh

set -u

INPUT="$(cat)"

# --- pre-filtro barato: roda em todo Bash call, sai cedo se nao ha suspeito
case "$INPUT" in
  *php*|*artisan*|*composer*|*vendor/bin/*|*mysql*|*mariadb*|*psql*|*redis-cli*) ;;
  *) exit 0 ;;
esac

command -v python3 > /dev/null 2>&1 || exit 0

# --- extrai cwd e command do JSON
CWD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("cwd",""))' 2> /dev/null)
CMD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2> /dev/null)
[ -z "$CMD" ] && exit 0

# --- detecta Sail: sobe do cwd ate a raiz procurando vendor/bin/sail
SAIL_ROOT=""
dir="${CWD:-$PWD}"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  if [ -f "$dir/vendor/bin/sail" ]; then
    SAIL_ROOT="$dir"
    break
  fi
  dir=$(dirname "$dir")
done
[ -z "$SAIL_ROOT" ] && exit 0

# --- classifica: imprime "<ofensor>\t<sugestao>" do primeiro segmento local
#     que rodaria PHP/DB no host; nada quando o comando pode passar.
VERDICT=$(python3 - "$CMD" << 'PY' 2> /dev/null
import re
import shlex
import sys

OPERATORS = {";", "&&", "||", "|", "|&", "&", "\n"}
ELSEWHERE = {"ssh", "scp", "rsync", "docker", "docker-compose", "podman", "kubectl", "sail"}
SHELLS = {"bash", "sh", "zsh", "dash"}


def strip_heredocs(command):
    lines = command.split("\n")
    kept = []
    delimiter = None
    for line in lines:
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        kept.append(line)
        match = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if match:
            delimiter = match.group(1)
    return "\n".join(kept)


def segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    current = []
    for token in lexer:
        if token in OPERATORS:
            if current:
                yield current
            current = []
            continue
        current.append(token)
    if current:
        yield current


def strip_prefixes(tokens):
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ("sudo", "env", "time", "nohup", "exec"):
            index += 1
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            index += 1
            continue
        break
    return tokens[index:]


def suggestion(tokens):
    first, rest = tokens[0], tokens[1:]
    tail = shlex.join(rest)
    if re.match(r"^php[0-9.]*$", first):
        if rest and rest[0] == "artisan":
            return "artisan " + shlex.join(rest[1:])
        return "php " + tail
    if first in ("artisan", "./artisan"):
        return "artisan " + tail
    if first == "composer":
        return "composer " + tail
    if first.startswith("./vendor/bin/") or first.startswith("vendor/bin/"):
        return "bin " + first.split("vendor/bin/", 1)[1] + " " + tail
    if first in ("mysql", "mariadb", "psql"):
        return first
    if first == "redis-cli":
        return "redis"
    return None


def judge(command, depth=0):
    if depth > 3:
        return None
    for tokens in segments(strip_heredocs(command)):
        tokens = strip_prefixes(tokens)
        if not tokens:
            continue
        first = tokens[0]
        if first in ELSEWHERE or first.endswith("/vendor/bin/sail") or first == "vendor/bin/sail":
            continue
        if first in SHELLS:
            payload = next((tokens[i + 1] for i, t in enumerate(tokens[:-1]) if re.match(r"^-[a-z]*c[a-z]*$", t)), None)
            if payload is not None:
                found = judge(payload, depth + 1)
                if found:
                    return found
            continue
        rest = suggestion(tokens)
        if rest is not None:
            return shlex.join(tokens), "./vendor/bin/sail " + rest.strip()
    return None


try:
    found = judge(sys.argv[1])
except ValueError:
    found = None

if found:
    print(found[0] + "\t" + found[1])
PY
)

[ -z "$VERDICT" ] && exit 0

OFFENDER="${VERDICT%%$'\t'*}"
SUGGESTION="${VERDICT#*$'\t'}"

cat >&2 << EOF
BLOQUEADO pelo sail-guard: este projeto usa Laravel Sail ($SAIL_ROOT/vendor/bin/sail existe).
Comando "$OFFENDER" rodaria no HOST, onde PHP/banco/redis podem nao existir — e vai falhar (connection refused, php not found).
Use o equivalente via Sail:
  $SUGGESTION
Se os containers nao estiverem de pe, suba antes com: ./vendor/bin/sail up -d
EOF
exit 2
