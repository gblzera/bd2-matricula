-- ============================================================================
-- 04_views.sql — Marco 2 · 3 views + 2 materialized views
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/04_views.sql
-- ============================================================================
\set ON_ERROR_STOP on

-- [C15] Todos os objetos vivem no schema `academico`, alinhado ao modelo de
-- partida do professor (docs/banco_de_dados_matricula_com_erros.sql, que abre
-- com `SET search_path TO academico, public`). O search_path é fixado aqui
-- para que este script seja executável isoladamente.
SET search_path TO academico, public;


BEGIN;

DROP VIEW IF EXISTS v_oferta_periodo, v_vagas_disponiveis, v_historico_aluno CASCADE;
DROP MATERIALIZED VIEW IF EXISTS mv_indicadores;
DROP MATERIALIZED VIEW IF EXISTS mv_historico_consolidado;

-- ----------------------------------------------------------------------------
-- VIEW 1 — v_oferta_periodo: o catálogo público do período corrente.
-- "Corrente" é dinâmico (CURRENT_DATE dentro do período), não hardcoded.
-- Horários agregados numa string legível via LATERAL (turma sem horário
-- publicado ainda aparece — LEFT JOIN).
-- ----------------------------------------------------------------------------
CREATE VIEW v_oferta_periodo AS
SELECT pl.ano_periodo_letivo || '/' || pl.semestre_periodo_letivo        AS periodo,
       t.id_turma                                AS id_turma,
       t.codigo_turma                            AS turma,
       d.codigo_disciplina                            AS disciplina,
       d.nome_disciplina                              AS nome_disciplina,
       d.ch_total_disciplina,
       docentes.titular                          AS professor,
       docentes.equipe                           AS equipe_docente,
       t.turno_turma,
       t.modalidade_turma,
       t.vagas_turma,
       h.encontros
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
                      AND CURRENT_DATE BETWEEN pl.data_inicio_periodo_letivo AND pl.data_fim_periodo_letivo
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
-- [E11] o professor virou uma EQUIPE: o titular é quem aparece no catálogo, e
-- a equipe completa vai junto numa string (co-docência é a regra em laboratório).
LEFT JOIN LATERAL (
  SELECT max(pe.nome_pessoa) FILTER (WHERE tp.papel_turma_professor = 'titular') AS titular,
         string_agg(pe.nome_pessoa || ' (' || tp.papel_turma_professor || ')', ' · '
                    ORDER BY tp.papel_turma_professor, pe.nome_pessoa)           AS equipe
  FROM turma_professor tp
  JOIN professor p ON p.id_professor = tp.id_professor
  JOIN pessoa pe   ON pe.id_pessoa = p.id_pessoa                    -- [E2]
  WHERE tp.id_turma = t.id_turma
) docentes ON true
LEFT JOIN LATERAL (
  SELECT string_agg(
           (ARRAY['seg','ter','qua','qui','sex','sab','dom'])[th.dia_semana_turma_horario]
           || ' ' || left(lower(th.faixa_turma_horario)::text, 5)
           || '–' || left(upper(th.faixa_turma_horario)::text, 5)
           -- [E12] sala NULL = turma EAD: o catálogo diz isso em vez de sumir com a linha
           || ' (' || coalesce(s.codigo_sala || '/' || pr.nome_predio, 'EAD') || ')',
           ' · ' ORDER BY th.dia_semana_turma_horario, lower(th.faixa_turma_horario)) AS encontros
  FROM turma_horario th
  LEFT JOIN sala s   ON s.id_sala = th.id_sala
  LEFT JOIN predio pr ON pr.id_predio = s.id_predio                 -- [E5]
  WHERE th.id_turma = t.id_turma
) h ON true;
COMMENT ON VIEW v_oferta_periodo IS 'Catálogo de oferta do período letivo corrente, com horários agregados.';

-- ----------------------------------------------------------------------------
-- VIEW 2 — v_vagas_disponiveis: vagas − confirmadas por turma.
-- É a fonte de leitura da transação de matrícula (Marco 2 · concorrência):
-- centraliza a REGRA de contagem (só 'confirmada' consome vaga) num único
-- lugar, em vez de espalhá-la por consultas ad hoc.
-- ----------------------------------------------------------------------------
CREATE VIEW v_vagas_disponiveis AS
SELECT t.id_turma                                                  AS id_turma,
       t.codigo_turma                                              AS turma,
       pl.ano_periodo_letivo, pl.semestre_periodo_letivo,
       t.vagas_turma,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')    AS confirmadas,
       t.vagas_turma - count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada') AS vagas_livres
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
LEFT JOIN matricula m  ON m.id_turma = t.id_turma
GROUP BY t.id_turma, pl.ano_periodo_letivo, pl.semestre_periodo_letivo;
COMMENT ON VIEW v_vagas_disponiveis IS 'Vagas livres por turma (regra: só status=confirmada consome vaga).';

