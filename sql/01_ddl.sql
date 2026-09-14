-- ============================================================================
-- 01_ddl.sql — DDL completo do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- O modelo do professor é a BASE (16 tabelas, correções [C1]–[C15]); a ampliação
-- [E1]–[E15] foi modelada em docs/esboco-schema-ampliado.md, revisada e validada
-- em banco descartável. Cada decisão é marcada no ponto em que vira DDL.
--
-- Ordem de colunas (padrão exigido): PK, FK, varchar, text, char, inteiros,
-- decimais — e depois data/hora e ranges, boolean, ENUM, jsonb.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d <banco> < sql/01_ddl.sql
-- Idempotente: recria o schema academico do zero a cada execução.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- [C15] Schema próprio; reset barato e de escopo restrito.
DROP SCHEMA IF EXISTS academico CASCADE;
CREATE SCHEMA academico;
SET search_path TO academico, public;

-- [C10] igualdade escalar + && numa mesma restrição de exclusão GiST.
-- [C15] A extensão fica em public: sobrevive ao DROP SCHEMA academico.
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;

-- ============================================================================
-- 1. TIPOS E DOMÍNIOS  [C12]
--    ENUM para conjunto fechado de rótulos; DOMAIN para faixa ou formato.
-- ============================================================================

-- [C1] range de TIME não existe nativamente; sem isto turma_horario não compila.
CREATE TYPE timerange AS RANGE (subtype = time);

-- [E16] DIVERGÊNCIA DELIBERADA do modelo do professor, que traz três turnos
-- ('MATUTINO','VESPERTINO','NOTURNO'). Esta instituição opera em DOIS: manhã e
-- noite. Rótulo que o domínio não usa é rótulo que um dia entra por engano —
-- o ENUM existe justamente para fechar o conjunto no valor certo, e um valor a
-- mais enfraquece a garantia. A base do professor segue com os três em
-- docs/modelo-fisico.html, que documenta o ponto de partida.
CREATE TYPE turno_t                AS ENUM ('matutino', 'noturno');
CREATE TYPE tipo_sala_t            AS ENUM ('teorica', 'laboratorio', 'auditorio');
CREATE TYPE vinculo_t              AS ENUM ('pre_requisito', 'co_requisito');
CREATE TYPE tipo_disc_t            AS ENUM ('obrigatoria', 'optativa', 'eletiva');
CREATE TYPE status_mat_t           AS ENUM ('pendente', 'confirmada', 'trancada', 'cancelada');
CREATE TYPE situacao_t             AS ENUM ('cursando', 'aprovado', 'reprovado_nota',
                                            'reprovado_frequencia', 'trancado');
-- [E2..E15] tipos novos da ampliação
CREATE TYPE tipo_telefone_t        AS ENUM ('celular', 'residencial', 'comercial');
CREATE TYPE tipo_documento_t       AS ENUM ('rg', 'passaporte', 'cnh', 'rne');  -- CPF fica em pessoa [E2]
CREATE TYPE papel_usuario_t        AS ENUM ('aluno', 'secretaria', 'coordenacao', 'admin');
CREATE TYPE regime_professor_t     AS ENUM ('horista', 'parcial', 'integral');
CREATE TYPE titulacao_t            AS ENUM ('graduacao', 'especializacao', 'mestrado',
                                            'doutorado', 'pos_doutorado');
CREATE TYPE forma_ingresso_t       AS ENUM ('vestibular', 'enem', 'transferencia', 'portador_diploma');
CREATE TYPE status_aluno_t         AS ENUM ('ativo', 'trancado', 'formado', 'evadido', 'jubilado');
CREATE TYPE grau_curso_t           AS ENUM ('bacharelado', 'licenciatura', 'tecnologo');
CREATE TYPE modalidade_t           AS ENUM ('presencial', 'ead', 'hibrido');
CREATE TYPE papel_docente_t        AS ENUM ('titular', 'auxiliar', 'substituto');
CREATE TYPE tipo_periodo_matricula_t AS ENUM ('matricula', 'ajuste', 'trancamento', 'rematricula');
CREATE TYPE tipo_aula_t            AS ENUM ('teorica', 'pratica');
CREATE TYPE tipo_bibliografia_t    AS ENUM ('basica', 'complementar');
CREATE TYPE status_aproveitamento_t AS ENUM ('pendente', 'deferido', 'indeferido');
CREATE TYPE acao_log_t             AS ENUM ('insert', 'update', 'delete');

CREATE DOMAIN nota_t AS numeric(4,2) CHECK (VALUE >= 0 AND VALUE <= 10);
CREATE DOMAIN pct_t  AS numeric(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);
CREATE DOMAIN cpf_t  AS char(11)     CHECK (VALUE ~ '^[0-9]{11}$');

-- ============================================================================
-- 2. GEOGRAFIA  [E1]
--    Tira "Brasília" de string repetida: cidade→estado→país com dedup por nível.
-- ============================================================================

CREATE TABLE pais (
  id_pais    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_pais  varchar(60) NOT NULL UNIQUE,
  sigla_pais char(2)     NOT NULL UNIQUE                          -- ISO 3166-1
);
COMMENT ON TABLE pais IS 'Países [E1].';

CREATE TABLE estado (
  id_estado   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pais     smallint    NOT NULL REFERENCES pais (id_pais),
  nome_estado varchar(60) NOT NULL,
  uf_estado   char(2)     NOT NULL,
  CONSTRAINT uq_estado_pais_uf UNIQUE (id_pais, uf_estado)
);
COMMENT ON TABLE estado IS 'Unidades federativas [E1].';

