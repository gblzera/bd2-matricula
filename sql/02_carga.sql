-- ============================================================================
-- 02_carga.sql — Marco 1 · Carga de dados do MODELO AMPLIADO (41 tabelas)
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Requisitos do enunciado: >= 100 alunos, >= 6 turmas, >= 300 matrículas
-- (generate_series permitido). Esta carga produz 120 alunos, 34 turmas em
-- 4 períodos letivos (2025/1 a 2026/2) e ~700 matrículas — agora com o
-- registro FINO que a ampliação criou: aulas, presenças, avaliações e notas.
--
-- A carga é 100% DETERMINÍSTICA (aritmética modular, sem random()):
-- reexecutar produz exatamente os mesmos dados — importante para
-- reproduzibilidade das consultas e das evidências de EXPLAIN do Marco 2.
--
-- O QUE MUDOU COM A AMPLIAÇÃO (ver docs/modelo-tabelas.drawio, página 2):
--   [E1] geografia: pais -> estado -> cidade -> endereco antes de qualquer campus
--   [E2] pessoa é o supertipo: nome/e-mail/CPF/nascimento saíram de aluno e
--        professor; a carga cria a pessoa e DEPOIS a especialização
--   [E4] usuario espelha a ROLE do PostgreSQL (login_usuario = nome da role)
--   [E11] o professor da turma virou turma_professor (titular + auxiliar)
--   [E14] nota_a1/a2/p3 sumiram de historico: agora são avaliacao + nota, e
--        a frequência sai de presenca. historico guarda só o CONSOLIDADO.
--
-- Cenários plantados de propósito (usados pelas consultas e pelo Marco 2):
--   · TABD-N1 (2026/2) com 8 vagas e 7 confirmadas  -> 1 vaga p/ disputa (Marco 2)
--   · COMP1-N1 (2026/2) sem nenhuma matrícula       -> junção externa (consulta 3)
--   · LBD2-N1 (2026/2) EAD, sem sala                -> EXCLUDE parcial [E12]
--   · alunos com 3-4 semestres de notas             -> LAG/evolução (consulta 8)
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/02_carga.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


BEGIN;

-- Idempotência: limpa dados preservando o esquema. A ordem não importa por
-- causa do CASCADE, mas a lista é explícita para que uma tabela nova nunca
-- fique de fora silenciosamente.
TRUNCATE pais, estado, cidade, endereco, pessoa, telefone, documento_pessoa,
         usuario, campus, departamento, predio, sala, recurso, sala_recurso,
         professor, formacao_professor, curso, coordenacao_curso, curriculo,
         disciplina, curriculo_disciplina, pre_requisito, aluno,
         aproveitamento_materia, periodo_letivo, periodo_matricula, feriado,
         turma, turma_professor, turma_horario, plano_ensino,
         unidade_plano_ensino, bibliografia, plano_ensino_bibliografia,
         matricula, historico, log_matricula, aula, presenca, avaliacao, nota
RESTART IDENTITY CASCADE;

-- ============================================================================
-- 1. GEOGRAFIA  [E1]
--    A cadeia inteira nasce aqui: nenhum endereço existe sem cidade, nenhuma
--    cidade sem estado, nenhum estado sem país. É o fim do "Brasília" digitado
--    à mão em cada campus.
-- ============================================================================
INSERT INTO pais (nome_pais, sigla_pais) VALUES ('Brasil', 'BR');

INSERT INTO estado (id_pais, nome_estado, uf_estado)
SELECT p.id_pais, v.nome, v.uf
FROM (VALUES
  ('Distrito Federal', 'DF'), ('Goiás', 'GO'), ('Minas Gerais', 'MG'),
  ('São Paulo', 'SP'),        ('Bahia', 'BA')
) AS v(nome, uf), pais p;

INSERT INTO cidade (id_estado, nome_cidade, codigo_ibge_cidade)
SELECT e.id_estado, v.nome, v.ibge
FROM (VALUES
  ('DF', 'Brasília',        '5300108'),
  ('GO', 'Goiânia',         '5208707'),
  ('GO', 'Anápolis',        '5201108'),
  ('GO', 'Luziânia',        '5212501'),
  ('MG', 'Belo Horizonte',  '3106200'),
  ('MG', 'Uberlândia',      '3170206'),
  ('SP', 'São Paulo',       '3550308'),
  ('SP', 'Campinas',        '3509502'),
  ('BA', 'Salvador',        '2927408')
) AS v(uf, nome, ibge)
JOIN estado e ON e.uf_estado = v.uf;

-- Endereços institucionais (os dois campi)
INSERT INTO endereco (id_cidade, logradouro_endereco, numero_endereco, complemento_endereco, bairro_endereco, cep_endereco)
SELECT c.id_cidade, v.log, v.num, v.compl, v.bairro, v.cep
FROM (VALUES
  ('Brasília', 'SEPN 707/907', '1',   'Campus A',   'Asa Norte', '70790075'),
  ('Brasília', 'SGAS 613/614', '255', 'Campus B',   'Asa Sul',   '70200730')
) AS v(cidade, log, num, compl, bairro, cep)
JOIN cidade c ON c.nome_cidade = v.cidade;

INSERT INTO campus (id_endereco, nome_campus)
SELECT e.id_endereco, v.nome
FROM (VALUES
  ('Campus B', 'Asa Sul'),
  ('Campus A', 'Asa Norte')
) AS v(compl, nome)
JOIN endereco e ON e.complemento_endereco = v.compl;

-- ============================================================================
-- 2. PESSOAS  [E2]
--    130 pessoas: 10 docentes, 118 discentes... na verdade 120 discentes e 2
--    servidores técnicos (secretaria e DBA). Toda especialização abaixo
--    (professor, aluno, usuario) aponta para uma linha daqui.
--    Faixas de CPF disjuntas por grupo — reexecução nunca colide, e o
--    05_volume_legado.sql usa a faixa 2e10, também disjunta.
-- ============================================================================
WITH nomes AS (
  SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
               'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
               'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
         ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
               'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
               'Gomes','Martins']                                AS sn
),
-- endereços residenciais: 1 por pessoa, distribuídos pelas cidades cadastradas
-- (a maioria em Brasília, como manda a realidade de um campus do DF)
ends AS (
  INSERT INTO endereco (id_cidade, logradouro_endereco, numero_endereco, bairro_endereco, cep_endereco)
  SELECT c.id_cidade,
         'Quadra ' || (100 + g.i % 400) || ' Conjunto ' || chr(65 + g.i % 20),
         ((g.i * 7) % 900 + 1)::text,
         (ARRAY['Asa Norte','Asa Sul','Taguatinga','Águas Claras','Sudoeste',
                'Guará','Ceilândia','Samambaia'])[1 + g.i % 8],
         lpad((70000000 + (g.i * 137) % 900000)::text, 8, '0')
  FROM generate_series(1, 132) AS g(i)
  JOIN LATERAL (
    SELECT id_cidade FROM cidade
    ORDER BY CASE WHEN g.i % 10 < 7 THEN 0 ELSE 1 END,   -- 70% Brasília
             CASE WHEN g.i % 10 < 7 THEN 0 ELSE (id_cidade + g.i) % 9 END,
             id_cidade
    LIMIT 1
  ) c ON true
  RETURNING id_endereco
)
INSERT INTO pessoa (id_endereco, nome_pessoa, email_pessoa, cpf_pessoa, nascimento_pessoa)
SELECT e.id_endereco, x.nome, x.email, x.cpf, x.nasc
FROM (
  -- (a) 10 docentes — nomes fixos, os mesmos da carga anterior
  SELECT 1 AS grupo, v.ord, v.nome,
         v.email,
         lpad((90000000000 + v.ord * 7654321)::text, 11, '0')::char(11) AS cpf,
         DATE '1970-01-01' + (v.ord * 613) AS nasc
  FROM (VALUES
    (1,'Marcos Tanaka','marcos.tanaka@iesb.br'),   (2,'Luciana Prado','luciana.prado@iesb.br'),
    (3,'André Vieira','andre.vieira@iesb.br'),     (4,'Camila Duarte','camila.duarte@iesb.br'),
    (5,'Ricardo Nóbrega','ricardo.nobrega@iesb.br'),(6,'Sofia Rezende','sofia.rezende@iesb.br'),
    (7,'Tiago Sales','tiago.sales@iesb.br'),       (8,'Vera Lúcia Pinto','vera.pinto@iesb.br'),
    (9,'Paulo César Lima','paulo.lima@iesb.br'),   (10,'Helena Barros','helena.barros@iesb.br')
  ) AS v(ord, nome, email)
  UNION ALL
  -- (b) 2 servidores técnicos: a secretaria acadêmica e o DBA
  SELECT 2, v.ord, v.nome, v.email,
         lpad((95000000000 + v.ord * 1234567)::text, 11, '0')::char(11),
         DATE '1985-05-10' + (v.ord * 97)
  FROM (VALUES
    (1, 'Juliana Freitas', 'juliana.freitas@iesb.br'),
    (2, 'Gabriel Kuhn Paz', 'gabriel.paz@iesb.br')
  ) AS v(ord, nome, email)
  UNION ALL
  -- (c) 120 discentes
  SELECT 3, g.i,
         n.pn[1 + (g.i * 7) % 20] || ' ' || n.sn[1 + (g.i * 13) % 15],
         lower(n.pn[1 + (g.i * 7) % 20] || '.' || n.sn[1 + (g.i * 13) % 15]) || g.i || '@aluno.iesb.br',
         lpad(((g.i::bigint * 137137137 + 91) % 100000000000)::text, 11, '0')::char(11),
         DATE '1999-01-01' + (g.i * 211) % 3000
  FROM generate_series(1, 120) AS g(i), nomes n
) AS x
JOIN LATERAL (
  SELECT id_endereco,
         row_number() OVER (ORDER BY id_endereco) AS rn
  FROM ends
) e ON e.rn = CASE x.grupo WHEN 1 THEN x.ord
                          WHEN 2 THEN 10 + x.ord
                          ELSE 12 + x.ord END;

