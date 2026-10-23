-- =============================================================================
-- Dados iniciais (gerado a partir do pacote "Lançar ClickUp" em 22/10/2026).
-- Executar DEPOIS de migrations/0001_estrutura_inicial.sql. Pode rodar de novo sem duplicar.
-- Revisar: quem é desenvolvedor e quem deve ser sincronizado. O id_externo de cada consultor
-- é preenchido sozinho na 1ª sincronização de membros, pelo e-mail.
-- FAPs conhecidas entram como "a_analisar": nenhuma lista sincroniza até o gestor marcar.
-- =============================================================================

-- Parâmetros
insert into public.configuracoes (chave, valor, descricao) values
  ('agrupamento', '{"janela_dias": 5, "limiar_sugestao": 40, "limiar_automatico": 85}',
   'Janela em dias e pontuações mínimas para sugerir e para agrupar sozinho'),
  ('sincronizacao', '{"intervalo_minutos": 20, "carga_inicial_dias": 90, "espaco_id": "90133723590"}',
   'Varredura periódica do ClickUp'),
  ('anexos', '{"tamanho_maximo_kb": 5120, "comprimir_para_kb": 300}',
   'Limites dos prints enviados pelos formulários')
on conflict (chave) do nothing;

-- Colunas iniciais do kanban (editáveis na tela de configuração)
insert into public.kanban_colunas (nome, ordem, cor, tipo)
select * from (values
  ('Entrada', 1, '#64748b', 'entrada'),
  ('Em análise', 2, '#7c3aed', 'andamento'),
  ('Em desenvolvimento', 3, '#d97706', 'andamento'),
  ('Aguardando cliente', 4, '#0891b2', 'espera'),
  ('Em homologação', 5, '#2563eb', 'andamento'),
  ('Concluída', 6, '#16a34a', 'concluida'),
  ('Cancelada', 7, '#9ca3af', 'cancelada')
) v(nome, ordem, cor, tipo)
where not exists (select 1 from public.kanban_colunas);

-- Consultores conhecidos (De-Para nome no ClickUp -> e-mail, do pacote legado). sincronizar = false até revisar.
insert into public.consultores (nome, nome_externo, email, papel) values
  ('Gilberto Martins da Silva Junior', 'Gilberto Martins da Silva Junior', 'gilberto.martins@sankhya.com.br', 'consultor'),
  ('Iago Proença', 'Iago Proença', 'iago.proenca@sankhya.com.br', 'consultor'),
  ('André Henrique Acunha', 'André Henrique Acunha', 'andre.acunha@sankhya.com.br', 'consultor'),
  ('Einstein', 'Einstein', 'einstein.franca@sankhya.com.br', 'consultor'),
  ('Evelym Morinigo', 'Evelym Morinigo', 'evelym.cano@sankhya.com.br', 'consultor'),
  ('Elisangela Ferreira', 'Elisangela Ferreira', 'elisangela.ferreira@sankhya.com.br', 'consultor'),
  ('Jean Urban', 'Jean Urban', 'jean.urban@sankhya.com.br', 'consultor'),
  ('Jefferson', 'Jefferson', 'jeferson.alves@sankhya.com.br', 'consultor'),
  ('Guilherme Espíndola da Rosa', 'Guilherme Espíndola da Rosa', 'guilherme.rosa@sankhya.com.br', 'consultor'),
  ('Elson Afonso Duarte', 'Elson Afonso Duarte', 'elson.duarte@sankhya.com.br', 'gerente_projetos'),
  ('Rodrigo Reis', 'Rodrigo Reis', 'reis.c.rodrigo@gmail.com', 'consultor'),
  ('LUCAS CARVALHO', 'LUCAS CARVALHO', 'lucas.celestino@sankhya.com.br', 'consultor'),
  ('Felipe Salles', 'Felipe Salles', 'felipe.lopes@sankhya.com.br', 'consultor'),
  ('Airton', 'Airton', 'airton.schmitz@sankhya.com.br', 'consultor'),
  ('Adriano Vilanova', 'Adriano Vilanova', 'adriano.araujo@sankhya.com.br', 'consultor'),
  ('Filipe Paes Capulo', 'Filipe Paes Capulo', 'filipe.capulo@sankhya.com.br', 'gerente_projetos'),
  ('Marcelo Fragoso', 'Marcelo Fragoso', 'marcelo.fragoso@sankhya.com.br', 'gerente_projetos'),
  ('Cleber Nascimento', 'Cleber Nascimento', 'cleber.nascimento@pectecnologia.com.br', 'consultor')
