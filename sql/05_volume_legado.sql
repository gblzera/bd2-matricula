-- ============================================================================
-- 05_volume_legado.sql — Marco 2 · Volume histórico para análise de desempenho
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- POR QUE ESTE SCRIPT EXISTE: com as ~800 matrículas da carga curada do
-- Marco 1, o planner resolve tudo com seq scan e as evidências de EXPLAIN
-- exigidas no Marco 2 não mostram nada. Este script adiciona os semestres
-- LEGADOS 2020/1–2024/2 (3.000 ex-alunos, 400 turmas, ~32 mil matrículas e
-- ~60 mil notas), 100% determinístico, SEM tocar nos cenários de 2025–2026
-- (TABD-N1 continua com 1 vaga livre; COMP1-N1 continua vazia).
--
-- O QUE O LEGADO RECONSTITUI — E O QUE NÃO RECONSTITUI (decisão registrada):
--   Reconstitui: pessoa/aluno, turma, docência, matrícula, avaliação, nota e
--   a situação consolidada. É o acervo acadêmico que uma secretaria realmente
--   guarda por 10 anos.
--   NÃO reconstitui: grade de horários, aulas e presenças. Esse dado não
--   existe num acervo de 2020 com essa granularidade, e inventá-lo (a) exigiria
--   alocar 400 turmas em 9 salas sem violar o EXCLUDE de choque [C10], e
--   (b) não acrescentaria nada à evidência de desempenho, que vem de
--   matricula/nota. Consequência assumida: a frequência das matrículas legadas
--   é NULL e a situação delas é decidida SÓ pela média — o que a consulta de
--   reprovação por frequência mostra apenas para 2025–2026.
--
-- Bônus de tabela: o histórico legado por ANO é exatamente o cenário que
-- motivaria particionamento (bônus do enunciado) — discutido em docs/.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/05_volume_legado.sql
-- Idempotente: remove o legado antes de recriar.
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


BEGIN;

-- ----------------------------------------------------------------------------
-- Idempotência: apaga apenas o legado. A ordem importa — o modelo ampliado
-- amarra nota e presenca à matrícula por FK COMPOSTA [E13], que NÃO tem
-- ON DELETE CASCADE de propósito: nota de aluno não some por acidente.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _turmas_legado ON COMMIT DROP AS
SELECT t.id_turma FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
WHERE pl.ano_periodo_letivo < 2025;

DELETE FROM nota      WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM presenca  WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM aula      WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM avaliacao WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM log_matricula
 WHERE detalhe_log_matricula @> '{"origem": "carga_legado"}';
DELETE FROM historico h USING matricula m
 WHERE m.id_matricula = h.id_matricula AND m.id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM matricula       WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM turma_professor WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM turma_horario   WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM turma           WHERE id_turma IN (SELECT id_turma FROM _turmas_legado);
DELETE FROM periodo_matricula pm USING periodo_letivo pl
 WHERE pl.id_periodo_letivo = pm.id_periodo_letivo AND pl.ano_periodo_letivo < 2025;
DELETE FROM periodo_letivo WHERE ano_periodo_letivo < 2025;

-- ex-alunos: identificados pelo domínio de e-mail da pessoa [E2]
CREATE TEMP TABLE _pessoas_legado ON COMMIT DROP AS
SELECT id_pessoa FROM pessoa WHERE email_pessoa LIKE '%@legado.iesb.br';
DELETE FROM aproveitamento_materia a USING aluno al
 WHERE al.id_aluno = a.id_aluno AND al.id_pessoa IN (SELECT id_pessoa FROM _pessoas_legado);
DELETE FROM aluno    WHERE id_pessoa IN (SELECT id_pessoa FROM _pessoas_legado);
DELETE FROM usuario  WHERE id_pessoa IN (SELECT id_pessoa FROM _pessoas_legado);
DELETE FROM pessoa   WHERE id_pessoa IN (SELECT id_pessoa FROM _pessoas_legado);

-- ...e também eventuais matrículas criadas pela demo de concorrência (07),
-- para a asserção do cenário TABD-N1 (7/8) valer em qualquer reexecução
DELETE FROM presenca p USING matricula m
 WHERE m.id_matricula = p.id_matricula AND m.data_matricula >= date_trunc('day', now());
