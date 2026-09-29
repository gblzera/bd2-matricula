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
-- [E17] vinculo_t removido: sem co-requisito, o tipo ficaria sem uso.
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

CREATE TABLE tb_pais (
  id_pais    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_pais  varchar(60) NOT NULL UNIQUE,
  sigla_pais char(2)     NOT NULL UNIQUE                          -- ISO 3166-1
);
COMMENT ON TABLE tb_pais IS 'Países [E1].';

CREATE TABLE tb_estado (
  id_estado   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pais     smallint    NOT NULL REFERENCES tb_pais (id_pais),
  nome_estado varchar(60) NOT NULL,
  uf_estado   char(2)     NOT NULL,
  CONSTRAINT uq_estado_pais_uf UNIQUE (id_pais, uf_estado)
);
COMMENT ON TABLE tb_estado IS 'Unidades federativas [E1].';

CREATE TABLE tb_cidade (
  id_cidade          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_estado          smallint    NOT NULL REFERENCES tb_estado (id_estado),
  nome_cidade        varchar(80) NOT NULL,
  codigo_ibge_cidade char(7)     UNIQUE,
  CONSTRAINT uq_cidade_estado_nome UNIQUE (id_estado, nome_cidade)
);
COMMENT ON TABLE tb_cidade IS 'Municípios; "Brasilia" ≠ "BRASÍLIA" morre aqui [E1].';

CREATE TABLE tb_endereco (
  id_endereco          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cidade            integer      NOT NULL REFERENCES tb_cidade (id_cidade),
  logradouro_endereco  varchar(120) NOT NULL,
  numero_endereco      varchar(10),                               -- varchar: "s/n"
  complemento_endereco varchar(60),
  bairro_endereco      varchar(60),
  cep_endereco         char(8) CHECK (cep_endereco ~ '^[0-9]{8}$')
);
COMMENT ON TABLE tb_endereco IS 'Endereços de pessoas e campi [E1].';

-- ============================================================================
-- 3. PESSOAS  [E2] [E3]
--    pessoa é o supertipo; aluno e professor são especializações 1:1 e não
--    exclusivas (um professor pode ser aluno de outro curso).
-- ============================================================================

CREATE TABLE tb_pessoa (
  id_pessoa         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_endereco       integer REFERENCES tb_endereco (id_endereco),
  nome_pessoa       varchar(120) NOT NULL,
  email_pessoa      varchar(120) NOT NULL UNIQUE CHECK (position('@' in email_pessoa) > 1),
  -- [E2] CPF é 1:1 com a pessoa no Brasil: fica AQUI, obrigatório, preservando
  -- [C12]. documento_pessoa guarda os demais documentos (multivalorados).
  cpf_pessoa        cpf_t NOT NULL UNIQUE,
  nascimento_pessoa date  NOT NULL
);
COMMENT ON TABLE tb_pessoa IS 'Supertipo de aluno e professor [E2]; nome/e-mail/CPF vivem só aqui.';

CREATE TABLE tb_telefone (
  id_telefone        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa          integer     NOT NULL REFERENCES tb_pessoa (id_pessoa) ON DELETE CASCADE,
  numero_telefone    varchar(20) NOT NULL,
  principal_telefone boolean     NOT NULL DEFAULT false,
  tipo_telefone      tipo_telefone_t NOT NULL,
  CONSTRAINT uq_telefone_pessoa_numero UNIQUE (id_pessoa, numero_telefone)
);
COMMENT ON TABLE tb_telefone IS 'Multivalorado → tabela (1FN) [E3]. Um principal por pessoa: índice parcial.';
-- só um telefone principal por pessoa (validado em banco descartável)
CREATE UNIQUE INDEX uq_telefone_principal ON tb_telefone (id_pessoa) WHERE principal_telefone;

CREATE TABLE tb_documento_pessoa (
  id_documento_pessoa      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa                integer     NOT NULL REFERENCES tb_pessoa (id_pessoa) ON DELETE CASCADE,
  numero_documento_pessoa  varchar(20) NOT NULL,
  orgao_documento_pessoa   varchar(20),
  emissao_documento_pessoa date,
  tipo_documento_pessoa    tipo_documento_t NOT NULL,
  -- o mesmo documento não pode pertencer a duas pessoas…
  CONSTRAINT uq_documento_tipo_numero UNIQUE (tipo_documento_pessoa, numero_documento_pessoa),
  -- …e uma pessoa tem no máximo um documento de cada tipo
  CONSTRAINT uq_documento_pessoa_tipo UNIQUE (id_pessoa, tipo_documento_pessoa)
);
COMMENT ON TABLE tb_documento_pessoa IS 'Documentos além do CPF [E3]; CPF mora em pessoa [E2].';

CREATE TABLE tb_usuario (
  id_usuario    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa     integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  login_usuario varchar(60) NOT NULL UNIQUE,     -- = nome da ROLE no PostgreSQL [E4]
  ativo_usuario boolean     NOT NULL DEFAULT true,
  papel_usuario papel_usuario_t NOT NULL
);
COMMENT ON TABLE tb_usuario IS 'Conta de acesso; login = ROLE do Postgres, casa com a RLS al_<RA> [E4].';

-- ============================================================================
-- 4. ESTRUTURA FÍSICA E ORGANIZACIONAL  [E5] [E6]
-- ============================================================================

