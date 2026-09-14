-- ============================================================================
-- 08_seguranca.sql — Marco 2 · Papéis de acesso, GRANT/REVOKE e Row-Level Security
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Modelo de acesso:
--   papel_aluno (NOLOGIN, papel-grupo)  lê o catálogo; nos dados pessoais
--                                       (aluno/matricula/historico) o RLS
--                                       restringe ÀS PRÓPRIAS LINHAS
--   secretaria  (LOGIN)                 opera matrículas e notas (CRUD), sem DDL
--   coordenacao (LOGIN)                 leitura de tudo + indicadores (mv)
--   al_<RA>     (LOGIN, membros de papel_aluno)  dois logins de demonstração
--
-- A identidade do aluno vem do NOME DA ROLE: 'al_' || matricula. A função
-- aluno_id_de(current_user) (SECURITY DEFINER) resolve a role para aluno.id_aluno —
-- as políticas usam essa função, sem recursão de RLS. A tabela `usuario` [E4]
-- guarda esse mesmo login do lado dos DADOS, e f_usuario_sessao() faz a volta.
--
-- O BURACO QUE A AMPLIAÇÃO ABRIU (e que este script fecha):
--   Antes, proteger `aluno`, `matricula` e `historico` bastava — nome, CPF e
--   notas moravam nessas três tabelas. Depois de [E2] o nome e o CPF foram
--   para `pessoa`, e depois de [E14] as notas foram para `nota`. As MESMAS
--   três políticas de antes passariam a deixar o dado pessoal e as notas de
--   TODO MUNDO em aberto. Normalizar mudou a superfície de ataque: por isso
--   `pessoa`, `nota` e `presenca` também ganham RLS aqui.
--   Regra de bolso que fica: RLS acompanha o DADO, não a tabela onde ele
--   estava quando a política foi escrita.
--
-- Roles são objetos de CLUSTER (sobrevivem ao DROP SCHEMA do 01_ddl.sql);
-- grants e políticas são recriados aqui a cada reconstrução. Idempotente.
-- Senhas didáticas de ambiente de aula — jamais fazer isso em produção.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/08_seguranca.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] objetos vivem em `academico`; fixado para execução isolada.
SET search_path TO academico, public;

-- ----------------------------------------------------------------------------
-- 1. Papéis (CREATE se não existirem; senha sempre redefinida)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN CREATE ROLE papel_aluno NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE ROLE secretaria  LOGIN;   EXCEPTION WHEN duplicate_object THEN NULL; END;
  BEGIN CREATE ROLE coordenacao LOGIN;   EXCEPTION WHEN duplicate_object THEN NULL; END;
  ALTER ROLE secretaria  PASSWORD 'secretaria123';
  ALTER ROLE coordenacao PASSWORD 'coordenacao123';
END $$;