-- ----------------------------------------------------------------------------
-- VIEW 3 — v_historico_aluno: histórico completo, pronto para o aluno consultar.
-- security_invoker = on (PG 15+): a view executa com as PERMISSÕES DE QUEM
-- CONSULTA, então as políticas de RLS do 08_seguranca.sql valem ATRAVÉS da
-- view. Sem isso, a view rodaria como o dono (superusuário bd2) e vazaria
-- o histórico de todos — exatamente o que o RLS deve impedir.
-- ----------------------------------------------------------------------------
CREATE VIEW v_historico_aluno WITH (security_invoker = on) AS
SELECT a.id_aluno                          AS id_aluno,
       a.matricula_aluno                   AS ra,
       pe.nome_pessoa                      AS aluno,                    -- [E2]
       pl.ano_periodo_letivo || '/' || pl.semestre_periodo_letivo  AS periodo,
       d.codigo_disciplina                      AS disciplina,
       d.nome_disciplina                        AS nome_disciplina,
       d.ch_total_disciplina,
       -- [E14] notas individuais em vez de três colunas fixas: a lista sai de
       -- `nota`, e média/frequência de v_desempenho_matricula (mesma regra da P3).
       notas.detalhe                            AS notas,
       dm.frequencia,
       dm.media_final,
       dm.usou_substitutiva,
       h.situacao_historico,
       h.data_fechamento_historico,
       m.status_matricula                      AS status_matricula
FROM aluno a
JOIN pessoa pe         ON pe.id_pessoa = a.id_pessoa
JOIN matricula m       ON m.id_aluno = a.id_aluno
JOIN turma t           ON t.id_turma = m.id_turma
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
LEFT JOIN historico h  ON h.id_matricula = m.id_matricula
LEFT JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula
LEFT JOIN LATERAL (
  SELECT string_agg(av.nome_avaliacao || ' ' || n.valor_nota, ' · '
                    ORDER BY av.substitutiva_avaliacao, av.nome_avaliacao) AS detalhe
  FROM nota n JOIN avaliacao av ON av.id_avaliacao = n.id_avaliacao
  WHERE n.id_matricula = m.id_matricula
) notas ON true
ORDER BY a.id_aluno, pl.ano_periodo_letivo, pl.semestre_periodo_letivo, d.codigo_disciplina;
COMMENT ON VIEW v_historico_aluno IS 'Histórico por aluno; security_invoker=on para o RLS valer através da view.';

-- ----------------------------------------------------------------------------
-- MATERIALIZED VIEW — mv_indicadores: painel disciplina × período.
--
-- POLÍTICA DE ATUALIZAÇÃO (justificativa exigida no enunciado):
--   Os indicadores agregam NOTAS e SITUAÇÕES, que só mudam em dois momentos
--   do semestre — lançamento de notas e fechamento do período. Não faz
--   sentido pagar o custo da agregação a cada consulta da coordenação
--   (view comum), nem manter refresh contínuo. Política adotada:
--     REFRESH MATERIALIZED VIEW CONCURRENTLY mv_indicadores;
--   executado (a) após o fechamento de cada período letivo e (b) sob demanda
--   após cargas em lote — o 05_volume_legado.sql faz exatamente isso.
--   O CONCURRENTLY não bloqueia leituras durante o refresh e exige o índice
--   ÚNICO criado abaixo (ux_mv_indicadores) — por isso ele existe.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_indicadores AS
SELECT d.id_disciplina                                                   AS id_disciplina,
       pl.id_periodo_letivo                                                  AS id_periodo_letivo,
       d.codigo_disciplina                                               AS disciplina,
       pl.ano_periodo_letivo, pl.semestre_periodo_letivo,
       count(DISTINCT t.id_turma)                                   AS turmas,
       sum(t.vagas_turma)                                           AS vagas_ofertadas,
       count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')     AS confirmadas,
       round(100.0 * count(m.id_matricula) FILTER (WHERE m.status_matricula = 'confirmada')
             / NULLIF(sum(t.vagas_turma), 0), 1)                    AS ocupacao_pct,
       round(avg(dm.media_final), 2)                                    AS media_geral,
       round(avg(dm.frequencia), 1)                                     AS frequencia_media,
       count(h.id_historico) FILTER (WHERE h.situacao_historico = 'aprovado')     AS aprovados,
       count(h.id_historico) FILTER (WHERE h.situacao_historico IN
             ('reprovado_nota', 'reprovado_frequencia'))      AS reprovados,
       round(100.0 * count(h.id_historico) FILTER (WHERE h.situacao_historico = 'aprovado')
             / NULLIF(count(h.id_historico) FILTER (WHERE h.situacao_historico IN
               ('aprovado', 'reprovado_nota', 'reprovado_frequencia')), 0), 1)
                                                              AS aprovacao_pct
