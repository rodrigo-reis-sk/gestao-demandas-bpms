"""
Configuração: credenciais, IDs de campos customizados do ClickUp, opções
de dropdown, valores fixos do fluxo "Atendimento Avulso" e o mapeamento
Parceiro -> FAP (reserva manual, usado só se o nome da lista não seguir o
padrão "<Parceiro> <FAP> Avulso").
"""

import os

try:
    from credenciais import CLICKUP_TOKEN, EXPERIENCE_USER, EXPERIENCE_PASS
except ImportError:
    # Fallback: variáveis de ambiente, caso credenciais.py não exista
    CLICKUP_TOKEN = os.environ.get("CLICKUP_TOKEN", "COLE_SEU_TOKEN_AQUI")
    EXPERIENCE_USER = os.environ.get("EXPERIENCE_USER", "COLE_SEU_USUARIO_AQUI")
    EXPERIENCE_PASS = os.environ.get("EXPERIENCE_PASS", "COLE_SUA_SENHA_AQUI")

CLICKUP_API = "https://api.clickup.com/api/v2"
CLICKUP_HEADERS = {"Authorization": CLICKUP_TOKEN}

# IDs de campos customizados (descobertos via GET /task/{id}, lista PMO BP-MS)
FIELD_APONTAMENTO = "e4204a9b-f556-41b4-9da7-87581b594693"
FIELD_EXPERIENCE = "84181300-22c8-4a05-bc56-e236584fcb3b"
FIELD_PARCEIRO = "d993c20b-a9b6-4fd4-bedc-c03b77e15ae5"
FIELD_PERIODO = "3d629467-1fc7-46d6-b925-42afba66df92"
FIELD_USUARIO_CLIENTE = "773bc404-9cb0-4935-80e5-baadda33bf0b"
FIELD_ETAPA = "2bffbedf-89bd-4b12-ba60-dff41f8d3cff"
FIELD_MODULO = "81662e73-38c7-4600-98fa-941625125ee6"

# Opções (option id) dos dropdowns relevantes
APONTAMENTO_OS_EXPERIENCE = "b7821882-acbb-4fc5-9fbd-3a0457721b48"

EXPERIENCE_OPTIONS = {
    "Não lançado": "665e39cf-381c-408b-8753-dcff7636fffd",
    "Lançado": "b4bd00b4-032d-4b2a-9501-762d6b930b8c",
    "Alterar": "dc7b474f-eb2b-4532-a45a-8ff1f1c06398",
    "Lixeira": "da6f4b56-c40b-411a-bd6d-6f6e09968e43",
}
EXPERIENCE_OPTIONS_BY_ID = {v: k for k, v in EXPERIENCE_OPTIONS.items()}

# Status nativo do ClickUp (não é o campo customizado Experience) usado na
# tarefa quando Experience = "Lixeira" -- confirmado via API que existe no
# Space PMO BP-MS (compartilhado entre as listas de todos os parceiros).
STATUS_NAO_EXECUTADO = "não executado"

ETAPA_ATENDIMENTO_AVULSO = "099676dd-040a-4c0c-aea8-4aacd238dfaf"
MODULO_ATENDIMENTO_AVULSO = "b136ff65-14b6-476c-8d91-611f8b19e9b5"

# Valores fixos do fluxo "Atendimento Avulso" no Experience (validados nos testes)
STAGE_ID_AVULSO = 30
PROCESS_ID_AVULSO = 91
PROCEDURE_ID_AVULSO = 1306

# Space "mãe" no ClickUp (PMO BP-MS) -- descobre sozinho todas as pastas de
# parceiros e suas listas dentro dele.
SPACE_ID_PMO_BP_MS = "90133723590"

# Pastas ADMINISTRATIVAS dentro do Space PMO BP-MS -- não são parceiros,
# nunca devem entrar na descoberta de listas nem em nenhuma rodada de
# sincronização (24/08/2026, a pedido do usuário). Comparação por nome
# EXATO da pasta no ClickUp (sem normalização de acento/maiúscula -- os
# três nomes abaixo são os literais confirmados pelo usuário). Ver uso em
# clickup_sync/list_discovery.get_all_lists_in_space, no mesmo lugar onde
# já existia o filtro de pasta começando com "Z" (10/08/2026).
PASTAS_IGNORADAS = {"1-BP-MS", "2- Horas Cruzadas", "3- Planos de Ação"}

