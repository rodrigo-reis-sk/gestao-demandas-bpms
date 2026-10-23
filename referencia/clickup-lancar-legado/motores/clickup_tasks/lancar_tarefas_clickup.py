import sys
import os
import datetime
import locale
import requests
import unicodedata
import json
import re
import time

# 1. Configurações e Autenticação
pasta_raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(pasta_raiz)

import credenciais
from clickup_sync.config import (
    CLICKUP_API, 
    CLICKUP_HEADERS,
    SPACE_ID_PMO_BP_MS,
    FIELD_ETAPA,
    FIELD_USUARIO_CLIENTE,
    FIELD_PARCEIRO,
    FIELD_MODULO,
    ETAPA_ATENDIMENTO_AVULSO,
    MODULO_ATENDIMENTO_AVULSO
)
from clickup_sync.list_discovery import get_all_lists_in_space
from clickup_sync.clickup_client import request_com_retry

# 2. Constantes e Mapeamento de Custom Fields
FIELD_AGENDA = "af3cf86c-a293-4d1c-9916-180ad84f0a7b"
AGENDA_REMOTO = "4e86dc7c-63fa-4bed-9d2d-5916a49dc896"

FIELD_APONTAMENTO = "e4204a9b-f556-41b4-9da7-87581b594693"
APONTAMENTO_OS_EXPERIENCE = "b7821882-acbb-4fc5-9fbd-3a0457721b48"

FIELD_DETALHAMENTO = "e74bba2f-032d-4e2e-8f37-ec19011312c0"
FIELD_ORIGEM = "a194dde3-5aca-4df7-9f94-d6a6f52fee85" 

OPCOES_ORIGEM = {
    'Whatsapp': 'ea52b08c-1678-466a-82ff-83e04f444f95',
    'E-mail': 'd1001cfa-f806-4de8-a7f8-a38103d886a9',
    'PMO': '5e6751db-5302-411b-8660-afe1f7857a06',
    'Service Desk': '1faf8fbe-33d5-4959-af7b-2ef0f0409eb9',
    'Sucesso do Cliente': '06101ce4-a9e1-44f9-8847-603ec8dc4634',
    'Consultor': 'f6008801-6cfb-492a-b6e6-3861f46f8039'
}

