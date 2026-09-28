#!/usr/bin/env bash
# Reconstrói o banco do zero: executa todos os scripts SQL na ordem numérica.
# Uso: ./scripts/run_all.sh [banco]   (padrão: matricula)
#      o contêiner bd2_aluno_postgres precisa estar no ar
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=bd2_aluno_postgres
BANCO="${1:-matricula}"
echo "Reconstruindo o banco '$BANCO' no contêiner $CONTAINER"

# A ordem é ordenada em locale C, de propósito. Deixar o shell expandir
# `sql/*.sql` faz a ordem depender do locale da máquina: em pt_BR.UTF-8 o
# "_" é ignorado na colação e `02b_geografia` vem ANTES de `02_carga` —
# a geografia roda sem país cadastrado e o script quebra. No macOS a ordem
# saía certa e o erro só apareceria na máquina de outra pessoa (ou no CI).
while IFS= read -r f; do
  echo ""
  echo "==================== $f ===================="
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U bd2 -d "$BANCO" < "$f"
done < <(printf '%s\n' sql/*.sql | LC_ALL=C sort)

echo ""
echo "OK — banco '$BANCO' reconstruído e verificado com sucesso."