CREATE TABLE cidade (
  id_cidade          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_estado          smallint    NOT NULL REFERENCES estado (id_estado),
  nome_cidade        varchar(80) NOT NULL,
  codigo_ibge_cidade char(7)     UNIQUE,
  CONSTRAINT uq_cidade_estado_nome UNIQUE (id_estado, nome_cidade)
);
COMMENT ON TABLE cidade IS 'Municípios; "Brasilia" ≠ "BRASÍLIA" morre aqui [E1].';

CREATE TABLE endereco (
  id_endereco          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cidade            integer      NOT NULL REFERENCES cidade (id_cidade),
  logradouro_endereco  varchar(120) NOT NULL,
  numero_endereco      varchar(10),                               -- varchar: "s/n"
  complemento_endereco varchar(60),
  bairro_endereco      varchar(60),
  cep_endereco         char(8) CHECK (cep_endereco ~ '^[0-9]{8}$')
);
COMMENT ON TABLE endereco IS 'Endereços de pessoas e campi [E1].';

-- ============================================================================
-- 3. PESSOAS  [E2] [E3]
--    pessoa é o supertipo; aluno e professor são especializações 1:1 e não
--    exclusivas (um professor pode ser aluno de outro curso).
-- ============================================================================

CREATE TABLE pessoa (
  id_pessoa         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_endereco       integer REFERENCES endereco (id_endereco),
  nome_pessoa       varchar(120) NOT NULL,
  email_pessoa      varchar(120) NOT NULL UNIQUE CHECK (position('@' in email_pessoa) > 1),
  -- [E2] CPF é 1:1 com a pessoa no Brasil: fica AQUI, obrigatório, preservando
  -- [C12]. documento_pessoa guarda os demais documentos (multivalorados).
  cpf_pessoa        cpf_t NOT NULL UNIQUE,
  nascimento_pessoa date  NOT NULL
);
COMMENT ON TABLE pessoa IS 'Supertipo de aluno e professor [E2]; nome/e-mail/CPF vivem só aqui.';

CREATE TABLE telefone (
  id_telefone        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa          integer     NOT NULL REFERENCES pessoa (id_pessoa) ON DELETE CASCADE,
  numero_telefone    varchar(20) NOT NULL,
  principal_telefone boolean     NOT NULL DEFAULT false,
  tipo_telefone      tipo_telefone_t NOT NULL,
  CONSTRAINT uq_telefone_pessoa_numero UNIQUE (id_pessoa, numero_telefone)
);
COMMENT ON TABLE telefone IS 'Multivalorado → tabela (1FN) [E3]. Um principal por pessoa: índice parcial.';
-- só um telefone principal por pessoa (validado em banco descartável)
CREATE UNIQUE INDEX uq_telefone_principal ON telefone (id_pessoa) WHERE principal_telefone;

CREATE TABLE documento_pessoa (
  id_documento_pessoa      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa                integer     NOT NULL REFERENCES pessoa (id_pessoa) ON DELETE CASCADE,
  numero_documento_pessoa  varchar(20) NOT NULL,
  orgao_documento_pessoa   varchar(20),
  emissao_documento_pessoa date,
  tipo_documento_pessoa    tipo_documento_t NOT NULL,
  -- o mesmo documento não pode pertencer a duas pessoas…
  CONSTRAINT uq_documento_tipo_numero UNIQUE (tipo_documento_pessoa, numero_documento_pessoa),
  -- …e uma pessoa tem no máximo um documento de cada tipo
  CONSTRAINT uq_documento_pessoa_tipo UNIQUE (id_pessoa, tipo_documento_pessoa)
);
COMMENT ON TABLE documento_pessoa IS 'Documentos além do CPF [E3]; CPF mora em pessoa [E2].';

CREATE TABLE usuario (
  id_usuario    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa     integer     NOT NULL UNIQUE REFERENCES pessoa (id_pessoa),
  login_usuario varchar(60) NOT NULL UNIQUE,     -- = nome da ROLE no PostgreSQL [E4]
  ativo_usuario boolean     NOT NULL DEFAULT true,
  papel_usuario papel_usuario_t NOT NULL
);
COMMENT ON TABLE usuario IS 'Conta de acesso; login = ROLE do Postgres, casa com a RLS al_<RA> [E4].';

-- ============================================================================
-- 4. ESTRUTURA FÍSICA E ORGANIZACIONAL  [E5] [E6]
-- ============================================================================