FROM turma t
JOIN periodo_letivo pl ON pl.id_periodo_letivo = t.id_periodo_letivo
JOIN disciplina d      ON d.id_disciplina = t.id_disciplina
LEFT JOIN matricula m  ON m.id_turma = t.id_turma
LEFT JOIN historico h  ON h.id_matricula = m.id_matricula
LEFT JOIN v_desempenho_matricula dm ON dm.id_matricula = m.id_matricula     -- [E14]
GROUP BY d.id_disciplina, pl.id_periodo_letivo;

-- Exigido pelo REFRESH ... CONCURRENTLY (identifica cada linha unicamente)
CREATE UNIQUE INDEX ux_mv_indicadores ON mv_indicadores (id_disciplina, id_periodo_letivo);
COMMENT ON MATERIALIZED VIEW mv_indicadores IS
  'Indicadores disciplina×período; refresh CONCURRENTLY pós-fechamento (política justificada no script).';

-- ----------------------------------------------------------------------------
-- MATERIALIZED VIEW 2 — mv_historico_consolidado: o objeto que a ampliação
-- PROMETEU em [E14] e que paga a conta que ela criou.
--
-- Antes, `historico` guardava nota_a1/a2/p3, frequência e uma coluna GERADA
-- com a média — leitura de uma linha só. Depois de [E14], a mesma informação
-- exige agregar `nota` (n linhas) e `presenca` (dezenas por matrícula). O
-- ganho é modelagem correta (1FN, avaliações flexíveis); o custo é agregação
-- a cada leitura. Esta MV é onde esse custo é pago UMA vez por fechamento —
-- e é ela que sustenta o índice B-tree de faixa de média do 06_indices.sql,
-- que antes vivia na coluna gerada.
--
-- Mesma política de refresh da mv_indicadores: pós-fechamento de período e
-- pós-carga em lote. O índice único abaixo é o que habilita CONCURRENTLY.
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_historico_consolidado AS
SELECT dm.id_matricula,
       dm.id_aluno,
       dm.id_turma,
       t.id_disciplina,
       t.id_periodo_letivo,
       dm.media_final,
       dm.frequencia,
       dm.avaliacoes_lancadas,
       dm.usou_substitutiva,
       h.situacao_historico,
       h.data_fechamento_historico
FROM v_desempenho_matricula dm
JOIN turma t          ON t.id_turma = dm.id_turma
LEFT JOIN historico h ON h.id_matricula = dm.id_matricula;

CREATE UNIQUE INDEX ux_mv_historico_consolidado ON mv_historico_consolidado (id_matricula);
COMMENT ON MATERIALIZED VIEW mv_historico_consolidado IS
  'Consolidado de média/frequência por matrícula [E14]; sucessor materializado da coluna gerada [C13].';

COMMIT;

\echo '=== Views criadas ==='
SELECT 'v_desempenho_matricula (01_ddl)' AS objeto, count(*) AS linhas FROM v_desempenho_matricula UNION ALL
SELECT 'v_oferta_periodo',               count(*)           FROM v_oferta_periodo    UNION ALL
SELECT 'v_vagas_disponiveis',            count(*)           FROM v_vagas_disponiveis UNION ALL
SELECT 'v_historico_aluno',              count(*)           FROM v_historico_aluno   UNION ALL
SELECT 'mv_indicadores',                 count(*)           FROM mv_indicadores      UNION ALL
SELECT 'mv_historico_consolidado',       count(*)           FROM mv_historico_consolidado;