DELETE FROM nota n USING matricula m
 WHERE m.id_matricula = n.id_matricula AND m.data_matricula >= date_trunc('day', now());
DELETE FROM matricula WHERE data_matricula >= date_trunc('day', now());

-- ----------------------------------------------------------------------------
-- Períodos legados: 2020/1 a 2024/2
-- ----------------------------------------------------------------------------
INSERT INTO periodo_letivo (ano_periodo_letivo, semestre_periodo_letivo, data_inicio_periodo_letivo, data_fim_periodo_letivo)
SELECT y, s,
       make_date(y, CASE s WHEN 1 THEN 2 ELSE 8 END, 3),
       make_date(y, CASE s WHEN 1 THEN 7 ELSE 12 END, 15)
FROM generate_series(2020, 2024) AS y, generate_series(1, 2) AS s;

-- ----------------------------------------------------------------------------
-- Ex-alunos: 3.000 pessoas + 3.000 alunos (ingressos 2020–2022).
-- Chaves projetadas para NUNCA colidir com a carga base: matrícula usa faixa
-- de i 1000–3999, CPF usa base 2e10 (a base usa < 1,7e10, docentes 9e10).
-- pessoa.id_endereco fica NULL: endereço de egresso não é dado que o acervo
-- guarde, e a coluna é anulável justamente para isso [E1].
-- ----------------------------------------------------------------------------
WITH base AS (
  SELECT i,
         CASE WHEN i % 10 < 6 THEN 'CC'
              WHEN i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2020 + (i % 3)      AS ano_ing
  FROM generate_series(1000, 3999) AS g(i)
),
nomes AS (
  SELECT ARRAY['Ana','Bruno','Carla','Diego','Elisa','Felipe','Gabriela','Heitor',
               'Isabela','Joao','Karina','Lucas','Mariana','Nicolas','Olivia',
               'Pedro','Rafaela','Samuel','Tatiana','Vinicius']  AS pn,
         ARRAY['Silva','Santos','Oliveira','Souza','Pereira','Costa','Rodrigues',
               'Almeida','Nascimento','Lima','Araujo','Fernandes','Carvalho',
               'Gomes','Martins']                                AS sn
)
INSERT INTO pessoa (id_endereco, nome_pessoa, email_pessoa, cpf_pessoa, nascimento_pessoa)
SELECT NULL,
       n.pn[1 + (b.i * 7) % 20] || ' ' || n.sn[1 + (b.i * 13) % 15],
       'egresso' || b.i || '@legado.iesb.br',
       lpad((20000000000 + b.i::bigint * 104729)::text, 11, '0')::char(11),
       DATE '1994-01-01' + (b.i * 211) % 3000
FROM base b CROSS JOIN nomes n;

WITH base AS (
  SELECT i,
         CASE WHEN i % 10 < 6 THEN 'CC'
              WHEN i % 10 < 9 THEN 'SI'
              ELSE 'ADS' END AS curso_cod,
         2020 + (i % 3)      AS ano_ing
  FROM generate_series(1000, 3999) AS g(i)
)
INSERT INTO aluno (id_pessoa, id_curso, id_curriculo, matricula_aluno, ingresso_aluno, forma_ingresso_aluno, status_aluno)
SELECT p.id_pessoa, c.id_curso, cu.id_curriculo,
       (b.ano_ing * 10000 + b.i)::text,
       make_date(b.ano_ing, 2, 1),
       (ARRAY['vestibular','enem','transferencia','portador_diploma'])[1 + b.i % 4]::forma_ingresso_t,
       -- egresso: a maioria já formou; uma parte evadiu; ~20% seguem ativos
       CASE WHEN b.i % 5 = 0 THEN 'ativo'
            WHEN b.i % 7 = 0 THEN 'evadido'
            ELSE 'formado' END::status_aluno_t
FROM base b
JOIN pessoa p ON p.email_pessoa = 'egresso' || b.i || '@legado.iesb.br'
JOIN curso c  ON c.codigo_curso = b.curso_cod
JOIN curriculo cu
  ON cu.id_curso = c.id_curso
 AND cu.ano_vigencia_curriculo = CASE WHEN b.curso_cod = 'CC' THEN 2024 ELSE 2025 END;
 -- simplificação: legados usam as matrizes mais antigas cadastradas

