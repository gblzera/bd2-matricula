

DROP SCHEMA IF EXISTS academico CASCADE;
CREATE SCHEMA academico;
SET search_path TO academico, public;

CREATE EXTENSION IF NOT EXISTS btree_gist;


CREATE TYPE turno_t       AS ENUM ('MATUTINO','VESPERTINO','NOTURNO');
CREATE TYPE tipo_disc_t   AS ENUM ('OBRIGATORIA','OPTATIVA');
CREATE TYPE vinculo_t     AS ENUM ('PRE_REQUISITO','CO_REQUISITO');
CREATE TYPE status_mat_t  AS ENUM ('MATRICULADO','TRANCADO','CANCELADO');
CREATE TYPE situacao_t    AS ENUM ('CURSANDO','APROVADO','REPROVADO_NOTA','REPROVADO_FALTA');
CREATE TYPE tipo_sala_t   AS ENUM ('TEORICA','LABORATORIO');

CREATE DOMAIN nota_t AS numeric(4,2) CHECK (VALUE >= 0 AND VALUE <= 10);
CREATE DOMAIN pct_t  AS numeric(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);

-- faixa de horário: exercita tipos de intervalo e restrições EXCLUDE
CREATE TYPE timerange AS RANGE (subtype = time);


CREATE TABLE campus (
    id      smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome    varchar(60) NOT NULL UNIQUE,
    cidade  varchar(60) NOT NULL
);

CREATE TABLE curso (
    id         smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo     varchar(10) NOT NULL UNIQUE,
    nome       varchar(120) NOT NULL,
    grau       varchar(20) NOT NULL
               CHECK (grau IN ('BACHARELADO','LICENCIATURA','TECNOLOGO')),
    ch_total   integer NOT NULL CHECK (ch_total > 0),
    campus_id  smallint NOT NULL REFERENCES campus ON DELETE RESTRICT
);

CREATE TABLE curriculo (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    curso_id      smallint NOT NULL REFERENCES curso ON DELETE CASCADE,
    ano_vigencia  smallint NOT NULL CHECK (ano_vigencia BETWEEN 2000 AND 2100),
    ativo         boolean  NOT NULL DEFAULT false,
    UNIQUE (curso_id, ano_vigencia)
);
-- regra: no máximo um currículo ativo por curso (índice único parcial)
CREATE UNIQUE INDEX uq_curriculo_ativo
    ON curriculo (curso_id) WHERE ativo;

CREATE TABLE disciplina (
    id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo       varchar(10) NOT NULL UNIQUE,
    nome         varchar(120) NOT NULL,
    ch_teorica   smallint NOT NULL CHECK (ch_teorica >= 0),
    ch_pratica   smallint NOT NULL CHECK (ch_pratica >= 0),
    ch_total     smallint GENERATED ALWAYS AS (ch_teorica + ch_pratica) STORED,
    ementa       text,
    CHECK (ch_teorica + ch_pratica > 0)
);

CREATE TABLE curriculo_disciplina (
    curriculo_id  integer NOT NULL REFERENCES curriculo ON DELETE CASCADE,
    disciplina_id integer NOT NULL REFERENCES disciplina ON DELETE RESTRICT,
    periodo       smallint NOT NULL CHECK (periodo BETWEEN 1 AND 12),
    tipo          tipo_disc_t NOT NULL DEFAULT 'OBRIGATORIA',
    PRIMARY KEY (curriculo_id, disciplina_id)
);


CREATE TABLE pre_requisito (
    disciplina_id integer NOT NULL REFERENCES disciplina ON DELETE CASCADE,
    requisito_id  integer NOT NULL REFERENCES disciplina ON DELETE RESTRICT,
    vinculo       vinculo_t NOT NULL DEFAULT 'PRE_REQUISITO',
    PRIMARY KEY (disciplina_id, requisito_id),
    CHECK (disciplina_id <> requisito_id)
);

CREATE TABLE professor (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula  varchar(12) NOT NULL UNIQUE,
    nome       varchar(120) NOT NULL,
    email      varchar(120) NOT NULL UNIQUE
               CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$'),
    titulacao  varchar(20) NOT NULL
               CHECK (titulacao IN ('ESPECIALISTA','MESTRE','DOUTOR'))
);