CREATE TABLE tb_campus (
  id_campus   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- UNIQUE honra a cardinalidade (0,1) do lado do endereço (achado F1 da revisão)
  id_endereco integer     NOT NULL UNIQUE REFERENCES tb_endereco (id_endereco),
  nome_campus varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_campus IS 'Campi; cidade_campus saiu — vem de endereco→cidade [E1].';

CREATE TABLE tb_departamento (
  id_departamento    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus          smallint    NOT NULL REFERENCES tb_campus (id_campus),
  id_professor_chefe integer,       -- FK circular com professor: constraint via ALTER, adiante [E6]
  nome_departamento  varchar(80) NOT NULL,
  sigla_departamento varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_departamento IS 'Departamentos; chefe é FK circular resolvida por ALTER [E6].';

CREATE TABLE tb_predio (
  id_predio      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus      smallint    NOT NULL REFERENCES tb_campus (id_campus),
  nome_predio    varchar(60) NOT NULL,
  andares_predio smallint CHECK (andares_predio > 0),
  CONSTRAINT uq_predio_campus_nome UNIQUE (id_campus, nome_predio)
);
COMMENT ON TABLE tb_predio IS 'Prédios do campus [E5].';

CREATE TABLE tb_sala (
  id_sala         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E5] sala muda de dono: o campus vem via prédio. [C4] evolui junto:
  -- código único DENTRO do prédio (prédios do mesmo campus podem repetir).
  id_predio       smallint    NOT NULL REFERENCES tb_predio (id_predio),
  codigo_sala     varchar(10) NOT NULL,
  andar_sala      smallint,
  capacidade_sala smallint    NOT NULL CHECK (capacidade_sala > 0),
  tipo_sala       tipo_sala_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT uq_sala_predio_codigo UNIQUE (id_predio, codigo_sala)   -- [C4→E5]
);
COMMENT ON TABLE tb_sala IS 'Salas físicas, por prédio [E5]; [C4] agora por prédio.';

CREATE TABLE tb_recurso (
  id_recurso   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nome_recurso varchar(60) NOT NULL UNIQUE
);
COMMENT ON TABLE tb_recurso IS 'Recursos alocáveis (projetor, bancada…) [E3].';

CREATE TABLE tb_sala_recurso (
  id_sala                 integer  NOT NULL REFERENCES tb_sala (id_sala) ON DELETE CASCADE,
  id_recurso              smallint NOT NULL REFERENCES tb_recurso (id_recurso),
  quantidade_sala_recurso smallint NOT NULL DEFAULT 1 CHECK (quantidade_sala_recurso > 0),
  PRIMARY KEY (id_sala, id_recurso)
);
COMMENT ON TABLE tb_sala_recurso IS 'N:N sala×recurso — o critério para alocar laboratório [E3].';

CREATE TABLE tb_professor (
  id_professor        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa           integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  id_departamento     smallint    NOT NULL REFERENCES tb_departamento (id_departamento),
  matricula_professor varchar(12) NOT NULL UNIQUE,
  regime_professor    regime_professor_t NOT NULL,
  titulacao_professor titulacao_t NOT NULL
);
COMMENT ON TABLE tb_professor IS 'Especialização 1:1 de pessoa [E2]; só o que é vínculo de trabalho.';

-- [E6] a FK circular departamento↔professor entra agora, com UNIQUE (F4: um
-- professor chefia no máximo um departamento; UNIQUE aceita vários NULLs).
ALTER TABLE tb_departamento
  ADD CONSTRAINT fk_departamento_chefe
      FOREIGN KEY (id_professor_chefe) REFERENCES tb_professor (id_professor),
  ADD CONSTRAINT uq_departamento_chefe UNIQUE (id_professor_chefe);

CREATE TABLE tb_formacao_professor (
  id_formacao_professor            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_professor                     integer      NOT NULL REFERENCES tb_professor (id_professor) ON DELETE CASCADE,
  curso_formacao_professor         varchar(120) NOT NULL,
  instituicao_formacao_professor   varchar(120) NOT NULL,
  ano_conclusao_formacao_professor smallint     NOT NULL CHECK (ano_conclusao_formacao_professor BETWEEN 1950 AND 2100),
  titulacao_formacao_professor     titulacao_t  NOT NULL,
  CONSTRAINT uq_formacao_prof UNIQUE (id_professor, curso_formacao_professor, instituicao_formacao_professor)
);
COMMENT ON TABLE tb_formacao_professor IS 'Formações (multivalorado, 1FN) [E3]; a titulação declarada fica em professor.';

-- ============================================================================
-- 5. ESTRUTURA ACADÊMICA  [E7] [E8] [E15]
-- ============================================================================

CREATE TABLE tb_curso (
  id_curso        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_campus       smallint     NOT NULL REFERENCES tb_campus (id_campus),
  id_departamento smallint     NOT NULL REFERENCES tb_departamento (id_departamento),
  codigo_curso    varchar(10)  NOT NULL UNIQUE,
  nome_curso      varchar(120) NOT NULL,
  ch_total_curso  integer      NOT NULL CHECK (ch_total_curso > 0),
  grau_curso      grau_curso_t NOT NULL,          -- era varchar+CHECK: rótulo fechado ⇒ ENUM [C12]
  modalidade_curso modalidade_t NOT NULL DEFAULT 'presencial'
);
COMMENT ON TABLE tb_curso IS 'Cursos; ganham departamento [E6] e modalidade.';

CREATE TABLE tb_coordenacao_curso (
  id_coordenacao_curso       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso                   smallint    NOT NULL REFERENCES tb_curso (id_curso),
  id_professor               integer     NOT NULL REFERENCES tb_professor (id_professor),
  portaria_coordenacao_curso varchar(30),
  vigencia_coordenacao_curso daterange   NOT NULL CHECK (NOT isempty(vigencia_coordenacao_curso)),
  -- [E8] um coordenador por curso a cada instante — técnica de [C10], sem trigger.
  -- Vigência aberta: daterange(inicio, NULL). Validado em banco descartável.
  CONSTRAINT ex_coordenacao_vigencia EXCLUDE USING gist
    (id_curso WITH =, vigencia_coordenacao_curso WITH &&)
);
COMMENT ON TABLE tb_coordenacao_curso IS 'Mandatos de coordenação; EXCLUDE de vigência [E8].';

CREATE TABLE tb_curriculo (
  id_curriculo           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_curso               smallint    NOT NULL REFERENCES tb_curso (id_curso),
  portaria_curriculo     varchar(30),
  ano_vigencia_curriculo smallint    NOT NULL CHECK (ano_vigencia_curriculo BETWEEN 1990 AND 2100),
  ativo_curriculo        boolean     NOT NULL DEFAULT true,
  CONSTRAINT uq_curriculo_curso_ano UNIQUE (id_curso, ano_vigencia_curriculo),   -- [C8]
  CONSTRAINT uq_curriculo_id_curso  UNIQUE (id_curriculo, id_curso)              -- alvo da FK composta [C6]
);
COMMENT ON TABLE tb_curriculo IS 'Matrizes curriculares por ano [C8]; alvo de [C6].';

CREATE TABLE tb_disciplina (
  id_disciplina         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_departamento       smallint     NOT NULL REFERENCES tb_departamento (id_departamento),
  codigo_disciplina     varchar(10)  NOT NULL UNIQUE,
  nome_disciplina       varchar(120) NOT NULL,
  ementa_disciplina     text,
  ch_teorica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_teorica_disciplina >= 0),
  ch_pratica_disciplina smallint NOT NULL DEFAULT 0 CHECK (ch_pratica_disciplina >= 0),
  ch_total_disciplina   smallint GENERATED ALWAYS AS (ch_teorica_disciplina + ch_pratica_disciplina) STORED,  -- [C13]
  CONSTRAINT ck_disciplina_ch_positiva CHECK (ch_teorica_disciplina + ch_pratica_disciplina > 0)
);
COMMENT ON TABLE tb_disciplina IS 'Catálogo; ch_total é gerada [C13]; ementa é a descrição perene — o plano de ensino é a execução [E7].';