-- Dois logins de demonstração: os 2 alunos com mais matrículas confirmadas
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT a.matricula_aluno
    FROM aluno a JOIN matricula m ON m.id_aluno = a.id_aluno AND m.status_matricula = 'confirmada'
    GROUP BY a.id_aluno ORDER BY count(*) DESC, a.id_aluno LIMIT 2
  LOOP
    BEGIN
      EXECUTE format('CREATE ROLE %I LOGIN IN ROLE papel_aluno', 'al_' || r.matricula_aluno);
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    EXECUTE format('ALTER ROLE %I PASSWORD %L', 'al_' || r.matricula_aluno, 'aluno123');
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Identidade: resolve o nome_aluno da role para o aluno correspondente.
-- SECURITY DEFINER: roda como o dono (bd2), enxergando a tabela aluno sem
-- passar pelo RLS — evita recursão de política e dispensa o aluno de ter
-- SELECT irrestrito em aluno. search_path fixo por segurança (boa prática
-- obrigatória em SECURITY DEFINER).
--
-- PEGADINHA DOCUMENTADA: a role NÃO pode ser lida com current_user DENTRO da
-- função — em SECURITY DEFINER, current_user passa a ser o DONO (bd2) durante
-- a execução, e a política negaria tudo. Por isso a role entra por PARÂMETRO:
-- as políticas avaliam current_user FORA da função (no contexto do usuário) e
-- passam o valor para cá.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION aluno_id_de(p_role text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = academico
AS $$ SELECT id_aluno FROM aluno WHERE matricula_aluno = substr(p_role, 4) $$;

-- Mesma técnica, um salto adiante: a PESSOA por trás da role. Existe como
-- função própria (em vez de subconsulta dentro da política de `pessoa`) para
-- que a política não precise ler `aluno` — que também tem RLS. Sem isso,
-- a política de uma tabela dependeria da política de outra.
CREATE OR REPLACE FUNCTION pessoa_id_de(p_role text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = academico
AS $$ SELECT id_pessoa FROM aluno WHERE matricula_aluno = substr(p_role, 4) $$;

-- ----------------------------------------------------------------------------
-- 3. GRANT / REVOKE (privilégio mínimo por papel)
-- O 01_ddl.sql recria o schema academico do zero [C15], então nada herda acesso:
-- partimos de "ninguém enxerga nada" e concedemos o mínimo.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA academico TO papel_aluno, secretaria, coordenacao;

-- papel_aluno: catálogo público em leitura...
GRANT SELECT ON campus, curso, curriculo, curriculo_disciplina, disciplina,
                pre_requisito, professor, periodo_letivo, predio, sala, turma,
                turma_professor, turma_horario, feriado, periodo_matricula,
                avaliacao, plano_ensino, unidade_plano_ensino, bibliografia,
                plano_ensino_bibliografia,
                v_oferta_periodo, v_vagas_disponiveis
TO papel_aluno;
-- ...e dados pessoais: o GRANT abre a TABELA, o RLS filtra as LINHAS.
-- pessoa/nota/presenca entram nesta lista por causa de [E2] e [E14] — é onde
-- o dado pessoal e as notas passaram a morar.
GRANT SELECT ON aluno, pessoa, matricula, historico, nota, presenca,
                v_historico_aluno
TO papel_aluno;
-- v_desempenho_matricula roda com direitos do DONO (01_ddl.sql): conceder a
-- VIEW não concede nota/presenca por baixo dela. É a camada que deixa o aluno
-- ver a PRÓPRIA média sem enxergar a tabela de notas inteira.
GRANT SELECT ON v_desempenho_matricula TO papel_aluno;

-- secretaria: opera o dia a dia (sem DROP/ALTER — DDL é do DBA)
GRANT SELECT ON ALL TABLES IN SCHEMA academico TO secretaria;
GRANT INSERT, UPDATE ON aluno, matricula, historico, log_matricula TO secretaria;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA academico TO secretaria;
GRANT EXECUTE ON FUNCTION fn_matricular_com_lock(integer, integer, numeric) TO secretaria;

-- coordenacao: leitura ampla + indicadores materializados
GRANT SELECT ON ALL TABLES IN SCHEMA academico TO coordenacao;
GRANT SELECT ON mv_indicadores, mv_historico_consolidado TO coordenacao;

-- ----------------------------------------------------------------------------
-- 4. Row-Level Security
-- ENABLE = a partir daqui, para quem não é dono, vale "nega tudo" e só as
-- políticas abrem linhas. (bd2 é dono/superusuário e ignora RLS — papel de DBA.)
-- ----------------------------------------------------------------------------
ALTER TABLE aluno     ENABLE ROW LEVEL SECURITY;
ALTER TABLE matricula ENABLE ROW LEVEL SECURITY;
ALTER TABLE historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE pessoa    ENABLE ROW LEVEL SECURITY;   -- [E2] nome e CPF moram aqui
ALTER TABLE nota      ENABLE ROW LEVEL SECURITY;   -- [E14] as notas moram aqui
ALTER TABLE presenca  ENABLE ROW LEVEL SECURITY;   -- [E13] a frequência, aqui

DROP POLICY IF EXISTS pol_aluno_so_ele_mesmo     ON aluno;
DROP POLICY IF EXISTS pol_matricula_so_do_aluno  ON matricula;
DROP POLICY IF EXISTS pol_historico_so_do_aluno  ON historico;
DROP POLICY IF EXISTS pol_pessoa_so_ela_mesma    ON pessoa;
DROP POLICY IF EXISTS pol_nota_so_do_aluno       ON nota;
DROP POLICY IF EXISTS pol_presenca_so_do_aluno   ON presenca;
DROP POLICY IF EXISTS pol_secretaria_aluno       ON aluno;
DROP POLICY IF EXISTS pol_secretaria_matricula   ON matricula;
DROP POLICY IF EXISTS pol_secretaria_historico   ON historico;
DROP POLICY IF EXISTS pol_secretaria_pessoa      ON pessoa;
DROP POLICY IF EXISTS pol_secretaria_nota        ON nota;
DROP POLICY IF EXISTS pol_secretaria_presenca    ON presenca;
DROP POLICY IF EXISTS pol_coordenacao_aluno      ON aluno;
DROP POLICY IF EXISTS pol_coordenacao_matricula  ON matricula;
DROP POLICY IF EXISTS pol_coordenacao_historico  ON historico;
DROP POLICY IF EXISTS pol_coordenacao_pessoa     ON pessoa;
DROP POLICY IF EXISTS pol_coordenacao_nota       ON nota;
DROP POLICY IF EXISTS pol_coordenacao_presenca   ON presenca;

-- Aluno: enxerga apenas a si e ao que é seu.
-- A exigência central do enunciado — "um aluno não vê o histórico de outro" —
-- é a pol_historico_so_do_aluno: a linha do histórico só aparece se pertencer
-- a uma matrícula do próprio aluno.
CREATE POLICY pol_aluno_so_ele_mesmo ON aluno
  FOR SELECT TO papel_aluno
  USING (id_aluno = aluno_id_de(current_user::text));

CREATE POLICY pol_matricula_so_do_aluno ON matricula
  FOR SELECT TO papel_aluno
  USING (id_aluno = aluno_id_de(current_user::text));

CREATE POLICY pol_historico_so_do_aluno ON historico
  FOR SELECT TO papel_aluno
  USING (EXISTS (SELECT 1 FROM matricula m
                 WHERE m.id_matricula = historico.id_matricula
                   AND m.id_aluno = aluno_id_de(current_user::text)));

-- [E2] a pessoa é o supertipo: sem esta política, o aluno leria nome, e-mail,
-- CPF e nascimento de TODO MUNDO — inclusive dos 3 mil egressos.
CREATE POLICY pol_pessoa_so_ela_mesma ON pessoa
  FOR SELECT TO papel_aluno
  USING (id_pessoa = pessoa_id_de(current_user::text));

-- [E14] a nota saiu de historico e veio para cá; a política vem junto.
CREATE POLICY pol_nota_so_do_aluno ON nota
  FOR SELECT TO papel_aluno
  USING (EXISTS (SELECT 1 FROM matricula m
                 WHERE m.id_matricula = nota.id_matricula
                   AND m.id_aluno = aluno_id_de(current_user::text)));

CREATE POLICY pol_presenca_so_do_aluno ON presenca
  FOR SELECT TO papel_aluno
  USING (EXISTS (SELECT 1 FROM matricula m
                 WHERE m.id_matricula = presenca.id_matricula
                   AND m.id_aluno = aluno_id_de(current_user::text)));

-- Secretaria: acesso operacional integral às linhas
CREATE POLICY pol_secretaria_aluno     ON aluno     TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_secretaria_matricula ON matricula TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_secretaria_historico ON historico TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_secretaria_pessoa    ON pessoa    TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_secretaria_nota      ON nota      TO secretaria USING (true) WITH CHECK (true);
CREATE POLICY pol_secretaria_presenca  ON presenca  TO secretaria USING (true) WITH CHECK (true);

-- Coordenação: leitura integral
CREATE POLICY pol_coordenacao_aluno     ON aluno     FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_coordenacao_matricula ON matricula FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_coordenacao_historico ON historico FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_coordenacao_pessoa    ON pessoa    FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_coordenacao_nota      ON nota      FOR SELECT TO coordenacao USING (true);
CREATE POLICY pol_coordenacao_presenca  ON presenca  FOR SELECT TO coordenacao USING (true);

-- ----------------------------------------------------------------------------
-- 5. Demonstração (a exigida na apresentação: aluno NÃO vê histórico alheio)
-- ----------------------------------------------------------------------------
SELECT 'al_' || a.matricula_aluno AS papel_a
FROM aluno a JOIN matricula m ON m.id_aluno = a.id_aluno AND m.status_matricula = 'confirmada'
GROUP BY a.id_aluno ORDER BY count(*) DESC, a.id_aluno LIMIT 1 \gset

\echo ''
\echo '=== DEMO RLS — visão do banco como cada papel ==='
\echo '-- Como DBA (bd2): total de linhas de histórico visíveis:'
SELECT count(*) AS historico_total FROM historico;

SET ROLE :"papel_a";
\echo '-- Como' :'papel_a' '(aluno): linhas de histórico visíveis (só as dele):'
SELECT count(*) AS historico_visivel FROM historico;
\echo '-- Como' :'papel_a' ': o histórico detalhado via view (RLS atravessa a view):'
SELECT periodo, disciplina, notas, media_final, frequencia, situacao_historico
FROM v_historico_aluno LIMIT 5;
\echo '-- Como' :'papel_a' ': tentando enxergar OUTROS alunos na tabela aluno:'
SELECT count(*) AS alunos_visiveis FROM aluno;
\echo '-- Como' :'papel_a' ': o buraco que a ampliação abriu, agora fechado —'
\echo '   pessoas visíveis (de 3.132) e notas visíveis (de ~60 mil):'
SELECT (SELECT count(*) FROM pessoa) AS pessoas_visiveis,
       (SELECT count(*) FROM nota)   AS notas_visiveis,
       (SELECT count(*) FROM presenca) AS presencas_visiveis;
RESET ROLE;

SET ROLE coordenacao;
\echo '-- Como coordenacao: leitura ampla (todos os históricos):'
SELECT count(*) AS historico_visivel FROM historico;
RESET ROLE;

\echo '=== fim da demo RLS ==='