CREATE TABLE sala (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campus_id   smallint NOT NULL REFERENCES campus ON DELETE RESTRICT,
    codigo      varchar(10) NOT NULL,
    capacidade  smallint NOT NULL CHECK (capacidade > 0),
    tipo        tipo_sala_t NOT NULL DEFAULT 'TEORICA',
    UNIQUE (campus_id, codigo)
);


CREATE TABLE periodo_letivo (
    id           smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ano          smallint NOT NULL,
    semestre     smallint NOT NULL CHECK (semestre IN (1,2)),
    data_inicio  date NOT NULL,
    data_fim     date NOT NULL,
    UNIQUE (ano, semestre),
    CHECK (data_fim > data_inicio)
);

CREATE TABLE feriado (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    data       date NOT NULL,
    descricao  varchar(120) NOT NULL,
    campus_id  smallint REFERENCES campus ON DELETE CASCADE,  -- NULL = todos
    UNIQUE (data, campus_id)
);

CREATE TABLE turma (
    id                 integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo             varchar(15) NOT NULL,
    disciplina_id      integer  NOT NULL REFERENCES disciplina ON DELETE RESTRICT,
    periodo_letivo_id  smallint NOT NULL REFERENCES periodo_letivo ON DELETE RESTRICT,
    professor_id       integer  REFERENCES professor ON DELETE SET NULL,
    turno              turno_t  NOT NULL,
    vagas              smallint NOT NULL CHECK (vagas > 0),
    UNIQUE (codigo, periodo_letivo_id, disciplina_id)
);

CREATE TABLE turma_horario (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    turma_id    integer NOT NULL REFERENCES turma ON DELETE CASCADE,
    sala_id     integer NOT NULL REFERENCES sala ON DELETE RESTRICT,
    dia_semana  smallint NOT NULL CHECK (dia_semana BETWEEN 1 AND 7), -- 1=domingo
    faixa       timerange NOT NULL,
    CHECK (NOT isempty(faixa))
);

-- uma sala não pode receber duas turmas no mesmo dia e horário
ALTER TABLE turma_horario
    ADD CONSTRAINT ex_sala_ocupada
    EXCLUDE USING gist (sala_id WITH =, dia_semana WITH =, faixa WITH &&);


CREATE TABLE aluno (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula     varchar(12) NOT NULL UNIQUE,
    nome          varchar(120) NOT NULL,
    cpf           char(11) NOT NULL UNIQUE CHECK (cpf ~ '^[0-9]{11}$'),
    email         varchar(120) NOT NULL UNIQUE,
    nascimento    date NOT NULL CHECK (nascimento < CURRENT_DATE),
    curso_id      smallint NOT NULL REFERENCES curso ON DELETE RESTRICT,
    curriculo_id  integer  NOT NULL REFERENCES curriculo ON DELETE RESTRICT,
    ingresso      date NOT NULL,
    ativo         boolean NOT NULL DEFAULT true
);

CREATE TABLE matricula (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aluno_id        integer NOT NULL REFERENCES aluno  ON DELETE CASCADE,
    turma_id        integer NOT NULL REFERENCES turma  ON DELETE RESTRICT,
    data_matricula  timestamptz NOT NULL DEFAULT now(),
    status          status_mat_t NOT NULL DEFAULT 'MATRICULADO',
    UNIQUE (aluno_id, turma_id)
);

CREATE TABLE historico (
    id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula_id  integer NOT NULL UNIQUE REFERENCES matricula ON DELETE CASCADE,
    nota_a1       nota_t,
    nota_a2       nota_t,
    nota_p3       nota_t,
    frequencia    pct_t NOT NULL DEFAULT 100,
    situacao      situacao_t NOT NULL DEFAULT 'CURSANDO',
   
    media_final numeric(4,2) GENERATED ALWAYS AS (
        CASE
          WHEN nota_a1 IS NULL OR nota_a2 IS NULL THEN NULL
          WHEN nota_p3 IS NULL THEN round(0.4*nota_a1 + 0.6*nota_a2, 2)
          ELSE round(greatest(0.4*nota_p3 + 0.6*nota_a2,
                              0.4*nota_a1 + 0.6*nota_p3), 2)
        END
    ) STORED
);