on conflict (email) do nothing;

-- Conta compartilhada "BPMS": não é uma pessoa e não é cadastrada como consultor.
-- De-para por FAP para a pessoa real (o id da conta é aprendido na 1ª sincronização).
insert into public.responsavel_real_por_fap (nome_externo, fap, consultor_id)
select 'BPMS', f.fap, r.id
from (values ('31176'), ('32222'), ('34033')) f(fap)
join public.consultores r on r.email = 'cleber.nascimento@pectecnologia.com.br'
on conflict (nome_externo, fap) do nothing;

-- Clientes = opções do campo Parceiro no ClickUp (X-Horas Cruzadas e X-Interno ficam de fora: são internos).
insert into public.clientes (nome, parceiro_id_externo) values
  ('Agrosalles', '25f4e223-f214-4893-809f-5c5e7f0f80c2'),
  ('Almont', 'd6a4985d-8564-4052-b5a1-9b51b4af27de'),
  ('Ambient', '50ebb845-bc80-40b8-8b94-4a304a7a6d09'),
  ('Amidos Nevada', '13ac5e6e-db8a-4cc5-af8d-379274cc2736'),
  ('Balcater', 'cee01cb8-7f90-49e9-9378-771d750659bb'),
  ('BCM', 'd5242e85-9b97-4d5d-b8ce-f8acb9571107'),
  ('BioLimp', '744ba06c-2eb7-44bf-812c-a2fcd216aaed'),
  ('Biomed MS', '2123dd58-a58f-4755-b144-13b656938a23'),
  ('Biomed SP', '0713f5ac-e8e0-45ff-aec6-414becb8b4f1'),
  ('Brasol', '68b52525-69a8-4c8e-9024-c1c1a0cfdcd2'),
  ('Central Embalagens', '6a909d84-3e78-4aed-9fa2-6b18e1e7b226'),
  ('CG Telhas', '38ad4792-3907-4efe-9ee9-02dfba3884c4'),
  ('Click TI', '3c7e1a45-3831-4d97-9bdf-d597871dd30e'),
  ('CLM', '66e7bd5c-9217-4dfd-8bd4-208020308352'),
  ('Contrafo', '5eca5f17-3eda-4bb3-a66d-f5c1ffa9bb99'),
  ('DSF', '3dd06eb4-4ac8-4865-8df5-98a3c3807640'),
  ('Energe', 'eba12152-d910-4c06-b1f0-efadeb44661c'),
  ('Germipasto', '65c6af23-8e9d-4e75-a802-6e97de4f9530'),
  ('Germisul', '24df838e-6f31-4e6f-b3cf-3449ad7b357a'),
  ('GP Embalagens', 'f05d588a-a951-42da-97b2-421a67fa317d'),
  ('Grande Aço', '7ce88e3a-5b0c-4e37-b617-151653b7429a'),
  ('Guatos', 'db085a6e-13ca-4686-8328-dc5b264e8034'),
  ('Guri', 'b773134e-ec8c-432e-ac97-2bf6c656dbaa'),
  ('Iccap', '715668d5-1a4b-4617-8f12-878f097b23f3'),
  ('Inovvati', '71acb05c-d83b-4383-acb3-539f7e10af1f'),
  ('Lider Soluções', '5e9f8d5e-971c-4dda-832f-b06d29f62bb9'),
  ('LPADV', '6fa35bbb-6cd2-401d-ba49-6eb06514cb2f'),
  ('Megadrone', '73359cba-a861-47b4-b067-a3f28599b29b'),
  ('MegaTrucks', '3cdbb2b4-e0b9-4c07-a2c8-13ef1db00ea7'),
  ('Mix Nutri', '19283823-2c98-4e5e-9f4a-c2e41c90b1e9'),
  ('MS Diagnóstica', '3d47bf73-ace9-4e6e-864a-e348f6718a76'),
  ('MS Energy', '48d25e32-8d2d-444d-8e2e-4b16b99274bf'),
  ('NEO', 'af6364bd-fc3b-442c-aaec-bec7de5d0c99'),
  ('Netcia', '40e0f8ef-aab2-44f7-8914-a39571847974'),
  ('Neurosoft', '1ed5727a-9e12-455e-9b41-dd97afaf0b99'),
  ('Nfoods', '3e215659-7d83-4780-a348-ce55eea641e7'),
  ('Origem', '0570ca6d-ea4d-4fe2-af3a-3b71086b39d9'),
  ('Perfilferros', '388c54e2-ebb3-4761-9555-9069633598f2'),
  ('Porto Plast', '8c3c3c4c-1b1d-415a-ae63-5aea2b84f609'),
  ('Pro-Info', '41912888-499b-4cf2-a13a-6b08dcc24bfb'),
  ('Projebio', '8111d70f-71a3-4198-a3e4-c5c78c0af64c'),
  ('Projesul', '3de6d5eb-32b9-4bba-8e87-fa63141e5ff0'),
  ('Quimisul', 'b30d864e-6249-4d86-a851-3cd8cfcd395b'),
  ('Semalo', '0a128c94-0f50-442c-a1d5-5b74a4b15222'),
  ('SF-Formas', '8b4f4031-e332-4e0d-9d8d-778d8c4a04aa'),
  ('Soldamaq', '3e9643ca-4039-4a5d-a52c-d0ec4f019d0f'),
  ('Sorpack (HPA)', '02db9030-bcf1-478a-b8c7-12190a32c4a6'),
  ('Toposat', '66343a9d-46e5-46d9-b79a-6bd2bd6ac390'),
  ('Topparfum', '8273680e-f527-48f5-902e-e0f1efbfee6c'),
  ('Vo Erminia', '3058e015-1f6f-4cae-a5c5-c58d5dc1b5be'),
  ('Volpini', '4bfd9844-afea-49eb-811d-eac7f7afef1c')