CREATE TABLE campus (
  id_campus   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE honra a cardinalidade (0,1) do lado do endereço (achado F1 da revisão)
  id_endereco integer     NOT NULL UNIQUE REFERENCES endereco (id_endereco),
  nome_campus varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE campus IS 'Campi; cidade_campus saiu — vem de endereco→cidade [E1].';

CREATE TABLE departamento (
  id_departamento    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus          smallint    NOT NULL REFERENCES campus (id_campus),
  id_professor_chefe integer,       -- FK circular com professor: constraint via ALTER, adiante [E6]
  nome_departamento  varchar(80) NOT NULL,
  sigla_departamento varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE departamento IS 'Departamentos; chefe é FK circular resolvida por ALTER [E6].';

CREATE TABLE predio (
  id_predio      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus      smallint    NOT NULL REFERENCES campus (id_campus),
  nome_predio    varchar(60) NOT NULL,
  andares_predio smallint CHECK (andares_predio > 0),
  CONSTRAINT uq_predio_campus_nome UNIQUE (id_campus, nome_predio)
);
COMMENT ON TABLE predio IS 'Prédios do campus [E5].';

CREATE TABLE sala (
  id_sala         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E5] sala muda de dono: o campus vem via prédio. [C4] evolui junto:
  -- código único DENTRO do prédio (prédios do mesmo campus podem repetir).
  id_predio       smallint    NOT NULL REFERENCES predio (id_predio),
  codigo_sala     varchar(10) NOT NULL,
  andar_sala      smallint,
  capacidade_sala smallint    NOT NULL CHECK (capacidade_sala > 0),
  tipo_sala       tipo_sala_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT uq_sala_predio_codigo UNIQUE (id_predio, codigo_sala)   -- [C4→E5]
);
COMMENT ON TABLE sala IS 'Salas físicas, por prédio [E5]; [C4] agora por prédio.';

CREATE TABLE recurso (
  id_recurso   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_recurso varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE recurso IS 'Recursos alocáveis (projetor, bancada…) [E3].';

CREATE TABLE sala_recurso (
  id_sala                 integer  NOT NULL REFERENCES sala (id_sala) ON DELETE CASCADE,
  id_recurso              smallint NOT NULL REFERENCES recurso (id_recurso),
  quantidade_sala_recurso smallint NOT NULL DEFAULT 1 CHECK (quantidade_sala_recurso > 0),
  PRIMARY KEY (id_sala, id_recurso)
);
COMMENT ON TABLE sala_recurso IS 'N:N sala×recurso — o critério para alocar laboratório [E3].';

CREATE TABLE professor (
  id_professor        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa           integer     NOT NULL UNIQUE REFERENCES pessoa (id_pessoa),
  id_departamento     smallint    NOT NULL REFERENCES departamento (id_departamento),
  matricula_professor varchar(12) NOT NULL UNIQUE,
  regime_professor    regime_professor_t NOT NULL,
  titulacao_professor titulacao_t NOT NULL
);
COMMENT ON TABLE professor IS 'Especialização 1:1 de pessoa [E2]; só o que é vínculo de trabalho.';

-- [E6] a FK circular departamento↔professor entra agora, com UNIQUE (F4: um
-- professor chefia no máximo um departamento; UNIQUE aceita vários NULLs).
ALTER TABLE departamento
  ADD CONSTRAINT fk_departamento_chefe
      FOREIGN KEY (id_professor_chefe) REFERENCES professor (id_professor),
  ADD CONSTRAINT uq_departamento_chefe UNIQUE (id_professor_chefe);

CREATE TABLE formacao_professor (
  id_formacao_professor            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_professor                     integer      NOT NULL REFERENCES professor (id_professor) ON DELETE CASCADE,
  curso_formacao_professor         varchar(120) NOT NULL,
  instituicao_formacao_professor   varchar(120) NOT NULL,
  ano_conclusao_formacao_professor smallint     NOT NULL CHECK (ano_conclusao_formacao_professor BETWEEN 1950 AND 2100),
  titulacao_formacao_professor     titulacao_t  NOT NULL,
  CONSTRAINT uq_formacao_prof UNIQUE (id_professor, curso_formacao_professor, instituicao_formacao_professor)
);
COMMENT ON TABLE formacao_professor IS 'Formações (multivalorado, 1FN) [E3]; a titulação declarada fica em professor.';

-- ============================================================================
-- 5. ESTRUTURA ACADÊMICA  [E7] [E8] [E15]
-- ============================================================================

CREATE TABLE curso (
  id_curso        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus       smallint     NOT NULL REFERENCES campus (id_campus),
  id_departamento smallint     NOT NULL REFERENCES departamento (id_departamento),
  codigo_curso    varchar(10)  NOT NULL UNIQUE,
  nome_curso      varchar(120) NOT NULL,
  ch_total_curso  integer      NOT NULL CHECK (ch_total_curso > 0),
  grau_curso      grau_curso_t NOT NULL,          -- era varchar+CHECK: rótulo fechado ⇒ ENUM [C12]
  modalidade_curso modalidade_t NOT NULL DEFAULT 'presencial'
);
COMMENT ON TABLE curso IS 'Cursos; ganham departamento [E6] e modalidade.';

CREATE TABLE coordenacao_curso (
  id_coordenacao_curso       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso                   smallint    NOT NULL REFERENCES curso (id_curso),
  id_professor               integer     NOT NULL REFERENCES professor (id_professor),
  portaria_coordenacao_curso varchar(30),
  vigencia_coordenacao_curso daterange   NOT NULL CHECK (NOT isempty(vigencia_coordenacao_curso)),
  -- [E8] um coordenador por curso a cada instante — técnica de [C10], sem trigger.
  -- Vigência aberta: daterange(inicio, NULL). Validado em banco descartável.
  CONSTRAINT ex_coordenacao_vigencia EXCLUDE USING gist
    (id_curso WITH =, vigencia_coordenacao_curso WITH &&)
);
COMMENT ON TABLE coordenacao_curso IS 'Mandatos de coordenação; EXCLUDE de vigência [E8].';

CREATE TABLE curriculo (
  id_curriculo           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso               smallint    NOT NULL REFERENCES curso (id_curso),
  portaria_curriculo     varchar(30),
  ano_vigencia_curriculo smallint    NOT NULL CHECK (ano_vigencia_curriculo BETWEEN 1990 AND 2100),
  ativo_curriculo        boolean     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculo_curso_ano UNIQUE (id_curso, ano_vigencia_curriculo),   -- [C8]
  CONSTRAINT uq_curriculo_id_curso  UNIQUE (id_curriculo, id_curso)              -- alvo da FK composta [C6]
);
COMMENT ON TABLE curriculo IS 'Matrizes curriculares por ano [C8]; alvo de [C6].';

CREATE TABLE disciplina (
  id_disciplina         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_departamento       smallint     NOT NULL REFERENCES departamento (id_departamento),
  codigo_disciplina     varchar(10)  NOT NULL UNIQUE,
  nome_disciplina       varchar(120) NOT NULL,
  ementa_disciplina     text,
  ch_teorica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_teorica_disciplina >= 0),
  ch_pratica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_pratica_disciplina >= 0),
  ch_total_disciplina   smallint GENERATED ALWAYS AS (ch_teorica_disciplina + ch_pratica_disciplina) STORED,  -- [C13]
  CONSTRAINT ck_disciplina_ch_positiva CHECK (ch_teorica_disciplina + ch_pratica_disciplina > 0)
);
COMMENT ON TABLE disciplina IS 'Catálogo; ch_total é gerada [C13]; ementa é a descrição perene — o plano de ensino é a execução [E7].';

