-- Confere que a saída da tradução das Edge Functions (gerada por funcoes.test.ts) é aceita
-- pela função do banco. Rodado por rodar.sh só quando o Deno está instalado.
\set ON_ERROR_STOP 1
\set tarefas `cat .saida_tarefa.json`
\echo '== I1 tarefa traduzida grava no banco'
select gravar_tarefas('clickup', :'tarefas'::jsonb) - 'novas_ids' as resultado;
do $$ begin
  if not exists (select 1 from tarefas where id_externo='86abc123' and minutos_periodo=120 and minutos_registrados=90
                   and detalhamento='Detalhe do campo' and cliente_id=(select id from clientes where nome='Germipasto')
                   and fap_id is not null) then
    raise exception 'FALHOU: tarefa traduzida nao gravou como esperado'; end if;
  raise notice 'ok traducao → banco';
end $$;
