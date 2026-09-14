-- Sessão de matrícula em READ COMMITTED (isolamento default do PostgreSQL).
-- Parâmetros (via psql -v): funcao, aluno, turma, pausa
-- Usada tanto para reproduzir a anomalia (funcao=fn_matricular_sem_protecao)
-- quanto para a Correção A (funcao=fn_matricular_com_lock).
SET search_path TO academico, public;  -- [C15]
\timing on
BEGIN;
SELECT :funcao(:aluno, :turma, :pausa) AS resultado;
COMMIT;
