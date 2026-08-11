#!/usr/bin/env bash
# =============================================================================
# Demonstração da disputa pela ÚLTIMA VAGA de TABD-N1 em duas sessões reais.
#
# Uso: ./scripts/demo_concorrencia.sh [sem_protecao|lock|serializable]
#   sem_protecao  reproduz a ANOMALIA (overbooking 9/8) em READ COMMITTED
#   lock          Correção A: SELECT ... FOR UPDATE serializa o trecho crítico
#   serializable  Correção B: mesmo código ingênuo, isolamento SERIALIZABLE
#
# Cronologia: a sessão A entra primeiro e segura a janela crítica por 4s;
# a sessão B entra 1s depois, sem pausa. O interlacing é determinístico.
# =============================================================================
set -uo pipefail   # sem -e de propósito: no modo serializable UMA sessão DEVE falhar (40001)
cd "$(dirname "$0")/.."

MODO=${1:-sem_protecao}
C=bd2_aluno_postgres
PSQL="docker exec -i $C psql -U bd2 -d matricula -qtA"

case "$MODO" in
  sem_protecao) SCRIPT=scripts/concorrencia/sessao_read_committed.sql; FUNCAO=fn_matricular_sem_protecao ;;
  lock)         SCRIPT=scripts/concorrencia/sessao_read_committed.sql; FUNCAO=fn_matricular_com_lock ;;
  serializable) SCRIPT=scripts/concorrencia/sessao_serializable.sql;   FUNCAO=fn_matricular_sem_protecao ;;
  *) echo "modo inválido: use sem_protecao | lock | serializable"; exit 1 ;;
esac

TURMA=$($PSQL -c "SELECT t.id FROM turma t JOIN periodo_letivo pl ON pl.id = t.periodo_letivo_id
                  WHERE t.codigo = 'TABD-N1' AND pl.ano = 2026 AND pl.semestre = 2")

# Dois alunos elegíveis (TABD no currículo, ativos, ainda não matriculados)
read -r ALUNO_A ALUNO_B <<< "$($PSQL -c "
  SELECT string_agg(id::text, ' ') FROM (
    SELECT a.id
    FROM aluno a
    JOIN curriculo_disciplina cd ON cd.curriculo_id = a.curriculo_id
    JOIN turma t ON t.disciplina_id = cd.disciplina_id
    WHERE t.id = $TURMA AND a.ativo
      AND NOT EXISTS (SELECT 1 FROM matricula m
                      WHERE m.aluno_id = a.id AND m.turma_id = t.id)
    ORDER BY a.id LIMIT 2) s")"

echo "=============================================================="
echo " Demo [$MODO] — TABD-N1 (turma id=$TURMA) · alunos $ALUNO_A e $ALUNO_B"
echo "=============================================================="
$PSQL -c "SELECT fn_demo_reset($TURMA)"
$PSQL -c "SELECT 'Estado inicial: ' || confirmadas || '/' || vagas || ' confirmadas'
          FROM v_vagas_disponiveis WHERE turma_id = $TURMA"
echo ""

OUT_A=$(mktemp); OUT_B=$(mktemp)

docker exec -i $C psql -U bd2 -d matricula \
  -v funcao=$FUNCAO -v aluno="$ALUNO_A" -v turma="$TURMA" -v pausa=4 \
  < "$SCRIPT" > "$OUT_A" 2>&1 &
PID_A=$!
sleep 1
docker exec -i $C psql -U bd2 -d matricula \
  -v funcao=$FUNCAO -v aluno="$ALUNO_B" -v turma="$TURMA" -v pausa=0 \
  < "$SCRIPT" > "$OUT_B" 2>&1
wait $PID_A

echo "--- Sessão A (aluno $ALUNO_A, pausa de 4s na janela crítica):"
cat "$OUT_A"
echo ""
echo "--- Sessão B (aluno $ALUNO_B, sem pausa, entrou 1s depois):"
cat "$OUT_B"
echo ""
$PSQL -c "SELECT 'Estado final: ' || confirmadas || '/' || vagas || ' — ' ||
          CASE WHEN confirmadas > vagas
               THEN 'ANOMALIA! turma estourada (overbooking)'
               ELSE 'limite de vagas respeitado' END
          FROM v_vagas_disponiveis WHERE turma_id = $TURMA"
rm -f "$OUT_A" "$OUT_B"
