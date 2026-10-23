"""
Descoberta de listas do ClickUp (parceiros) dentro de um Space, com
reconhecimento por semelhança de nome, e extração do número da FAP a
partir do nome da lista (padrão "<Parceiro> <FAP> Avulso").

PASTAS ADMINISTRATIVAS IGNORADAS (24/08/2026, a pedido do usuário): além
das pastas cujo nome começa com "Z" (convenção antiga, 10/08/2026), toda
pasta cujo nome bate exatamente com PASTAS_IGNORADAS (config.py -- hoje
"1-BP-MS", "2- Horas Cruzadas", "3- Planos de Ação") é pulada em
get_all_lists_in_space, antes até de buscar as listas de dentro dela.
Essas pastas são administrativas/internas, não parceiros -- nunca devem
entrar em nenhuma rodada (contagem ao vivo da tela, checagem de órfãos,
Criar/Alterar/Excluir).
"""

import re

from .clickup_client import get_folders, get_lists_in_folder, get_folderless_lists
from .config import PASTAS_IGNORADAS
from .text_matching import normalizar_texto, bate_aproximada

FAP_REGEX = re.compile(r"\b(\d{4,6})\b")


def _comeca_com_z(nome):
    """Convenção do ClickUp pra marcar algo fora do fluxo normal (confirmado Fragoso, 10/08/2026)."""
    return (nome or "").strip().upper().startswith("Z")


def _pasta_administrativa_ignorada(nome):
    """
    24/08/2026, a pedido do usuário: pastas administrativas do Space
    (ex: "1-BP-MS", "2- Horas Cruzadas", "3- Planos de Ação") não são
    parceiros e nunca devem aparecer na descoberta de listas -- ver
    PASTAS_IGNORADAS em config.py. Comparação exata (só tira espaço nas
    pontas), não normalizada -- os nomes em PASTAS_IGNORADAS já são os
    literais confirmados pelo usuário.
    """
    return (nome or "").strip() in PASTAS_IGNORADAS


def extrair_fap_do_nome_lista(list_name):
    """
    Extrai o número da FAP a partir do nome da lista do ClickUp, que já
    segue o padrão '<Parceiro> <FAP> Avulso' (ex: 'Germipasto 32221 Avulso').
    Retorna None se não encontrar um número no padrão esperado.
    """
    match = FAP_REGEX.search(list_name)
    return match.group(1) if match else None