OPCOES_PARCEIRO = {
    'Agrosalles': '25f4e223-f214-4893-809f-5c5e7f0f80c2', 'Almont': 'd6a4985d-8564-4052-b5a1-9b51b4af27de',
    'Ambient': '50ebb845-bc80-40b8-8b94-4a304a7a6d09', 'Amidos Nevada': '13ac5e6e-db8a-4cc5-af8d-379274cc2736',
    'Balcater': 'cee01cb8-7f90-49e9-9378-771d750659bb', 'BCM': 'd5242e85-9b97-4d5d-b8ce-f8acb9571107',
    'BioLimp': '744ba06c-2eb7-44bf-812c-a2fcd216aaed', 'Biomed MS': '2123dd58-a58f-4755-b144-13b656938a23',
    'Biomed SP': '0713f5ac-e8e0-45ff-aec6-414becb8b4f1', 'Brasol': '68b52525-69a8-4c8e-9024-c1c1a0cfdcd2',
    'Central Embalagens': '6a909d84-3e78-4aed-9fa2-6b18e1e7b226', 'CG Telhas': '38ad4792-3907-4efe-9ee9-02dfba3884c4',
    'Click TI': '3c7e1a45-3831-4d97-9bdf-d597871dd30e', 'CLM': '66e7bd5c-9217-4dfd-8bd4-208020308352',
    'Contrafo': '5eca5f17-3eda-4bb3-a66d-f5c1ffa9bb99', 'DSF': '3dd06eb4-4ac8-4865-8df5-98a3c3807640',
    'Energe': 'eba12152-d910-4c06-b1f0-efadeb44661c', 'Germipasto': '65c6af23-8e9d-4e75-a802-6e97de4f9530',
    'Germisul': '24df838e-6f31-4e6f-b3cf-3449ad7b357a', 'GP Embalagens': 'f05d588a-a951-42da-97b2-421a67fa317d',
    'Grande Aço': '7ce88e3a-5b0c-4e37-b617-151653b7429a', 'Guatos': 'db085a6e-13ca-4686-8328-dc5b264e8034',
    'Guri': 'b773134e-ec8c-432e-ac97-2bf6c656dbaa', 'Iccap': '715668d5-1a4b-4617-8f12-878f097b23f3',
    'Inovvati': '71acb05c-d83b-4383-acb3-539f7e10af1f', 'Lider Soluções': '5e9f8d5e-971c-4dda-832f-b06d29f62bb9',
    'LPADV': '6fa35bbb-6cd2-401d-ba49-6eb06514cb2f', 'Megadrone': '73359cba-a861-47b4-b067-a3f28599b29b',
    'MegaTrucks': '3cdbb2b4-e0b9-4c07-a2c8-13ef1db00ea7', 'Mix Nutri': '19283823-2c98-4e5e-9f4a-c2e41c90b1e9',
    'MS Diagnóstica': '3d47bf73-ace9-4e6e-864a-e348f6718a76', 'MS Energy': '48d25e32-8d2d-444d-8e2e-4b16b99274bf',
    'NEO': 'af6364bd-fc3b-442c-aaec-bec7de5d0c99', 'Netcia': '40e0f8ef-aab2-44f7-8914-a39571847974',
    'Neurosoft': '1ed5727a-9e12-455e-9b41-dd97afaf0b99', 'Nfoods': '3e215659-7d83-4780-a348-ce55eea641e7',
    'Origem': '0570ca6d-ea4d-4fe2-af3a-3b71086b39d9', 'Perfilferros': '388c54e2-ebb3-4761-9555-9069633598f2',
    'Porto Plast': '8c3c3c4c-1b1d-415a-ae63-5aea2b84f609', 'Pro-Info': '41912888-499b-4cf2-a13a-6b08dcc24bfb',
    'Projebio': '8111d70f-71a3-4198-a3e4-c5c78c0af64c', 'Projesul': '3de6d5eb-32b9-4bba-8e87-fa63141e5ff0',
    'Quimisul': 'b30d864e-6249-4d86-a851-3cd8cfcd395b', 'Semalo': '0a128c94-0f50-442c-a1d5-5b74a4b15222',
    'SF-Formas': '8b4f4031-e332-4e0d-9d8d-778d8c4a04aa', 'Soldamaq': '3e9643ca-4039-4a5d-a52c-d0ec4f019d0f',
    'Sorpack (HPA)': '02db9030-bcf1-478a-b8c7-12190a32c4a6', 'Toposat': '66343a9d-46e5-46d9-b79a-6bd2bd6ac390',
    'Topparfum': '8273680e-f527-48f5-902e-e0f1efbfee6c', 'Vo Erminia': '3058e015-1f6f-4cae-a5c5-c58d5dc1b5be',
    'Volpini': '4bfd9844-afea-49eb-811d-eac7f7afef1c', 'X-Horas Cruzadas': '8e04b0eb-e792-4b18-9d7b-f44118638350',
    'X-Interno': '59151650-bfd0-4730-a947-72e4daf22bcb'
}

# Quando a demanda tiver data de vencimento, em qual subtarefa mensal ela entra?
#   False -> sempre no mês corrente (comportamento atual)
#   True  -> no mês da data de vencimento (ex.: lançada em 28/09, vence 03/10 -> "2026-10 Outubro")
MES_PELA_DATA_VENCIMENTO = True

# Cache local dos membros do workspace (Responsável/Consultor)
ARQUIVO_CACHE_MEMBROS = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'membros_cache.json')

