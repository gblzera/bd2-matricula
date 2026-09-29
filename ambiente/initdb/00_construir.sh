#!/bin/bash
# Constrói o projeto inteiro na PRIMEIRA subida do contêiner.
#
# O entrypoint do postgres roda tudo que está em /docker-entrypoint-initdb.d/
# antes de liberar conexões — então, quando o healthcheck ficar verde, o banco
# já está pronto. Quem recebe o projeto só precisa de `docker compose up -d`.
#
# Por que um .sh em vez de deixar os .sql soltos aqui: o entrypoint expande
# `*.sql` com o glob do shell, e a ordem sai do locale da imagem. Em locale
# UTF-8 o "_" é ignorado na colação e 02b_geografia vem ANTES de 02_carga —
# a geografia roda sem país cadastrado e o build quebra. Aqui a ordem é
# explícita e não depende de locale nenhum.
set -euo pipefail

rodar() {                     # rodar <banco> <arquivo...>
  local banco="$1"; shift
  for f in "$@"; do
    echo "  [$banco] $(basename "$f")"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$banco" -q -f "$f"
  done
}

echo "=== Sistema de Matrícula Acadêmica — construindo o banco 'matricula'"
rodar matricula \
  /projeto/sql/01_ddl.sql \
  /projeto/sql/02_carga.sql \
  /projeto/sql/02b_geografia_ibge.sql \
  /projeto/sql/03_consultas.sql \
  /projeto/sql/04_views.sql \
  /projeto/sql/05_volume_legado.sql \
  /projeto/sql/06_indices.sql \
  /projeto/sql/07_transacoes.sql \
  /projeto/sql/08_seguranca.sql \
  /projeto/sql/90_testes_restricoes.sql

if [ -d /projeto/college ]; then
  echo "=== espelho em inglês — construindo o banco 'college'"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
       -c "CREATE DATABASE college"
  rodar college \
    /projeto/college/01_schema.sql \
    /projeto/college/02_seed.sql \
    /projeto/college/02b_geography_ibge.sql \
    /projeto/college/03_views.sql \
    /projeto/college/04_legacy_volume.sql
fi

echo "=== pronto: 'matricula' (português) e 'college' (inglês)"
