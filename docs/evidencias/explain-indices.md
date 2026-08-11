# Evidências de EXPLAIN (ANALYZE, BUFFERS) — antes e depois de cada índice

> Medições reais executando [sql/06_indices.sql](../../sql/06_indices.sql) sobre a base com o
> volume legado carregado ([sql/05_volume_legado.sql](../../sql/05_volume_legado.sql)):
> **32.796 matrículas, 31.167 históricos, 32.879 logs**. PostgreSQL 17 no ambiente
> Docker oficial da disciplina. O script é o gerador das evidências: reexecutá-lo
> reproduz os planos abaixo (a carga é determinística).

## Resumo dos ganhos

| # | Índice | Tipo | Consulta-alvo | Antes | Depois | Ganho |
|---|---|---|---|---|---|---|
| 1 | `idx_matricula_turma_confirmada` | **B-tree parcial** (`WHERE status='confirmada'`) | contagem de vagas de uma turma | 0,92 ms · 389 buffers · Seq Scan | 0,03 ms · 3 buffers · **Index Only Scan** | **~32×** |
| 2 | `idx_matricula_data_brin` | **BRIN** (`pages_per_range=16`) | matrículas por janela de tempo (2022/1) | 1,12 ms · 389 buffers · Seq Scan | 0,34 ms · 37 buffers · Bitmap/BRIN | **~3,3×** (índice de **24 kB**) |
| 3 | `idx_historico_media` | B-tree | cortes por faixa de média (`>= 9,5`) | 2,14 ms · 844 buffers · Seq Scan | 0,05 ms · 4 buffers · **Index Only Scan** | **~46×** |
| 4 | `idx_log_detalhe_gin` | **GIN jsonb_path_ops** (bônus JSONB) | auditoria por conteúdo (`detalhe @> {...}`) | 2,92 ms · 1.392 buffers · Seq Scan | 0,14 ms · 33 buffers · Bitmap/GIN | **~21×** |

Tamanhos medidos: `idx_historico_media` 704 kB · `idx_matricula_turma_confirmada` 216 kB ·
`idx_log_detalhe_gin` 176 kB · `idx_matricula_data_brin` **24 kB**.

## Leitura crítica (o que defender na arguição)

1. **Parcial (índice 1).** O predicado `WHERE status = 'confirmada'` grava a regra de
   negócio ("só confirmada consome vaga") dentro do índice: ele não indexa canceladas e
   trancadas, fica menor e vira **Index Only Scan** — 389 → 3 buffers. É a leitura feita
   pela transação de matrícula do `07_transacoes.sql`, o caminho mais quente do sistema.
2. **BRIN (índice 2).** Só funciona porque `data_matricula` é correlacionada com a ordem
   física (carga em ordem cronológica). Detalhe de tuning que faz diferença: com o
   `pages_per_range` default (128), uma tabela de ~390 páginas gera só 3 faixas e o BRIN
   quase não poda (medimos: 261 buffers). Com `pages_per_range = 16`, 37 buffers.
   Custo-benefício: 24 kB de índice contra 216–704 kB dos B-trees.
3. **B-tree em media_final (índice 3).** Consulta de cauda de distribuição (410 de
   31.167 linhas ≈ 1,3%) — seletividade alta é exatamente onde B-tree ganha de seq scan.
   Nota: `media_final` é coluna GERADA [C13] — indexá-la é indexar a regra institucional.
4. **GIN (índice 4 = bônus JSONB).** `jsonb_path_ops` em vez da opclass default: indexa
   apenas hashes de caminho, menor e mais rápida, ao custo de suportar só `@>` — que é o
   único operador da consulta de auditoria. Trade-off consciente.

## Índices que NÃO criamos (e por quê)

- `matricula (aluno_id)` — desnecessário: `uq_matricula_aluno_turma` [C2] já indexa
  `aluno_id` como coluna líder. Constraint de integridade servindo ao desempenho.
- `historico (matricula_id)` — a UNIQUE do 1:1 já é um índice.
- Conflito de salas — o `EXCLUDE ... USING gist` [C10] já mantém um GiST.

## Saída bruta

A execução completa com os planos integrais está reproduzível via:

```bash
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/06_indices.sql
```