CREATE TABLE log_matricula (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    matricula_id  integer NOT NULL,
    acao          varchar(20) NOT NULL,
    ocorrido_em   timestamptz NOT NULL DEFAULT now(),
    usuario       name NOT NULL DEFAULT CURRENT_USER,
    detalhe       jsonb
);


CREATE OR REPLACE FUNCTION fn_valida_vaga() RETURNS trigger AS $$
DECLARE
    v_vagas     smallint;
    v_ocupadas  integer;
BEGIN
    SELECT vagas INTO v_vagas FROM turma WHERE id = NEW.turma_id;

    SELECT count(*) INTO v_ocupadas
      FROM matricula
     WHERE turma_id = NEW.turma_id
       AND status   = 'MATRICULADO'
       AND id <> COALESCE(NEW.id, -1);

    IF v_ocupadas >= v_vagas THEN
        RAISE EXCEPTION 'Turma % sem vagas (% de %)',
            NEW.turma_id, v_ocupadas, v_vagas
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_valida_vaga
    BEFORE INSERT OR UPDATE ON matricula
    FOR EACH ROW EXECUTE FUNCTION fn_valida_vaga();

-- ---------------------------------------------------------------------
-- 6. ÍNDICES
-- ---------------------------------------------------------------------
CREATE INDEX ix_matricula_turma_ativa
    ON matricula (turma_id) WHERE status = 'MATRICULADO';   -- parcial
CREATE INDEX ix_matricula_aluno       ON matricula (aluno_id);
CREATE INDEX ix_turma_periodo_disc    ON turma (periodo_letivo_id, disciplina_id);
CREATE INDEX ix_historico_situacao    ON historico (situacao) WHERE situacao <> 'CURSANDO';
CREATE INDEX ix_log_ocorrido          ON log_matricula USING brin (ocorrido_em);
CREATE INDEX ix_disciplina_ementa_fts
    ON disciplina USING gin (to_tsvector('portuguese', coalesce(ementa,'')));


CREATE VIEW vw_oferta AS
SELECT pl.ano, pl.semestre, d.codigo AS disciplina, d.nome, t.codigo AS turma,
       t.turno, p.nome AS professor, s.codigo AS sala,
       th.dia_semana, lower(th.faixa) AS inicio, upper(th.faixa) AS fim, t.vagas
  FROM turma t
  JOIN disciplina     d  ON d.id  = t.disciplina_id
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
  LEFT JOIN professor p  ON p.id  = t.professor_id
  LEFT JOIN turma_horario th ON th.turma_id = t.id
  LEFT JOIN sala      s  ON s.id  = th.sala_id;

CREATE VIEW vw_vagas AS
SELECT t.id AS turma_id, t.codigo, d.codigo AS disciplina, t.vagas,
       count(m.id) FILTER (WHERE m.status = 'MATRICULADO') AS ocupadas,
       t.vagas - count(m.id) FILTER (WHERE m.status = 'MATRICULADO') AS restantes
  FROM turma t
  JOIN disciplina d ON d.id = t.disciplina_id
  LEFT JOIN matricula m ON m.turma_id = t.id
 GROUP BY t.id, t.codigo, d.codigo, t.vagas;

CREATE VIEW vw_historico AS
SELECT a.matricula AS ra, a.nome AS aluno, d.codigo AS disciplina, d.ch_total,
       pl.ano, pl.semestre, h.nota_a1, h.nota_a2, h.nota_p3,
       h.frequencia, h.media_final,
       CASE
         WHEN h.frequencia < 75      THEN 'SR'
         WHEN h.media_final IS NULL  THEN NULL
         WHEN h.media_final >= 9     THEN 'SS'
         WHEN h.media_final >= 7     THEN 'MS'
         WHEN h.media_final >= 5     THEN 'MM'
         WHEN h.media_final >= 3     THEN 'MI'
         WHEN h.media_final >  0     THEN 'II'
         ELSE 'SR'
       END AS mencao
  FROM historico h
  JOIN matricula m  ON m.id  = h.matricula_id
  JOIN aluno a      ON a.id  = m.aluno_id
  JOIN turma t      ON t.id  = m.turma_id
  JOIN disciplina d ON d.id  = t.disciplina_id
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id;