-- ----------------------------------------------------------------------------
-- Turmas legadas: 40 por período (2 por disciplina), vagas 100, docência
-- round-robin. O titular entra em turma_professor [E11] — a coluna
-- turma.id_professor não existe mais.
-- ----------------------------------------------------------------------------
INSERT INTO turma (id_disciplina, id_periodo_letivo, codigo_turma, vagas_turma, turno_turma, modalidade_turma)
SELECT d.id_disciplina, pl.id_periodo_letivo,
       'LEG-' || d.codigo_disciplina || '-' || g.n, 100, 'noturno', 'presencial'
FROM periodo_letivo pl
CROSS JOIN disciplina d
CROSS JOIN generate_series(1, 2) AS g(n)
WHERE pl.ano_periodo_letivo < 2025;

INSERT INTO turma_professor (id_turma, id_professor, ch_turma_professor, papel_turma_professor)
SELECT t.id_turma, p.id_professor, d.ch_total_disciplina, 'titular'
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
JOIN LATERAL (
  SELECT id_professor FROM professor
  ORDER BY (id_professor + t.id_disciplina + t.id_periodo_letivo) % 10, id_professor
  LIMIT 1
) p ON true;

-- ----------------------------------------------------------------------------
-- Matrículas legadas: ~80 alunos por turma, seleção determinística por hash.
-- ORDER BY período garante ordem física correlacionada com data_matricula —
-- é isso que faz o índice BRIN do 06_indices.sql brilhar.
-- ----------------------------------------------------------------------------
WITH legadas AS (
  SELECT t.id_turma AS id_turma, t.id_disciplina, pl.data_inicio_periodo_letivo,
         row_number() OVER (ORDER BY pl.data_inicio_periodo_letivo, t.id_turma) AS trn
  FROM turma t
  JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
),
escolhas AS (
  SELECT l.id_turma, l.data_inicio_periodo_letivo, k.k,
         1000 + (l.trn * 53 + k.k * 17) % 3000 AS i_egresso   -- i do e-mail determinístico
  FROM legadas l
  CROSS JOIN generate_series(1, 80) AS k(k)
)
INSERT INTO matricula (id_aluno, id_turma, data_matricula, status_matricula)
SELECT a.id_aluno, e.id_turma,
       (e.data_inicio_periodo_letivo - 10)::timestamptz + make_interval(hours => (e.k * 3)::int),
       CASE WHEN e.k % 17 = 0 THEN 'cancelada'
            WHEN e.k % 13 = 0 THEN 'trancada'
            ELSE 'confirmada' END::status_mat_t
FROM escolhas e
JOIN pessoa p ON p.email_pessoa = 'egresso' || e.i_egresso || '@legado.iesb.br'
JOIN aluno a  ON a.id_pessoa = p.id_pessoa
ORDER BY e.data_inicio_periodo_letivo, e.id_turma, e.k
ON CONFLICT (id_aluno, id_turma) DO NOTHING;

-- ----------------------------------------------------------------------------
-- Avaliações e notas legadas [E14] — mesmas fórmulas da carga base, para que
-- a média continue reproduzível. É esta tabela (`nota`, ~60 mil linhas) que
-- alimenta a mv_historico_consolidado e o índice de faixa de média.
-- ----------------------------------------------------------------------------
INSERT INTO avaliacao (id_turma, nome_avaliacao, peso_avaliacao, data_avaliacao, substitutiva_avaliacao)
SELECT t.id_turma, v.nome, v.peso, pl.data_inicio_periodo_letivo + v.dia, v.subst
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
CROSS JOIN (VALUES ('A1', 4.00, 60, false), ('A2', 6.00, 120, false), ('P3', 6.00, 135, true))
  AS v(nome, peso, dia, subst);

INSERT INTO nota (id_avaliacao, id_matricula, id_turma, valor_nota)
SELECT av.id_avaliacao, m.id_matricula, m.id_turma,
       CASE av.nome_avaliacao
         WHEN 'A1' THEN round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
         WHEN 'A2' THEN round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)
         ELSE           round((4   + ((m.id_aluno * 41 + m.id_turma * 7)  % 56) / 10.0)::numeric, 1)
       END
