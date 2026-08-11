#!/usr/bin/env bash
# =============================================================================
# Backup lógico do banco matricula — pg_dump em formato custom (-Fc).
# Por que -Fc: comprimido, restaura com pg_restore (seletivo, paralelo,
# reordenável) — o formato recomendado para backup lógico de uma base.
# Uso: ./scripts/backup.sh          -> backups/matricula_AAAAmmdd_HHMMSS.dump
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p backups
ARQ="backups/matricula_$(date +%Y%m%d_%H%M%S).dump"

docker exec bd2_aluno_postgres pg_dump -U bd2 -Fc -d matricula > "$ARQ"

echo "Backup gerado: $ARQ ($(du -h "$ARQ" | cut -f1))"