# Período (dropdown) — opções copiadas do ClickUp em 30/09/2026. Se criarem opção nova lá, acrescentar aqui.
FIELD_PERIODO = "3d629467-1fc7-46d6-b925-42afba66df92"
OPCOES_PERIODO = {
    '05h-08h': '0fc2a69e-2f71-4042-bfb1-e43acdb445b9', '06h-07h': '06120584-93d4-4435-a90d-e78ba5e890a3', '06h-08h': 'ed939305-a7fa-4b7d-8ca1-96e9abaca3de',
    '06h-09h': '2a8591f8-2e0a-4d6c-a00c-4aab71f76e17', '06h-12h': 'db828a2b-532c-408e-baf3-1307445841e3', '07h-08h': 'da161a8b-8dd2-4f2a-a04c-5eb293d64931',
    '07h-09h': '08f8568c-5ab5-43d6-8ef4-4c0e31d9e2ab', '07h-11h': '45d8cc8e-e8d3-42e8-ac31-e7f82280eb46', '07h-15h': 'ff24fab9-0b69-4978-8aa7-8c116787cbee',
    '07h-17h': '15c19f67-0231-4d57-a588-3d7b9678b57c', '08h-09h': '0aeaee07-1acc-49dd-9b91-a7ae6375b854', '08h-10h': '1192005b-c2b8-44b1-bca2-758779ecda3b',
    '08h-11h': 'dfa0da08-b756-403f-a5f2-38ea4356889d', '08h-12h': '69521ca7-d9ce-4614-8032-4913ff3b791c', '08h-15h': '2790f3b6-c8dc-416f-8b79-53888bc514e7',
    '08h-16h': '783aabeb-d5ea-4d3a-bdd6-7ec17e08c254', '08h-17h': '1ac6020c-4d46-43ff-aedd-2baa33358ef3', '08h-18h': '77fcac6d-8cd5-4579-adee-96c99b86c2f4',
    '09h-10h': 'ac73021d-55b0-4b28-9219-1eec313e1bb4', '09h-11h': 'edb6229e-3211-4fa6-9a9a-e468ff304dc5', '09h-12h': 'c508319e-b088-4025-94bb-101fe56ad71c',
    '09h-13h': '3c71c702-0235-4bf3-b93b-3be435cb874e', '09h-15h': '5681cdf4-6332-4006-94b5-1d50d4b1467e', '09h-16h': 'f7db4846-fa19-4b17-94f1-7a8f2bf4cc60',
    '09h-17h': '89bd8c5b-3198-435f-87a8-1c37c4e42597', '09h-18h': 'e0487312-9def-4b3f-8879-9f6e8a444f13', '10h-11h': '0ca053e8-6473-41de-aa92-e8bada97cc94',
    '10h-12h': '449ba90b-d575-4a98-bdcd-79310e16a73a', '10h-13h': '4cf9d94d-2f90-419f-8317-85e196ac1ff1', '10h-15h': 'c009bc6b-5e0e-4dec-b5cd-c484538cf925',
    '10h-16h': 'a395cf66-3ae8-4852-b496-f77f9b3b9a48', '10h-17h': '1b945365-1c5b-4a5d-906f-6bebe3128a87', '10h-18h': '0590e913-594d-4b53-9e7b-e0b0062df534',
    '11h-12h': '33c4483c-0f21-4ea2-a899-5db34cf81e1f', '11h-14h': 'd881154c-455d-4a6b-9117-7a80ec7f9457', '11h-16h': '671598ad-3df6-4dd9-9479-4b161156feb9',
    '11h-18h': 'e2924368-1d37-4147-87d7-91c721448ca8', '12h-13h': 'df786498-ca26-43c1-a8f0-95c7bbcd693b', '12h-14h': 'd953c851-9338-49b8-bdcf-ebc5af1c253b',
    '12h-18h': 'aaa77b65-9879-4587-bdc8-5437ad468f27', '13h-14h': '3f660701-f6d5-4543-bef1-4ecf45314d01', '13h-15h': 'fc2da5d0-4caa-487e-ab92-47d5188993ee',
    '13h-16h': 'ffefda9d-c4db-40aa-9ad1-51449e07e05d', '13h-17h': '0ee1b5d3-e823-4a1d-b688-87fac4e8c4ed', '14h-15h': '2f09befe-216b-4068-b1c1-4e1c2267b9d8',
    '14h-16h': '0de81654-d96f-4cb9-a245-565c816a36a2', '14h-17h': '9c413d51-03e8-4dc3-9982-ecd7a710f830', '14h-18h': '4dde7ed0-2a9b-44b0-8475-708705ea065d',
    '14h-22h': '6fdeb6c1-c6ab-440c-82ad-5283e6d4276f', '15h-16h': 'deb426e0-a03a-40bf-9fb9-942754ec4dbf', '15h-17h': '4c7d8dca-9f7b-49f0-a50f-3ce4ae142480',
    '15h-18h': '9de9241f-132d-4b67-b1b1-774767062d17', '16h-17h': '15654209-2bc4-4475-a76a-1d71a5d592c9', '16h-18h': 'bbb03ee2-168b-47a8-87e2-0d04f1e40749',
    '17h-18h': '73929e9e-88d3-4d57-8861-530952b59179', '18h-19h': '66cf9a40-6c3b-4377-9a91-d7763c5c0d58', '18h-20h': '614933fc-95bf-4f2a-8726-73da7427190d',
    '18h-21h': '75bdcfc1-dd9f-4c7b-b2fe-e7f75a326b18', '18h-22h': 'f5f6855b-6070-4212-9e39-9fe120033a66', '19h-20h': '20b8a70d-d5b0-46a5-8e52-f891e022564c',
    '19h-21h': '4507472d-1efb-48cb-b2c6-585bc483b878', '19h-22h': '054c0e68-7e47-4dc1-b94b-b7a76166fc5b', '20h-21h': '8656a8bf-1d92-4e5b-a857-c7ea48d6ad43',
    '21h-22h': '6f90354f-05bd-4a1b-9406-d7c406d9d636', '22h-23h': 'b73de0dc-e256-4c3b-a030-68400cb2b694', 'Feriado': '147e713a-287e-436c-ba7a-e09921fb01fa',
    'Férias': 'a0f6f880-8173-46fd-b4f8-6459938dd2e3', 'Madrugada': '18e5669b-98c9-401e-9fed-c613007105e7', 'Vários': '7c189a08-0a4f-418d-b29f-32d6426a327b',
}