-- Telefones [E3]: um celular principal para todos; fixo adicional a cada 3.
INSERT INTO telefone (id_pessoa, numero_telefone, principal_telefone, tipo_telefone)
SELECT p.id_pessoa,
       '(61) 9' || lpad(((p.id_pessoa * 81721) % 100000000)::text, 8, '0'),
       true, 'celular'
FROM pessoa p;

INSERT INTO telefone (id_pessoa, numero_telefone, principal_telefone, tipo_telefone)
SELECT p.id_pessoa,
       '(61) 3' || lpad(((p.id_pessoa * 5417) % 10000000)::text, 7, '0'),
       false, 'residencial'
FROM pessoa p
WHERE p.id_pessoa % 3 = 0;

-- Documentos [E3]: RG para todos (o CPF NÃO entra aqui — é 1:1 com a pessoa
-- e por isso vive em pessoa.cpf_pessoa [E2]); CNH para uma parte.
INSERT INTO documento_pessoa (id_pessoa, numero_documento_pessoa, orgao_documento_pessoa, emissao_documento_pessoa, tipo_documento_pessoa)
SELECT p.id_pessoa,
       lpad(((p.id_pessoa * 314159) % 10000000)::text, 7, '0'),
       (ARRAY['SSP/DF','SSP/GO','SSP/MG','SSP/SP','SSP/BA'])[1 + p.id_pessoa % 5],
       p.nascimento_pessoa + interval '18 years',
       'rg'
FROM pessoa p;

INSERT INTO documento_pessoa (id_pessoa, numero_documento_pessoa, orgao_documento_pessoa, emissao_documento_pessoa, tipo_documento_pessoa)
SELECT p.id_pessoa,
       lpad(((p.id_pessoa * 2718281) % 100000000000)::text, 11, '0'),
       'DETRAN/DF',
       p.nascimento_pessoa + interval '20 years',
       'cnh'
FROM pessoa p
WHERE p.id_pessoa % 5 = 0;

-- ============================================================================
-- 3. INFRAESTRUTURA  [E5] [E6]
-- ============================================================================
INSERT INTO departamento (id_campus, nome_departamento, sigla_departamento)
SELECT c.id_campus, v.nome, v.sigla
FROM (VALUES
  ('Asa Sul',   'Departamento de Ciência da Computação', 'DCC'),
  ('Asa Sul',   'Departamento de Matemática',            'DMAT'),
  ('Asa Norte', 'Departamento de Gestão',                'DGES')
) AS v(campus, nome, sigla)
JOIN campus c ON c.nome_campus = v.campus;

-- [E5] sala não pertence mais ao campus direto: pertence ao PRÉDIO.
INSERT INTO predio (id_campus, nome_predio, andares_predio)
SELECT c.id_campus, v.nome, v.andares
FROM (VALUES
  ('Asa Sul',   'Bloco A', 4),
  ('Asa Sul',   'Bloco B', 3),
  ('Asa Norte', 'Bloco Único', 5),
  ('Asa Norte', 'Anexo Laboratórios', 2)
) AS v(campus, nome, andares)
JOIN campus c ON c.nome_campus = v.campus;

-- "T101" existe nos DOIS campi: continua legal, agora por UNIQUE(predio, codigo) [C4→E5]
INSERT INTO sala (id_predio, codigo_sala, andar_sala, capacidade_sala, tipo_sala)
SELECT pr.id_predio, v.codigo, v.andar, v.cap, v.tipo::tipo_sala_t
FROM (VALUES
  ('Asa Sul',   'Bloco A',            'T101', 1, 60,  'teorica'),
  ('Asa Sul',   'Bloco A',            'T102', 1, 60,  'teorica'),
  ('Asa Sul',   'Bloco A',            'T103', 2, 45,  'teorica'),
  ('Asa Sul',   'Bloco B',            'L201', 2, 25,  'laboratorio'),
  ('Asa Sul',   'Bloco B',            'L202', 2, 25,  'laboratorio'),
  ('Asa Sul',   'Bloco B',            'AUD1', 1, 120, 'auditorio'),
  ('Asa Norte', 'Bloco Único',        'T101', 1, 50,  'teorica'),
  ('Asa Norte', 'Bloco Único',        'T102', 1, 40,  'teorica'),
  ('Asa Norte', 'Anexo Laboratórios', 'L101', 1, 25,  'laboratorio')
) AS v(campus, predio, codigo, andar, cap, tipo)
JOIN campus c  ON c.nome_campus = v.campus
JOIN predio pr ON pr.id_campus = c.id_campus AND pr.nome_predio = v.predio;

INSERT INTO recurso (nome_recurso) VALUES
  ('Projetor multimídia'), ('Quadro branco'), ('Ar-condicionado'),
  ('Computadores'), ('Lousa digital');

-- Recursos por sala: quadro em todas; projetor e ar na maioria; computadores
-- só em laboratório (a regra que justifica a tabela existir).
INSERT INTO sala_recurso (id_sala, id_recurso, quantidade_sala_recurso)
SELECT s.id_sala, r.id_recurso,
       CASE r.nome_recurso WHEN 'Computadores' THEN s.capacidade_sala ELSE 1 END
FROM sala s
CROSS JOIN recurso r
WHERE (r.nome_recurso = 'Quadro branco')
   OR (r.nome_recurso = 'Projetor multimídia' AND s.id_sala % 4 <> 0)
   OR (r.nome_recurso = 'Ar-condicionado'     AND s.id_sala % 3 <> 0)
   OR (r.nome_recurso = 'Computadores'        AND s.tipo_sala = 'laboratorio')
   OR (r.nome_recurso = 'Lousa digital'       AND s.tipo_sala = 'auditorio');

-- ============================================================================
-- 4. DOCENTES  [E2] [E6]
-- ============================================================================
INSERT INTO professor (id_pessoa, id_departamento, matricula_professor, regime_professor, titulacao_professor)
SELECT p.id_pessoa, d.id_departamento, v.mat, v.regime::regime_professor_t, v.titulacao::titulacao_t
FROM (VALUES
  ('marcos.tanaka@iesb.br',   'P0001', 'DCC',  'integral', 'doutorado'),
  ('luciana.prado@iesb.br',   'P0002', 'DMAT', 'integral', 'doutorado'),
  ('andre.vieira@iesb.br',    'P0003', 'DCC',  'parcial',  'mestrado'),
  ('camila.duarte@iesb.br',   'P0004', 'DCC',  'integral', 'doutorado'),
  ('ricardo.nobrega@iesb.br', 'P0005', 'DCC',  'parcial',  'mestrado'),
  ('sofia.rezende@iesb.br',   'P0006', 'DGES', 'horista',  'especializacao'),
  ('tiago.sales@iesb.br',     'P0007', 'DCC',  'parcial',  'mestrado'),
  ('vera.pinto@iesb.br',      'P0008', 'DMAT', 'integral', 'doutorado'),
  ('paulo.lima@iesb.br',      'P0009', 'DCC',  'parcial',  'mestrado'),
  ('helena.barros@iesb.br',   'P0010', 'DGES', 'horista',  'especializacao')
) AS v(email, mat, sigla, regime, titulacao)
JOIN pessoa p       ON p.email_pessoa = v.email
JOIN departamento d ON d.sigla_departamento = v.sigla;

-- Formações [E3]: a graduação de todos, e a pós de quem tem título maior.
INSERT INTO formacao_professor (id_professor, curso_formacao_professor, instituicao_formacao_professor, ano_conclusao_formacao_professor, titulacao_formacao_professor)
SELECT pr.id_professor, 'Ciência da Computação',
       (ARRAY['UnB','UFG','USP','UFMG','PUC'])[1 + pr.id_professor % 5],
       1995 + (pr.id_professor * 3) % 15, 'graduacao'