# Mapeamento Parceiro (nome no ClickUp) -> FAP (extraído da planilha De-Para).
# Usado só como RESERVA, quando o nome da lista não segue o padrão
# "<Parceiro> <FAP> Avulso" (fonte primária: extrair_fap_do_nome_lista).
# ATENÇÃO: revisar/completar esta lista periodicamente.
PARCEIRO_FAP = {
    "Agrosalles": "31927",
    "BCM": "31863",
    "Biomed SP": "30302",
    "CG Telhas": "28509",
    "Casa da Locacao": "32393",
    "Central Embalagens": "28400",
    "Click TI": "32876",
    "Contrafo": "29307",
    "Energe": "30603",
    "Germipasto": "32221",
    "Guatos": "32363",
    "Lider Soluções": "33241",
    "LPADV": "27568",
    "MS Diagnóstica": "29180",
    "MS Energy": "27553",
    "Neurosoft": "31935",
    "Origem": "33239",
    "Pro-Info": "31826",
    "Projebio": "32720",
    "Projebio": "33621",
    "Semalo": "28371",
    "Soldamaq": "32222",
    "Vo Erminia": "31348",
    "SF-Formas": "27956",
    "Inovvati": "32223",
    "MegaTrucks": "33084",
    "Mix Nutri": "29269",
    "Netcia": "27102",
    "Brasol": "26688",
    "Guri": "32242",
    "Volpini": "30325",
}

# De-Para de consultores: nome como aparece no ClickUp (assignee) -> e-mail
# cadastrado no Experience. Usado quando o nome diverge o suficiente entre
# os dois sistemas (sobrenome diferente, apelido, nome de casada/solteira,
# erro de digitação no cadastro) a ponto de a correspondência automática
# (find_person_id) não conseguir resolver com segurança sozinha.
#
# Verificado primeiro, antes de qualquer tentativa de casamento por nome --
# elimina ambiguidade e deixa o resultado 100% previsível.
#
# Extraído de membros_clickup_experience.xlsx (06/08/2026). Adicione uma
# linha aqui sempre que aparecer um "Aviso: ... não encontrado entre as
# pessoas do projeto" no terminal para alguém que você sabe que está certo,
# só com nome diferente.
CONSULTOR_DE_PARA = {
    "Gilberto Martins da Silva Junior": "gilberto.martins@sankhya.com.br",
    "Iago Proença": "iago.proenca@sankhya.com.br",
    "André Henrique Acunha": "andre.acunha@sankhya.com.br",
    "Einstein": "einstein.franca@sankhya.com.br",
    "Evelym Morinigo": "evelym.cano@sankhya.com.br",
    "Elisangela Ferreira": "elisangela.ferreira@sankhya.com.br",
    "Jean Urban": "jean.urban@sankhya.com.br",
    "Jefferson": "jeferson.alves@sankhya.com.br",
    "Guilherme Espíndola da Rosa": "guilherme.rosa@sankhya.com.br",
    "Elson Afonso Duarte": "elson.duarte@sankhya.com.br",
    "Rodrigo Reis": "rodrigo.reis@sankhya.com.br",
    "LUCAS CARVALHO": "lucas.celestino@sankhya.com.br",
    "Felipe Salles": "felipe.lopes@sankhya.com.br",
    "Airton": "airton.schmitz@sankhya.com.br",
    "Adriano Vilanova": "adriano.araujo@sankhya.com.br",
    "Filipe Paes Capulo": "filipe.capulo@sankhya.com.br",
    "Marcelo Fragoso": "marcelo.fragoso@sankhya.com.br",
}

# De-Para de consultor ESPECÍFICO POR FAP (25/08/2026, a pedido do
# usuário, caso real Soldamaq FAP 31176) -- diferente de CONSULTOR_DE_PARA
# acima (que vale pra qualquer projeto), aqui o nome do ClickUp só é
# traduzido pro e-mail do Experience quando a FAP TAMBÉM bate. Necessário
# porque "BPMS" não é o nome de uma pessoa -- é um assignee genérico do
# ClickUp que pode representar gente diferente em projetos diferentes;
# mapear "BPMS" -> Cleber Nascimento em CONSULTOR_DE_PARA (sem escopo de
# FAP) arriscaria resolver errado se "BPMS" aparecer noutro projeto
# representando outro consultor. Checado ANTES de CONSULTOR_DE_PARA (ver
# sync_engine.py) -- se a FAP da tarefa bater com uma chave aqui E o nome
# do assignee também bater dentro dela, usa o e-mail daqui; senão, cai no
# De-Para global de sempre.
#
# Chave externa: FAP (string, mesmo formato de PARCEIRO_FAP acima).
# Chave interna: nome do assignee como vem do ClickUp -> e-mail no
# Experience.
CONSULTOR_DE_PARA_POR_FAP = {
    "31176": {  # Soldamaq
        "BPMS": "cleber.nascimento@pectecnologia.com.br",  # Cleber Nascimento
    },
    # 29/09/2026 (usuário: "BPMS é vinculado ao consultor
    # cleber.nascimento@pectecnologia.com.br"): demais FAPs da Soldamaq.
    "32222": {  # Soldamaq Avulso
        "BPMS": "cleber.nascimento@pectecnologia.com.br",
    },
    "34033": {  # Soldamaq Avulso (WMS Acompanhamento)
        "BPMS": "cleber.nascimento@pectecnologia.com.br",
    },
}

