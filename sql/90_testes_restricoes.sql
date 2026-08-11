-- ============================================================================
-- 90_testes_restricoes.sql — Prova de que as correções do modelo funcionam
-- Projeto Acadêmico BD2 (CCO072) · IESB 2026/2 · Sistema de Matrícula Acadêmica
--
-- Cada teste tenta inserir um dado INVÁLIDO que o modelo lógico original
-- ACEITARIA, e espera que o banco REJEITE (graças às correções C2–C10).
-- Padrão: bloco aninhado com EXCEPTION — se o INSERT passar, o teste FALHA
-- com exceção; se o banco rejeitar com o erro esperado, imprime OK.
-- Nada fica gravado: cada tentativa é revertida pelo próprio bloco.
--
-- Execução:  docker exec -i bd2_aluno_postgres psql -U bd2 -d matricula < sql/90_testes_restricoes.sql
-- ============================================================================
\set ON_ERROR_STOP on

\echo '=== Testes de restrições (todos devem imprimir OK) ==='

-- [C7] pré-requisito reflexivo (disciplina exige a si mesma)
DO $$
BEGIN
  BEGIN
    INSERT INTO pre_requisito (disciplina_id, requisito_id)
    SELECT id, id FROM disciplina WHERE codigo = 'BD2';
    RAISE EXCEPTION 'TESTE FALHOU: aceitou pré-requisito reflexivo (C7)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [C7] pré-requisito reflexivo rejeitado (check_violation)';
  END;
END $$;

-- [C2] matrícula duplicada (mesmo aluno, mesma turma)
DO $$
BEGIN
  BEGIN
    INSERT INTO matricula (aluno_id, turma_id)
    SELECT aluno_id, turma_id FROM matricula LIMIT 1;
    RAISE EXCEPTION 'TESTE FALHOU: aceitou matrícula duplicada (C2)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C2] matrícula duplicada rejeitada (unique_violation)';
  END;
END $$;

-- [C3] período letivo duplicado (segundo "2026/2")
DO $$
BEGIN
  BEGIN
    INSERT INTO periodo_letivo (ano, semestre, data_inicio, data_fim)
    VALUES (2026, 2, DATE '2026-08-01', DATE '2026-12-15');
    RAISE EXCEPTION 'TESTE FALHOU: aceitou período letivo duplicado (C3)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C3] período 2026/2 duplicado rejeitado (unique_violation)';
  END;
END $$;

-- [C10] choque de sala: outra turma na MESMA sala, dia e faixa sobreposta,
-- no MESMO período letivo
DO $$
DECLARE
  h turma_horario%ROWTYPE;
  outra integer;
BEGIN
  SELECT * INTO h FROM turma_horario ORDER BY id LIMIT 1;
  SELECT t.id INTO outra
  FROM turma t
  WHERE t.periodo_letivo_id = h.periodo_letivo_id AND t.id <> h.turma_id
    AND NOT EXISTS (SELECT 1 FROM turma_horario x       -- evita cair no ex_turma_sem_choque
                    WHERE x.turma_id = t.id AND x.dia_semana = h.dia_semana
                      AND x.faixa && h.faixa)
  LIMIT 1;
  BEGIN
    INSERT INTO turma_horario (turma_id, periodo_letivo_id, sala_id, dia_semana, faixa)
    VALUES (outra, h.periodo_letivo_id, h.sala_id, h.dia_semana, h.faixa);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou duas turmas na mesma sala/horário (C10)';
  EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK  [C10] choque de sala rejeitado (exclusion_violation via GiST)';
  END;
END $$;

-- [C6] aluno apontando currículo de OUTRO curso (a FK composta barra)
DO $$
DECLARE
  al aluno%ROWTYPE;
  curriculo_errado integer;
BEGIN
  SELECT * INTO al FROM aluno ORDER BY id LIMIT 1;
  SELECT id INTO curriculo_errado FROM curriculo WHERE curso_id <> al.curso_id LIMIT 1;
  BEGIN
    UPDATE aluno SET curriculo_id = curriculo_errado WHERE id = al.id;
    RAISE EXCEPTION 'TESTE FALHOU: aceitou currículo de outro curso (C6)';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'OK  [C6] currículo de outro curso rejeitado (foreign_key_violation composta)';
  END;
END $$;

-- [C12] nota fora da escala 0–10 (domínio nota_t)
DO $$
BEGIN
  BEGIN
    UPDATE historico SET nota_a1 = 11 WHERE id = (SELECT id FROM historico LIMIT 1);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou nota 11 (C12)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK  [C12] nota 11 rejeitada pelo domínio nota_t (check_violation)';
  END;
END $$;

-- [C9] feriado NACIONAL duplicado (campus NULL × campus NULL)
DO $$
BEGIN
  BEGIN
    INSERT INTO feriado (data, descricao, campus_id)
    VALUES (DATE '2026-09-07', 'Independência (duplicada)', NULL);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou feriado nacional duplicado (C9)';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK  [C9] feriado nacional duplicado rejeitado (UNIQUE NULLS NOT DISTINCT)';
  END;
END $$;

-- [C13] coluna gerada não aceita escrita direta (media_final é sempre derivada)
DO $$
BEGIN
  BEGIN
    UPDATE historico SET media_final = 9.99 WHERE id = (SELECT id FROM historico LIMIT 1);
    RAISE EXCEPTION 'TESTE FALHOU: aceitou escrita direta em media_final (C13)';
  EXCEPTION WHEN generated_always THEN
    RAISE NOTICE 'OK  [C13] escrita direta em media_final rejeitada (generated_always)';
  END;
END $$;

\echo '=== Fim dos testes — banco permanece íntegro (nenhuma linha gravada) ==='