FROM professor pr
UNION ALL
SELECT pr.id_professor,
       CASE pr.titulacao_professor WHEN 'doutorado' THEN 'Doutorado em Informática'
                                   WHEN 'mestrado'  THEN 'Mestrado em Informática'
                                   ELSE 'Especialização em Banco de Dados' END,
       (ARRAY['UnB','USP','UFRJ','UFPE','UNICAMP'])[1 + (pr.id_professor * 2) % 5],
       2008 + (pr.id_professor * 2) % 14, pr.titulacao_professor
FROM professor pr
WHERE pr.titulacao_professor <> 'graduacao';

-- [E6] chefia: a FK circular criada por ALTER, com UNIQUE (um chefe por professor).
UPDATE departamento d
SET id_professor_chefe = pr.id_professor
FROM professor pr, pessoa p
WHERE pr.id_pessoa = p.id_pessoa
  AND (d.sigla_departamento, p.email_pessoa) IN (
        ('DCC',  'marcos.tanaka@iesb.br'),
        ('DMAT', 'vera.pinto@iesb.br'),
        ('DGES', 'helena.barros@iesb.br'));

-- ============================================================================
-- 5. USUÁRIOS  [E4]
--    login_usuario É o nome da ROLE do PostgreSQL. O 08_seguranca.sql cria as
--    roles com exatamente estes nomes — e f_usuario_sessao() liga uma coisa
--    à outra em tempo de execução, sem tabela de-para separada.
-- ============================================================================
INSERT INTO usuario (id_pessoa, login_usuario, papel_usuario)
SELECT p.id_pessoa, v.login, v.papel::papel_usuario_t
FROM (VALUES
  ('juliana.freitas@iesb.br', 'secretaria',  'secretaria'),
  ('gabriel.paz@iesb.br',     'bd2',         'admin'),        -- o DBA da disciplina
  ('marcos.tanaka@iesb.br',   'coordenacao', 'coordenacao')
) AS v(email, login, papel)
JOIN pessoa p ON p.email_pessoa = v.email;

-- ============================================================================
-- 6. CURSOS, CURRÍCULOS E DISCIPLINAS
-- ============================================================================
INSERT INTO curso (id_campus, id_departamento, codigo_curso, nome_curso, ch_total_curso, grau_curso, modalidade_curso)
SELECT c.id_campus, d.id_departamento, v.codigo, v.nome, v.ch,
       v.grau::grau_curso_t, v.modalidade::modalidade_t
FROM (VALUES
  ('CC',  'Ciência da Computação',                 3200, 'bacharelado', 'Asa Sul',   'DCC',  'presencial'),
  ('SI',  'Sistemas de Informação',                3000, 'bacharelado', 'Asa Sul',   'DCC',  'presencial'),
  ('ADS', 'Análise e Desenvolvimento de Sistemas', 2400, 'tecnologo',   'Asa Norte', 'DGES', 'hibrido')
) AS v(codigo, nome, ch, grau, campus, sigla, modalidade)
JOIN campus c       ON c.nome_campus = v.campus
JOIN departamento d ON d.sigla_departamento = v.sigla;

-- [E8] coordenação COM VIGÊNCIA: o EXCLUDE gist garante um coordenador por
-- curso a cada instante. O mandato encerrado de CC prova que o histórico cabe
-- na mesma tabela — o que uma coluna id_coordenador em curso não permitiria.
INSERT INTO coordenacao_curso (id_curso, id_professor, portaria_coordenacao_curso, vigencia_coordenacao_curso)
SELECT c.id_curso, pr.id_professor, v.portaria, v.vig
FROM (VALUES
  ('CC',  'P0004', 'PORT-2021-014', daterange(DATE '2021-01-01', DATE '2024-01-01', '[)')),
  ('CC',  'P0001', 'PORT-2024-003', daterange(DATE '2024-01-01', NULL, '[)')),
  ('SI',  'P0005', 'PORT-2023-021', daterange(DATE '2023-03-01', NULL, '[)')),
  ('ADS', 'P0010', 'PORT-2022-008', daterange(DATE '2022-08-01', NULL, '[)'))
) AS v(curso, prof, portaria, vig)
JOIN curso c     ON c.codigo_curso = v.curso
JOIN professor pr ON pr.matricula_professor = v.prof;

INSERT INTO curriculo (id_curso, portaria_curriculo, ano_vigencia_curriculo, ativo_curriculo)
SELECT c.id_curso, v.portaria, v.ano, v.ativo
FROM (VALUES
  ('CC',  'RES-2023-091', 2024, false),   -- matriz antiga (ingressantes 2024/2025)
  ('CC',  'RES-2025-112', 2026, true),    -- matriz vigente
  ('SI',  'RES-2024-077', 2025, true),
  ('ADS', 'RES-2024-078', 2025, true)
) AS v(curso, portaria, ano, ativo)
JOIN curso c ON c.codigo_curso = v.curso;

-- Catálogo de disciplinas — ch_total é coluna GERADA [C13], não se insere.
-- Cada disciplina agora tem DONO (departamento) [E6] e ementa.
INSERT INTO disciplina (id_departamento, codigo_disciplina, nome_disciplina, ementa_disciplina, ch_teorica_disciplina, ch_pratica_disciplina)
SELECT d.id_departamento, v.codigo, v.nome,
       'Ementa de ' || v.nome || '. Conteúdo programático detalhado no plano de ensino vigente.',
       v.teo, v.pra
FROM (VALUES
  ('DCC',  'ALG1',  'Algoritmos e Programação',             60, 30),
  ('DMAT', 'MAT1',  'Matemática Discreta',                  60,  0),
  ('DCC',  'ED1',   'Estruturas de Dados',                  60, 30),
  ('DCC',  'POO1',  'Programação Orientada a Objetos',      60, 30),
  ('DCC',  'LFA',   'Linguagens Formais e Autômatos',       60,  0),
  ('DCC',  'BD1',   'Banco de Dados I',                     60, 30),
  ('DCC',  'SO1',   'Sistemas Operacionais',                60, 30),
  ('DCC',  'IA1',   'Inteligência Artificial',              60, 30),
  ('DCC',  'BD2',   'Banco de Dados II',                    60, 30),
  ('DCC',  'ENG1',  'Engenharia de Software',               60,  0),
  ('DCC',  'COMP1', 'Compiladores',                         60, 30),
  ('DCC',  'TABD',  'Tópicos Avançados em Banco de Dados',  30, 30),
  ('DCC',  'LBD2',  'Laboratório de Banco de Dados',         0, 60),
  ('DCC',  'RED1',  'Redes de Computadores',                60, 30),
  ('DGES', 'ETI',   'Ética e Cidadania',                    30,  0),
  ('DGES', 'EMP',   'Empreendedorismo',                     30,  0),
  ('DGES', 'GPI',   'Gestão de Projetos de TI',             60,  0),
  ('DGES', 'SIG',   'Sistemas de Informação Gerenciais',    60,  0),
  ('DCC',  'WEB1',  'Desenvolvimento Web',                  30, 60),
  ('DMAT', 'EST1',  'Probabilidade e Estatística',          60,  0)
) AS v(sigla, codigo, nome, teo, pra)
JOIN departamento d ON d.sigla_departamento = v.sigla;

-- Cadeia de pré-requisitos (profundidade 4: TABD -> BD2 -> BD1 -> ED1 -> ALG1)
-- e um co-requisito (LBD2 acompanha BD2) — exercitados nas consultas 5 e 6.
INSERT INTO pre_requisito (id_disciplina, id_requisito, vinculo_pre_requisito)
SELECT d.id_disciplina, r.id_disciplina, v.vinculo::vinculo_t
FROM (VALUES
  ('ED1',   'ALG1', 'pre_requisito'),
  ('POO1',  'ALG1', 'pre_requisito'),
  ('LFA',   'MAT1', 'pre_requisito'),
  ('BD1',   'ED1',  'pre_requisito'),
  ('SO1',   'ED1',  'pre_requisito'),
  ('IA1',   'ED1',  'pre_requisito'),
  ('IA1',   'MAT1', 'pre_requisito'),
  ('BD2',   'BD1',  'pre_requisito'),
  ('ENG1',  'POO1', 'pre_requisito'),
  ('COMP1', 'LFA',  'pre_requisito'),
  ('COMP1', 'ED1',  'pre_requisito'),
  ('TABD',  'BD2',  'pre_requisito'),
  ('LBD2',  'BD2',  'co_requisito')
) AS v(disc, req, vinculo)
JOIN disciplina d ON d.codigo_disciplina = v.disc
JOIN disciplina r ON r.codigo_disciplina = v.req;

