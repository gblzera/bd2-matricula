# Backup e recuperação — procedimento documentado e reproduzível

> Exigência do Marco 2: procedimento de backup e restauração **documentado e
> reproduzível do zero**, com restauração **ao vivo** na apresentação.

## Estratégia

Backup **lógico** com `pg_dump -Fc` (formato custom): comprimido, restaurável com
`pg_restore` (que permite restauração seletiva, paralela e reordenada). Para o
escopo da disciplina — uma base, janela de manutenção folgada — backup lógico é
o adequado; PITR/WAL archiving seria o próximo passo em produção e está fora do
escopo (justificativa registrada).

A restauração de ensaio é feita numa base **separada** (`matricula_restore`):
valida o dump sem arriscar a base boa — backup que nunca foi restaurado não é
backup, é esperança.

## Procedimento

```bash
# 1. Gerar o backup (backups/matricula_AAAAmmdd_HHMMSS.dump)
./scripts/backup.sh

# 2. Ensaiar a restauração numa base nova e conferir volumes
./scripts/restore.sh backups/matricula_<carimbo>.dump

# 3. (Desastre real) restaurar por cima da base original
./scripts/restore.sh backups/matricula_<carimbo>.dump matricula
```

## Ensaio executado (evidência)

```
$ ./scripts/backup.sh
Backup gerado: backups/matricula_20260811_121356.dump (996K)

$ ./scripts/restore.sh backups/matricula_20260811_121356.dump
Restauração concluída em 'matricula_restore'. Conferência de volumes:
   tabela   | count
------------+-------
 alunos     |  3120
 matriculas | 32797
 historicos | 31168
```

Contagens idênticas à base de origem no momento do dump (verificado). A base de
ensaio foi removida após a conferência.

## Simulação de desastre total (roteiro da apresentação)

```bash
./scripts/backup.sh                                  # 1. backup em dia
cd ambiente && docker compose down -v && docker compose up -d && cd ..
                                                     # 2. DESASTRE: -v apaga o volume de dados
./scripts/restore.sh backups/matricula_<carimbo>.dump matricula
                                                     # 3. restauração na base original recriada
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/08_seguranca.sql
                                                     # 4. reaplicar grants/RLS (roles são de cluster;
                                                     #    o dump da BASE não carrega CREATE ROLE)
```

**Ponto de atenção documentado:** `pg_dump` de uma base **não** inclui roles
(objetos de cluster). Após restaurar em um cluster virgem, reexecutar
`08_seguranca.sql` (idempotente) recria papéis, grants e políticas. Alternativa
completa: `pg_dumpall --globals-only` para acompanhar os dumps.

## O que o dump carrega (e a ordem interna do pg_restore)

Tipos e domínios (inclusive `timerange` [C1]), tabelas, dados, colunas geradas
(recalculadas ao inserir), constraints e EXCLUDE (validados após a carga de
dados), índices (recriados ao final — mais rápido que inserir com índice),
views, materialized views (com `REFRESH` ao final) e funções. Ou seja: o dump
prova que o esquema inteiro é autossuficiente.
