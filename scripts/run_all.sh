#!/usr/bin/env bash
# Reconstrói o banco do zero: executa todos os scripts SQL na ordem numérica.
# Uso: ./scripts/run_all.sh   (o contêiner bd2_aluno_postgres precisa estar no ar)
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=bd2_aluno_postgres

for f in sql/*.sql; do
  echo ""
  echo "==================== $f ===================="
  docker exec -i "$CONTAINER" psql -q -v ON_ERROR_STOP=1 -U bd2 -d matricula < "$f"
done

echo ""
echo "OK — banco reconstruído e verificado com sucesso."