INSERT INTO curriculo_disciplina (id_curriculo, id_disciplina, periodo_curriculo_disciplina, tipo_curriculo_disciplina)
SELECT cu.id_curriculo, d.id_disciplina, v.periodo, v.tipo::tipo_disc_t
FROM (VALUES
  -- CC 2026 (vigente)
  ('CC', 2026, 'ALG1', 1, 'obrigatoria'), ('CC', 2026, 'MAT1', 1, 'obrigatoria'),
  ('CC', 2026, 'ETI',  1, 'obrigatoria'), ('CC', 2026, 'ED1',  2, 'obrigatoria'),
  ('CC', 2026, 'POO1', 2, 'obrigatoria'), ('CC', 2026, 'EST1', 2, 'obrigatoria'),
  ('CC', 2026, 'BD1',  3, 'obrigatoria'), ('CC', 2026, 'LFA',  3, 'obrigatoria'),
  ('CC', 2026, 'WEB1', 3, 'obrigatoria'), ('CC', 2026, 'BD2',  4, 'obrigatoria'),
  ('CC', 2026, 'SO1',  4, 'obrigatoria'), ('CC', 2026, 'ENG1', 4, 'obrigatoria'),
  ('CC', 2026, 'IA1',  5, 'obrigatoria'), ('CC', 2026, 'TABD', 5, 'optativa'),
  ('CC', 2026, 'LBD2', 5, 'optativa'),    ('CC', 2026, 'COMP1',6, 'obrigatoria'),
  ('CC', 2026, 'RED1', 6, 'obrigatoria'), ('CC', 2026, 'GPI',  6, 'eletiva'),
  -- CC 2024 (matriz antiga — sem TABD/LBD2)
  ('CC', 2024, 'ALG1', 1, 'obrigatoria'), ('CC', 2024, 'MAT1', 1, 'obrigatoria'),
  ('CC', 2024, 'ETI',  1, 'obrigatoria'), ('CC', 2024, 'ED1',  2, 'obrigatoria'),
  ('CC', 2024, 'POO1', 2, 'obrigatoria'), ('CC', 2024, 'EST1', 2, 'obrigatoria'),
  ('CC', 2024, 'BD1',  3, 'obrigatoria'), ('CC', 2024, 'LFA',  3, 'obrigatoria'),
  ('CC', 2024, 'EMP',  3, 'eletiva'),     ('CC', 2024, 'BD2',  4, 'obrigatoria'),
  ('CC', 2024, 'SO1',  4, 'obrigatoria'), ('CC', 2024, 'ENG1', 4, 'obrigatoria'),
  ('CC', 2024, 'IA1',  5, 'obrigatoria'), ('CC', 2024, 'COMP1',5, 'obrigatoria'),
  ('CC', 2024, 'RED1', 5, 'obrigatoria'), ('CC', 2024, 'WEB1', 6, 'obrigatoria'),
  ('CC', 2024, 'GPI',  6, 'obrigatoria'),
  -- SI 2025
  ('SI', 2025, 'ALG1', 1, 'obrigatoria'), ('SI', 2025, 'MAT1', 1, 'obrigatoria'),
  ('SI', 2025, 'SIG',  1, 'obrigatoria'), ('SI', 2025, 'POO1', 2, 'obrigatoria'),
  ('SI', 2025, 'EST1', 2, 'obrigatoria'), ('SI', 2025, 'EMP',  2, 'eletiva'),
  ('SI', 2025, 'BD1',  3, 'obrigatoria'), ('SI', 2025, 'WEB1', 3, 'obrigatoria'),
  ('SI', 2025, 'ENG1', 4, 'obrigatoria'), ('SI', 2025, 'GPI',  4, 'obrigatoria'),
  ('SI', 2025, 'BD2',  5, 'optativa'),    ('SI', 2025, 'ETI',  5, 'obrigatoria'),
  -- ADS 2025
  ('ADS', 2025, 'ALG1', 1, 'obrigatoria'), ('ADS', 2025, 'ETI',  1, 'obrigatoria'),
  ('ADS', 2025, 'POO1', 2, 'obrigatoria'), ('ADS', 2025, 'WEB1', 2, 'obrigatoria'),
  ('ADS', 2025, 'BD1',  3, 'obrigatoria'), ('ADS', 2025, 'RED1', 3, 'obrigatoria'),
  ('ADS', 2025, 'GPI',  4, 'obrigatoria'), ('ADS', 2025, 'EMP',  4, 'eletiva')
) AS v(curso, ano, disc, periodo, tipo)
JOIN curso c      ON c.codigo_curso = v.curso
JOIN curriculo cu ON cu.id_curso = c.id_curso AND cu.ano_vigencia_curriculo = v.ano
JOIN disciplina d ON d.codigo_disciplina = v.disc;

-- ============================================================================
-- 7. CALENDÁRIO  [E9] [E10]
-- ============================================================================
INSERT INTO periodo_letivo (ano_periodo_letivo, semestre_periodo_letivo, data_inicio_periodo_letivo, data_fim_periodo_letivo) VALUES
  (2025, 1, DATE '2025-02-03', DATE '2025-07-05'),
  (2025, 2, DATE '2025-08-04', DATE '2025-12-20'),
  (2026, 1, DATE '2026-02-02', DATE '2026-07-04'),
  (2026, 2, DATE '2026-08-03', DATE '2026-12-19');   -- período corrente

-- [E9] janelas de matrícula: o EXCLUDE gist impede duas janelas do MESMO tipo
-- se sobreporem no mesmo período. Tipos diferentes PODEM conviver — e convivem:
-- o ajuste começa antes de a matrícula terminar, de propósito.
INSERT INTO periodo_matricula (id_periodo_letivo, descricao_periodo_matricula, janela_periodo_matricula, tipo_periodo_matricula)
SELECT pl.id_periodo_letivo, v.descricao,
       tstzrange(
         (pl.data_inicio_periodo_letivo + v.ini)::timestamptz,
         (pl.data_inicio_periodo_letivo + v.fim)::timestamptz, '[)'),
       v.tipo::tipo_periodo_matricula_t
FROM periodo_letivo pl
CROSS JOIN (VALUES
  ('Matrícula regular',   -30, -10, 'matricula'),
  ('Rematrícula',         -45, -30, 'rematricula'),
  ('Ajuste de matrícula', -12,   7, 'ajuste'),
  ('Trancamento',          15,  60, 'trancamento')
) AS v(descricao, ini, fim, tipo);

-- [E10] feriado por ARCO EXCLUSIVO: exatamente uma das 4 FKs preenchida.
-- O "tipo" (nacional/estadual/…) NÃO é coluna: seria derivável do arco (3FN).
INSERT INTO feriado (id_pais, descricao_feriado, data_feriado, facultativo_feriado)
SELECT p.id_pais, v.descricao, v.data::date, v.facultativo
FROM (VALUES
  ('2026-09-07', 'Independência do Brasil',    false),
  ('2026-10-12', 'Nossa Senhora Aparecida',    false),
  ('2026-11-02', 'Finados',                    false),
  ('2026-11-15', 'Proclamação da República',   false),
  ('2026-11-20', 'Dia da Consciência Negra',   false),
  ('2025-09-07', 'Independência do Brasil',    false),
  ('2025-10-12', 'Nossa Senhora Aparecida',    false),
  ('2025-11-15', 'Proclamação da República',   false),
  ('2026-02-16', 'Carnaval',                   true),
  ('2026-04-03', 'Sexta-feira Santa',          false)
) AS v(data, descricao, facultativo), pais p;

INSERT INTO feriado (id_estado, descricao_feriado, data_feriado, facultativo_feriado)
SELECT e.id_estado, 'Dia do Evangélico (DF)', DATE '2026-11-30', false
FROM estado e WHERE e.uf_estado = 'DF';

INSERT INTO feriado (id_cidade, descricao_feriado, data_feriado, facultativo_feriado)
SELECT c.id_cidade, 'Aniversário de Brasília', DATE '2026-04-21', false
FROM cidade c WHERE c.nome_cidade = 'Brasília';

INSERT INTO feriado (id_campus, descricao_feriado, data_feriado, facultativo_feriado)
SELECT c.id_campus, 'Dia do Folclore — evento interno', DATE '2026-08-22', true
FROM campus c WHERE c.nome_campus = 'Asa Norte';

-- ============================================================================
-- 8. TURMAS, DOCÊNCIA E HORÁRIOS  [E11] [E12]
-- ============================================================================
INSERT INTO turma (id_disciplina, id_periodo_letivo, codigo_turma, vagas_turma, turno_turma, modalidade_turma)
SELECT d.id_disciplina, pl.id_periodo_letivo, v.codigo, v.vagas,
       v.turno::turno_t, v.modalidade::modalidade_t