def filtrar_listas_por_nome(listas, name_filter, avisar_fuzzy=False):
    """
    Filtra em MEMÓRIA uma lista já carregada de listas do ClickUp (no
    formato devolvido por `get_all_lists_in_space`,
    [{"id":..., "name":..., "folder_name":...}, ...]) pelo nome do
    parceiro, com o mesmo reconhecimento por semelhança usado em
    `get_all_lists_in_space`, aplicado a CADA termo:
      1) Tenta correspondência normalizada (ignora acentos, pontuação,
         maiúsculas/minúsculas).
      2) Se nada bater exatamente pra aquele termo, cai numa busca
         aproximada (fuzzy) só pra ele.

    MÚLTIPLOS TERMOS (24/08/2026, a pedido do usuário): `name_filter` pode
    trazer mais de um termo separado por vírgula (ex: "32699, 32221,
    33545", pra rodar um lote específico de FAPs de uma vez) -- cada
    termo é limpo com `strip()` e tratado de forma INDEPENDENTE, com a
    mesma lógica de sempre (direta primeiro, fuzzy só se a direta não
    achar nada PRA AQUELE termo). Os resultados de todos os termos são
    combinados numa lista só, sem repetir a mesma lista do ClickUp duas
    vezes (controlado por `id`, caso dois termos diferentes acabem
    batendo na mesma lista). Sem vírgula nenhuma, `name_filter` inteiro
    vira o único termo -- mesmo comportamento de sempre nesse caso (nem a
    ordem dos resultados muda pra quem já usa um termo só).

    NÃO faz nenhuma chamada de rede -- extraída de dentro de
    `get_all_lists_in_space` em 19/08/2026 pra poder ser reaproveitada
    contra uma lista já buscada antes (ver `main.py`, contagem ao vivo na
    tela de parâmetros). Buscar tudo de novo a cada tecla digitada batia
    no rate limit do ClickUp (HTTP 429) em produção -- por isso a busca
    de verdade (`get_folders`/`get_lists_in_folder`/`get_folderless_lists`)
    deve acontecer só UMA vez, com o resultado guardado em cache (já com
    o filtro de "Z" e de "concluído" aplicado, ver `get_all_lists_in_space`),
    e essa função usada pra filtrar esse cache em memória quantas vezes
    for preciso -- inclusive com múltiplos termos, continua sem bater na
    API nenhuma vez.

    `avisar_fuzzy`: se True, imprime no terminal quando a busca caiu pro
    caminho aproximado (mesmo aviso que `get_all_lists_in_space` sempre
    imprimiu), especificando pra qual termo isso aconteceu quando há mais
    de um -- desligado por padrão porque a contagem ao vivo chama isto a
    cada tecla digitada, e imprimir a cada tecla poluiria o terminal sem
    necessidade.
    """
    if not name_filter:
        return listas

    if "," in name_filter:
        termos = [t.strip() for t in name_filter.split(",") if t.strip()]
    else:
        termos = [name_filter]

    resultados_totais = []
    ids_vistos = set()

    for termo in termos:
        # FAP NUMÉRICA = SÓ CORRESPONDÊNCIA EXATA (30/09/2026, a pedido do
        # usuário -- ver claude/fix_fap_numerica_sem_aproximacao_30092026.md).
        # Caso real: '30674' (inexistente) caiu no fuzzy e rodou a rodada
        # completa, inclusive checagem de órfãos com exclusão, em HPA 30604
        # e Neurosoft 30764. Número de FAP não tem "erro de digitação
        # tolerável": ou é a FAP, ou é outro projeto. Também não aceita
        # pedaço de número ('3060' não pega 30604) -- compara com cada
        # número inteiro que aparece no nome da lista.
        if termo.isdigit():
            exatas = [l for l in listas if termo in re.findall(r"\d+", l["name"])]
            if not exatas:
                if avisar_fuzzy:
                    print(f"[Aviso] FAP '{termo}' não encontrada em nenhuma lista do ClickUp -- "
                          f"ignorada (número de FAP não usa correspondência aproximada). "
                          f"Confira o número digitado.")
                continue
            for l in exatas:
                if l["id"] not in ids_vistos:
                    ids_vistos.add(l["id"])
                    resultados_totais.append(l)
            continue

        termo_norm = normalizar_texto(termo)

        # 1) Correspondência normalizada (substring, tolerante a pontuação/acentos)
        diretas = [l for l in listas if termo_norm in normalizar_texto(l["name"])]
        if diretas:
            for l in diretas:
                if l["id"] not in ids_vistos:
                    ids_vistos.add(l["id"])
                    resultados_totais.append(l)
            continue  # achou direto pra esse termo -- não tenta fuzzy pra ele

        # 2) Busca aproximada (fuzzy, palavra por palavra) -- lida com erros de
        #    digitação isolados sem ser derrubada por diferenças de tamanho
        aproximadas = [l for l in listas if bate_aproximada(termo_norm, normalizar_texto(l["name"]))]
        if not aproximadas:
            continue  # nada pra esse termo, nem direto nem fuzzy -- segue pro próximo

        if avisar_fuzzy:
            print(f"[Aviso] Nenhuma lista com correspondência exata para '{termo}'. Usando correspondência aproximada:")
            for l in aproximadas:
                print(f"  ~ {l['folder_name'] or ''} / {l['name']}")

        for l in aproximadas:
            if l["id"] not in ids_vistos:
                ids_vistos.add(l["id"])
                resultados_totais.append(l)

    return resultados_totais


def get_all_lists_in_space(space_id, name_filter=None):
    """
    Descobre todas as listas de um Space (dentro de pastas de parceiros +
    listas soltas) -- SEMPRE bate na API do ClickUp (busca pastas + listas
    de cada pasta + listas soltas), independente de `name_filter`; o
    filtro por nome é aplicado depois, em memória, por
    `filtrar_listas_por_nome`. Quem for chamar isso repetidamente com o
    MESMO espaço só variando `name_filter` (ex: a cada tecla digitada numa
    tela) deve buscar uma vez com `name_filter=None` e reaproveitar o
    resultado com `filtrar_listas_por_nome` -- ver nota nessa função sobre
    o rate limit (HTTP 429) que motivou essa separação em 19/08/2026.

    name_filter (opcional): filtra por nome com reconhecimento por
    semelhança (ver `filtrar_listas_por_nome`).

    Retorna: [{"id": ..., "name": ..., "folder_name": ...}, ...]
    """
    listas = []

    for folder in get_folders(space_id):
        if _comeca_com_z(folder["name"]) or _pasta_administrativa_ignorada(folder["name"]):
            continue
        for lst in get_lists_in_folder(folder["id"]):
            listas.append({"id": lst["id"], "name": lst["name"], "folder_name": folder["name"]})

    for lst in get_folderless_lists(space_id):
        listas.append({"id": lst["id"], "name": lst["name"], "folder_name": None})

    # Nunca sugerir listas de projetos já encerrados (o nome costuma indicar
    # isso, ex: "(Concluída 31/12/2025)"). A validação definitiva de status
    # ainda acontece contra o Experience antes de qualquer lançamento, mas
    # já filtrar aqui evita sugerir a lista errada no pop-up de confirmação.
    listas = [l for l in listas if "conclu" not in normalizar_texto(l["name"])]

    # Listas cujo próprio nome começa com "Z" também são desconsideradas
    # (além das pastas já filtradas acima, que cobrem listas soltas fora
    # de qualquer pasta com nome em Z).
    listas = [l for l in listas if not _comeca_com_z(l["name"])]

    if not name_filter:
        return listas

    return filtrar_listas_por_nome(listas, name_filter, avisar_fuzzy=True)