# Pessoas vinculadas a um projeto no Experience que NÃO são consultores de
# campo (13/08/2026, a pedido do usuário -- "retirar dessa busca por
# lançamentos as pessoas que não são consultores, igual fazemos no
# ClickUp"). Usado por clickup_sync/orphan_check.checar_orfaos pra pular
# essas pessoas na busca de lançamentos por pessoa (get_persons_by_
# implantation traz TODO MUNDO vinculado ao projeto -- consultor, gerente
# de projeto etc. -- sem distinção nenhuma vinda da API; ela até devolve um
# campo "role", mas nunca foi usado nem os valores reais dele foram
# confirmados).
#
# Fonte: coluna "Tipo de Pessoa" de membros_clickup_experience.xlsx
# (atualizada pelo usuário em 13/08/2026 com essa coluna nova -- antes só
# tinha o De-Para de nome/e-mail usado em CONSULTOR_DE_PARA acima). Todo
# mundo com "Tipo de Pessoa" != "Consultor" nessa planilha entra aqui --
# hoje são 3 "Gerente de Projeto": Elson Afonso Duarte, Filipe Paes Capulo
# e o próprio Marcelo Fragoso (usuário deste script, PMO/back-office).
#
# Isso é uma lista NEGATIVA (exclusão), não positiva: só quem está
# CONFIRMADO como não-consultor entra aqui. Ninguém é removido da busca por
# padrão só por não estar em CONSULTOR_DE_PARA -- a planilha de origem
# cobre só as 17 pessoas com nome/e-mail divergente entre ClickUp e
# Experience, não o quadro completo de consultores; tratar isso como lista
# positiva excluiria por engano gente que nunca foi cadastrada aqui.
#
# Comparado por e-mail da Experience (campo "email" de cada pessoa
# devolvida por get_persons_by_implantation), em minúsculas.
#
# Atualize esta lista sempre que a coluna "Tipo de Pessoa" da planilha
# mudar (alguém virou consultor, ou um novo não-consultor passou a
# aparecer vinculado a algum projeto).
PESSOAS_NAO_CONSULTORAS_EMAILS = {
    "elson.duarte@sankhya.com.br",   # Gerente de Projeto
    "filipe.capulo@sankhya.com.br",  # Gerente de Projeto
    "marcelo.fragoso@sankhya.com.br",  # Gerente de Projeto (o próprio usuário)
}

# Roles (papéis) do Experience -- lista completa devolvida por
# GET /roles/type?is_sankhya=true&is_leader=false&has_leader=true&is_investee=false&is_fap_coordinator=false
# (fonte: usuário, 14/08/2026). Reproduzida aqui só como referência --
# ROLES_ID_PERMITIDOS_CHECAGEM abaixo é o que de fato é usado no filtro.
ROLES_EXPERIENCE = {
    12: "Assistente de Serviços",
    68: "Base Service",
    5: "Consultor(a)/Analista",
    67: "Consultor de Sucesso do Cliente",
    10: "Gestor/Coordenador(a) de Serviços",
    63: "Executivo Comercial",
    4: "Gerente/Analista de Projeto",
    66: "Gerente de Relacionamento",
}

# Filtro por role de verdade (14/08/2026, a pedido do usuário -- somar à
# lista negativa manual acima, não substituir): só essas duas entram na
# checagem de lançamentos por pessoa em orphan_check.checar_orfaos --
# "Consultor(a)/Analista" (5) e "Gerente/Analista de Projeto" (4). Usado
# em COMBINAÇÃO com PESSOAS_NAO_CONSULTORAS_EMAILS (as duas camadas
# precisam aprovar a pessoa) -- ver orphan_check._eh_consultor_ou_gp.
# O formato exato do campo "role" devolvido por get_persons_by_implantation
# nunca foi confirmado 100% (só o nome do campo, no docstring de
# persons.py) -- o código de leitura falha ABERTO (mantém a pessoa) se não
# conseguir extrair o id, em vez de excluir por engano.
ROLES_ID_PERMITIDOS_CHECAGEM = {4, 5}