FROM (VALUES
  -- 2025/1
  (2025, 1, 'ALG1',  'ALG1-N1',  'noturno',  50, 'presencial'),
  (2025, 1, 'MAT1',  'MAT1-N1',  'noturno',  50, 'presencial'),
  (2025, 1, 'ED1',   'ED1-N1',   'noturno',  40, 'presencial'),
  (2025, 1, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2025, 1, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2025, 1, 'ETI',   'ETI-M1',   'matutino', 60, 'presencial'),
  -- 2025/2
  (2025, 2, 'ED1',   'ED1-N1',   'noturno',  40, 'presencial'),
  (2025, 2, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2025, 2, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2025, 2, 'SO1',   'SO1-N1',   'noturno',  35, 'presencial'),
  (2025, 2, 'LFA',   'LFA-N1',   'noturno',  35, 'presencial'),
  (2025, 2, 'EST1',  'EST1-M1',  'matutino', 45, 'presencial'),
  (2025, 2, 'EMP',   'EMP-M1',   'matutino', 60, 'presencial'),
  -- 2026/1
  (2026, 1, 'BD1',   'BD1-N1',   'noturno',  40, 'presencial'),
  (2026, 1, 'BD2',   'BD2-N1',   'noturno',  35, 'presencial'),
  (2026, 1, 'ENG1',  'ENG1-N1',  'noturno',  40, 'presencial'),
  (2026, 1, 'SO1',   'SO1-N1',   'noturno',  35, 'presencial'),
  (2026, 1, 'IA1',   'IA1-N1',   'noturno',  30, 'presencial'),
  (2026, 1, 'RED1',  'RED1-N1',  'noturno',  35, 'presencial'),
  (2026, 1, 'WEB1',  'WEB1-M1',  'matutino', 30, 'presencial'),
  -- 2026/2 (período corrente — a "grade viva")
  (2026, 2, 'ALG1',  'ALG1-M1',  'matutino', 45, 'presencial'),
  (2026, 2, 'ALG1',  'ALG1-N1',  'noturno',  50, 'presencial'),
  (2026, 2, 'ED1',   'ED1-M1',   'matutino', 40, 'presencial'),
  (2026, 2, 'POO1',  'POO1-N1',  'noturno',  40, 'presencial'),
  (2026, 2, 'BD1',   'BD1-M1',   'matutino', 35, 'presencial'),
  (2026, 2, 'BD1',   'BD1-N1',   'noturno',  35, 'presencial'),
  (2026, 2, 'BD2',   'BD2-N1',   'noturno',  30, 'presencial'),
  (2026, 2, 'ENG1',  'ENG1-N1',  'noturno',  40, 'presencial'),
  (2026, 2, 'IA1',   'IA1-N1',   'noturno',  30, 'presencial'),
  (2026, 2, 'LFA',   'LFA-M1',   'matutino', 35, 'presencial'),
  (2026, 2, 'TABD',  'TABD-N1',  'noturno',   8, 'presencial'),  -- disputa da última vaga (Marco 2)
  (2026, 2, 'COMP1', 'COMP1-N1', 'noturno',  25, 'presencial'),  -- ficará SEM matrículas (consulta 3)
  (2026, 2, 'LBD2',  'LBD2-N1',  'noturno',  20, 'ead'),         -- EAD: sem sala [E12]
  (2026, 2, 'WEB1',  'WEB1-M1',  'matutino', 30, 'presencial')
) AS v(ano, sem, disc, codigo, turno, vagas, modalidade)
JOIN periodo_letivo pl ON pl.ano_periodo_letivo = v.ano AND pl.semestre_periodo_letivo = v.sem
JOIN disciplina d      ON d.codigo_disciplina = v.disc;

-- [E11] co-docência: o titular (um só por turma, garantido por índice parcial
-- único) e, nas turmas com prática, um auxiliar. Era uma coluna id_professor
-- em turma; virou tabela porque a realidade tem mais de um docente.
INSERT INTO turma_professor (id_turma, id_professor, ch_turma_professor, papel_turma_professor)
SELECT t.id_turma, pr.id_professor, d.ch_total_disciplina, 'titular'
FROM turma t
JOIN disciplina d ON d.id_disciplina = t.id_disciplina
JOIN professor pr ON pr.matricula_professor = (CASE d.codigo_disciplina
        WHEN 'ALG1'  THEN 'P0001' WHEN 'MAT1'  THEN 'P0002' WHEN 'ED1'   THEN 'P0003'
        WHEN 'POO1'  THEN 'P0004' WHEN 'BD1'   THEN 'P0005' WHEN 'ETI'   THEN 'P0006'
        WHEN 'SO1'   THEN 'P0007' WHEN 'LFA'   THEN 'P0008' WHEN 'EST1'  THEN 'P0002'
        WHEN 'EMP'   THEN 'P0006' WHEN 'BD2'   THEN 'P0001' WHEN 'ENG1'  THEN 'P0004'
        WHEN 'IA1'   THEN 'P0009' WHEN 'RED1'  THEN 'P0010' WHEN 'WEB1'  THEN 'P0003'
        WHEN 'TABD'  THEN 'P0001' WHEN 'COMP1' THEN 'P0010' WHEN 'LBD2'  THEN 'P0005'
        WHEN 'GPI'   THEN 'P0010' ELSE 'P0009' END);

-- auxiliar nas turmas com carga prática (o laboratório precisa de dois)
INSERT INTO turma_professor (id_turma, id_professor, ch_turma_professor, papel_turma_professor)
SELECT t.id_turma, pr.id_professor, d.ch_pratica_disciplina, 'auxiliar'
FROM turma t
JOIN disciplina d ON d.id_disciplina = t.id_disciplina AND d.ch_pratica_disciplina >= 30
JOIN LATERAL (
  SELECT p2.id_professor FROM professor p2
  WHERE p2.id_professor <> (SELECT tp.id_professor FROM turma_professor tp
                            WHERE tp.id_turma = t.id_turma AND tp.papel_turma_professor = 'titular')
  ORDER BY (p2.id_professor + t.id_turma) % 10, p2.id_professor
  LIMIT 1
) pr ON true
WHERE t.id_turma % 2 = 0;

-- ----------------------------------------------------------------------------
-- Horários: 2 encontros semanais por turma, gerados deterministicamente.
-- Combinações (par de dias × faixa) e sala rotacionada por rn garantem que a
-- restrição de exclusão [C10] passe. Faixas: matutino 08:00/10:00, noturno
-- 19:00/20:50 — duração 1h40.
-- [E12] turma EAD entra com id_sala NULL: o EXCLUDE de sala é PARCIAL
-- (WHERE id_sala IS NOT NULL), então dois horários EAD convivem sem choque.
-- ----------------------------------------------------------------------------
WITH t AS (
  SELECT tu.id_turma, tu.id_periodo_letivo, tu.turno_turma, tu.modalidade_turma,
         row_number() OVER (PARTITION BY tu.id_periodo_letivo, tu.turno_turma
                            ORDER BY tu.codigo_turma) - 1 AS rn
  FROM turma tu
), s AS (
  SELECT id_sala, row_number() OVER (ORDER BY id_sala) - 1 AS sn FROM sala
)
INSERT INTO turma_horario (id_turma, id_periodo_letivo, id_sala, dia_semana_turma_horario, faixa_turma_horario, tipo_aula_turma_horario)
SELECT t.id_turma, t.id_periodo_letivo,
       CASE WHEN t.modalidade_turma = 'ead' THEN NULL ELSE s.id_sala END,
       d.dia,
       CASE
         WHEN t.turno_turma = 'matutino' AND (t.rn / 2) % 2 = 0 THEN timerange(TIME '08:00', TIME '09:40')
         WHEN t.turno_turma = 'matutino'                        THEN timerange(TIME '10:00', TIME '11:40')
         WHEN (t.rn / 2) % 2 = 0                                THEN timerange(TIME '19:00', TIME '20:40')
         ELSE                                                        timerange(TIME '20:50', TIME '22:30')
       END AS faixa,
       CASE WHEN d.ord = 2 AND dd.ch_pratica_disciplina > 0 THEN 'pratica' ELSE 'teorica' END::tipo_aula_t
FROM t
JOIN turma tu     ON tu.id_turma = t.id_turma
JOIN disciplina dd ON dd.id_disciplina = tu.id_disciplina
JOIN s ON s.sn = t.rn % 9                                   -- 9 salas cadastradas
CROSS JOIN LATERAL (VALUES
  (1, CASE WHEN t.rn % 2 = 0 THEN 1 ELSE 2 END),            -- seg ou ter
  (2, CASE WHEN t.rn % 2 = 0 THEN 3 ELSE 4 END)             -- qua ou qui
) AS d(ord, dia);

-- ============================================================================
-- 9. PLANOS DE ENSINO  [E7]
--    O plano PERTENCE À DISCIPLINA (id_turma NULL = plano base). Uma turma
--    pode ter a SUA versão — e a FK composta garante que a versão só existe
--    para uma turma DAQUELA disciplina. UNIQUE NULLS NOT DISTINCT impede um
--    segundo plano base [técnica de C9].
-- ============================================================================
INSERT INTO plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino, metodologia_plano_ensino, criterio_avaliacao_plano_ensino, aprovacao_plano_ensino)
SELECT d.id_disciplina, NULL,
       'Capacitar o estudante em ' || d.nome_disciplina || ', articulando teoria e prática.',
       CASE WHEN d.ch_pratica_disciplina > 0
            THEN 'Aulas expositivas dialogadas, laboratório e projeto integrador.'
            ELSE 'Aulas expositivas dialogadas, estudos dirigidos e seminários.' END,
       'Duas avaliações (A1 peso 4, A2 peso 6) e prova substitutiva conforme regimento.',
       DATE '2025-01-15'
FROM disciplina d;