CREATE TABLE tb_curriculo_disciplina (
  id_curriculo                 integer     NOT NULL REFERENCES tb_curriculo (id_curriculo) ON DELETE CASCADE,
  id_disciplina                integer     NOT NULL REFERENCES tb_disciplina (id_disciplina),
  periodo_curriculo_disciplina smallint    NOT NULL CHECK (periodo_curriculo_disciplina BETWEEN 1 AND 12),
  tipo_curriculo_disciplina    tipo_disc_t NOT NULL DEFAULT 'obrigatoria',
  PRIMARY KEY (id_curriculo, id_disciplina)
);
COMMENT ON TABLE tb_curriculo_disciplina IS 'Grade: período sugerido de cada disciplina no currículo.';

-- [E17] O pré-requisito passa a pertencer ao CURRÍCULO, não ao catálogo.
-- Antes, "BD2 exige BD1" valia para toda matriz de uma vez; mas a cadeia é
-- decisão de cada matriz, e matrizes diferentes encadeiam diferente.
-- As DUAS chaves compostas são o ponto: exigem que a disciplina E o requisito
-- estejam ambos NAQUELE currículo. Apontar para matéria fora da matriz é
-- impossível por restrição, sem trigger — a técnica de [C6] outra vez.
-- `vinculo` saiu a pedido: o modelo expressa só pré-requisito. Consequência
-- assumida: o co-requisito (LBD2 junto de BD2) deixa de ser representável.
-- `ch_minima_pre_requisito` saiu junto — nunca foi usado por consulta nenhuma.
CREATE TABLE tb_pre_requisito (
  id_curriculo               integer NOT NULL,
  id_disciplina              integer NOT NULL,
  id_requisito               integer NOT NULL,
  media_minima_pre_requisito nota_t  NOT NULL DEFAULT 5.00,
  PRIMARY KEY (id_curriculo, id_disciplina, id_requisito),
  CONSTRAINT fk_prereq_disciplina_do_curriculo
    FOREIGN KEY (id_curriculo, id_disciplina)
    REFERENCES tb_curriculo_disciplina (id_curriculo, id_disciplina) ON DELETE CASCADE,
  CONSTRAINT fk_prereq_requisito_do_curriculo
    FOREIGN KEY (id_curriculo, id_requisito)
    REFERENCES tb_curriculo_disciplina (id_curriculo, id_disciplina),
  CONSTRAINT ck_prereq_nao_reflexivo CHECK (id_disciplina <> id_requisito)   -- [C7]
);
COMMENT ON TABLE tb_pre_requisito IS 'id_disciplina EXIGE id_requisito, com média/CH mínimas por aresta; ciclos maiores: consulta recursiva [C7].';