CREATE TABLE curriculo_disciplina (
  id_curriculo                 integer     NOT NULL REFERENCES curriculo (id_curriculo) ON DELETE CASCADE,
  id_disciplina                integer     NOT NULL REFERENCES disciplina (id_disciplina),
  periodo_curriculo_disciplina smallint    NOT NULL CHECK (periodo_curriculo_disciplina BETWEEN 1 AND 12),
  tipo_curriculo_disciplina    tipo_disc_t NOT NULL DEFAULT 'obrigatoria',
  PRIMARY KEY (id_curriculo, id_disciplina)
);
COMMENT ON TABLE curriculo_disciplina IS 'Grade: período sugerido de cada disciplina no currículo.';

CREATE TABLE pre_requisito (
  id_disciplina             integer   NOT NULL REFERENCES disciplina (id_disciplina) ON DELETE CASCADE,
  id_requisito              integer   NOT NULL REFERENCES disciplina (id_disciplina) ON DELETE CASCADE,
  ch_minima_pre_requisito   smallint  CHECK (ch_minima_pre_requisito > 0),  -- alternativa por CH acumulada
  media_minima_pre_requisito nota_t   NOT NULL DEFAULT 5.00,
  vinculo_pre_requisito     vinculo_t NOT NULL DEFAULT 'pre_requisito',
  PRIMARY KEY (id_disciplina, id_requisito),
  CONSTRAINT ck_prereq_nao_reflexivo CHECK (id_disciplina <> id_requisito)   -- [C7]
);
COMMENT ON TABLE pre_requisito IS 'id_disciplina EXIGE id_requisito, com média/CH mínimas por aresta; ciclos maiores: consulta recursiva [C7].';

CREATE TABLE aluno (
  id_aluno             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa            integer     NOT NULL UNIQUE REFERENCES pessoa (id_pessoa),
  id_curso             smallint    NOT NULL REFERENCES curso (id_curso),
  id_curriculo         integer     NOT NULL,
  matricula_aluno      varchar(12) NOT NULL UNIQUE,
  ingresso_aluno       date        NOT NULL,
  forma_ingresso_aluno forma_ingresso_t NOT NULL,
  status_aluno         status_aluno_t   NOT NULL DEFAULT 'ativo',
  -- [C6] o currículo do aluno tem que ser um currículo do curso do aluno.
  CONSTRAINT fk_aluno_curriculo_do_curso
    FOREIGN KEY (id_curriculo, id_curso) REFERENCES curriculo (id_curriculo, id_curso)
);
COMMENT ON TABLE aluno IS 'Especialização 1:1 de pessoa [E2]; fica só o vínculo acadêmico. [C6] mantido.';
-- Ambiguidade HERDADA do modelo do professor, registrada para quem vier depois:
-- `matricula_aluno` é o RA (identificação do aluno na instituição, uma por aluno),
-- enquanto a TABELA `matricula` é a inscrição do aluno numa turma (muitas por aluno).
-- São conceitos distintos com a mesma palavra. Renomear divergiria da convenção do
-- professor, então o nome fica e a distinção é documentada aqui.
COMMENT ON COLUMN aluno.matricula_aluno IS
  'RA: identificação do aluno na instituição. NÃO confundir com a tabela matricula (inscrição em turma).';

CREATE TABLE aproveitamento_materia (
  id_aproveitamento_materia               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno                                integer      NOT NULL REFERENCES aluno (id_aluno),
  id_disciplina                           integer      NOT NULL REFERENCES disciplina (id_disciplina),
  id_usuario_avaliador                    integer      REFERENCES usuario (id_usuario),
  disciplina_origem_aproveitamento_materia  varchar(120) NOT NULL,
  instituicao_origem_aproveitamento_materia varchar(120) NOT NULL,
  parecer_aproveitamento_materia          text,
  ch_origem_aproveitamento_materia        smallint NOT NULL CHECK (ch_origem_aproveitamento_materia > 0),
  nota_origem_aproveitamento_materia      nota_t   NOT NULL,
  solicitacao_aproveitamento_materia      date     NOT NULL DEFAULT current_date,
  decisao_aproveitamento_materia          date,
  status_aproveitamento_materia           status_aproveitamento_t NOT NULL DEFAULT 'pendente',
  CONSTRAINT uq_aproveitamento_aluno_disc UNIQUE (id_aluno, id_disciplina)
  -- Regras de deferimento cruzam tabela (CH da disciplina, forma de ingresso):
  -- ficam na função de deferimento, não em CHECK [E15].
);
COMMENT ON TABLE aproveitamento_materia IS 'Dispensa por estudo anterior [E15]; conta em pode_cursar().';