-- Versão de turma para as ofertas de 2026/2 de BD2 e TABD: é o caso que
-- justifica id_turma na tabela — o mesmo plano base, adaptado à oferta.
INSERT INTO plano_ensino (id_disciplina, id_turma, objetivo_plano_ensino, metodologia_plano_ensino, criterio_avaliacao_plano_ensino, aprovacao_plano_ensino)
SELECT t.id_disciplina, t.id_turma,
       'Versão 2026/2 do plano de ' || d.nome_disciplina || ': ênfase em PostgreSQL 17.',
       'Aulas expositivas, laboratório com contêiner Docker e projeto em dupla.',
       'A1 (peso 4) sobre modelagem; A2 (peso 6) sobre implementação; substitutiva conforme regimento.',
       DATE '2026-07-20'
FROM turma t
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
WHERE pl.ano_periodo_letivo = 2026 AND pl.semestre_periodo_letivo = 2
  AND d.codigo_disciplina IN ('BD2', 'TABD');

-- Unidades do plano base: 4 por disciplina, somando a CH total da disciplina.
INSERT INTO unidade_plano_ensino (id_plano_ensino, titulo_unidade_plano_ensino, conteudo_unidade_plano_ensino, ordem_unidade_plano_ensino, ch_unidade_plano_ensino)
SELECT pe.id_plano_ensino,
       'Unidade ' || u.ord || ' — ' || d.codigo_disciplina,
       'Conteúdo da unidade ' || u.ord || ' de ' || d.nome_disciplina || '.',
       u.ord,
       (d.ch_total_disciplina / 4) + CASE WHEN u.ord <= d.ch_total_disciplina % 4 THEN 1 ELSE 0 END
FROM plano_ensino pe
JOIN disciplina d ON d.id_disciplina = pe.id_disciplina
CROSS JOIN generate_series(1, 4) AS u(ord)
WHERE pe.id_turma IS NULL;

INSERT INTO bibliografia (titulo_bibliografia, autor_bibliografia, editora_bibliografia, isbn_bibliografia, ano_bibliografia, edicao_bibliografia) VALUES
  ('Sistemas de Banco de Dados',            'Elmasri, R.; Navathe, S.', 'Pearson',       '9788579361852', 2011, 6),
  ('Sistema de Banco de Dados',             'Silberschatz, A.',         'Elsevier',      '9788535245356', 2012, 6),
  ('Projeto de Banco de Dados',             'Heuser, C. A.',            'Bookman',       '9788577803828', 2009, 6),
  ('Introdução a Sistemas de Bancos de Dados','Date, C. J.',            'Campus',        '9788535212730', 2004, 8),
  ('PostgreSQL: Guia do Programador',       'Milani, A.',               'Novatec',       '9788575221365', 2008, 1),
  ('Algoritmos: Teoria e Prática',          'Cormen, T. H.',            'GEN LTC',       '9788535236996', 2012, 3),
  ('Estruturas de Dados e Algoritmos em Java','Goodrich, M. T.',        'Bookman',       '9788577805006', 2013, 5),
  ('Engenharia de Software',                'Sommerville, I.',          'Pearson',       '9788543024974', 2018, 10),
  ('Redes de Computadores',                 'Tanenbaum, A. S.',         'Pearson',       '9788543020563', 2021, 6),
  ('Inteligência Artificial',               'Russell, S.; Norvig, P.',  'GEN LTC',       '9788535251418', 2013, 3),
  ('Fundamentos de Matemática Discreta',    'Gersting, J. L.',          'GEN LTC',       '9788521633334', 2016, 7),
  ('Estatística Básica',                    'Bussab, W. O.; Morettin, P.','Saraiva',     '9788502207998', 2013, 8);

-- Bibliografia por plano: uma básica e uma complementar, escolhidas de forma
-- determinística — a chave (plano, bibliografia) impede repetir o mesmo título.
INSERT INTO plano_ensino_bibliografia (id_plano_ensino, id_bibliografia, tipo_plano_ensino_bibliografia)
SELECT pe.id_plano_ensino, b.id_bibliografia, v.tipo::tipo_bibliografia_t
FROM plano_ensino pe
CROSS JOIN (VALUES ('basica', 0), ('complementar', 5)) AS v(tipo, deslo)
JOIN LATERAL (
  SELECT id_bibliografia FROM bibliografia
  ORDER BY ((id_bibliografia + pe.id_plano_ensino + v.deslo) % 12), id_bibliografia
  LIMIT 1
) b ON true
WHERE pe.id_turma IS NULL
ON CONFLICT (id_plano_ensino, id_bibliografia) DO NOTHING;

-- ============================================================================
-- 10. DISCENTES  [E2]
--     120 alunos, cada um apontando para a pessoa já criada. O currículo é
--     coerente com o curso — a FK composta [C6] exige.
-- ============================================================================
INSERT INTO aluno (id_pessoa, id_curso, id_curriculo, matricula_aluno, ingresso_aluno, forma_ingresso_aluno, status_aluno)
SELECT p.id_pessoa, c.id_curso, cu.id_curriculo,
       (b.ano_ing * 10000 + b.i)::text,
       make_date(b.ano_ing, 2, 1),
       (ARRAY['vestibular','enem','transferencia','portador_diploma'])[1 + b.i % 4]::forma_ingresso_t,
       CASE WHEN b.i % 17 = 0 THEN 'trancado' ELSE 'ativo' END::status_aluno_t
FROM (
  SELECT g.i,
         CASE WHEN g.i % 10 < 6 THEN 'CC'
              WHEN g.i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2024 + (g.i % 3)     AS ano_ing,
         -- o e-mail é a chave natural que liga o aluno i à pessoa criada no
         -- passo 2: a MESMA expressão, para não depender de ordem de id
         lower(n.pn[1 + (g.i * 7) % 20] || '.' || n.sn[1 + (g.i * 13) % 15]) || g.i || '@aluno.iesb.br' AS email
  FROM generate_series(1, 120) AS g(i),
       (SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
                     'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
                     'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
               ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
                     'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
                     'Gomes','Martins']                                AS sn) n
) b
JOIN pessoa p ON p.email_pessoa = b.email
JOIN curso c  ON c.codigo_curso = b.curso_cod
JOIN curriculo cu
  ON cu.id_curso = c.id_curso
 AND cu.ano_vigencia_curriculo = CASE
       WHEN b.curso_cod = 'CC' AND b.ano_ing >= 2026 THEN 2026
       WHEN b.curso_cod = 'CC'                       THEN 2024
       ELSE 2025 END;

-- Um usuário por aluno [E4]: login = 'al_' || RA, o mesmo nome que o
-- 08_seguranca.sql dá à ROLE. É essa igualdade que a RLS usa.
INSERT INTO usuario (id_pessoa, login_usuario, ativo_usuario, papel_usuario)
SELECT a.id_pessoa, 'al_' || a.matricula_aluno, (a.status_aluno = 'ativo'), 'aluno'
FROM aluno a;

-- ============================================================================
-- 11. MATRÍCULAS
--     Elegibilidade realista: o aluno só se matricula em turma cuja disciplina
--     pertence ao SEU currículo e cujo período começa depois do seu ingresso.
--     Seleção determinística por hash; no máximo 1 turma por disciplina/período
--     por aluno; lotação alvo ~75% das vagas (máx. 28 por turma).
-- ============================================================================
WITH pool AS (
  SELECT tu.id_turma AS id_turma, tu.codigo_turma, tu.vagas_turma, tu.id_periodo_letivo,
         tu.id_disciplina, a.id_aluno AS id_aluno, pl.data_inicio_periodo_letivo,
         (a.id_aluno * 31 + tu.id_turma * 17) % 997 AS h
  FROM turma tu
  JOIN periodo_letivo pl       ON pl.id_periodo_letivo = tu.id_periodo_letivo
  JOIN curriculo_disciplina cd ON cd.id_disciplina = tu.id_disciplina
  JOIN aluno a                 ON a.id_curriculo = cd.id_curriculo
                              AND a.status_aluno = 'ativo'
                              AND a.ingresso_aluno <= pl.data_inicio_periodo_letivo
  WHERE tu.codigo_turma <> 'COMP1-N1'          -- deixada vazia de propósito (consulta 3)
),
sem_duplicata AS (                       -- 1 turma por (aluno, período, disciplina)
  SELECT *,
         row_number() OVER (PARTITION BY id_aluno, id_periodo_letivo, id_disciplina
                            ORDER BY h, id_turma) AS r1
  FROM pool
),
ranqueado AS (
  SELECT *,
         row_number() OVER (PARTITION BY id_turma ORDER BY h, id_aluno) AS rk
  FROM sem_duplicata
  WHERE r1 = 1
)
INSERT INTO matricula (id_aluno, id_turma, data_matricula, status_matricula)
SELECT r.id_aluno,
       r.id_turma,
       (r.data_inicio_periodo_letivo - 10)::timestamptz + make_interval(hours => (r.rk * 3)::int),
       CASE
         WHEN r.codigo_turma = 'TABD-N1' THEN 'confirmada'    -- cenário da última vaga
         WHEN r.rk % 17 = 0        THEN 'cancelada'
         WHEN r.rk % 13 = 0        THEN 'trancada'
         ELSE 'confirmada'
       END::status_mat_t
