#!/usr/bin/env bash
# =============================================================================
# Restauração do backup em uma base NOVA (ensaio seguro de disaster recovery).
# Uso: ./scripts/restore.sh backups/matricula_XXXX.dump [base_destino]
#      base_destino default: matricula_restore
# Para restaurar POR CIMA da base original (desastre real): use a base 'matricula'
# — o script derruba conexões e recria a base de destino do zero.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ARQ="${1:?informe o arquivo .dump (ex.: backups/matricula_20261101_090000.dump)}"
DESTINO="${2:-matricula_restore}"

# Recria a base de destino (derruba conexões penduradas antes)
docker exec bd2_aluno_postgres psql -U bd2 -d postgres -qc \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DESTINO';"
docker exec bd2_aluno_postgres psql -U bd2 -d postgres -qc "DROP DATABASE IF EXISTS $DESTINO;"
docker exec bd2_aluno_postgres psql -U bd2 -d postgres -qc "CREATE DATABASE $DESTINO;"

# --no-owner: os objetos ficam do usuário que restaura (bd2), sem depender
# das roles do momento do dump
docker exec -i bd2_aluno_postgres pg_restore -U bd2 -d "$DESTINO" --no-owner < "$ARQ"

echo ""
echo "Restauração concluída em '$DESTINO'. Conferência de volumes:"
docker exec bd2_aluno_postgres psql -U bd2 -d "$DESTINO" -c \
  "SELECT 'alunos' AS tabela, count(*) FROM aluno
   UNION ALL SELECT 'matriculas', count(*) FROM matricula
   UNION ALL SELECT 'historicos', count(*) FROM historico;"