-- ============================================================================
-- 6. TEMPO E CALENDÁRIO  [E9] [E10]
-- ============================================================================

CREATE TABLE periodo_letivo (
  id_periodo_letivo          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ano_periodo_letivo         smallint NOT NULL,
  semestre_periodo_letivo    smallint NOT NULL CHECK (semestre_periodo_letivo IN (1, 2)),
  data_inicio_periodo_letivo date     NOT NULL,
  data_fim_periodo_letivo    date     NOT NULL,
  CONSTRAINT uq_periodo_ano_semestre UNIQUE (ano_periodo_letivo, semestre_periodo_letivo),  -- [C3]
  CONSTRAINT ck_periodo_datas        CHECK (data_inicio_periodo_letivo < data_fim_periodo_letivo)
);
COMMENT ON TABLE periodo_letivo IS 'Semestres letivos [C3].';

CREATE TABLE periodo_matricula (
  id_periodo_matricula        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_periodo_letivo           smallint    NOT NULL REFERENCES periodo_letivo (id_periodo_letivo),
  descricao_periodo_matricula varchar(60) NOT NULL,
  janela_periodo_matricula    tstzrange   NOT NULL CHECK (NOT isempty(janela_periodo_matricula)),
  tipo_periodo_matricula      tipo_periodo_matricula_t NOT NULL,
  -- [E9] janelas do mesmo tipo não se sobrepõem no período; tipos diferentes
  -- podem (ajuste cobre o fim da matrícula). ENUM em GiST: btree_gist, validado.
  CONSTRAINT ex_periodo_matricula_janela EXCLUDE USING gist
    (id_periodo_letivo WITH =, tipo_periodo_matricula WITH =, janela_periodo_matricula WITH &&)
);
COMMENT ON TABLE periodo_matricula IS 'QUANDO se pode matricular [E9]; a função de matrícula consulta now() <@ janela.';

CREATE TABLE feriado (
  id_feriado          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E10] arco exclusivo: o ALCANCE do feriado é exatamente uma das 4 FKs.
  -- O ENUM de tipo foi REMOVIDO de propósito: seria derivável do arco
  -- (dependência funcional tipo↔FK — violaria 3FN); facultativo é ortogonal.
  id_pais             smallint REFERENCES pais (id_pais),
  id_estado           smallint REFERENCES estado (id_estado),
  id_cidade           integer  REFERENCES cidade (id_cidade),
  id_campus           smallint REFERENCES campus (id_campus),
  descricao_feriado   varchar(120) NOT NULL,
  data_feriado        date         NOT NULL,
  facultativo_feriado boolean      NOT NULL DEFAULT false,
  CONSTRAINT ck_feriado_arco CHECK (
    (id_pais   IS NOT NULL)::int + (id_estado IS NOT NULL)::int +
    (id_cidade IS NOT NULL)::int + (id_campus IS NOT NULL)::int = 1)
);
COMMENT ON TABLE feriado IS 'Alcance pelo arco de FKs [E10]; dedup por nível preserva [C9].';
-- [C9→E10] dedup por nível: sem isto, dois feriados nacionais na mesma data
-- voltariam a passar — que era o erro original do modelo do professor.
CREATE UNIQUE INDEX uq_feriado_pais_data   ON feriado (id_pais,   data_feriado) WHERE id_pais   IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_estado_data ON feriado (id_estado, data_feriado) WHERE id_estado IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_cidade_data ON feriado (id_cidade, data_feriado) WHERE id_cidade IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_campus_data ON feriado (id_campus, data_feriado) WHERE id_campus IS NOT NULL;

-- ============================================================================
-- 7. OFERTA E DOCÊNCIA  [E11] [E12]
-- ============================================================================

CREATE TABLE turma (
  id_turma          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina     integer     NOT NULL REFERENCES disciplina (id_disciplina),
  id_periodo_letivo smallint    NOT NULL REFERENCES periodo_letivo (id_periodo_letivo),
  codigo_turma      varchar(15) NOT NULL,
  vagas_turma       smallint    NOT NULL CHECK (vagas_turma >= 0),
  turno_turma       turno_t     NOT NULL,
  modalidade_turma  modalidade_t NOT NULL DEFAULT 'presencial',
  CONSTRAINT uq_turma_periodo_codigo UNIQUE (id_periodo_letivo, codigo_turma),  -- [C5]
  CONSTRAINT uq_turma_id_periodo     UNIQUE (id_turma, id_periodo_letivo),      -- alvo de [C10]
  CONSTRAINT uq_turma_id_disciplina  UNIQUE (id_turma, id_disciplina)           -- alvo de [E7]
  -- id_professor SAIU → turma_professor [E11] (co-docência)
);
COMMENT ON TABLE turma IS 'Oferta; professor foi para turma_professor [E11].';