FROM ranqueado r
WHERE r.rk <= CASE WHEN r.codigo_turma = 'TABD-N1'
                   THEN 7                               -- 7 de 8 vagas: sobra 1
                   ELSE LEAST((r.vagas_turma * 3) / 4, 28) END;

-- ============================================================================
-- 12. AVALIAÇÕES E NOTAS  [E14]
--     Onde antes havia nota_a1/nota_a2/nota_p3 em historico (colunas fixas,
--     violação de 1FN disfarçada), agora há avaliacao × nota. Pesos das
--     avaliações REGULARES somam 10; a substitutiva não entra na soma —
--     ela SUBSTITUI a de menor nota, que é a regra da P3 do modelo original.
-- ============================================================================
INSERT INTO avaliacao (id_turma, nome_avaliacao, peso_avaliacao, data_avaliacao, substitutiva_avaliacao)
SELECT t.id_turma, v.nome, v.peso,
       pl.data_inicio_periodo_letivo + v.dia, v.subst
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
CROSS JOIN (VALUES
  ('A1', 4.00,  60, false),
  ('A2', 6.00, 120, false),
  ('P3', 6.00, 135, true)
) AS v(nome, peso, dia, subst);

-- Notas: só para períodos ENCERRADOS (< 2026/2) e matrículas confirmadas.
-- As fórmulas são as mesmas da carga anterior — a média continua reproduzível.
INSERT INTO nota (id_avaliacao, id_matricula, id_turma, valor_nota)
SELECT av.id_avaliacao, m.id_matricula, m.id_turma,
       CASE av.nome_avaliacao
         WHEN 'A1' THEN round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
         WHEN 'A2' THEN round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)
         ELSE           round((4   + ((m.id_aluno * 41 + m.id_turma * 7)  % 56) / 10.0)::numeric, 1)
       END
FROM matricula m
JOIN turma tu          ON tu.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2)
JOIN avaliacao av      ON av.id_turma = m.id_turma
WHERE m.status_matricula = 'confirmada'
  AND (
    NOT av.substitutiva_avaliacao                       -- A1 e A2 para todos
    OR (                                                -- P3 só para quem precisa
      (0.4 * round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
     + 0.6 * round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)) < 5
      AND m.id_aluno % 3 <> 0
    )
  );

-- ============================================================================
-- 13. AULAS E PRESENÇAS  [E13]
--     A frequência deixou de ser um número digitado: ela EMERGE das presenças.
--     Aula pula feriado — a regra que o modelo do professor não conseguia
--     expressar porque não tinha aula nenhuma.
-- ============================================================================
INSERT INTO aula (id_turma_horario, id_unidade_plano_ensino, id_turma, conteudo_aula, data_aula, realizada_aula)
SELECT th.id_turma_horario, u.id_unidade_plano_ensino, th.id_turma,
       'Encontro ' || dt.n || ' — ' || d.codigo_disciplina,
       dt.data, true
FROM turma_horario th
JOIN turma t           ON t.id_turma = th.id_turma
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN periodo_letivo pl ON pl.id_periodo_letivo = th.id_periodo_letivo
CROSS JOIN LATERAL (
  -- 18 semanas a partir do primeiro dia da semana pedido pelo horário
  SELECT row_number() OVER (ORDER BY g.d) AS n, g.d AS data
  FROM generate_series(
         pl.data_inicio_periodo_letivo
           + ((th.dia_semana_turma_horario - EXTRACT(ISODOW FROM pl.data_inicio_periodo_letivo)::int + 7) % 7),
         pl.data_fim_periodo_letivo, interval '7 days') AS g(d)
  LIMIT 18
) dt
LEFT JOIN LATERAL (                                  -- distribui as 4 unidades
  SELECT ue.id_unidade_plano_ensino
  FROM plano_ensino pe
  JOIN unidade_plano_ensino ue ON ue.id_plano_ensino = pe.id_plano_ensino
  WHERE pe.id_disciplina = t.id_disciplina AND pe.id_turma IS NULL
    AND ue.ordem_unidade_plano_ensino = LEAST(4, 1 + ((dt.n - 1) / 5))
  LIMIT 1
) u ON true
WHERE NOT EXISTS (                                   -- não há aula em feriado
  SELECT 1 FROM feriado f
  WHERE f.data_feriado = dt.data AND NOT f.facultativo_feriado
);

-- Presenças: toda matrícula confirmada em toda aula da sua turma.
-- A falta é determinística e é ela que produz a frequência. Dois regimes de
-- propósito: a maioria falta ~5% (aprova por frequência) e um em cada 11
-- alunos falta ~33% — abaixo dos 75% exigidos. É esse grupo que faz existir
-- a situação 'reprovado_frequencia', usada pelas consultas 4 e 10.
INSERT INTO presenca (id_aula, id_matricula, id_turma, presente_presenca, justificada_presenca)
SELECT a.id_aula, m.id_matricula, m.id_turma,
       CASE WHEN m.id_aluno % 11 = 0
            THEN ((m.id_aluno * 7 + a.id_aula * 3) % 3)  <> 0
            ELSE ((m.id_aluno * 7 + a.id_aula * 3) % 20) <> 0 END,
       CASE WHEN m.id_aluno % 11 = 0
            THEN ((m.id_aluno * 7 + a.id_aula * 3) % 3)  = 0 AND (m.id_aluno % 4 = 0)
            ELSE ((m.id_aluno * 7 + a.id_aula * 3) % 20) = 0 AND (m.id_aluno % 4 = 0) END
FROM aula a
JOIN matricula m       ON m.id_turma = a.id_turma AND m.status_matricula = 'confirmada'
JOIN turma t           ON t.id_turma = a.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2);

-- ============================================================================
-- 14. HISTÓRICO CONSOLIDADO  [E14]
--     historico não guarda mais nota nem frequência: guarda a SITUAÇÃO e a
--     data de fechamento. Média e frequência são derivadas de nota/presenca —
--     é esse o custo assumido da ampliação, e a MV do 04_views.sql é a
--     resposta a ele.
-- ============================================================================
INSERT INTO historico (id_matricula, data_fechamento_historico, situacao_historico)
SELECT m.id_matricula,
       CASE WHEN x.encerrado THEN pl.data_fim_periodo_letivo END,
       CASE
         WHEN m.status_matricula = 'trancada' THEN 'trancado'
         WHEN NOT x.encerrado                 THEN 'cursando'
         WHEN x.freq < 75                     THEN 'reprovado_frequencia'
         WHEN x.media >= 5                    THEN 'aprovado'
         ELSE 'reprovado_nota'
       END::situacao_t
FROM matricula m
JOIN turma tu          ON tu.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo
-- média e frequência vêm da MESMA view que as consultas usam
-- (v_desempenho_matricula, criada no 01_ddl.sql [E14]): a regra da
-- substitutiva não pode divergir entre a carga e o relatório.
LEFT JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula
CROSS JOIN LATERAL (
  SELECT (pl.ano_periodo_letivo, pl.semestre_periodo_letivo) < (2026, 2) AS encerrado,
         dm.media_final AS media,
         dm.frequencia  AS freq
) AS x
WHERE m.status_matricula <> 'cancelada';

-- ============================================================================
-- 15. APROVEITAMENTO DE MATÉRIA  [E15]
--     Dispensa por estudo anterior: entra como 2ª via de "pode cursar".
--     Um caso de cada status, para as consultas terem o que mostrar.
-- ============================================================================
INSERT INTO aproveitamento_materia (id_aluno, id_disciplina, id_usuario_avaliador,
       disciplina_origem_aproveitamento_materia, instituicao_origem_aproveitamento_materia,
       parecer_aproveitamento_materia, ch_origem_aproveitamento_materia,
       nota_origem_aproveitamento_materia, solicitacao_aproveitamento_materia,
       decisao_aproveitamento_materia, status_aproveitamento_materia)
SELECT a.id_aluno, d.id_disciplina, u.id_usuario,
       'Introdução à ' || d.nome_disciplina,
       (ARRAY['UnB','UFG','IFB','UCB','Unip'])[1 + a.id_aluno % 5],
       CASE v.status
         WHEN 'deferido'   THEN 'Ementa e carga horária compatíveis (>= 75%). Deferido.'
         WHEN 'indeferido' THEN 'Carga horária insuficiente frente à disciplina de destino.'
         ELSE NULL END,
       CASE v.status WHEN 'indeferido' THEN 30 ELSE d.ch_total_disciplina END,
       CASE v.status WHEN 'indeferido' THEN 6.0 ELSE 8.5 END,
       DATE '2026-01-20',
       CASE WHEN v.status = 'pendente' THEN NULL ELSE DATE '2026-02-10' END,
       v.status::status_aproveitamento_t
