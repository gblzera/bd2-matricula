# Análise crítica do Modelo Lógico — erros encontrados e correções no Modelo Físico

> Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
>
> O modelo lógico fornecido no enunciado contém erros e omissões propositais.
> Este documento registra **cada problema encontrado**, a **consequência prática**
> de deixá-lo como está e a **correção aplicada no DDL** ([sql/01_ddl.sql](../sql/01_ddl.sql)).
> Cada item tem um código `C#` que aparece como comentário no DDL, no ponto exato da correção.

## Erros que impedem o DDL de sequer rodar

### C1 — O tipo `timerange` não existe no PostgreSQL

- **Onde:** `turma_horario.faixa timerange`
- **Problema:** o PostgreSQL tem `tsrange`, `tstzrange`, `daterange`, `int4range`, `int8range` e
  `numrange` nativos — mas **não existe** range de `time`. Um `CREATE TABLE` literal do modelo
  falharia com `type "timerange" does not exist`.
- **Correção:** criar o tipo com `CREATE TYPE timerange AS RANGE (subtype = time)`.
  De brinde, tipos range criados assim ganham suporte automático a operadores como `&&`
  (sobreposição) e a índices GiST — o que viabiliza a correção C10.

## Erros de integridade (o banco aceitaria dados inválidos)

### C2 — `matricula` sem unicidade de (aluno, turma)

- **Onde:** `matricula` só tem PK em `id`.
- **Problema:** o mesmo aluno pode se matricular **duas vezes na mesma turma** — duas linhas
  distintas, ids diferentes. Corrompe contagem de vagas, histórico e qualquer relatório.
- **Correção:** `UNIQUE (aluno_id, turma_id)`.
- **Nota de projeto:** uma alternativa mais permissiva seria um índice único parcial
  (`WHERE status <> 'cancelada'`) permitindo re-matrícula após cancelamento. Mantivemos a
  restrição total no Marco 1 (mais simples de defender) e a variante parcial é candidata a
  "índice parcial" do Marco 2.

### C3 — `periodo_letivo` sem unicidade de (ano, semestre)

- **Problema:** nada impede dois registros "2026/2". Toda a oferta do semestre poderia se
  dividir entre dois períodos duplicados.
- **Correção:** `UNIQUE (ano, semestre)` + `CHECK (semestre IN (1,2))` + `CHECK (data_inicio < data_fim)`.

### C4 — `sala` sem unicidade de código por campus

- **Problema:** duas salas "T101" no mesmo campus. O código de sala só faz sentido único
  **dentro** de um campus (campi diferentes podem repetir códigos — e a carga demonstra isso).
- **Correção:** `UNIQUE (campus_id, codigo)`.

### C5 — `turma` sem unicidade de código por período letivo

- **Problema:** duas turmas "BD2-N1" no mesmo semestre. O código de turma se repete entre
  semestres (a cada oferta), mas não pode se repetir dentro do mesmo período.
- **Correção:** `UNIQUE (periodo_letivo_id, codigo)`.

### C6 — `aluno` com `curso_id` e `curriculo_id` redundantes (risco de inconsistência)

- **Onde:** `aluno.curso_id → curso` e `aluno.curriculo_id → curriculo`; mas `curriculo`
  **já pertence** a um curso (`curriculo.curso_id`).
- **Problema:** com duas FKs independentes, o aluno pode apontar para o curso de Computação
  e para um currículo de Direito — cada FK é válida isoladamente e o banco aceita.
  É uma dependência transitiva não protegida.
- **Correção:** manter as duas colunas (como no modelo), mas amarrá-las com **FK composta**:
  `FOREIGN KEY (curriculo_id, curso_id) REFERENCES curriculo (id, curso_id)`.
  Exige `UNIQUE (id, curso_id)` em `curriculo` (superchave da PK — barata e legítima).
  Agora o currículo do aluno é, por construção, um currículo do curso do aluno.

### C7 — `pre_requisito` permite disciplina ser pré-requisito de si mesma

- **Correção:** `CHECK (disciplina_id <> requisito_id)`.
- **Limite conhecido:** ciclos maiores (A→B→A) **não são expressáveis** em constraint
  declarativa; a consulta recursiva 5 (árvore de pré-requisitos) usa proteção de ciclo e
  serve de ferramenta de auditoria. Tratamento definitivo (trigger) é candidato ao Marco 2.

### C8 — `curriculo` sem unicidade de (curso, ano de vigência)

- **Problema:** dois "currículo 2026 de CC" distintos.
- **Correção:** `UNIQUE (curso_id, ano_vigencia)`.

### C9 — `feriado` sem unicidade e sem semântica definida para campus NULL

- **Problema:** o mesmo feriado pode ser cadastrado N vezes. E o que significa
  `campus_id NULL`? Definimos: **NULL = feriado nacional** (vale para todos os campi).
  Detalhe técnico: em `UNIQUE` comum, NULLs não conflitam entre si — dois feriados nacionais
  na mesma data passariam.
- **Correção:** `UNIQUE NULLS NOT DISTINCT (campus_id, data)` (recurso do PostgreSQL 15+).

### C10 — `turma_horario` sem proteção contra choque de sala

- **Problema:** duas turmas podem ocupar **a mesma sala, no mesmo dia, em faixas sobrepostas**.
  É exatamente o tipo de regra que constraint de unicidade comum não pega (sobreposição ≠ igualdade).