CREATE MATERIALIZED VIEW mv_indicadores_curso AS
SELECT c.codigo AS curso, pl.ano, pl.semestre,
       count(*) AS matriculas,
       round(avg(h.media_final), 2) AS media_geral,
       round(100.0 * count(*) FILTER (WHERE h.situacao = 'APROVADO')
             / nullif(count(*) FILTER (WHERE h.situacao <> 'CURSANDO'), 0), 1)
             AS taxa_aprovacao
  FROM historico h
  JOIN matricula m  ON m.id = h.matricula_id
  JOIN aluno a      ON a.id = m.aluno_id
  JOIN curso c      ON c.id = a.curso_id
  JOIN turma t      ON t.id = m.turma_id
  JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
 GROUP BY c.codigo, pl.ano, pl.semestre
 WITH NO DATA;

CREATE UNIQUE INDEX uq_mv_indicadores
    ON mv_indicadores_curso (curso, ano, semestre);  


INSERT INTO campus (nome, cidade) VALUES
 ('Asa Sul','Brasília'), ('Ceilândia','Brasília');

INSERT INTO curso (codigo, nome, grau, ch_total, campus_id) VALUES
 ('CCO','Ciência da Computação','BACHARELADO',3200,1),
 ('ENGC','Engenharia de Computação','BACHARELADO',3600,1),
 ('ADS','Análise e Desenvolvimento de Sistemas','TECNOLOGO',2000,1);

INSERT INTO curriculo (curso_id, ano_vigencia, ativo) VALUES
 (1,2026,true), (1,2023,false), (2,2026,true), (3,2026,true);

INSERT INTO disciplina (codigo, nome, ch_teorica, ch_pratica, ementa) VALUES
 ('HMDC253','Banco de Dados I',30,30,'Modelagem conceitual, modelo relacional, álgebra relacional, normalização e SQL.'),
 ('CCO072','Banco de Dados II',30,30,'Arquitetura de SGBD, transações, controle de concorrência, recuperação, segurança, otimização de consultas e bancos distribuídos.'),
 ('CCO085','Programação Paralela',45,15,'Concorrência, paralelismo, memória compartilhada e distribuída.'),
 ('MDC050','Inteligência Artificial',45,15,'Busca, representação do conhecimento e aprendizado de máquina.'),
 ('ADS033','Aprendizagem de Máquina',30,30,'Aprendizado supervisionado e não supervisionado, avaliação de modelos.'),
 ('MDC118','Algoritmos e Programação de Computadores I',30,30,'Lógica de programação e estruturas básicas.'),
 ('MDC122','Sistemas Operacionais',45,15,'Processos, escalonamento, memória e sistemas de arquivos.');

INSERT INTO curriculo_disciplina (curriculo_id, disciplina_id, periodo, tipo) VALUES
 (1,1,2,'OBRIGATORIA'), (1,2,4,'OBRIGATORIA'), (1,3,6,'OBRIGATORIA'),
 (1,4,4,'OBRIGATORIA'), (1,6,1,'OBRIGATORIA'), (1,7,4,'OBRIGATORIA'),
 (4,5,5,'OBRIGATORIA');

INSERT INTO pre_requisito (disciplina_id, requisito_id, vinculo) VALUES
 (1,6,'PRE_REQUISITO'),   -- BD I  requer APC I
 (2,1,'PRE_REQUISITO'),   -- BD II requer BD I
 (3,6,'PRE_REQUISITO'),   -- Prog Paralela requer APC I
 (3,7,'PRE_REQUISITO'),   -- Prog Paralela requer Sist Operacionais
 (4,6,'PRE_REQUISITO');