CREATE TABLE tb_aluno (
  id_aluno             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pessoa            integer     NOT NULL UNIQUE REFERENCES tb_pessoa (id_pessoa),
  id_curso             smallint    NOT NULL REFERENCES tb_curso (id_curso),
  id_curriculo         integer     NOT NULL,
  -- [E18] `ingresso_aluno` saiu: o RA já carrega o ano nos quatro primeiros
  -- dígitos (20240036 = 2024), então a data era determinada por ele —
  -- transitiva. Quem precisa do ano lê `left(matricula_aluno, 4)`.
  matricula_aluno      varchar(12) NOT NULL UNIQUE,
  forma_ingresso_aluno forma_ingresso_t NOT NULL,
  status_aluno         status_aluno_t   NOT NULL DEFAULT 'ativo',
  -- [C6] o currículo do aluno tem que ser um currículo do curso do aluno.
  CONSTRAINT fk_aluno_curriculo_do_curso
    FOREIGN KEY (id_curriculo, id_curso) REFERENCES tb_curriculo (id_curriculo, id_curso)
);
COMMENT ON TABLE tb_aluno IS 'Especialização 1:1 de pessoa [E2]; fica só o vínculo acadêmico. [C6] mantido.';
-- Ambiguidade HERDADA do modelo do professor, registrada para quem vier depois:
-- `matricula_aluno` é o RA (identificação do aluno na instituição, uma por aluno),
-- enquanto a TABELA `tb_matricula` é a inscrição do aluno numa turma (muitas por aluno).
-- São conceitos distintos com a mesma palavra. Renomear divergiria da convenção do
-- professor, então o nome fica e a distinção é documentada aqui.
COMMENT ON COLUMN tb_aluno.matricula_aluno IS
  'RA: identificação do aluno na instituição. NÃO confundir com a tabela matricula (inscrição em turma).';

