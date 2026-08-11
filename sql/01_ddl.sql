-- ============================================================================
-- 01_ddl.sql — Marco 1 · DDL completo (tipos, domínios, tabelas e restrições)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Implementa o Modelo Lógico fornecido no enunciado, CORRIGINDO os erros do
-- modelo. Cada correção é marcada com [C#] e explicada em
-- docs/correcoes-modelo-logico.md.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/01_ddl.sql
-- O script é idempotente: recria o esquema do zero a cada execução.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- Reset completo (permite reexecutar sem `docker compose down -v`)
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

-- [C10] btree_gist permite misturar igualdade escalar (=) com sobreposição de
-- range (&&) numa mesma restrição de exclusão GiST.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ============================================================================
-- 1. TIPOS E DOMÍNIOS  [C12]
--    Critério: ENUM para conjuntos fechados de rótulos; DOMAIN para faixa ou
--    formato sobre um tipo base.
-- ============================================================================

-- [C1] O modelo lógico usa "timerange", que NÃO existe nativamente no
-- PostgreSQL (há tsrange, daterange etc., mas nenhum range de TIME).
-- Sem esta linha, o CREATE TABLE turma_horario falharia.
-- Tipos range criados assim ganham && e suporte GiST automaticamente.
CREATE TYPE timerange AS RANGE (subtype = time);

CREATE TYPE turno_t      AS ENUM ('matutino', 'vespertino', 'noturno');
CREATE TYPE tipo_sala_t  AS ENUM ('teorica', 'laboratorio', 'auditorio');
CREATE TYPE vinculo_t    AS ENUM ('pre_requisito', 'co_requisito');
CREATE TYPE tipo_disc_t  AS ENUM ('obrigatoria', 'optativa', 'eletiva');
CREATE TYPE status_mat_t AS ENUM ('pendente', 'confirmada', 'trancada', 'cancelada');
CREATE TYPE situacao_t   AS ENUM ('cursando', 'aprovado', 'reprovado_nota',
                                  'reprovado_frequencia', 'trancado');

CREATE DOMAIN nota_t AS numeric(4,2)
  CHECK (VALUE >= 0 AND VALUE <= 10);          -- notas na escala 0–10

CREATE DOMAIN pct_t AS numeric(5,2)
  CHECK (VALUE >= 0 AND VALUE <= 100);         -- percentuais 0–100

CREATE DOMAIN cpf_t AS char(11)
  CHECK (VALUE ~ '^[0-9]{11}$');               -- 11 dígitos, sem máscara

-- ============================================================================
-- 2. TABELAS
--    Ordem respeita dependências de FK. IDs com GENERATED ALWAYS AS IDENTITY
--    (padrão SQL moderno; evita os problemas clássicos de SERIAL).
--    Política de deleção: RESTRICT (implícito) no núcleo acadêmico — dado
--    acadêmico não some por arrasto; CASCADE apenas em tabelas-detalhe.
-- ============================================================================

CREATE TABLE campus (
  id     smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome   varchar(60) NOT NULL UNIQUE,
  cidade varchar(60) NOT NULL
);
COMMENT ON TABLE campus IS 'Campi do centro universitário.';

CREATE TABLE curso (
  id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo    varchar(10)  NOT NULL UNIQUE,
  nome      varchar(120) NOT NULL,
  grau      varchar(20)  NOT NULL
            CHECK (grau IN ('bacharelado', 'licenciatura', 'tecnologo')),
  ch_total  integer      NOT NULL CHECK (ch_total > 0),
  campus_id smallint     NOT NULL REFERENCES campus (id)
);
COMMENT ON TABLE curso IS 'Cursos de graduação ofertados.';

CREATE TABLE curriculo (
  id           integer  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  curso_id     smallint NOT NULL REFERENCES curso (id),
  ano_vigencia smallint NOT NULL CHECK (ano_vigencia BETWEEN 1990 AND 2100),
  ativo        boolean  NOT NULL DEFAULT true,
  -- [C8] sem isto, dois "currículo 2026" do mesmo curso seriam aceitos
  CONSTRAINT uq_curriculo_curso_ano UNIQUE (curso_id, ano_vigencia),
  -- [C6] superchave-alvo da FK composta de aluno (garante currículo do curso certo)
  CONSTRAINT uq_curriculo_id_curso  UNIQUE (id, curso_id)
);
COMMENT ON TABLE curriculo IS 'Versões de grade curricular de um curso (matriz por ano de vigência).';

CREATE TABLE disciplina (
  id         integer  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo     varchar(10)  NOT NULL UNIQUE,
  nome       varchar(120) NOT NULL,
  ch_teorica smallint NOT NULL DEFAULT 0 CHECK (ch_teorica >= 0),
  ch_pratica smallint NOT NULL DEFAULT 0 CHECK (ch_pratica >= 0),
  -- [C13] coluna gerada: impossível divergir da soma das cargas
  ch_total   smallint GENERATED ALWAYS AS (ch_teorica + ch_pratica) STORED,
  ementa     text,
  CONSTRAINT ck_disciplina_ch_positiva CHECK (ch_teorica + ch_pratica > 0)
);
COMMENT ON TABLE disciplina IS 'Catálogo de disciplinas (independente de curso; a ligação é via currículo).';
COMMENT ON COLUMN disciplina.ch_total IS 'Gerada: ch_teorica + ch_pratica [C13].';

CREATE TABLE pre_requisito (
  disciplina_id integer   NOT NULL REFERENCES disciplina (id) ON DELETE CASCADE,
  requisito_id  integer   NOT NULL REFERENCES disciplina (id) ON DELETE CASCADE,
  vinculo       vinculo_t NOT NULL DEFAULT 'pre_requisito',
  PRIMARY KEY (disciplina_id, requisito_id),
  -- [C7] disciplina não pode ser pré-requisito de si mesma
  -- (ciclos maiores não são expressáveis em constraint — ver consulta 5 e docs)
  CONSTRAINT ck_prereq_nao_reflexivo CHECK (disciplina_id <> requisito_id)
);
COMMENT ON TABLE pre_requisito IS 'Auto-relacionamento N:N: disciplina_id EXIGE requisito_id.';

CREATE TABLE curriculo_disciplina (
  curriculo_id  integer     NOT NULL REFERENCES curriculo (id) ON DELETE CASCADE,
  disciplina_id integer     NOT NULL REFERENCES disciplina (id),
  periodo       smallint    NOT NULL CHECK (periodo BETWEEN 1 AND 12),
  tipo          tipo_disc_t NOT NULL DEFAULT 'obrigatoria',
  PRIMARY KEY (curriculo_id, disciplina_id)
);
COMMENT ON TABLE curriculo_disciplina IS 'Grade: em que período de cada currículo cada disciplina é sugerida.';

CREATE TABLE professor (
  id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  matricula varchar(12)  NOT NULL UNIQUE,
  nome      varchar(120) NOT NULL,
  email     varchar(120) NOT NULL UNIQUE CHECK (position('@' in email) > 1),
  titulacao varchar(20)
            CHECK (titulacao IN ('graduacao', 'especializacao', 'mestrado', 'doutorado'))
);
COMMENT ON TABLE professor IS 'Corpo docente. titulacao é anulável (pode não estar informada).';

CREATE TABLE periodo_letivo (
  id          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ano         smallint NOT NULL,
  semestre    smallint NOT NULL CHECK (semestre IN (1, 2)),
  data_inicio date     NOT NULL,
  data_fim    date     NOT NULL,
  -- [C3] sem isto, dois registros "2026/2" seriam aceitos
  CONSTRAINT uq_periodo_ano_semestre UNIQUE (ano, semestre),
  CONSTRAINT ck_periodo_datas        CHECK (data_inicio < data_fim)
);
COMMENT ON TABLE periodo_letivo IS 'Semestres letivos (ex.: 2026/2).';

CREATE TABLE sala (
  id         integer  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  campus_id  smallint NOT NULL REFERENCES campus (id),
  codigo     varchar(10) NOT NULL,
  capacidade smallint NOT NULL CHECK (capacidade > 0),
  tipo       tipo_sala_t NOT NULL DEFAULT 'teorica',
  -- [C4] código de sala é único DENTRO do campus (campi podem repetir códigos)
  CONSTRAINT uq_sala_campus_codigo UNIQUE (campus_id, codigo)
);
COMMENT ON TABLE sala IS 'Salas físicas, por campus.';

CREATE TABLE turma (
  id                integer  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo            varchar(15) NOT NULL,
  disciplina_id     integer  NOT NULL REFERENCES disciplina (id),
  periodo_letivo_id smallint NOT NULL REFERENCES periodo_letivo (id),
  professor_id      integer  NOT NULL REFERENCES professor (id),
  turno             turno_t  NOT NULL,
  vagas             smallint NOT NULL CHECK (vagas >= 0),
  -- [C5] código de turma é único DENTRO do período letivo (repete entre semestres)
  CONSTRAINT uq_turma_periodo_codigo UNIQUE (periodo_letivo_id, codigo),
  -- [C10] superchave-alvo da FK composta de turma_horario
  CONSTRAINT uq_turma_id_periodo     UNIQUE (id, periodo_letivo_id)
);
COMMENT ON TABLE turma IS 'Oferta de uma disciplina em um período letivo.';
COMMENT ON COLUMN turma.vagas IS 'Limite de matrículas confirmadas — a disputa pela última vaga é o Marco 2.';

CREATE TABLE turma_horario (
  id                integer   GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  turma_id          integer   NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da turma via FK
  -- composta (não pode divergir) e permite restringir choque de sala por período.
  periodo_letivo_id smallint  NOT NULL,
  sala_id           integer   NOT NULL REFERENCES sala (id),
  dia_semana        smallint  NOT NULL CHECK (dia_semana BETWEEN 1 AND 7), -- ISO: 1=segunda
  faixa             timerange NOT NULL CHECK (NOT isempty(faixa)),         -- [C1]
  CONSTRAINT fk_horario_turma_periodo
    FOREIGN KEY (turma_id, periodo_letivo_id)
    REFERENCES turma (id, periodo_letivo_id) ON DELETE CASCADE,
  -- [C10] uma sala não pode receber duas turmas em faixas sobrepostas no mesmo
  -- dia do mesmo período letivo (igualdade escalar + && de range ⇒ GiST + btree_gist)
  CONSTRAINT ex_sala_sem_choque EXCLUDE USING gist (
    periodo_letivo_id WITH =, sala_id WITH =, dia_semana WITH =, faixa WITH &&),
  -- [C10] a própria turma não pode ter dois horários sobrepostos no mesmo dia
  CONSTRAINT ex_turma_sem_choque EXCLUDE USING gist (
    turma_id WITH =, dia_semana WITH =, faixa WITH &&)
);
COMMENT ON TABLE turma_horario IS 'Encontros semanais de uma turma (dia, faixa horária, sala).';

CREATE TABLE aluno (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  matricula    varchar(12)  NOT NULL UNIQUE,
  nome         varchar(120) NOT NULL,
  cpf          cpf_t        NOT NULL UNIQUE,                               -- [C12]
  email        varchar(120) NOT NULL UNIQUE CHECK (position('@' in email) > 1),
  nascimento   date,
  curso_id     smallint NOT NULL REFERENCES curso (id),
  curriculo_id integer  NOT NULL,
  ingresso     date     NOT NULL,
  ativo        boolean  NOT NULL DEFAULT true,
  -- [C6] FK COMPOSTA: o currículo do aluno tem que ser um currículo do curso
  -- do aluno. Com duas FKs separadas (como no modelo lógico), aluno de
  -- Computação poderia apontar currículo de Direito.
  CONSTRAINT fk_aluno_curriculo_do_curso
    FOREIGN KEY (curriculo_id, curso_id) REFERENCES curriculo (id, curso_id),
  CONSTRAINT ck_aluno_nascimento_ingresso
    CHECK (nascimento IS NULL OR nascimento < ingresso)
);
COMMENT ON TABLE aluno IS 'Alunos. curso_id + curriculo_id amarrados por FK composta [C6].';

CREATE TABLE matricula (
  id             integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  aluno_id       integer      NOT NULL REFERENCES aluno (id),
  turma_id       integer      NOT NULL REFERENCES turma (id),
  data_matricula timestamptz  NOT NULL DEFAULT now(),
  status         status_mat_t NOT NULL DEFAULT 'confirmada',
  -- [C2] sem isto, o mesmo aluno se matricula duas vezes na mesma turma
  CONSTRAINT uq_matricula_aluno_turma UNIQUE (aluno_id, turma_id)
);
COMMENT ON TABLE matricula IS 'Vínculo aluno×turma. Vaga é consumida por status=confirmada.';

CREATE TABLE historico (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE ⇒ relação 1:1 com matricula (extensão de avaliação da matrícula);
  -- CASCADE: histórico é detalhe da matrícula, não vive sem ela.
  matricula_id integer NOT NULL UNIQUE REFERENCES matricula (id) ON DELETE CASCADE,
  nota_a1      nota_t,                          -- [C12] domínio 0–10
  nota_a2      nota_t,
  nota_p3      nota_t,
  frequencia   pct_t,                           -- [C12] domínio 0–100
  situacao     situacao_t NOT NULL DEFAULT 'cursando',
  -- [C13] regra institucional: MF = 0,4·A1 + 0,6·A2; se houver P3, ela
  -- substitui a nota que mais beneficia o aluno. Gerada ⇒ nunca inconsistente.
  media_final  numeric(4,2) GENERATED ALWAYS AS (
    CASE
      WHEN nota_a1 IS NULL OR nota_a2 IS NULL THEN NULL
      WHEN nota_p3 IS NULL THEN round(0.4 * nota_a1 + 0.6 * nota_a2, 2)
      ELSE round(GREATEST(0.4 * nota_a1 + 0.6 * nota_a2,
                          0.4 * nota_p3 + 0.6 * nota_a2,
                          0.4 * nota_a1 + 0.6 * nota_p3), 2)
    END) STORED
);
COMMENT ON TABLE historico IS 'Resultado acadêmico 1:1 com matricula; media_final é coluna gerada [C13].';

CREATE TABLE feriado (
  id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  data      date         NOT NULL,
  descricao varchar(120) NOT NULL,
  campus_id smallint REFERENCES campus (id) ON DELETE CASCADE,  -- NULL = nacional
  -- [C9] sem NULLS NOT DISTINCT (PG 15+), dois feriados NACIONAIS na mesma
  -- data passariam (NULL ≠ NULL em UNIQUE comum)
  CONSTRAINT uq_feriado_campus_data UNIQUE NULLS NOT DISTINCT (campus_id, data)
);
COMMENT ON TABLE feriado IS 'Feriados; campus_id NULL = feriado nacional [C9].';

CREATE TABLE log_matricula (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK, de propósito: trilha de auditoria sobrevive à remoção da
  -- origem (decisão documentada em docs/correcoes-modelo-logico.md)
  matricula_id integer,
  acao         varchar(20) NOT NULL,
  ocorrido_em  timestamptz NOT NULL DEFAULT now(),
  usuario      name        NOT NULL DEFAULT current_user,
  detalhe      jsonb
);
COMMENT ON TABLE log_matricula IS 'Auditoria de eventos de matrícula. matricula_id sem FK de propósito [C11].';

COMMIT;

-- Confirmação visual ao final da execução
\echo '=== Esquema criado. Tabelas: ==='
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
