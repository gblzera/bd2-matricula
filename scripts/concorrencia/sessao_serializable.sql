-- Sessão de matrícula sob SERIALIZABLE — Correção B (otimista).
-- Parâmetros (via psql -v): funcao (ignorado: usa sempre a fn ingênua), aluno, turma, pausa
-- O ponto pedagógico: o CÓDIGO é o mesmo da anomalia (fn_matricular_sem_protecao);
-- quem corrige é o NÍVEL DE ISOLAMENTO. O SSI detecta a dependência
-- leitura->escrita cruzada e aborta uma das transações com SQLSTATE 40001
-- (serialization_failure) — a aplicação deve capturar e RETENTAR; na nova
-- tentativa, a contagem já mostra a turma cheia e a matrícula é recusada.
SET search_path TO academico, public;  -- [C15]
\timing on
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT fn_matricular_sem_protecao(:aluno, :turma, :pausa) AS resultado;
COMMIT;