- **Correção:** restrição de exclusão com GiST:
  `EXCLUDE USING gist (periodo_letivo_id WITH =, sala_id WITH =, dia_semana WITH =, faixa WITH &&)`
  (requer a extensão `btree_gist` para misturar `=` escalar com `&&` de range).
- **Decisão de projeto embutida:** o conflito só existe **dentro do mesmo período letivo**
  (a sala ocupada na segunda 19h de 2025/2 não conflita com 2026/2). Como `turma_horario`
  não tem o período, **denormalizamos** `periodo_letivo_id` para dentro dela, amarrado por
  FK composta `(turma_id, periodo_letivo_id) → turma (id, periodo_letivo_id)` — a
  denormalização é controlada: não pode divergir da turma.
  Também adicionamos `EXCLUDE (turma_id WITH =, dia_semana WITH =, faixa WITH &&)`
  (a própria turma não pode ter dois horários sobrepostos) e `CHECK (dia_semana BETWEEN 1 AND 7)`
  (convenção ISO: 1 = segunda) e `CHECK (NOT isempty(faixa))`.

### C11 — `log_matricula.matricula_id` sem FK — decisão documentada

- **Observação:** no diagrama, `matricula_id` do log **não** está marcado como FK.
- **Decisão:** manter **sem FK, de propósito**. É trilha de auditoria: o registro de log deve
  sobreviver à eventual remoção da matrícula que o originou (com FK + CASCADE o log sumiria
  junto; com RESTRICT, impediria expurgo). Defaults completam o desenho:
  `ocorrido_em DEFAULT now()`, `usuario name DEFAULT current_user`, `detalhe jsonb`.
- **Alternativa rejeitada:** FK com `ON DELETE SET NULL` — perderíamos a referência histórica
  no expurgo, que é justamente o que o log quer preservar.

## Omissões de tipos, domínios e validações

### C12 — Nenhuma validação de domínio nos atributos

O modelo indica tipos "customizados" (`nota_t`, `pct_t`, `turno_t`, `status_mat_t`, …) mas não
os define. Definimos no DDL:

| Tipo | Definição | Usado em |
|---|---|---|
| `nota_t` | `DOMAIN numeric(4,2) CHECK (0 ≤ valor ≤ 10)` | historico.nota_a1/a2/p3 |
| `pct_t` | `DOMAIN numeric(5,2) CHECK (0 ≤ valor ≤ 100)` | historico.frequencia |
| `cpf_t` | `DOMAIN char(11) CHECK (~ '^[0-9]{11}$')` | aluno.cpf |
| `turno_t` | `ENUM (matutino, vespertino, noturno)` | turma.turno |
| `tipo_sala_t` | `ENUM (teorica, laboratorio, auditorio)` | sala.tipo |
| `vinculo_t` | `ENUM (pre_requisito, co_requisito)` | pre_requisito.vinculo |
| `tipo_disc_t` | `ENUM (obrigatoria, optativa, eletiva)` | curriculo_disciplina.tipo |
| `status_mat_t` | `ENUM (pendente, confirmada, trancada, cancelada)` | matricula.status |
| `situacao_t` | `ENUM (cursando, aprovado, reprovado_nota, reprovado_frequencia, trancado)` | historico.situacao |
| `timerange` | `RANGE (subtype = time)` — ver C1 | turma_horario.faixa |

Critério **enum vs domain**: enum para conjuntos fechados de rótulos controlados pelo DBA;
domain para restrições de faixa/formato sobre um tipo base.

Além disso o modelo não marca nulidade nem checks básicos. Adotamos: `NOT NULL` por padrão
(exceções documentadas coluna a coluna no DDL) e CHECKs de sanidade — `vagas >= 0`,
`capacidade > 0`, cargas horárias `>= 0` com `ch_teorica + ch_pratica > 0`,
`nascimento < ingresso`, e-mail com `@`, etc.

### C13 — Colunas geradas indicadas mas não especificadas

- `disciplina.ch_total` = `GENERATED ALWAYS AS (ch_teorica + ch_pratica) STORED`.
- `historico.media_final` = regra institucional: `MF = 0,4·A1 + 0,6·A2`; se houver P3, ela
  **substitui a nota que mais beneficia o aluno**:
  `GREATEST(0.4·a1 + 0.6·a2, 0.4·p3 + 0.6·a2, 0.4·a1 + 0.6·p3)`.
  NULL até que A1 e A2 estejam lançadas. `STORED` (única modalidade no PG 17) — e por ser
  gerada, é **impossível** haver média inconsistente com as notas.

## Regras reais que constraint declarativa não alcança (registradas para o Marco 2)

| Regra | Por que não é constraint | Tratamento planejado |
|---|---|---|
| Nº de confirmadas ≤ `turma.vagas` | envolve agregação sobre outra tabela | transação da "última vaga" (Marco 2 — é o cerne do marco de concorrência) |
| `turma.vagas` ≤ capacidade da sala | atravessa `turma_horario → sala` | validação em transação/trigger |
| Choque de horário do **aluno** (2 turmas sobrepostas) | atravessa matricula×turma_horario | consulta 9 detecta; regra de negócio na matrícula |
| Ciclos em `pre_requisito` | recursivo por natureza | consulta 5 audita; trigger candidata |
| Matrícula exige pré-requisitos aprovados | consulta recursiva sobre histórico | consulta 6 verifica; regra da transação de matrícula |

---

*Resumo executivo: 1 erro fatal de tipo (C1), 9 falhas de integridade (C2–C10), 1 decisão
de auditoria documentada (C11), tipos/domínios e colunas geradas especificados (C12–C13).*