CREATE TABLE tb_aproveitamento_materia (
  id_aproveitamento_materia               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno                                integer      NOT NULL REFERENCES tb_aluno (id_aluno),
  id_disciplina                           integer      NOT NULL REFERENCES tb_disciplina (id_disciplina),
  id_usuario_avaliador                    integer      REFERENCES tb_usuario (id_usuario),
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
COMMENT ON TABLE tb_aproveitamento_materia IS 'Dispensa por estudo anterior [E15]; conta em pode_cursar().';

-- ============================================================================
-- 6. TEMPO E CALENDÁRIO  [E9] [E10]
-- ============================================================================

CREATE TABLE tb_periodo_letivo (
  id_periodo_letivo          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ano_periodo_letivo         smallint NOT NULL,
  semestre_periodo_letivo    smallint NOT NULL CHECK (semestre_periodo_letivo IN (1, 2)),
  data_inicio_periodo_letivo date     NOT NULL,
  data_fim_periodo_letivo    date     NOT NULL,
  CONSTRAINT uq_periodo_ano_semestre UNIQUE (ano_periodo_letivo, semestre_periodo_letivo),  -- [C3]
  CONSTRAINT ck_periodo_datas        CHECK (data_inicio_periodo_letivo < data_fim_periodo_letivo)
);
COMMENT ON TABLE tb_periodo_letivo IS 'Semestres letivos [C3].';

CREATE TABLE tb_periodo_matricula (
  id_periodo_matricula        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_periodo_letivo           smallint    NOT NULL REFERENCES tb_periodo_letivo (id_periodo_letivo),
  descricao_periodo_matricula varchar(60) NOT NULL,
  janela_periodo_matricula    tstzrange   NOT NULL CHECK (NOT isempty(janela_periodo_matricula)),
  tipo_periodo_matricula      tipo_periodo_matricula_t NOT NULL,
  -- [E9] janelas do mesmo tipo não se sobrepõem no período; tipos diferentes
  -- podem (ajuste cobre o fim da matrícula). ENUM em GiST: btree_gist, validado.
  CONSTRAINT ex_periodo_matricula_janela EXCLUDE USING gist
    (id_periodo_letivo WITH =, tipo_periodo_matricula WITH =, janela_periodo_matricula WITH &&)
);
COMMENT ON TABLE tb_periodo_matricula IS 'QUANDO se pode matricular [E9]; a função de matrícula consulta now() <@ janela.';

CREATE TABLE tb_feriado (
  id_feriado          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [E10] arco exclusivo: o ALCANCE do feriado é exatamente uma das 4 FKs.
  -- O ENUM de tipo foi REMOVIDO de propósito: seria derivável do arco
  -- (dependência funcional tipo↔FK — violaria 3FN); facultativo é ortogonal.
  id_pais             smallint REFERENCES tb_pais (id_pais),
  id_estado           smallint REFERENCES tb_estado (id_estado),
  id_cidade           integer  REFERENCES tb_cidade (id_cidade),
  id_campus           smallint REFERENCES tb_campus (id_campus),
  descricao_feriado   varchar(120) NOT NULL,
  data_feriado        date         NOT NULL,
  facultativo_feriado boolean      NOT NULL DEFAULT false,
  CONSTRAINT ck_feriado_arco CHECK (
    (id_pais   IS NOT NULL)::int + (id_estado IS NOT NULL)::int +
    (id_cidade IS NOT NULL)::int + (id_campus IS NOT NULL)::int = 1)
);
COMMENT ON TABLE tb_feriado IS 'Alcance pelo arco de FKs [E10]; dedup por nível preserva [C9].';
-- [C9→E10] dedup por nível: sem isto, dois feriados nacionais na mesma data
-- voltariam a passar — que era o erro original do modelo do professor.
CREATE UNIQUE INDEX uq_feriado_pais_data   ON tb_feriado (id_pais,   data_feriado) WHERE id_pais   IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_estado_data ON tb_feriado (id_estado, data_feriado) WHERE id_estado IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_cidade_data ON tb_feriado (id_cidade, data_feriado) WHERE id_cidade IS NOT NULL;
CREATE UNIQUE INDEX uq_feriado_campus_data ON tb_feriado (id_campus, data_feriado) WHERE id_campus IS NOT NULL;

-- ============================================================================
-- 7. OFERTA E DOCÊNCIA  [E11] [E12]
-- ============================================================================

CREATE TABLE tb_turma (
  id_turma          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina     integer     NOT NULL REFERENCES tb_disciplina (id_disciplina),
  id_periodo_letivo smallint    NOT NULL REFERENCES tb_periodo_letivo (id_periodo_letivo),
  codigo_turma      varchar(15) NOT NULL,
  vagas_turma       smallint    NOT NULL CHECK (vagas_turma >= 0),
  turno_turma       turno_t     NOT NULL,
  modalidade_turma  modalidade_t NOT NULL DEFAULT 'presencial',
  CONSTRAINT uq_turma_periodo_codigo UNIQUE (id_periodo_letivo, codigo_turma),  -- [C5]
  CONSTRAINT uq_turma_id_periodo     UNIQUE (id_turma, id_periodo_letivo),      -- alvo de [C10]
  CONSTRAINT uq_turma_id_disciplina  UNIQUE (id_turma, id_disciplina)           -- alvo de [E7]
  -- id_professor SAIU → turma_professor [E11] (co-docência)
);
COMMENT ON TABLE tb_turma IS 'Oferta; professor foi para turma_professor [E11].';

CREATE TABLE tb_turma_professor (
  id_turma              integer  NOT NULL REFERENCES tb_turma (id_turma),
  id_professor          integer  NOT NULL REFERENCES tb_professor (id_professor),
  ch_turma_professor    smallint CHECK (ch_turma_professor > 0),
  papel_turma_professor papel_docente_t NOT NULL DEFAULT 'titular',
  PRIMARY KEY (id_turma, id_professor)
);
COMMENT ON TABLE tb_turma_professor IS 'Co-docência [E11]; um titular por turma via índice parcial.';
CREATE UNIQUE INDEX uq_turma_prof_titular ON tb_turma_professor (id_turma)
  WHERE papel_turma_professor = 'titular';

CREATE TABLE tb_turma_horario (
  id_turma_horario         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma                 integer  NOT NULL,
  -- [C10] denormalização CONTROLADA: o período vem junto da turma via FK composta.
  id_periodo_letivo        smallint NOT NULL,
  -- [E12] sala ANULÁVEL: turma EAD tem horário sem sala física.
  id_sala                  integer  REFERENCES tb_sala (id_sala),
  dia_semana_turma_horario smallint  NOT NULL CHECK (dia_semana_turma_horario BETWEEN 1 AND 7),
  faixa_turma_horario      timerange NOT NULL CHECK (NOT isempty(faixa_turma_horario)),   -- [C1]
  tipo_aula_turma_horario  tipo_aula_t NOT NULL DEFAULT 'teorica',
  CONSTRAINT fk_horario_turma_periodo
    FOREIGN KEY (id_turma, id_periodo_letivo)
    REFERENCES tb_turma (id_turma, id_periodo_letivo) ON DELETE CASCADE,
  CONSTRAINT uq_horario_id_turma UNIQUE (id_turma_horario, id_turma),   -- alvo de [E13]
  -- [C10] choque de sala só para quem TEM sala (EXCLUDE parcial, validado) [E12]
  CONSTRAINT ex_sala_sem_choque EXCLUDE USING gist (
    id_periodo_letivo WITH =, id_sala WITH =, dia_semana_turma_horario WITH =,
    faixa_turma_horario WITH &&) WHERE (id_sala IS NOT NULL),
  -- [C10] a própria turma não se sobrepõe, com ou sem sala
  CONSTRAINT ex_turma_sem_choque EXCLUDE USING gist (
    id_turma WITH =, dia_semana_turma_horario WITH =, faixa_turma_horario WITH &&)
);
COMMENT ON TABLE tb_turma_horario IS 'Encontros semanais; sala NULL = EAD [E12]; alvo de [E13].';

-- ============================================================================
-- 8. PLANO DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA; a turma pode ter a sua versão.
--    id_turma NULL  = plano base da disciplina;
--    id_turma preenchido = versão daquela oferta.
-- ============================================================================

CREATE TABLE tb_plano_ensino (
  id_plano_ensino                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_disciplina                   integer NOT NULL,
  id_turma                        integer,
  objetivo_plano_ensino           text NOT NULL,
  metodologia_plano_ensino        text,
  criterio_avaliacao_plano_ensino text,
  aprovacao_plano_ensino          date,
  CONSTRAINT fk_plano_disciplina FOREIGN KEY (id_disciplina) REFERENCES tb_disciplina (id_disciplina),
  -- [E7] técnica de [C9]: um único plano base (turma NULL) e no máximo uma
  -- versão por turma.
  CONSTRAINT uq_plano_disciplina_turma UNIQUE NULLS NOT DISTINCT (id_disciplina, id_turma),
  -- [E7] técnica de [C6]: a versão só pode pendurar numa turma DESSA disciplina.
  -- (com id_turma NULL a FK composta não é avaliada — MATCH SIMPLE — e o plano
  -- base passa; preenchida, o par é validado contra turma.)
  CONSTRAINT fk_plano_turma_da_disciplina
    FOREIGN KEY (id_turma, id_disciplina) REFERENCES tb_turma (id_turma, id_disciplina)
);
COMMENT ON TABLE tb_plano_ensino IS 'Da disciplina, com versão opcional por turma [E7]: técnicas de [C9] e [C6].';

CREATE TABLE tb_unidade_plano_ensino (
  id_unidade_plano_ensino        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_plano_ensino                integer      NOT NULL REFERENCES tb_plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  titulo_unidade_plano_ensino    varchar(120) NOT NULL,
  conteudo_unidade_plano_ensino  text,
  ordem_unidade_plano_ensino     smallint NOT NULL CHECK (ordem_unidade_plano_ensino > 0),
  ch_unidade_plano_ensino        smallint NOT NULL CHECK (ch_unidade_plano_ensino > 0),
  CONSTRAINT uq_unidade_plano_ordem UNIQUE (id_plano_ensino, ordem_unidade_plano_ensino)
);
COMMENT ON TABLE tb_unidade_plano_ensino IS 'Unidades do plano; soma de CH ≤ CH da disciplina fica em função [E7].';

CREATE TABLE tb_bibliografia (
  id_bibliografia      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  titulo_bibliografia  varchar(200) NOT NULL,
  autor_bibliografia   varchar(120) NOT NULL,
  editora_bibliografia varchar(80),
  isbn_bibliografia    char(13) UNIQUE,
  ano_bibliografia     smallint CHECK (ano_bibliografia BETWEEN 1800 AND 2100),
  edicao_bibliografia  smallint CHECK (edicao_bibliografia > 0)
);
COMMENT ON TABLE tb_bibliografia IS 'Obras; N:N com plano via plano_ensino_bibliografia.';

CREATE TABLE tb_plano_ensino_bibliografia (
  id_plano_ensino               integer NOT NULL REFERENCES tb_plano_ensino (id_plano_ensino) ON DELETE CASCADE,
  id_bibliografia               integer NOT NULL REFERENCES tb_bibliografia (id_bibliografia),
  tipo_plano_ensino_bibliografia tipo_bibliografia_t NOT NULL,
  PRIMARY KEY (id_plano_ensino, id_bibliografia)
);
COMMENT ON TABLE tb_plano_ensino_bibliografia IS 'Básica × complementar por plano.';

-- ============================================================================
-- 9. MATRÍCULA E HISTÓRICO  [C2] [C11] [E14]
-- ============================================================================

CREATE TABLE tb_matricula (
  id_matricula     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_aluno         integer      NOT NULL REFERENCES tb_aluno (id_aluno),
  id_turma         integer      NOT NULL REFERENCES tb_turma (id_turma),
  data_matricula   timestamptz  NOT NULL DEFAULT now(),
  -- DEFAULT 'confirmada' MANTIDO (achado F9): vagas conta confirmadas e a
  -- demo da última vaga depende disso; o fluxo pendente→confirmada, quando
  -- existir, muda o default junto com a função de matrícula.
  status_matricula status_mat_t NOT NULL DEFAULT 'confirmada',
  CONSTRAINT uq_matricula_aluno_turma UNIQUE (id_aluno, id_turma),   -- [C2]
  CONSTRAINT uq_matricula_id_turma    UNIQUE (id_matricula, id_turma)  -- alvo de [E13]
);
COMMENT ON TABLE tb_matricula IS 'Inscrição do aluno numa turma [C2] — uma linha por turma cursada, não confundir com aluno.matricula_aluno (o RA). Vaga consumida por confirmada; a disputa é o Marco 2.';

CREATE TABLE tb_historico (
  id_historico              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_matricula              integer NOT NULL UNIQUE REFERENCES tb_matricula (id_matricula) ON DELETE CASCADE,
  data_fechamento_historico date,
  situacao_historico        situacao_t NOT NULL DEFAULT 'cursando'
  -- [E14] nota_a1/a2/p3, frequência e media_final SAÍRAM: agora derivam de
  -- nota/presenca na MV historico_consolidado (refresh ao fechar o período).
  -- Custo assumido e registrado: o GENERATED de [C13] e o índice B-tree de 46×
  -- migram para a MV — que aceita índice e REFRESH CONCURRENTLY (validado).
);
COMMENT ON TABLE tb_historico IS 'Consolidado 1:1 da matrícula [E14]; o registro fino vive em nota/presenca.';

-- [E19] O log deixa de ser só da matrícula e passa a ser GENÉRICO: uma linha
-- por alteração, em qualquer tabela auditada, gravada por trigger. Antes ele
-- dependia da aplicação lembrar de inserir; agora quem grava é o banco, e
-- "esquecer de logar" deixa de ser possível.
--
-- Nota para a arguição: isto NÃO contradiz o "zero triggers" do modelo. Aquilo
-- vale para trigger de VALIDAÇÃO — regra de integridade que o banco já sabe
-- declarar, e que em trigger vira código com desvio. Auditoria é o caso oposto:
-- não há forma declarativa de dizer "registre quem mudou o quê", e o trigger é
-- a ferramenta certa justamente por interceptar TODO caminho de escrita.
CREATE TABLE tb_log_auditoria (
  id_log_auditoria    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- [C11] SEM FK para a linha auditada, de propósito: a trilha sobrevive ao
  -- expurgo do dado. Auditoria que some junto com o auditado não é auditoria.
  id_usuario          integer REFERENCES tb_usuario (id_usuario),
  nome_tabela         name        NOT NULL,
  acao_log            acao_log_t  NOT NULL,
  ocorrido_em         timestamptz NOT NULL DEFAULT now(),
  dados_antes         jsonb,
  dados_depois        jsonb
);
COMMENT ON TABLE tb_log_auditoria IS 'Trilha de auditoria gravada por trigger [E19]; sem FK para o auditado [C11].';

-- [E4] resolve a ROLE da sessão para usuario.id_usuario (NULL se não mapeada —
-- o log nunca deixa de ser gravado por causa disso).
CREATE FUNCTION f_usuario_sessao() RETURNS integer
  LANGUAGE sql STABLE
  AS $$ SELECT id_usuario FROM academico.tb_usuario WHERE login_usuario = current_user $$;
ALTER TABLE tb_log_auditoria ALTER COLUMN id_usuario SET DEFAULT f_usuario_sessao();

-- ============================================================================
-- 10. AULA E AVALIAÇÃO  [E13] [E14]
--     Coerência SEM trigger: id_turma viaja nas junções e é amarrada por FK
--     composta — a técnica de [C6]/[C10] pela terceira vez.
-- ============================================================================

CREATE TABLE tb_aula (
  id_aula                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma_horario        integer NOT NULL,
  id_unidade_plano_ensino integer REFERENCES tb_unidade_plano_ensino (id_unidade_plano_ensino),
  -- [E13] denormalização controlada: a turma vem junto do horário via FK composta.
  id_turma                integer NOT NULL,
  conteudo_aula           text,
  data_aula               date    NOT NULL,
  realizada_aula          boolean NOT NULL DEFAULT true,
  CONSTRAINT fk_aula_horario_da_turma
    FOREIGN KEY (id_turma_horario, id_turma)
    REFERENCES tb_turma_horario (id_turma_horario, id_turma),
  CONSTRAINT uq_aula_horario_data UNIQUE (id_turma_horario, data_aula),
  CONSTRAINT uq_aula_id_turma     UNIQUE (id_aula, id_turma)          -- alvo p/ presenca [E13]
);
COMMENT ON TABLE tb_aula IS 'Encontros realizados; feriado × data fica em função [E13].';

CREATE TABLE tb_presenca (
  id_aula              integer NOT NULL,
  id_matricula         integer NOT NULL,
  -- [E13] a MESMA turma amarra a aula e a matrícula: coerência por constraint.
  id_turma             integer NOT NULL,
  presente_presenca    boolean NOT NULL DEFAULT true,
  justificada_presenca boolean NOT NULL DEFAULT false,
  PRIMARY KEY (id_aula, id_matricula),
  CONSTRAINT fk_presenca_aula_da_turma
    FOREIGN KEY (id_aula, id_turma) REFERENCES tb_aula (id_aula, id_turma),
  CONSTRAINT fk_presenca_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES tb_matricula (id_matricula, id_turma)
);
COMMENT ON TABLE tb_presenca IS 'Presença por aula; aluno de outra turma é IMPOSSÍVEL por FK composta [E13].';

CREATE TABLE tb_avaliacao (
  id_avaliacao           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_turma               integer      NOT NULL REFERENCES tb_turma (id_turma),
  nome_avaliacao         varchar(60)  NOT NULL,
  -- [E14] escala DECIDIDA: pesos somam 10.00 (coerente com nota_t 0–10);
  -- o teto fecha o achado F7. A soma exata por turma é conferida no fechamento.
  peso_avaliacao         numeric(4,2) NOT NULL CHECK (peso_avaliacao > 0 AND peso_avaliacao <= 10),
  data_avaliacao         date,
  substitutiva_avaliacao boolean      NOT NULL DEFAULT false,
  CONSTRAINT uq_avaliacao_turma_nome UNIQUE (id_turma, nome_avaliacao),
  CONSTRAINT uq_avaliacao_id_turma   UNIQUE (id_avaliacao, id_turma)   -- alvo de [E13]
);
COMMENT ON TABLE tb_avaliacao IS 'Avaliações por turma [E14]; substitutiva preserva a regra da P3 [C13].';

CREATE TABLE tb_nota (
  id_avaliacao integer NOT NULL,
  id_matricula integer NOT NULL,
  id_turma     integer NOT NULL,          -- [E13] mesma técnica da presenca
  valor_nota   nota_t  NOT NULL,
  PRIMARY KEY (id_avaliacao, id_matricula),
  CONSTRAINT fk_nota_avaliacao_da_turma
    FOREIGN KEY (id_avaliacao, id_turma) REFERENCES tb_avaliacao (id_avaliacao, id_turma),
  CONSTRAINT fk_nota_matricula_da_turma
    FOREIGN KEY (id_matricula, id_turma) REFERENCES tb_matricula (id_matricula, id_turma)
);
COMMENT ON TABLE tb_nota IS 'Nota por avaliação; nota em avaliação de outra turma é IMPOSSÍVEL por FK composta [E13].';

-- ============================================================================
-- 11. DERIVAÇÃO DO DESEMPENHO  [E14]
--     Sucessora direta da coluna GERADA que a ampliação removeu de historico.
--     Antes, media_final_historico era `GENERATED ALWAYS AS (...) STORED` sobre
--     nota_a1/a2/p3 — três colunas fixas, 1FN disfarçada. Agora a nota vive em
--     `tb_nota` (n linhas por matrícula) e a média é DERIVADA aqui, uma vez, para
--     que consultas, views e a MV do 04 usem a MESMA regra.
--
--     A regra da P3 do modelo original é preservada: a avaliação SUBSTITUTIVA
--     troca a MENOR nota regular, e só quando é maior que ela.
--
--     Direitos do DONO (sem security_invoker), de propósito: quem consulta
--     precisa enxergar `tb_nota`/`tb_presenca` inteiras para a agregação fechar. O
--     isolamento por aluno é feito uma camada acima, em historico_aluno
--     (security_invoker = on), que filtra por `tb_matricula` — protegida por RLS.
--     Por isso esta view NÃO é concedida a papel_aluno (ver 08_seguranca.sql).
-- ============================================================================
CREATE VIEW vw_desempenho_matricula AS
WITH regulares AS (
  SELECT n.id_matricula, n.valor_nota, av.peso_avaliacao,
         row_number() OVER (PARTITION BY n.id_matricula ORDER BY n.valor_nota, av.id_avaliacao) AS posicao
  FROM tb_nota n
  JOIN tb_avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE NOT av.substitutiva_avaliacao
),
substitutiva AS (
  SELECT n.id_matricula, max(n.valor_nota) AS valor_nota
  FROM tb_nota n
  JOIN tb_avaliacao av ON av.id_avaliacao = n.id_avaliacao
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
  FROM tb_presenca p
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
FROM tb_matricula m
LEFT JOIN media md      ON md.id_matricula = m.id_matricula
LEFT JOIN frequencia fq ON fq.id_matricula = m.id_matricula;
COMMENT ON VIEW vw_desempenho_matricula IS
  'Média final (com a regra da substitutiva) e frequência, derivadas de nota/presenca [E14]. Sucessora da coluna gerada [C13].';


-- ============================================================================
-- 12. AUDITORIA TRANSVERSAL  [E19]
--     Três colunas em TODA tabela e dois triggers. É a única parte do modelo
--     que se aplica por igual a todas as 41 — e por isso entra num laço, não
--     copiada 41 vezes.
-- ============================================================================

-- criado_em / atualizado_em / excluido_em em todas as tabelas de dados.
-- log_auditoria fica de fora: ela é append-only e já tem `ocorrido_em`;
-- auditar a própria auditoria seria recursão sem ganho.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academico' AND tablename <> 'tb_log_auditoria'
           ORDER BY tablename
  LOOP
    EXECUTE format(
      'ALTER TABLE %I
         ADD COLUMN criado_em     timestamptz NOT NULL DEFAULT now(),
         ADD COLUMN atualizado_em timestamptz,
         ADD COLUMN excluido_em   timestamptz', t);
  END LOOP;
END $$;

COMMENT ON COLUMN tb_matricula.excluido_em IS
  'Exclusão lógica: preenchida em vez de apagar a linha. NULL = ativa.';

-- Marca a hora da última alteração. BEFORE UPDATE porque precisa alterar NEW
-- antes da gravação — um AFTER não conseguiria.
CREATE FUNCTION f_marca_atualizacao() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $$;

-- Grava a trilha. AFTER e RETURN NULL: o trigger não interfere na operação,
-- só registra o que já aconteceu. `to_jsonb(OLD/NEW)` guarda a linha inteira,
-- então a trilha continua legível mesmo se a tabela ganhar colunas depois.
CREATE FUNCTION f_auditoria() RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO academico.tb_log_auditoria (nome_tabela, acao_log, dados_antes, dados_depois)
  VALUES (TG_TABLE_NAME,
          lower(TG_OP)::acao_log_t,
          CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

-- f_marca_atualizacao vale para todas; f_auditoria só para as tabelas onde
-- "quem mudou o quê" é pergunta real. Auditar as 5.570 cidades do IBGE — dado
-- de referência que ninguém edita — seria encher a trilha de ruído e esconder
-- o que importa. As cinco escolhidas são as que guardam pessoa, vínculo e nota.
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables
           WHERE schemaname = 'academico' AND tablename <> 'tb_log_auditoria'
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_atualizacao BEFORE UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_marca_atualizacao()', t, t);
  END LOOP;

  FOREACH t IN ARRAY ARRAY['tb_pessoa','tb_aluno','tb_matricula','tb_nota','tb_historico']
  LOOP
    EXECUTE format(
      'CREATE TRIGGER tg_%s_auditoria AFTER INSERT OR UPDATE OR DELETE ON %I
         FOR EACH ROW EXECUTE FUNCTION f_auditoria()', t, t);
  END LOOP;
END $$;

COMMIT;

-- [C15] sessões novas nascem com o search_path certo, em qualquer banco:
SELECT format('ALTER DATABASE %I SET search_path TO academico, public', current_database())
\gexec

\echo '=== Esquema ampliado criado. Tabelas: ==='
SELECT count(*) AS tabelas FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE';
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'academico' AND table_type = 'BASE TABLE' ORDER BY table_name;
