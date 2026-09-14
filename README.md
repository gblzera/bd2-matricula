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
  01_ddl.sql                  Marco 1 · 41 tabelas, tipos, domínios, restrições + a view de derivação
  02_carga.sql                Marco 1 · carga determinística (120 alunos, 34 turmas, ~800 matrículas,
                              1.189 aulas, 17 mil presenças, 995 notas)
  03_consultas.sql            Marco 1 · 10 consultas comentadas (recursivas, janelas, ranges)
  04_views.sql                Marco 2 · 3 views + 2 materialized views (política de refresh justificada)
  05_volume_legado.sql        Marco 2 · semestres 2020–2024 (~33 mil matrículas, ~60 mil notas)
  06_indices.sql              Marco 2 · 4 índices (parcial, BRIN, B-tree, GIN bônus) + EXPLAIN
  07_transacoes.sql           Marco 2 · funções de matrícula (anomalia + correção por lock)
  08_seguranca.sql            Marco 2 · papéis, GRANT/REVOKE e RLS (com demo)
  90_testes_restricoes.sql    21 testes: o que o modelo deve REJEITAR [C2]–[C13], [E2]–[E14] — e o que deve ACEITAR
docs/
  modelo-er.drawio            Modelagem da BASE (16 tabelas): conceitual, lógico/físico, correções C1–C15
  esboco-schema-ampliado.md   Esboço do grupo que originou a ampliação (revisado e testado)
  modelo-tabelas.drawio       **MODELO AMPLIADO oficial (41 tabelas)**: tabelas+relacionamentos, normalização, decisões E1–E16
  correcoes-modelo-logico.md  Análise crítica: erros do modelo lógico e correções aplicadas
  estado-do-projeto.md        Handoff: resumo, decisões (com justificativa) e pendências — LER PRIMEIRO
  modelo-fisico.html          Página visual: diagrama ER, catálogo das tabelas e correções antes/depois
  backup-restore.md           Procedimento de backup/restauração + simulação de desastre
  plano-marco2.md             Plano de ataque do Marco 2 (histórico)
  evidencias/
    explain-indices.md        EXPLAIN (ANALYZE, BUFFERS) antes/depois de cada índice
    transacoes-demo.md        Anomalia da última vaga + 2 correções (execuções reais)
    rls-demo.md               RLS em ação: aluno não vê histórico alheio
college/
  README.md                   Espelho do modelo em INGLÊS (banco `college`) — como e por quê
  01_schema.sql               41 tabelas, identificadores em inglês, tudo no singular
  02_seed.sql                 mesma carga determinística
  03_views.sql                views + materialized views
  04_legacy_volume.sql        semestres legados
ambiente/
  docker-compose.yml          Cópia do ambiente oficial da disciplina
scripts/
  run_all.sh                  Reconstrói o banco inteiro na ordem (01→08 + testes)
  gerar_college.py            Gera college/ a partir de sql/ pelo mapa de tradução
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

## A modelagem (entrega do Marco 1)

A modelagem é entregue **em draw.io**, como o professor exige, em dois arquivos:

| Arquivo | O que é |
|---|---|
| [docs/modelo-tabelas.drawio](docs/modelo-tabelas.drawio) | **O modelo ampliado oficial — 41 tabelas.** P.1: tabelas, colunas, os 60 relacionamentos com rotas limpas e, no canto superior esquerdo, o painel de normalização (1FN/2FN/3FN pela Tabela 15.1 do Elmasri) — a página 1 sozinha é a entrega do Marco 1; p.2: as decisões da ampliação **[E1]–[E16]** e o impacto na base. Para exportar PNG, exporte **só a página 1** (a opção *todas as páginas* sobrepõe as páginas no mesmo desenho) |
| [docs/modelo-er.drawio](docs/modelo-er.drawio) | A **base**: o modelo do professor corrigido (16 tabelas, C1–C15), com o conceitual em notação de Chen |

O modelo do professor é a base e foi **ampliado por completo** a partir do esboço do
grupo ([docs/esboco-schema-ampliado.md](docs/esboco-schema-ampliado.md)), revisado em
cinco dimensões e testado construção a construção em banco descartável. Grupos da
ampliação: geografia normalizada, supertipo `pessoa`, prédio/recurso/departamento,
plano de ensino **da disciplina** com versão por turma, co-docência, janela de
matrícula, aula/presença e avaliação/nota flexíveis.

**O modelo ampliado está no ar.** Desde 27/08/2026 a base `matricula` É o modelo de
41 tabelas: `./scripts/run_all.sh` reconstrói tudo do zero — DDL, carga, consultas,
views, volume legado, índices, transações, RLS e a bateria de restrições — e termina
verde. O diagrama é conferido contra o DDL por script (41 tabelas, 226 colunas em
ordem exata, 60 FKs com uma linha cada), e o dump do modelo anterior de 16 tabelas
ficou em `backups/matricula_v1_16tabelas_20260827.dump`.

### O que a ampliação custou (e onde o custo foi pago)

| O que mudou | Consequência | Onde foi resolvido |
|---|---|---|
| [E2] nome/CPF saíram de `aluno` para `pessoa` | toda consulta com gente ganhou uma junção; e o **RLS de `aluno` deixou de proteger o nome** | `08_seguranca.sql` põe RLS em `pessoa` |
| [E14] notas saíram de `historico` para `nota` | média deixou de ser coluna; e as notas **ficaram fora do RLS** | view `v_desempenho_matricula` (01_ddl) + RLS em `nota`/`presenca` |
| [E14] a média era coluna GERADA e indexável | uma view não aceita índice | `mv_historico_consolidado` (04_views) carrega o índice — **56 ms → 0,13 ms** |
| [C11] `acao_log_t` virou DML (`insert`/`update`/`delete`) | a RECUSA de vaga não tem verbo e deixou de ser logada | documentado em `07_transacoes.sql`; evento de negócio vai no `jsonb` |

Nenhuma dessas regras usa trigger: a coerência entre aula, presença, nota e turma é
garantida por **FK composta** [E13] — `90_testes_restricoes.sql` prova que uma nota
em avaliação de outra turma é impossível.

## Marcos

| Marco | Data | Conteúdo | Status |
|---|---|---|---|
| Marco 1 | 14/09/2026 | Modelagem draw.io + DDL + carga + 10 consultas | ✅ neste repositório |
| Marco 2 | 06/11/2026 | views, índices, transações, segurança, backup | ✅ neste repositório |
| Apresentação | 09/11 ou 16/11 | demonstração ao vivo + arguição cruzada | roteiros prontos em `docs/evidencias/` |

## Apresentação

Roteiro completo do seminário (minuto a minuto, comandos validados, fallbacks e
mapa de estudo da arguição): [docs/roteiro-apresentacao.md](docs/roteiro-apresentacao.md).

## Demonstrações rápidas (roteiro da apresentação)

```bash
./scripts/run_all.sh                          # reconstrói a base inteira, do zero, em ~3s
./scripts/demo_concorrencia.sh sem_protecao   # a ANOMALIA: overbooking 9/8
./scripts/demo_concorrencia.sh lock           # correção A: FOR UPDATE (8/8)
./scripts/demo_concorrencia.sh serializable   # correção B: SSI aborta com 40001 (8/8)
./scripts/backup.sh                           # backup -Fc
docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/06_indices.sql   # EXPLAIN antes/depois ao vivo
```
