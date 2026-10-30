#!/usr/bin/env bash
# Testa as migrações e o seed num Postgres 16 local (simula o mínimo do Supabase).
# Uso: bash supabase/testes/rodar.sh        (variáveis PGHOST/PGUSER/PGPASSWORD se precisar)
# Cria e apaga o banco "teste_bpms". Nunca rode contra o Supabase de produção.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$DIR/.."
dropdb --if-exists teste_bpms && createdb teste_bpms
for f in "$DIR/00_supabase_simulado.sql" \
         "$RAIZ/migrations/0001_estrutura_inicial.sql" \
         "$RAIZ/migrations/0002_sincronizacao.sql" \
         "$RAIZ/migrations/0003_listas_e_estrutura.sql" \
         "$RAIZ/migrations/0004_demandas_e_agendas.sql" \
         "$RAIZ/migrations/0005_ajustes_hierarquia.sql" \
         "$RAIZ/migrations/0006_hierarquia_robusta.sql" \
         "$RAIZ/migrations/0007_tela_unica.sql" \
         "$RAIZ/migrations/0008_correcoes_validacao.sql" \
         "$RAIZ/migrations/0009_chamados.sql" \
         "$RAIZ/migrations/0010_portal.sql" \
         "$RAIZ/migrations/0011_criacao_tarefa.sql" \
         "$RAIZ/migrations/0012_relatorio_e_consultor.sql" \
         "$RAIZ/migrations/0013_acessos.sql" \
         "$RAIZ/migrations/0014_pessoas_acompanhadas.sql" \
         "$RAIZ/seed.sql" "$RAIZ/seed.sql" \
         "$DIR/99_testes.sql" "$DIR/99_testes_fase1.sql" "$DIR/99_testes_0003.sql" "$DIR/99_testes_0004.sql" "$DIR/99_testes_0005.sql" "$DIR/99_testes_0006.sql" "$DIR/99_testes_0007.sql" "$DIR/99_testes_0008.sql" "$DIR/99_testes_0009.sql" "$DIR/99_testes_0010.sql" "$DIR/99_testes_0011.sql" "$DIR/99_testes_0012.sql" "$DIR/99_testes_0013.sql" "$DIR/99_testes_0014.sql"; do
  echo "### $(basename "$f")"
  (cd "$DIR" && psql -q -v ON_ERROR_STOP=1 -d teste_bpms -f "$f")
done
# Edge Functions: testes de tradução e do cliente da API (precisa do Deno)
if command -v deno >/dev/null; then
  echo "### funcoes.test.ts, formulario.test.ts e criacao.test.ts"
  (cd "$RAIZ/.." && deno test -q --allow-write=supabase/testes --allow-env=CLICKUP_TEAM_ID supabase/testes/funcoes.test.ts supabase/testes/formulario.test.ts supabase/testes/criacao.test.ts supabase/testes/acessos.test.ts supabase/testes/consulta.test.ts)
  echo "### 99_testes_traducao.sql"
  (cd "$DIR" && psql -q -v ON_ERROR_STOP=1 -d teste_bpms -f 99_testes_traducao.sql)
else
  echo "(Deno não instalado: testes das Edge Functions pulados)"
fi
