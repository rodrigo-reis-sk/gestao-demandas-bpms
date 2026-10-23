-- Testes da migração 0003 (listas e tarefas-estrutura). Rodado por rodar.sh depois de 99_testes_fase1.sql.
\set ON_ERROR_STOP 1
\echo '== L1 regras automáticas de listas'
-- uma lista administrativa que tinha ficado "a_analisar" (versão antiga) é corrigida na próxima varredura
insert into clientes_faps (nome_lista, pasta_nome, lista_id_externo, tipo, situacao_sincronizacao)
values ('Comercial', '1-BP-MS', 'LADM', 'outro', 'a_analisar');
select gravar_listas('[
  {"lista_id_externo":"LADM","nome_lista":"Comercial","pasta_nome":"1-BP-MS","tipo":"outro","ativa":true,"administrativa":true},
  {"lista_id_externo":"L2","nome_lista":"BCM 31863 Avulso","pasta_nome":"BCM","fap":"31863","tipo":"avulso","ativa":true,"nome_cliente":"BCM"},
  {"lista_id_externo":"L3","nome_lista":"Cliente Novo 40000 Avulso","pasta_nome":"Cliente Novo","fap":"40000","tipo":"avulso","ativa":true,"nome_cliente":"Cliente Novo"},
  {"lista_id_externo":"L1","nome_lista":"Germipasto 32221 Avulso","pasta_nome":"GERMIPASTO - FC","fap":"32221","tipo":"avulso","ativa":true,"nome_cliente":"Germipasto","sigla_gerente":"FC"},
  {"lista_id_externo":"LZ","nome_lista":"Antiga 22222 Avulso","pasta_nome":"ZGERMISUL","fap":"22222","tipo":"avulso","ativa":false,"nome_cliente":"Antiga"}
]') as resultado;
select lista_id_externo, tipo, situacao_sincronizacao, sugerida, analisada_em is not null as decidida
  from clientes_faps where lista_id_externo in ('LADM','L2','L3','L1','LZ') order by 1;
do $$ begin
  if (select situacao_sincronizacao||'/'||tipo from clientes_faps where lista_id_externo='LADM') <> 'nao_sincronizar/interno' then
    raise exception 'FALHOU: pasta administrativa nao virou nao_sincronizar/interno'; end if;
  if (select analisada_em from clientes_faps where lista_id_externo='LADM') is not null then
    raise exception 'FALHOU: regra automatica contou como decisao do gestor'; end if;
  if not (select sugerida from clientes_faps where lista_id_externo='L2') then
    raise exception 'FALHOU: Avulso de cliente conhecido nao ficou sugerida'; end if;
  if (select sugerida from clientes_faps where lista_id_externo='L3') then
    raise exception 'FALHOU: lista sem cliente identificado ficou sugerida'; end if;
  if (select situacao_sincronizacao from clientes_faps where lista_id_externo='L1') <> 'sincronizar' then
    raise exception 'FALHOU: regra automatica mudou decisao do gestor'; end if;
  if (select co.email from clientes c join consultores co on co.id=c.gerente_projetos_id where c.nome='Germipasto')
     <> 'filipe.capulo@sankhya.com.br' then
    raise exception 'FALHOU: gerente FC nao foi ligado ao cliente'; end if;
  if (select listas_sugeridas from vw_pendencias_gestor) < 1 then raise exception 'FALHOU: contador de sugeridas'; end if;
  raise notice 'ok regras de listas';
end $$;

\echo '== L2 limpeza das tarefas-estrutura (rodando a 0003 de novo)'
insert into tarefas (id_externo, nome, status) values
  ('est1', '1-Atendimento da Base', 'atendimento base'),
  ('est2', '2026-10 Outubro', 'em andamento'),
  ('real1', '2-Serviços', 'em andamento');
\i ../migrations/0003_listas_e_estrutura.sql
do $$ begin
  if (select count(*) from tarefas where id_externo in ('est1','est2') and situacao='ignorada') <> 2 then
    raise exception 'FALHOU: tarefa-estrutura continuou pendente'; end if;
  if (select situacao from tarefas where id_externo='real1') <> 'pendente' then
    raise exception 'FALHOU: tarefa normal foi ignorada'; end if;
  raise notice 'ok limpeza';
end $$;
\echo '== FIM 0003'