on conflict (nome) do nothing;

-- Parceiro que tem FAP mas não aparece no dropdown Parceiro do ClickUp (conferir o nome lá).
insert into public.clientes (nome) values ('Casa da Locacao') on conflict (nome) do nothing;

-- FAPs conhecidas (tabela de reserva do pacote legado). A sincronização completa as demais pelo nome da lista.
insert into public.clientes_faps (cliente_id, fap, tipo)
select c.id, v.fap, 'avulso'
from (values
  ('Agrosalles', '31927'),
  ('BCM', '31863'),
  ('Biomed SP', '30302'),
  ('CG Telhas', '28509'),
  ('Casa da Locacao', '32393'),
  ('Central Embalagens', '28400'),
  ('Click TI', '32876'),
  ('Contrafo', '29307'),
  ('Energe', '30603'),
  ('Germipasto', '32221'),
  ('Guatos', '32363'),
  ('Lider Soluções', '33241'),
  ('LPADV', '27568'),
  ('MS Diagnóstica', '29180'),
  ('MS Energy', '27553'),
  ('Neurosoft', '31935'),
  ('Origem', '33239'),
  ('Pro-Info', '31826'),
  ('Projebio', '32720'),
  ('Projebio', '33621'),
  ('Semalo', '28371'),
  ('Soldamaq', '32222'),
  ('Vo Erminia', '31348'),
  ('SF-Formas', '27956'),
  ('Inovvati', '32223'),
  ('MegaTrucks', '33084'),
  ('Mix Nutri', '29269'),
  ('Netcia', '27102'),
  ('Brasol', '26688'),
  ('Guri', '32242'),
  ('Volpini', '30325')
) v(cliente, fap)
join public.clientes c on c.nome = v.cliente
where not exists (select 1 from public.clientes_faps f
                  where f.cliente_id = c.id and f.fap = v.fap and f.tipo = 'avulso');