FROM matricula m
JOIN turma tu          ON tu.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
JOIN avaliacao av      ON av.id_turma = m.id_turma
WHERE m.status_matricula = 'confirmada'
  AND (NOT av.substitutiva_avaliacao
       OR ((0.4 * round((3   + ((m.id_aluno * 37 + m.id_turma * 11) % 71) / 10.0)::numeric, 1)
          + 0.6 * round((3.5 + ((m.id_aluno * 29 + m.id_turma * 13) % 66) / 10.0)::numeric, 1)) < 5
           AND m.id_aluno % 3 <> 0));

-- ----------------------------------------------------------------------------
-- Histórico consolidado do legado. Sem presença, a frequência é NULL e a
-- situação sai só da média — declarado no cabeçalho deste script.
-- ----------------------------------------------------------------------------
INSERT INTO historico (id_matricula, data_fechamento_historico, situacao_historico)
SELECT m.id_matricula, pl.data_fim_periodo_letivo,
       CASE WHEN m.status_matricula = 'trancada' THEN 'trancado'
            WHEN dm.media_final >= 5            THEN 'aprovado'
            ELSE 'reprovado_nota' END::situacao_t
FROM matricula m
JOIN turma tu          ON tu.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
LEFT JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula
WHERE m.status_matricula <> 'cancelada';

-- ----------------------------------------------------------------------------
-- Auditoria do legado (engorda log_matricula p/ a evidência do índice GIN).
-- acao_log_t é DML; o evento de negócio vai no jsonb — que é o que o GIN indexa.
-- ----------------------------------------------------------------------------
INSERT INTO log_matricula (id_matricula, id_usuario, ocorrido_em_log_matricula, acao_log_matricula, detalhe_log_matricula)
SELECT m.id_matricula, u.id_usuario, m.data_matricula, 'insert',
       jsonb_build_object('evento', 'matricula_criada', 'turma', tu.codigo_turma,
                          'origem', 'carga_legado', 'status_inicial', m.status_matricula::text)
FROM matricula m
JOIN turma tu          ON tu.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = tu.id_periodo_letivo AND pl.ano_periodo_letivo < 2025
LEFT JOIN usuario u    ON u.login_usuario = 'bd2';

COMMIT;

-- Estatísticas frescas para o planner (essencial antes das evidências de EXPLAIN)
ANALYZE;

-- Política de refresh das MVs em ação: carga em lote concluída => refresh
REFRESH MATERIALIZED VIEW mv_indicadores;
REFRESH MATERIALIZED VIEW mv_historico_consolidado;

DO $$
DECLARE n_mat int; n_conf_tabd int; n_notas int; n_pessoas int;
BEGIN
  SELECT count(*) INTO n_mat    FROM matricula;
  SELECT count(*) INTO n_notas  FROM nota;
  SELECT count(*) INTO n_pessoas FROM pessoa;
  SELECT count(*) INTO n_conf_tabd FROM matricula m JOIN turma t ON t.id_turma = m.id_turma
   WHERE t.codigo_turma = 'TABD-N1' AND m.status_matricula = 'confirmada';
  IF n_mat   < 30000 THEN RAISE EXCEPTION 'Volume insuficiente: % matrículas', n_mat; END IF;
  IF n_notas < 50000 THEN RAISE EXCEPTION 'Volume insuficiente: % notas', n_notas; END IF;
  IF n_conf_tabd <> 7 THEN RAISE EXCEPTION 'Cenário TABD-N1 corrompido: % confirmadas', n_conf_tabd; END IF;
  RAISE NOTICE 'Volume legado OK: % pessoas, % matrículas, % notas; TABD-N1 intacta (7/8).',
    n_pessoas, n_mat, n_notas;
END $$;

\echo '=== Volumes após carga legada ==='
SELECT 'pessoa' AS tabela, count(*) FROM pessoa                UNION ALL
SELECT 'aluno',            count(*) FROM aluno                 UNION ALL
SELECT 'turma',            count(*) FROM turma                 UNION ALL
SELECT 'matricula',        count(*) FROM matricula             UNION ALL
SELECT 'avaliacao',        count(*) FROM avaliacao             UNION ALL
SELECT 'nota',             count(*) FROM nota                  UNION ALL
SELECT 'presenca',         count(*) FROM presenca              UNION ALL
SELECT 'historico',        count(*) FROM historico             UNION ALL
SELECT 'log_matricula',    count(*) FROM log_matricula         UNION ALL
SELECT 'mv_historico_consolidado', count(*) FROM mv_historico_consolidado
ORDER BY tabela;
