# Projeto Acadêmico BD2 — Sistema de Matrícula Acadêmica

> **IESB · Banco de Dados II (CCO072) · 2026/2 · Prof. Rodrigo Gonçalves**
> Implementação do modelo lógico fornecido no enunciado sobre PostgreSQL 17,
> com correções documentadas dos erros do modelo, carga reproduzível e
> consultas avançadas.

## Como subir o banco do zero

Pré-requisito: Docker Desktop instalado.

```bash
# 1. Subir o ambiente (PostgreSQL 17 + pgAdmin — cópia do ambiente oficial da disciplina)
cd ambiente && docker compose up -d && cd ..

# 2. Construir o banco completo (DDL + carga + consultas + testes)
./scripts/run_all.sh
```

Pronto. Acessos:

| Serviço | Endereço | Credenciais |
|---|---|---|
| PostgreSQL | `localhost:5432` | usuário `bd2` · senha `bd2` · base `matricula` |
| pgAdmin | `http://localhost:8080` | `admin@iesb.br` · `admin` |

Para recomeçar do zero: `docker compose down -v` (na pasta `ambiente/`) e repetir os passos —
ou simplesmente rodar `./scripts/run_all.sh` de novo: **todos os scripts são idempotentes**
(o DDL recria o esquema, a carga é 100% determinística).

## Estrutura do repositório

```
sql/
  01_ddl.sql                  Marco 1 · tipos, domínios, tabelas e restrições
  02_carga.sql                Marco 1 · carga determinística (120 alunos, 34 turmas, ~800 matrículas)
  03_consultas.sql            Marco 1 · 10 consultas comentadas (recursivas, janelas, ranges)
  04_views.sql                Marco 2 · 3 views + materialized view (política de refresh justificada)
  05_volume_legado.sql        Marco 2 · semestres 2020–2024 (~33 mil matrículas) p/ evidências
  06_indices.sql              Marco 2 · 4 índices (parcial, BRIN, B-tree, GIN bônus) + EXPLAIN
  07_transacoes.sql           Marco 2 · funções de matrícula (anomalia + correção por lock)
  08_seguranca.sql            Marco 2 · papéis, GRANT/REVOKE e RLS (com demo)
  90_testes_restricoes.sql    Testes: dados inválidos sendo rejeitados pelas correções
docs/
  correcoes-modelo-logico.md  Análise crítica: erros do modelo lógico e correções aplicadas
  modelo-fisico.html          Página visual: diagrama ER, catálogo das tabelas e correções antes/depois
  backup-restore.md           Procedimento de backup/restauração + simulação de desastre
  plano-marco2.md             Plano de ataque do Marco 2 (histórico)
  evidencias/
    explain-indices.md        EXPLAIN (ANALYZE, BUFFERS) antes/depois de cada índice
    transacoes-demo.md        Anomalia da última vaga + 2 correções (execuções reais)
    rls-demo.md               RLS em ação: aluno não vê histórico alheio
ambiente/
  docker-compose.yml          Cópia do ambiente oficial da disciplina
scripts/
  run_all.sh                  Reconstrói o banco inteiro na ordem (01→08 + testes)
  demo_concorrencia.sh        Disputa da última vaga: sem_protecao | lock | serializable
  backup.sh / restore.sh      Backup pg_dump -Fc e restauração ensaiada
  concorrencia/               Roteiros das sessões (READ COMMITTED e SERIALIZABLE)
AUTORES.md                    Frentes de responsabilidade de cada integrante
```

## O ponto central: os erros do modelo lógico

O modelo lógico do enunciado contém erros propositais, corrigidos aqui no modelo
físico. O detalhamento completo (13 itens, com consequência prática e justificativa
de cada correção) está em [docs/correcoes-modelo-logico.md](docs/correcoes-modelo-logico.md).
Destaques:

- **C1** — `timerange` não existe no PostgreSQL: criado com `CREATE TYPE ... AS RANGE`.
- **C2** — `matricula` sem `UNIQUE (aluno_id, turma_id)`: aluno podia se matricular 2× na mesma turma.
- **C6** — `aluno.curso_id` + `aluno.curriculo_id` sem amarração: aluno de um curso podia
  apontar currículo de outro. Corrigido com **FK composta**.
- **C10** — nada impedia duas turmas na mesma sala/horário: corrigido com
  **restrição de exclusão GiST** sobre range de horário (`&&`).

Cada correção aparece no [sql/01_ddl.sql](sql/01_ddl.sql) marcada com `[C#]`, e o
[sql/90_testes_restricoes.sql](sql/90_testes_restricoes.sql) **prova** cada uma rejeitando
dados inválidos.

Para estudar visualmente, abra [docs/modelo-fisico.html](docs/modelo-fisico.html) no navegador
(`open docs/modelo-fisico.html`): diagrama ER com cardinalidades, catálogo das 16 tabelas com
chaves, e as 13 correções lado a lado (antes → depois).

## Marcos

| Marco | Data | Conteúdo | Status |
|---|---|---|---|
| Marco 1 | 14/09/2026 | DDL + carga + 10 consultas | ✅ neste repositório |
| Marco 2 | 06/11/2026 | views, índices, transações, segurança, backup | ✅ neste repositório |
| Apresentação | 09/11 ou 16/11 | demonstração ao vivo + arguição cruzada | roteiros prontos em `docs/evidencias/` |

## Demonstrações rápidas (roteiro da apresentação)

```bash
./scripts/demo_concorrencia.sh sem_protecao   # a ANOMALIA: overbooking 9/8
./scripts/demo_concorrencia.sh lock           # correção A: FOR UPDATE (8/8)
./scripts/demo_concorrencia.sh serializable   # correção B: SSI aborta com 40001 (8/8)
./scripts/backup.sh                           # backup -Fc
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/06_indices.sql   # EXPLAIN antes/depois ao vivo
```
