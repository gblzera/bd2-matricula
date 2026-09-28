#!/usr/bin/env bash
# Reconstrói o banco do zero: executa todos os scripts SQL na ordem numérica.
#
# Dois modos, porque o mesmo script serve a máquina do grupo e a integração
# contínua — e um teste que só roda numa das duas não é um teste:
#
#   local (padrão)  ./scripts/run_all.sh [banco]
#                   fala com o contêiner bd2_aluno_postgres via docker exec
#
#   direto          DATABASE_URL=postgresql://bd2:bd2@localhost:5432/matricula \
#                   ./scripts/run_all.sh
#                   fala com um PostgreSQL alcançável por psql, sem Docker.
#                   É o que o .github/workflows/banco.yml usa.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${CONTAINER:-bd2_aluno_postgres}"
BANCO="${1:-matricula}"

if [ -n "${DATABASE_URL:-}" ]; then
  echo "Reconstruindo via psql direto: ${DATABASE_URL%%\?*}"
  rodar() { psql -q -v ON_ERROR_STOP=1 "$DATABASE_URL" -f "$1"; }
else
  echo "Reconstruindo o banco '$BANCO' no contêiner $CONTAINER"
  rodar() { docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U bd2 -d "$BANCO" < "$1"; }
fi

# A ordem é ordenada em locale C, de propósito. Deixar o shell expandir
# `sql/*.sql` faz a ordem depender do locale da máquina: em pt_BR.UTF-8 o
# "_" é ignorado na colação e `02b_geografia` vem ANTES de `02_carga` —
# a geografia roda sem país cadastrado e o script quebra. No macOS a ordem
# saía certa e o erro só apareceria na máquina de outra pessoa (ou no CI).
while IFS= read -r f; do
  echo ""
  echo "==================== $f ===================="
  rodar "$f"
done < <(printf '%s\n' sql/*.sql | LC_ALL=C sort)

echo ""
echo "OK — banco '$BANCO' reconstruído e verificado com sucesso."
