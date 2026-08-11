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
  02_carga.sql                Marco 1 · carga determinística (120 alunos, 34 turmas, ~700 matrículas)
  03_consultas.sql            Marco 1 · 10 consultas comentadas (recursivas, janelas, ranges)
  90_testes_restricoes.sql    Testes: dados inválidos sendo rejeitados pelas correções
docs/
  correcoes-modelo-logico.md  Análise crítica: erros do modelo lógico e correções aplicadas
  plano-marco2.md             Plano de ataque do Marco 2
  evidencias/                 Evidências de EXPLAIN (Marco 2)
ambiente/
  docker-compose.yml          Cópia do ambiente oficial da disciplina
scripts/
  run_all.sh                  Executa todos os scripts SQL na ordem
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

## Marcos

| Marco | Data | Conteúdo | Status |
|---|---|---|---|
| Marco 1 | 14/09/2026 | DDL + carga + 10 consultas | ✅ neste repositório |
| Marco 2 | 06/11/2026 | views, índices, transações, segurança, backup | 🔜 [plano](docs/plano-marco2.md) |
| Apresentação | 09/11 ou 16/11 | demonstração ao vivo + arguição cruzada | — |