CREATE TABLE turma_professor (
  id_turma              integer  NOT NULL REFERENCES turma (id_turma),
  id_professor          integer  NOT NULL REFERENCES professor (id_professor),
  ch_turma_professor    smallint CHECK (ch_turma_professor > 0),
  papel_turma_professor papel_docente_t NOT NULL DEFAULT 'titular',
  PRIMARY KEY (id_turma, id_professor)
);
COMMENT ON TABLE turma_professor IS 'Co-docência [E11]; um titular por turma via índice parcial.';
CREATE UNIQUE INDEX uq_turma_prof_titular ON turma_professor (id_turma)
  WHERE papel_turma_professor = 'titular';

CREATE TABLE turma_horario (
  id_turma_horario         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma                 integer  NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da turma via FK composta.
  id_periodo_letivo        smallint NOT NULL,
  -- [E12] sala ANULÁVEL: turma EAD tem horário sem sala física.
  id_sala                  integer  REFERENCES sala (id_sala),
  dia_semana_turma_horario smallint  NOT NULL CHECK (dia_semana_turma_horario BETWEEN 1 AND 7),
  faixa_turma_horario      timerange NOT NULL CHECK (NOT isempty(faixa_turma_horario)),   -- [C1]
  tipo_aula_turma_horario  tipo_aula_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT fk_horario_turma_periodo
    FOREIGN KEY (id_turma, id_periodo_letivo)
    REFERENCES turma (id_turma, id_periodo_letivo) ON DELETE CASCADE,
  CONSTRAINT uq_horario_id_turma UNIQUE (id_turma_horario, id_turma),   -- alvo de [E13]
  -- [C10] choque de sala só para quem TEM sala (EXCLUDE parcial, validado) [E12]
  CONSTRAINT ex_sala_sem_choque EXCLUDE USING gist (
    id_periodo_letivo WITH =, id_sala WITH =, dia_semana_turma_horario WITH =,
    faixa_turma_horario WITH &&) WHERE (id_sala IS NOT NULL),
  -- [C10] a própria turma não se sobrepõe, com ou sem sala
  CONSTRAINT ex_turma_sem_choque EXCLUDE USING gist (
    id_turma WITH =, dia_semana_turma_horario WITH =, faixa_turma_horario WITH &&)
);
COMMENT ON TABLE turma_horario IS 'Encontros semanais; sala NULL = EAD [E12]; alvo de [E13].';

-- ============================================================================
-- 8. PLANO DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA; a turma pode ter a sua versão.
--    id_turma NULL  = plano base da disciplina;
--    id_turma preenchido = versão daquela oferta.
-- ============================================================================

CREATE TABLE plano_ensino (
  id_plano_ensino                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina                   integer NOT NULL,
  id_turma                        integer,
  objetivo_plano_ensino           text NOT NULL,
  metodologia_plano_ensino        text,
  criterio_avaliacao_plano_ensino text,
  aprovacao_plano_ensino          date,
  CONSTRAINT fk_plano_disciplina FOREIGN KEY (id_disciplina) REFERENCES disciplina (id_disciplina),
  -- [E7] técnica de [C9]: um único plano base (turma NULL) e no máximo uma
  -- versão por turma.
  CONSTRAINT uq_plano_disciplina_turma UNIQUE NULLS NOT DISTINCT (id_disciplina, id_turma),
  -- [E7] técnica de [C6]: a versão só pode pendurar numa turma DESSA disciplina.
  -- (com id_turma NULL a FK composta não é avaliada — MATCH SIMPLE — e o plano
  -- base passa; preenchida, o par é validado contra turma.)
  CONSTRAINT fk_plano_turma_da_disciplina
    FOREIGN KEY (id_turma, id_disciplina) REFERENCES turma (id_turma, id_disciplina)
);
COMMENT ON TABLE plano_ensino IS 'Da disciplina, com versão opcional por turma [E7]: técnicas de [C9] e [C6].';

CREATE TABLE unidade_plano_ensino (
  id_unidade_plano_ensino        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_plano_ensino                integer      NOT NULL REFERENCES plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  titulo_unidade_plano_ensino    varchar(120) NOT NULL,
  conteudo_unidade_plano_ensino  text,
  ordem_unidade_plano_ensino     smallint NOT NULL CHECK (ordem_unidade_plano_ensino > 0),
  ch_unidade_plano_ensino        smallint NOT NULL CHECK (ch_unidade_plano_ensino > 0),
  CONSTRAINT uq_unidade_plano_ordem UNIQUE (id_plano_ensino, ordem_unidade_plano_ensino)
);
COMMENT ON TABLE unidade_plano_ensino IS 'Unidades do plano; soma de CH ≤ CH da disciplina fica em função [E7].';

CREATE TABLE bibliografia (
  id_bibliografia      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  titulo_bibliografia  varchar(200) NOT NULL,
  autor_bibliografia   varchar(120) NOT NULL,
  editora_bibliografia varchar(80),
  isbn_bibliografia    char(13) UNIQUE,
  ano_bibliografia     smallint CHECK (ano_bibliografia BETWEEN 1800 AND 2100),
  edicao_bibliografia  smallint CHECK (edicao_bibliografia > 0)
);
COMMENT ON TABLE bibliografia IS 'Obras; N:N com plano via plano_ensino_bibliografia.';