def interpretar_periodo(texto):
    """Aceita '08h-10h', '8h as 10h', '8 às 10', '08:00-10:00', 'feriado'... e devolve a opção oficial (ou None)."""
    if not texto or not texto.strip():
        return None
    t = remover_acentos(texto).lower().strip()
    for nome in OPCOES_PERIODO:
        if remover_acentos(nome).lower() == t:
            return nome
    horas = re.findall(r'(\d{1,2})\s*(?:[:h]\s*(\d{2}))?', t)
    if len(horas) >= 2:
        if any(m not in ("", "00") for _, m in horas[:2]):
            return None   # horário quebrado (ex.: 9h30): não arredonda, usuário escolhe
        candidato = f"{int(horas[0][0]):02d}h-{int(horas[1][0]):02d}h"
        if candidato in OPCOES_PERIODO:
            return candidato
    return None

# 3. Funções Principais
MESES_PT = {
    1: "Janeiro", 2: "Fevereiro", 3: "Março", 4: "Abril",
    5: "Maio", 6: "Junho", 7: "Julho", 8: "Agosto",
    9: "Setembro", 10: "Outubro", 11: "Novembro", 12: "Dezembro"
}

def gerar_nome_mes_atual(data_ref=None):
    """Nome da subtarefa mensal no padrão 'AAAA-MM Mês'. Sem data_ref, usa hoje."""
    ref = data_ref or datetime.date.today()
    return f"{ref.strftime('%Y-%m')} {MESES_PT[ref.month]}"

def data_para_ms(data):
    """Converte date em timestamp (ms) ao meio-dia local, evitando que o fuso jogue o dia para trás."""
    dt = datetime.datetime(data.year, data.month, data.day, 12, 0, 0)
    return int(dt.timestamp() * 1000)

def listar_membros_workspace():
    """Busca os membros do workspace no ClickUp. Retorna lista de dicts {id, nome, email}."""
    resp = request_com_retry(lambda: requests.get(f"{CLICKUP_API}/team", headers=CLICKUP_HEADERS))
    if resp is None or resp.status_code != 200:
        raise Exception("Não foi possível buscar os membros do workspace no ClickUp.")

    membros = {}
    for team in resp.json().get('teams', []):
        for m in team.get('members', []):
            u = m.get('user') or {}
            if not u.get('id'):
                continue
            nome = (u.get('username') or u.get('email') or '').strip()
            if nome:
                membros[u['id']] = {'id': u['id'], 'nome': nome, 'email': u.get('email', '')}

    # Nomes repetidos ganham o e-mail entre parênteses para não confundir
    contagem = {}
    for m in membros.values():
        contagem[m['nome'].lower()] = contagem.get(m['nome'].lower(), 0) + 1
    for m in membros.values():
        if contagem[m['nome'].lower()] > 1 and m['email']:
            m['nome'] = f"{m['nome']} ({m['email']})"

    return sorted(membros.values(), key=lambda x: remover_acentos(x['nome']).lower())