FROM (VALUES
  ('ETI',  'deferido',   1), ('EMP',  'deferido',   2), ('MAT1', 'deferido',   3),
  ('SIG',  'indeferido', 4), ('EST1', 'indeferido', 5),
  ('WEB1', 'pendente',   6), ('GPI',  'pendente',   7), ('ALG1', 'pendente',   8)
) AS v(disc, status, ord)
JOIN disciplina d ON d.codigo_disciplina = v.disc
JOIN LATERAL (
  SELECT id_aluno FROM aluno WHERE status_aluno = 'ativo'
  ORDER BY (id_aluno * 13 + v.ord) % 97, id_aluno LIMIT 1
) a ON true
LEFT JOIN usuario u ON u.login_usuario = 'secretaria'
ON CONFLICT (id_aluno, id_disciplina) DO NOTHING;

-- ============================================================================
-- 16. AUDITORIA  [C11] [E4]
--     acao_log_t é DML ('insert'/'update'/'delete'): o QUE aconteceu com a
--     LINHA. O evento de negócio ("matrícula criada", "status alterado") vai
--     no jsonb — que é justamente o que o índice GIN do 06_indices.sql explora.
--     id_usuario tem DEFAULT f_usuario_sessao(); aqui é passado explicitamente
--     porque a carga fala em nome do administrador.
-- ============================================================================
INSERT INTO log_matricula (id_matricula, id_usuario, ocorrido_em_log_matricula, acao_log_matricula, detalhe_log_matricula)
SELECT m.id_matricula, u.id_usuario, m.data_matricula, 'insert',
       jsonb_build_object('evento', 'matricula_criada', 'turma', tu.codigo_turma,
                          'origem', 'carga_inicial', 'status_inicial', 'confirmada')
FROM matricula m
JOIN turma tu ON tu.id_turma = m.id_turma
LEFT JOIN usuario u ON u.login_usuario = 'bd2';

INSERT INTO log_matricula (id_matricula, id_usuario, ocorrido_em_log_matricula, acao_log_matricula, detalhe_log_matricula)
SELECT m.id_matricula, u.id_usuario, m.data_matricula + interval '5 days', 'update',
       jsonb_build_object('evento', 'status_alterado', 'turma', tu.codigo_turma,
                          'origem', 'carga_inicial',
                          'de', 'confirmada', 'para', m.status_matricula::text)
FROM matricula m
JOIN turma tu ON tu.id_turma = m.id_turma
LEFT JOIN usuario u ON u.login_usuario = 'bd2'
WHERE m.status_matricula IN ('trancada', 'cancelada');

COMMIT;

-- ============================================================================
-- Verificação: falha ruidosamente se os mínimos do enunciado não forem atingidos
-- ou se um dos cenários plantados tiver sido corrompido.
-- ============================================================================
DO $$
DECLARE
  n_alunos int; n_turmas int; n_matriculas int; n_vagas_tabd int;
  n_notas int; n_presencas int; n_aulas int; n_comp1 int; n_ead int;
BEGIN
  SELECT count(*) INTO n_alunos     FROM aluno;
  SELECT count(*) INTO n_turmas     FROM turma;
  SELECT count(*) INTO n_matriculas FROM matricula;
  SELECT count(*) INTO n_notas      FROM nota;
  SELECT count(*) INTO n_presencas  FROM presenca;
  SELECT count(*) INTO n_aulas      FROM aula;
  SELECT t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')
    INTO n_vagas_tabd
  FROM turma t LEFT JOIN matricula m ON m.id_turma = t.id_turma
  WHERE t.codigo_turma = 'TABD-N1' GROUP BY t.vagas_turma;
  SELECT count(*) INTO n_comp1 FROM matricula m JOIN turma t ON t.id_turma = m.id_turma
   WHERE t.codigo_turma = 'COMP1-N1';
  SELECT count(*) INTO n_ead FROM turma_horario th JOIN turma t ON t.id_turma = th.id_turma
   WHERE t.codigo_turma = 'LBD2-N1' AND th.id_sala IS NULL;

  IF n_alunos     < 100 THEN RAISE EXCEPTION 'Carga insuficiente: % alunos (mínimo 100)', n_alunos; END IF;
  IF n_turmas     < 6   THEN RAISE EXCEPTION 'Carga insuficiente: % turmas (mínimo 6)', n_turmas; END IF;
  IF n_matriculas < 300 THEN RAISE EXCEPTION 'Carga insuficiente: % matrículas (mínimo 300)', n_matriculas; END IF;
  IF n_vagas_tabd <> 1  THEN RAISE EXCEPTION 'Cenário da última vaga quebrado: TABD-N1 com % vagas livres (esperado 1)', n_vagas_tabd; END IF;
  IF n_comp1 <> 0       THEN RAISE EXCEPTION 'Cenário da junção externa quebrado: COMP1-N1 tem % matrículas (esperado 0)', n_comp1; END IF;
  IF n_ead   <  1       THEN RAISE EXCEPTION 'Cenário EAD quebrado: LBD2-N1 sem horário de sala NULL'; END IF;
  IF n_notas      < 500 THEN RAISE EXCEPTION 'Poucas notas: %', n_notas; END IF;
  IF NOT EXISTS (SELECT 1 FROM historico WHERE situacao_historico = 'reprovado_frequencia')
    THEN RAISE EXCEPTION 'Cenário de frequência quebrado: ninguém reprovou por falta'; END IF;
  IF n_presencas  < 5000 THEN RAISE EXCEPTION 'Poucas presenças: %', n_presencas; END IF;

  RAISE NOTICE 'Carga OK: % alunos, % turmas, % matrículas, % aulas, % presenças, % notas.',
    n_alunos, n_turmas, n_matriculas, n_aulas, n_presencas, n_notas;
  RAISE NOTICE 'Cenários intactos: TABD-N1 com 1 vaga livre, COMP1-N1 vazia, LBD2-N1 EAD sem sala.';
END $$;

\echo '=== Resumo da carga (41 tabelas) ==='
SELECT 'pais' AS tabela, count(*) FROM pais                          UNION ALL
SELECT 'estado',            count(*) FROM estado                     UNION ALL
SELECT 'cidade',            count(*) FROM cidade                     UNION ALL
SELECT 'endereco',          count(*) FROM endereco                   UNION ALL
SELECT 'pessoa',            count(*) FROM pessoa                     UNION ALL
SELECT 'telefone',          count(*) FROM telefone                   UNION ALL
SELECT 'documento_pessoa',  count(*) FROM documento_pessoa           UNION ALL
SELECT 'usuario',           count(*) FROM usuario                    UNION ALL
SELECT 'campus',            count(*) FROM campus                     UNION ALL
SELECT 'departamento',      count(*) FROM departamento               UNION ALL
SELECT 'predio',            count(*) FROM predio                     UNION ALL
SELECT 'sala',              count(*) FROM sala                       UNION ALL
SELECT 'recurso',           count(*) FROM recurso                    UNION ALL
SELECT 'sala_recurso',      count(*) FROM sala_recurso               UNION ALL
SELECT 'professor',         count(*) FROM professor                  UNION ALL
SELECT 'formacao_professor',count(*) FROM formacao_professor         UNION ALL
SELECT 'curso',             count(*) FROM curso                      UNION ALL
SELECT 'coordenacao_curso', count(*) FROM coordenacao_curso          UNION ALL
SELECT 'curriculo',         count(*) FROM curriculo                  UNION ALL
SELECT 'disciplina',        count(*) FROM disciplina                 UNION ALL
SELECT 'curriculo_disciplina', count(*) FROM curriculo_disciplina    UNION ALL
SELECT 'pre_requisito',     count(*) FROM pre_requisito              UNION ALL
SELECT 'aluno',             count(*) FROM aluno                      UNION ALL
SELECT 'aproveitamento_materia', count(*) FROM aproveitamento_materia UNION ALL
SELECT 'periodo_letivo',    count(*) FROM periodo_letivo             UNION ALL
SELECT 'periodo_matricula', count(*) FROM periodo_matricula          UNION ALL
SELECT 'feriado',           count(*) FROM feriado                    UNION ALL
SELECT 'turma',             count(*) FROM turma                      UNION ALL
SELECT 'turma_professor',   count(*) FROM turma_professor            UNION ALL
SELECT 'turma_horario',     count(*) FROM turma_horario              UNION ALL
SELECT 'plano_ensino',      count(*) FROM plano_ensino               UNION ALL
SELECT 'unidade_plano_ensino', count(*) FROM unidade_plano_ensino    UNION ALL
SELECT 'bibliografia',      count(*) FROM bibliografia               UNION ALL
SELECT 'plano_ensino_bibliografia', count(*) FROM plano_ensino_bibliografia UNION ALL
SELECT 'matricula',         count(*) FROM matricula                  UNION ALL
SELECT 'historico',         count(*) FROM historico                  UNION ALL
SELECT 'log_matricula',     count(*) FROM log_matricula              UNION ALL
SELECT 'aula',              count(*) FROM aula                       UNION ALL
SELECT 'presenca',          count(*) FROM presenca                   UNION ALL
SELECT 'avaliacao',         count(*) FROM avaliacao                  UNION ALL
SELECT 'nota',              count(*) FROM nota
ORDER BY tabela;