INSERT INTO professor (matricula, nome, email, titulacao) VALUES
 ('201680','Rodrigo Gonçalves Pinto','rodrigo.pinto@iesb.edu.br','MESTRE'),
 ('201455','Marcelo Paiva','marcelo.paiva@iesb.edu.br','DOUTOR'),
 ('201322','Roger Santos','roger.santos@iesb.edu.br','MESTRE');

INSERT INTO sala (campus_id, codigo, capacidade, tipo) VALUES
 (1,'JB1',55,'LABORATORIO'), (1,'JB2/4',36,'LABORATORIO'),
 (1,'JB5',44,'LABORATORIO'), (1,'IA2',24,'LABORATORIO'),
 (1,'IA3',30,'LABORATORIO'), (1,'JA2',32,'TEORICA');

INSERT INTO periodo_letivo (ano, semestre, data_inicio, data_fim) VALUES
 (2026,2,'2026-08-03','2026-12-12'), (2026,1,'2026-02-02','2026-06-20');

INSERT INTO feriado (data, descricao, campus_id) VALUES
 ('2026-09-07','Independência do Brasil',NULL),
 ('2026-10-12','Nossa Senhora Aparecida',NULL),
 ('2026-10-13','Recesso — antecipação do Dia do Professor',NULL),
 ('2026-11-02','Finados',NULL),
 ('2026-11-15','Proclamação da República',NULL),
 ('2026-11-20','Dia da Consciência Negra',NULL),
 ('2026-11-30','Dia do Evangélico',NULL),
 ('2026-12-25','Natal',NULL);

INSERT INTO turma (codigo, disciplina_id, periodo_letivo_id, professor_id, turno, vagas) VALUES
 ('CCODM2B',2,1,1,'MATUTINO',40),
 ('CCONM2B',2,1,1,'NOTURNO',24),
 ('CCODM3B',3,1,1,'MATUTINO',30),
 ('CCONM3B',3,1,1,'NOTURNO',30),
 ('ENGCDM2B',4,1,1,'MATUTINO',36),
 ('ADSDM2C',5,1,1,'MATUTINO',36);

INSERT INTO turma_horario (turma_id, sala_id, dia_semana, faixa) VALUES
 (1,1,2,'[08:15,11:00)'),   -- BD II matutino  · segunda · JB1
 (2,4,2,'[19:15,22:00)'),   -- BD II noturno   · segunda · IA2
 (3,5,5,'[08:15,11:00)'),   -- Prog Paralela M · quinta  · IA3
 (4,5,5,'[19:15,22:00)'),   -- Prog Paralela N · quinta  · IA3
 (5,2,4,'[08:15,11:00)'),   -- IA matutino     · quarta  · JB2/4
 (6,2,6,'[08:15,11:00)');   -- Apr. Máquina    · sexta   · JB2/4

INSERT INTO aluno (matricula, nome, cpf, email, nascimento, curso_id, curriculo_id, ingresso)
SELECT lpad(g::text, 8, '0'),
       'Aluno ' || g,
       lpad(g::text, 11, '0'),
       'aluno' || g || '@iesb.edu.br',
       DATE '2003-01-01' + (g % 900),
       1, 1,
       DATE '2024-02-01'
  FROM generate_series(1, 120) g;


INSERT INTO matricula (aluno_id, turma_id)
SELECT g, 1 FROM generate_series(1, 30) g;
INSERT INTO matricula (aluno_id, turma_id)
SELECT g, 2 FROM generate_series(31, 50) g;

INSERT INTO historico (matricula_id, nota_a1, nota_a2, frequencia, situacao)
SELECT m.id,
       round((random() * 6 + 4)::numeric, 1),
       round((random() * 6 + 4)::numeric, 1),
       round((random() * 30 + 70)::numeric, 1),
       'CURSANDO'
  FROM matricula m;

UPDATE historico SET situacao =
    CASE WHEN frequencia < 75      THEN 'REPROVADO_FALTA'::situacao_t
         WHEN media_final >= 5     THEN 'APROVADO'::situacao_t
         ELSE 'REPROVADO_NOTA'::situacao_t END;

REFRESH MATERIALIZED VIEW mv_indicadores_curso;
ANALYZE;