def carregar_membros_cache():
    try:
        with open(ARQUIVO_CACHE_MEMBROS, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return []

def salvar_membros_cache(membros):
    try:
        with open(ARQUIVO_CACHE_MEMBROS, 'w', encoding='utf-8') as f:
            json.dump(membros, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"Erro ao salvar cache de membros: {e}")

def remover_acentos(texto):
    """Remove acentos e cedilhas para não haver conflito de nomes."""
    if not texto: return ""
    return ''.join(c for c in unicodedata.normalize('NFD', texto) if unicodedata.category(c) != 'Mn')

# ---------------------------------------------------------------
# FAPs (listas "Avulso") do parceiro
# ---------------------------------------------------------------
# Regras:
#  - Só entram listas com "avulso" no nome e que NÃO começam com "Z" (Z = FAP encerrada).
#  - O nome da pasta também conta (ex.: parceiro "Pro-Info" x lista "Por-Info ... Avulso" na pasta "PRO-INFO").
#  - Palavra no nome da lista pesa mais que palavra no nome da pasta, e fica só o grupo de maior
#    pontuação (ex.: "Biomed MS" fica com "Biomed/MS ..." e descarta "Biomed/SP ...").
#  - Se sobrar mais de uma FAP (ex.: Amidos 32699 x Amidos 30930 Great Nature), quem escolhe é o usuário.
PALAVRAS_IGNORADAS = {"de", "da", "do", "das", "dos", "e", "a", "o", "em", "para", "avulso"}
TEMPO_CACHE_LISTAS = 600  # segundos
_cache_listas = {"ts": 0, "dados": None}

def _tokens(texto):
    partes = re.split(r'[^a-z0-9]+', remover_acentos(texto or "").lower())
    return [t for t in partes if t and not t.isdigit() and t not in PALAVRAS_IGNORADAS]

def _lista_ativa_avulso(nome):
    n = remover_acentos(nome or "").lower().strip()
    return "avulso" in n and not n.startswith("z")

def carregar_listas_avulso(forcar=False):
    """Lê pastas + listas do espaço PMO BP-MS (com cache de 10 min). Retorna [{id, nome, pasta}]."""
    agora = time.time()
    if not forcar and _cache_listas["dados"] is not None and agora - _cache_listas["ts"] < TEMPO_CACHE_LISTAS:
        return _cache_listas["dados"]

    listas = []
    resp = request_com_retry(lambda: requests.get(
        f"{CLICKUP_API}/space/{SPACE_ID_PMO_BP_MS}/folder?archived=false", headers=CLICKUP_HEADERS))
    if resp is not None and resp.status_code == 200:
        for pasta in resp.json().get("folders", []):
            for l in pasta.get("lists", []):
                listas.append({"id": str(l["id"]), "nome": l["name"], "pasta": pasta.get("name", "")})
        resp2 = request_com_retry(lambda: requests.get(
            f"{CLICKUP_API}/space/{SPACE_ID_PMO_BP_MS}/list?archived=false", headers=CLICKUP_HEADERS))
        if resp2 is not None and resp2.status_code == 200:
            for l in resp2.json().get("lists", []):
                listas.append({"id": str(l["id"]), "nome": l["name"], "pasta": ""})
    else:
        # Plano B: função antiga do clickup_sync
        for l in get_all_lists_in_space(SPACE_ID_PMO_BP_MS) or []:
            pasta = (l.get("folder") or {}).get("name", "") if isinstance(l.get("folder"), dict) else ""
            listas.append({"id": str(l["id"]), "nome": l["name"], "pasta": pasta})

    if not listas:
        raise Exception("Não foi possível ler as listas do espaço PMO BP-MS no ClickUp.")

    ativas = [l for l in listas if _lista_ativa_avulso(l["nome"])]
    _cache_listas.update(ts=agora, dados=ativas)
    return ativas

def selecionar_faps(nome_parceiro, listas):
    """Filtra, dentre as listas avulso ativas, as FAPs do parceiro (lógica pura, testável)."""
    tp = _tokens(nome_parceiro)
    if not tp:
        return []
    principal = tp[0]           # 1ª palavra do parceiro precisa aparecer na lista ou na pasta
    tp_set = set(tp)
    candidatos = []
    for l in listas:
        tl, tf = set(_tokens(l["nome"])), set(_tokens(l["pasta"]))
        if principal not in (tl | tf):
            continue
        pontos = 10 * len(tp_set & tl) + len(tp_set & tf)
        candidatos.append((pontos, l))
    if not candidatos:
        return []
    maior = max(p for p, _ in candidatos)
    return sorted([l for p, l in candidatos if p == maior], key=lambda x: remover_acentos(x["nome"]).lower())

def listar_faps_do_parceiro(nome_parceiro, forcar=False):
    return selecionar_faps(nome_parceiro, carregar_listas_avulso(forcar))

def obter_lista_do_parceiro(nome_parceiro):
    """Compatibilidade: devolve o ID só quando existe UMA FAP. Com várias, exige escolha explícita."""
    faps = listar_faps_do_parceiro(nome_parceiro)
    if len(faps) == 1:
        return faps[0]["id"]
    if len(faps) > 1:
        nomes = "\n - ".join(f["nome"] for f in faps)
        raise Exception(f"O parceiro '{nome_parceiro}' tem mais de uma FAP avulso ativa. "
                        f"Escolha a FAP no lançamento:\n - {nomes}")
    return None

# ---------------------------------------------------------------
# Acesso do responsável à pasta do parceiro
# ---------------------------------------------------------------
# Se o responsável não tiver acesso à FAP, compartilha a PASTA do parceiro com ele como
# "Apenas exibição" (permission_level 1) via API v3 do ClickUp, antes de criar a tarefa.
# Nunca rebaixa quem já tem acesso: se já aparece como membro da lista, não mexe.
PERMISSAO_APENAS_EXIBICAO = 1
CLICKUP_API_V3 = (CLICKUP_API.replace("/api/v2", "/api/v3")
                  if "/api/v2" in CLICKUP_API else "https://api.clickup.com/api/v3")
_cache_workspace = {"id": None}

def obter_workspace_id():
    if _cache_workspace["id"]:
        return _cache_workspace["id"]
    resp = request_com_retry(lambda: requests.get(f"{CLICKUP_API}/team", headers=CLICKUP_HEADERS))
    if resp is None or resp.status_code != 200 or not resp.json().get("teams"):
        raise Exception("Não foi possível identificar o workspace do ClickUp.")
    _cache_workspace["id"] = str(resp.json()["teams"][0]["id"])
    return _cache_workspace["id"]

def membros_da_lista(list_id):
    """IDs de quem tem acesso à lista. None se não conseguiu consultar."""
    resp = request_com_retry(lambda: requests.get(f"{CLICKUP_API}/list/{list_id}/member", headers=CLICKUP_HEADERS))
    if resp is None or resp.status_code != 200:
        return None
    return {int(m["id"]) for m in resp.json().get("members", []) if m.get("id") is not None}

def local_de_compartilhamento(list_id):
    """Pasta da lista (o que aparece em 'Compartilhar Esta Pasta'). Lista solta -> a própria lista."""
    resp = request_com_retry(lambda: requests.get(f"{CLICKUP_API}/list/{list_id}", headers=CLICKUP_HEADERS))
    if resp is not None and resp.status_code == 200:
        pasta = resp.json().get("folder") or {}
        if pasta.get("id") and not pasta.get("hidden"):
            return "folder", str(pasta["id"]), pasta.get("name", "")
    return "list", str(list_id), ""

def garantir_acesso_responsavel(list_id, user_id, avisos=None):
    """Garante que o responsável enxergue a FAP. Retorna True se precisou liberar acesso."""
    avisos = avisos if avisos is not None else []
    user_id = int(user_id)

    membros = membros_da_lista(list_id)
    if membros is None:
        avisos.append("Não consegui conferir o acesso do responsável à pasta; a tarefa foi lançada assim mesmo.")
        return False
    if user_id in membros:
        return False

    tipo, obj_id, nome_pasta = local_de_compartilhamento(list_id)
    url = f"{CLICKUP_API_V3}/workspaces/{obter_workspace_id()}/{tipo}/{obj_id}/acls"
    corpo = {"entries": [{"kind": "user", "id": str(user_id), "permission_level": PERMISSAO_APENAS_EXIBICAO}]}
    resp = request_com_retry(lambda: requests.patch(url, json=corpo, headers=CLICKUP_HEADERS))

    if resp is None or resp.status_code not in (200, 201, 204):
        detalhe = f"Status {resp.status_code}: {resp.text[:300]}" if resp is not None else "sem resposta"
        raise Exception(
            "O responsável não tem acesso à pasta do parceiro e não consegui liberar automaticamente "
            f"({detalhe}).\n\nLibere manualmente em 'Compartilhar Esta Pasta' ou lance sem responsável.")

    alvo = f"pasta '{nome_pasta}'" if tipo == "folder" else "lista"
    avisos.append(f"Acesso 'Apenas exibição' liberado para o responsável na {alvo}.")
    return True

def obter_ou_criar_tarefa_base(list_id, uuid_parceiro):
    """Encontra a tarefa raiz ('1-Atendimento Base'). Se não existir, cria!"""
    resp = request_com_retry(lambda: requests.get(f"{CLICKUP_API}/list/{list_id}/task", headers=CLICKUP_HEADERS))
    
    if resp is not None and resp.status_code == 200:
        for t in resp.json().get('tasks', []):
            nome_tarefa = t.get('name', '').upper()
            if "1-ATENDIMENTO" in nome_tarefa or "1 - ATENDIMENTO" in nome_tarefa:
                return t['id']
                
    print("Tarefa '1-Atendimento Base' não encontrada. Criando estrutura base...")
    payload_criacao = {
        "name": "1-Atendimento Base",
        "status": "em andamento", 
        "custom_fields": []
    }
    
    if uuid_parceiro:
        payload_criacao["custom_fields"].append({"id": FIELD_PARCEIRO, "value": uuid_parceiro})
        
    resp_post = request_com_retry(lambda: requests.post(f"{CLICKUP_API}/list/{list_id}/task", json=payload_criacao, headers=CLICKUP_HEADERS))
    
    if resp_post is not None and resp_post.status_code in (200, 201):
        novo_id = resp_post.json().get('id')
        print(f"Tarefa '1-Atendimento Base' criada com sucesso (ID: {novo_id}).")
        return novo_id
        
    return None

def obter_ou_criar_subtarefa_mensal(list_id, parent_task_id, nome_mes, uuid_parceiro):
    url_get = f"{CLICKUP_API}/list/{list_id}/task?subtasks=true"
    resp_get = request_com_retry(lambda: requests.get(url_get, headers=CLICKUP_HEADERS))
    
    tarefa_mensal_id = None
    if resp_get is not None and resp_get.status_code == 200:
        for t in resp_get.json().get('tasks', []):
            if t.get('name') == nome_mes and t.get('parent') == parent_task_id:
                tarefa_mensal_id = t['id']
                break
                
    if not tarefa_mensal_id:
        payload_criacao = {
            "name": nome_mes, 
            "parent": parent_task_id,
            "status": "em andamento",
            "custom_fields": []
        }
        if uuid_parceiro:
            payload_criacao["custom_fields"].append({"id": FIELD_PARCEIRO, "value": uuid_parceiro})
            
        resp_post = request_com_retry(lambda: requests.post(f"{CLICKUP_API}/list/{list_id}/task", json=payload_criacao, headers=CLICKUP_HEADERS))
        
        if resp_post is not None and resp_post.status_code in (200, 201):
            tarefa_mensal_id = resp_post.json().get('id')
        else:
            raise Exception("Não foi possível criar a subtarefa do mês. Verifique as permissões.")
    else:
        request_com_retry(lambda: requests.put(f"{CLICKUP_API}/task/{tarefa_mensal_id}", json={"status": "em andamento"}, headers=CLICKUP_HEADERS))
        if uuid_parceiro:
            request_com_retry(lambda: requests.post(f"{CLICKUP_API}/task/{tarefa_mensal_id}/field/{FIELD_PARCEIRO}", json={"value": uuid_parceiro}, headers=CLICKUP_HEADERS))

    return tarefa_mensal_id

def criar_demanda_padrao(titulo, detalhamento, parceiro, usuario_cliente, origem=None,
                         responsavel_id=None, data_vencimento=None, list_id=None, avisos=None,
                         periodo=None):
    """
    list_id        : ID da FAP (lista Avulso) escolhida. None = descobre sozinho (só funciona com 1 FAP).
    periodo        : opção do campo Período (ex.: '08h-10h'). None = não preenche.
    avisos         : lista opcional que recebe mensagens para exibir ao usuário (ex.: acesso liberado).
    responsavel_id : ID numérico do usuário no ClickUp (assignee). None = sem responsável.
    data_vencimento: datetime.date. None = sem data (status 'backlog base').
    """
    uuid_parceiro = OPCOES_PARCEIRO.get(parceiro)
    
    if not list_id:
        list_id = obter_lista_do_parceiro(parceiro)
    if not list_id:
        raise Exception(f"Nenhuma FAP avulso ativa encontrada para '{parceiro}' no espaço PMO BP-MS "
                        "(listas com 'Avulso' no nome e sem 'Z' na frente).")

    if responsavel_id:
        garantir_acesso_responsavel(list_id, responsavel_id, avisos)
        
    parent_task_id = obter_ou_criar_tarefa_base(list_id, uuid_parceiro)
    if not parent_task_id:
        raise Exception(f"Falha ao encontrar ou criar a tarefa-pai '1-Atendimento Base' na lista '{parceiro}'.")

    if data_vencimento and MES_PELA_DATA_VENCIMENTO:
        nome_mes = gerar_nome_mes_atual(data_vencimento)
    else:
        nome_mes = gerar_nome_mes_atual()
    subtarefa_mensal_id = obter_ou_criar_subtarefa_mensal(list_id, parent_task_id, nome_mes, uuid_parceiro)
    
    if not subtarefa_mensal_id:
        raise Exception("Erro fatal ao resolver a subtarefa do mês.")

    url = f"{CLICKUP_API}/list/{list_id}/task"
    
    payload = {
        "name": titulo,
        "parent": subtarefa_mensal_id,
        "custom_fields": [
            {"id": FIELD_ETAPA, "value": ETAPA_ATENDIMENTO_AVULSO},         
            {"id": FIELD_MODULO, "value": MODULO_ATENDIMENTO_AVULSO},       
            {"id": FIELD_AGENDA, "value": AGENDA_REMOTO},                   
            {"id": FIELD_APONTAMENTO, "value": APONTAMENTO_OS_EXPERIENCE},  
            {"id": FIELD_USUARIO_CLIENTE, "value": usuario_cliente},        
            {"id": FIELD_DETALHAMENTO, "value": detalhamento}               
        ]
    }
    
    if uuid_parceiro:
        payload["custom_fields"].append({"id": FIELD_PARCEIRO, "value": uuid_parceiro})

    # Regra PMO BP-MS: sem data -> "backlog base"; com data -> status padrão da lista (não iniciado)
    if periodo:
        nome_periodo = interpretar_periodo(periodo)
        if not nome_periodo:
            raise Exception(f"Período '{periodo}' não existe no ClickUp. Use uma opção da lista (ex.: 08h-10h).")
        payload["custom_fields"].append({"id": FIELD_PERIODO, "value": OPCOES_PERIODO[nome_periodo]})

    if data_vencimento:
        payload["due_date"] = data_para_ms(data_vencimento)
        payload["due_date_time"] = False   # só a data, sem horário
    else:
        payload["status"] = "backlog base"

    if responsavel_id:
        payload["assignees"] = [int(responsavel_id)]
        
    if origem:
        uuid_origem = OPCOES_ORIGEM.get(origem)
        if uuid_origem:
            payload["custom_fields"].append({"id": FIELD_ORIGEM, "value": uuid_origem})

    resp = request_com_retry(lambda: requests.post(url, json=payload, headers=CLICKUP_HEADERS))

    if resp is not None:
        if resp.status_code in (200, 201):
            return resp.json().get('id')
        else:
            raise Exception(f"Status {resp.status_code}: {resp.text}")
    else:
        raise Exception("Sem resposta do servidor do ClickUp.")