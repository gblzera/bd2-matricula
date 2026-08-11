-- ============================================================================
-- 07_transacoes.sql — Marco 2 · Transações e controle de concorrência
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- A ANOMALIA: duas sessões disputam a ÚLTIMA VAGA de TABD-N1 (a carga deixa
-- exatamente 7 confirmadas para 8 vagas). O fluxo ingênuo "conta -> confere
-- -> insere" sofre de READ-CHECK-ACT race: em READ COMMITTED, as duas sessões
-- contam 7, as duas concluem que há vaga, as duas inserem => 9/8 (overbooking).
-- Nenhuma constraint pega isso: o limite de vagas atravessa uma agregação
-- sobre OUTRA tabela (ver docs/correcoes-modelo-logico.md, seção final).
--
-- Este script instala as funções; a demonstração ao vivo usa os roteiros de
-- scripts/concorrencia/ orquestrados por scripts/demo_concorrencia.sh, e a
-- execução capturada fica em docs/evidencias/transacoes-demo.md.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/07_transacoes.sql
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

-- ----------------------------------------------------------------------------
-- Versão INGÊNUA — reproduz a anomalia (e, sob SERIALIZABLE, é corrigida
-- pelo próprio isolamento, sem mudar UMA linha do código: esse é o ponto).
-- p_pausa: janela artificial (segundos) entre a checagem e a gravação, para
-- tornar a corrida determinística na demonstração. Documentada e honesta:
-- na vida real a janela existe, só é mais estreita.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_matricular_sem_protecao(
  p_aluno integer, p_turma integer, p_pausa numeric DEFAULT 0)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_vagas int;
  v_confirmadas int;
  v_matricula_id int;
BEGIN
  SELECT vagas INTO v_vagas FROM turma WHERE id = p_turma;

  SELECT count(*) INTO v_confirmadas                -- LEITURA...
  FROM matricula WHERE turma_id = p_turma AND status = 'confirmada';

  IF v_confirmadas >= v_vagas THEN
    INSERT INTO log_matricula (matricula_id, acao, detalhe)
    VALUES (NULL, 'vaga_recusada',
            jsonb_build_object('aluno_id', p_aluno, 'turma_id', p_turma,
                               'ocupacao', v_confirmadas || '/' || v_vagas));
    RETURN format('RECUSADA: turma %s cheia (%s/%s)', p_turma, v_confirmadas, v_vagas);
  END IF;

  PERFORM pg_sleep(p_pausa);                        -- ...JANELA DA CORRIDA...

  INSERT INTO matricula (aluno_id, turma_id)        -- ...GRAVAÇÃO
  VALUES (p_aluno, p_turma)
  RETURNING id INTO v_matricula_id;

  INSERT INTO historico (matricula_id) VALUES (v_matricula_id);
  INSERT INTO log_matricula (matricula_id, acao, detalhe)
  VALUES (v_matricula_id, 'matricula_criada',
          jsonb_build_object('via', 'fn_matricular_sem_protecao'));

  RETURN format('CONFIRMADA: aluno %s ficou com a vaga %s/%s da turma %s',
                p_aluno, v_confirmadas + 1, v_vagas, p_turma);
END $$;

-- ----------------------------------------------------------------------------
-- CORREÇÃO A — bloqueio explícito (pessimista).
-- SELECT ... FOR UPDATE na linha da TURMA serializa o trecho crítico: a
-- segunda sessão FICA BLOQUEADA no lock até a primeira commitar, e então
-- reconta — já vendo a matrícula nova. A linha da turma funciona como
-- "mutex natural" da vaga; só muda 1 linha em relação à versão ingênua.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_matricular_com_lock(
  p_aluno integer, p_turma integer, p_pausa numeric DEFAULT 0)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_vagas int;
  v_confirmadas int;
  v_matricula_id int;
BEGIN
  SELECT vagas INTO v_vagas
  FROM turma WHERE id = p_turma
  FOR UPDATE;                                       -- <<< o trecho crítico começa AQUI

  SELECT count(*) INTO v_confirmadas
  FROM matricula WHERE turma_id = p_turma AND status = 'confirmada';

  IF v_confirmadas >= v_vagas THEN
    INSERT INTO log_matricula (matricula_id, acao, detalhe)
    VALUES (NULL, 'vaga_recusada',
            jsonb_build_object('aluno_id', p_aluno, 'turma_id', p_turma,
                               'ocupacao', v_confirmadas || '/' || v_vagas));
    RETURN format('RECUSADA: turma %s cheia (%s/%s)', p_turma, v_confirmadas, v_vagas);
  END IF;

  PERFORM pg_sleep(p_pausa);

  INSERT INTO matricula (aluno_id, turma_id)
  VALUES (p_aluno, p_turma)
  RETURNING id INTO v_matricula_id;

  INSERT INTO historico (matricula_id) VALUES (v_matricula_id);
  INSERT INTO log_matricula (matricula_id, acao, detalhe)
  VALUES (v_matricula_id, 'matricula_criada',
          jsonb_build_object('via', 'fn_matricular_com_lock'));

  RETURN format('CONFIRMADA: aluno %s ficou com a vaga %s/%s da turma %s',
                p_aluno, v_confirmadas + 1, v_vagas, p_turma);
END $$;

-- CORREÇÃO B não é uma função nova: é a MESMA fn_matricular_sem_protecao
-- executada sob BEGIN ISOLATION LEVEL SERIALIZABLE (otimista). O SSI detecta
-- a dependência leitura->escrita cruzada e aborta uma das transações com
-- SQLSTATE 40001 (serialization_failure); a aplicação faz retry e, na nova
-- tentativa, vê a turma cheia. Ver scripts/concorrencia/sessao_serializable.sql.

-- ----------------------------------------------------------------------------
-- Reset do cenário da demonstração: remove só as matrículas criadas pelas
-- demos (as da carga têm data anterior ao início do período; as da demo são
-- de agora). O CASCADE do histórico [1:1] limpa junto; o log FICA — auditoria
-- sobrevive de propósito [C11].
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_demo_reset(p_turma integer)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_removidas int;
BEGIN
  DELETE FROM matricula
  WHERE turma_id = p_turma AND data_matricula >= date_trunc('day', now());
  GET DIAGNOSTICS v_removidas = ROW_COUNT;
  RETURN format('Reset: %s matrícula(s) de demonstração removida(s) da turma %s.',
                v_removidas, p_turma);
END $$;

COMMIT;

\echo '=== Funções de concorrência instaladas ==='
SELECT proname AS funcao FROM pg_proc
WHERE proname IN ('fn_matricular_sem_protecao', 'fn_matricular_com_lock', 'fn_demo_reset')
ORDER BY proname;