CREATE TABLE plano_ensino_bibliografia (
  id_plano_ensino               integer NOT NULL REFERENCES plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  id_bibliografia               integer NOT NULL REFERENCES bibliografia (id_bibliografia),
  tipo_plano_ensino_bibliografia tipo_bibliografia_t NOT NULL,
  PRIMARY KEY (id_plano_ensino, id_bibliografia)
);
COMMENT ON TABLE plano_ensino_bibliografia IS 'Básica × complementar por plano.';

-- ============================================================================
-- 9. MATRÍCULA E HISTÓRICO  [C2] [C11] [E14]
-- ============================================================================

CREATE TABLE matricula (
  id_matricula     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno         integer      NOT NULL REFERENCES aluno (id_aluno),
  id_turma         integer      NOT NULL REFERENCES turma (id_turma),
  data_matricula   timestamptz  NOT NULL DEFAULT now(),
  -- DEFAULT 'confirmada' MANTIDO (achado F9): vw_vagas conta confirmadas e a
  -- demo da última vaga depende disso; o fluxo pendente→confirmada, quando
  -- existir, muda o default junto com a função de matrícula.
  status_matricula status_mat_t NOT NULL DEFAULT 'confirmada',
  CONSTRAINT uq_matricula_aluno_turma UNIQUE (id_aluno, id_turma),   -- [C2]
  CONSTRAINT uq_matricula_id_turma    UNIQUE (id_matricula, id_turma)  -- alvo de [E13]
);
COMMENT ON TABLE matricula IS 'Inscrição do aluno numa turma [C2] — uma linha por turma cursada, não confundir com aluno.matricula_aluno (o RA). Vaga consumida por confirmada; a disputa é o Marco 2.';

CREATE TABLE historico (
  id_historico              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_matricula              integer NOT NULL UNIQUE REFERENCES matricula (id_matricula) ON DELETE CASCADE,
  data_fechamento_historico date,
  situacao_historico        situacao_t NOT NULL DEFAULT 'cursando'
  -- [E14] nota_a1/a2/p3, frequência e media_final SAÍRAM: agora derivam de
  -- nota/presenca na MV mv_historico_consolidado (refresh ao fechar o período).
  -- Custo assumido e registrado: o GENERATED de [C13] e o índice B-tree de 46×
  -- migram para a MV — que aceita índice e REFRESH CONCURRENTLY (validado).
);
COMMENT ON TABLE historico IS 'Consolidado 1:1 da matrícula [E14]; o registro fino vive em nota/presenca.';

CREATE TABLE log_matricula (
  id_log_matricula          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK, de propósito: a trilha sobrevive ao expurgo da matrícula.
  id_matricula              integer,
  id_usuario                integer REFERENCES usuario (id_usuario),
  ocorrido_em_log_matricula timestamptz NOT NULL DEFAULT now(),
  acao_log_matricula        acao_log_t  NOT NULL,
  detalhe_log_matricula     jsonb
);
COMMENT ON TABLE log_matricula IS 'Auditoria [C11]; id_usuario resolvido da sessão por f_usuario_sessao [E4].';

-- [E4] resolve a ROLE da sessão para usuario.id_usuario (NULL se não mapeada —
-- o log nunca deixa de ser gravado por causa disso).
CREATE FUNCTION f_usuario_sessao() RETURNS integer
  LANGUAGE sql STABLE
  AS $$ SELECT id_usuario FROM academico.usuario WHERE login_usuario = current_user $$;
ALTER TABLE log_matricula ALTER COLUMN id_usuario SET DEFAULT f_usuario_sessao();

-- ============================================================================
-- 10. AULA E AVALIAÇÃO  [E13] [E14]
--     Coerência SEM trigger: id_turma viaja nas junções e é amarrada por FK
--     composta — a técnica de [C6]/[C10] pela terceira vez.
-- ============================================================================

CREATE TABLE aula (
  id_aula                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma_horario        integer NOT NULL,
  id_unidade_plano_ensino integer REFERENCES unidade_plano_ensino (id_unidade_plano_ensino),
  -- [E13] denormalização controlada: a turma vem junto do horário via FK composta.
  id_turma                integer NOT NULL,
  conteudo_aula           text,
  data_aula               date    NOT NULL,
  realizada_aula          boolean NOT NULL DEFAULT true,
  CONSTRAINT fk_aula_horario_da_turma
    FOREIGN KEY (id_turma_horario, id_turma)
    REFERENCES turma_horario (id_turma_horario, id_turma),
  CONSTRAINT uq_aula_horario_data UNIQUE (id_turma_horario, data_aula),
  CONSTRAINT uq_aula_id_turma     UNIQUE (id_aula, id_turma)          -- alvo p/ presenca [E13]
);
COMMENT ON TABLE aula IS 'Encontros realizados; feriado × data fica em função [E13].';

CREATE TABLE presenca (
  id_aula              integer NOT NULL,
  id_matricula         integer NOT NULL,
  -- [E13] a MESMA turma amarra a aula e a matrícula: coerência por constraint.
  id_turma             integer NOT NULL,
  presente_presenca    boolean NOT NULL DEFAULT true,
  justificada_presenca boolean NOT NULL DEFAULT false,
  PRIMARY KEY (id_aula, id_matricula),
  CONSTRAINT fk_presenca_aula_da_turma
    FOREIGN KEY (id_aula, id_turma) REFERENCES aula (id_aula, id_turma),
  CONSTRAINT fk_presenca_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES matricula (id_matricula, id_turma)
);
COMMENT ON TABLE presenca IS 'Presença por aula; aluno de outra turma é IMPOSSÍVEL por FK composta [E13].';

CREATE TABLE avaliacao (
  id_avaliacao           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma               integer      NOT NULL REFERENCES turma (id_turma),
  nome_avaliacao         varchar(60)  NOT NULL,
  -- [E14] escala DECIDIDA: pesos somam 10.00 (coerente com nota_t 0–10);
  -- o teto fecha o achado F7. A soma exata por turma é conferida no fechamento.
  peso_avaliacao         numeric(4,2) NOT NULL CHECK (peso_avaliacao > 0 AND peso_avaliacao <= 10),
  data_avaliacao         date,
  substitutiva_avaliacao boolean      NOT NULL DEFAULT false,
  CONSTRAINT uq_avaliacao_turma_nome UNIQUE (id_turma, nome_avaliacao),
  CONSTRAINT uq_avaliacao_id_turma   UNIQUE (id_avaliacao, id_turma)   -- alvo de [E13]
);
COMMENT ON TABLE avaliacao IS 'Avaliações por turma [E14]; substitutiva preserva a regra da P3 [C13].';

CREATE TABLE nota (
  id_avaliacao integer NOT NULL,
  id_matricula integer NOT NULL,
  id_turma     integer NOT NULL,          -- [E13] mesma técnica da presenca
  valor_nota   nota_t  NOT NULL,
  PRIMARY KEY (id_avaliacao, id_matricula),
  CONSTRAINT fk_nota_avaliacao_da_turma
    FOREIGN KEY (id_avaliacao, id_turma) REFERENCES avaliacao (id_avaliacao, id_turma),
  CONSTRAINT fk_nota_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES matricula (id_matricula, id_turma)
);
COMMENT ON TABLE nota IS 'Nota por avaliação; nota em avaliação de outra turma é IMPOSSÍVEL por FK composta [E13].';

-- ============================================================================
-- 11. DERIVAÇÃO DO DESEMPENHO  [E14]
--     Sucessora direta da coluna GERADA que a ampliação removeu de historico.
--     Antes, media_final_historico era `GENERATED ALWAYS AS (...) STORED` sobre
--     nota_a1/a2/p3 — três colunas fixas, 1FN disfarçada. Agora a nota vive em
--     `nota` (n linhas por matrícula) e a média é DERIVADA aqui, uma vez, para
--     que consultas, views e a MV do 04 usem a MESMA regra.
--
--     A regra da P3 do modelo original é preservada: a avaliação SUBSTITUTIVA
--     troca a MENOR nota regular, e só quando é maior que ela.
--
--     Direitos do DONO (sem security_invoker), de propósito: quem consulta
--     precisa enxergar `nota`/`presenca` inteiras para a agregação fechar. O
--     isolamento por aluno é feito uma camada acima, em v_historico_aluno
--     (security_invoker = on), que filtra por `matricula` — protegida por RLS.
--     Por isso esta view NÃO é concedida a papel_aluno (ver 08_seguranca.sql).
-- ============================================================================
CREATE VIEW v_desempenho_matricula AS
WITH regulares AS (
  SELECT n.id_matricula, n.valor_nota, av.peso_avaliacao,
         row_number() OVER (PARTITION BY n.id_matricula ORDER BY n.valor_nota, av.id_avaliacao) AS posicao
  FROM nota n
  JOIN avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE NOT av.substitutiva_avaliacao
),
substitutiva AS (
  SELECT n.id_matricula, max(n.valor_nota) AS valor_nota
  FROM nota n
  JOIN avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE av.substitutiva_avaliacao
  GROUP BY n.id_matricula
),
media AS (
  SELECT r.id_matricula,
         round(sum(CASE WHEN r.posicao = 1 AND s.valor_nota > r.valor_nota
                        THEN s.valor_nota ELSE r.valor_nota END * r.peso_avaliacao)
               / sum(r.peso_avaliacao), 2)                       AS media_final,
         count(*)                                                AS avaliacoes_lancadas,
         bool_or(s.valor_nota IS NOT NULL)                       AS usou_substitutiva
  FROM regulares r
  LEFT JOIN substitutiva s ON s.id_matricula = r.id_matricula
  GROUP BY r.id_matricula
),
frequencia AS (
  SELECT p.id_matricula,
         count(*)                                                AS aulas_previstas,
         count(*) FILTER (WHERE p.presente_presenca)             AS presencas,
         round(100.0 * count(*) FILTER (WHERE p.presente_presenca) / count(*), 2)::pct_t AS frequencia
  FROM presenca p
  GROUP BY p.id_matricula
)
SELECT m.id_matricula,
       m.id_aluno,
       m.id_turma,
       md.media_final,
       md.avaliacoes_lancadas,
       md.usou_substitutiva,
       fq.aulas_previstas,
       fq.presencas,
       fq.frequencia
FROM matricula m
LEFT JOIN media md      ON md.id_matricula = m.id_matricula
LEFT JOIN frequencia fq ON fq.id_matricula = m.id_matricula;
COMMENT ON VIEW v_desempenho_matricula IS
  'Média final (com a regra da substitutiva) e frequência, derivadas de nota/presenca [E14]. Sucessora da coluna gerada [C13].';

COMMIT;

-- [C15] sessões novas nascem com o search_path certo, em qualquer banco:
SELECT format('ALTER DATABASE %I SET search_path TO academico, public', current_database())
\gexec

\echo '=== Esquema ampliado criado. Tabelas: ==='
SELECT count(*) AS tabelas FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE';
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE' ORDER BY table_name;
