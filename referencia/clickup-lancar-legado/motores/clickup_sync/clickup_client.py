"""
Cliente direto da API do ClickUp: buscar tarefas/pastas/listas, e ler/
escrever campos customizados de uma tarefa.
"""

import concurrent.futures
import random
import time
from datetime import datetime

import requests

from .config import CLICKUP_API, CLICKUP_HEADERS, FIELD_EXPERIENCE, EXPERIENCE_OPTIONS, STATUS_NAO_EXECUTADO


def _data_para_ms(data_str, fim_do_dia=False):
    """Converte 'YYYY-MM-DD' para timestamp em milissegundos (UTC-3 -> ms)."""
    hora = "23:59:59" if fim_do_dia else "00:00:00"
    dt = datetime.strptime(f"{data_str} {hora}", "%Y-%m-%d %H:%M:%S")
    return int(dt.timestamp() * 1000)


# Teto de tempo ABSOLUTO por tentativa de requisição (22/09/2026, a pedido
# do usuário -- ver `claude/fix_timeout_duro_travamento_rede_22092026.md`
# pro histórico completo). Motivo: em 22/09/2026 identificamos, comparando
# 6 execuções do mesmo dia (uma pela manhã, cinco seguidas à tarde), que a
# requisição de tarefas de uma lista específica travava para sempre --
# sem estourar o timeout=20 do `requests`, sem lançar exceção, sem
# imprimir nenhuma mensagem de erro ou retry -- deixando o programa inteiro
# pendurado indefinidamente até o usuário fechar a janela e tentar de novo
# (4 tentativas seguidas travaram no mesmo ponto exato, sempre logo após a
# lista "Origem 33239 Avulso"). Isso indica que o parâmetro timeout= do
# requests não estava sendo respeitado por algo na camada de rede (proxy,
# antivírus ou VPN engolindo o pacote sem devolver RST/FIN), já que toda a
# lógica de retry/backoff abaixo já cobre exceção e erro HTTP normalmente.
#
# _executar_com_timeout_duro roda a chamada numa thread separada e usa
# `future.result(timeout=...)` como um segundo cronômetro, independente do
# requests. Se estourar, a thread trava pra sempre em segundo plano (o
# Python não mata uma thread à força), mas o fluxo principal PARA de
# esperar por ela e trata isso como uma falha comum -- entra no mesmo
# caminho de retry/erro que já existia, em vez de travar a rodada inteira
# sem aviso nenhum.
# Reduzido de 30 pra 15s em 22/09/2026 (2ª rodada de diagnóstico, depois
# de confirmar que a 1ª correção deste fix nunca chegou a ir pro disco --
# ver seção "Correção do próprio fix" no .md): com 15s, se o timeout duro
# estiver funcionando de verdade, a mensagem de aviso aparece rápido o
# bastante pra não parecer travamento total antes de alguém decidir matar
# o processo por impaciência.
_TIMEOUT_DURO_SEGUNDOS = 15


# Executor ÚNICO e persistente, criado uma vez só e reaproveitado por
# TODAS as chamadas (22/09/2026, 6ª rodada de diagnóstico). Motivo: as
# versões 4 e 5 já eliminaram as duas chamadas Tkinter thread-unsafe
# conhecidas em main.py (`janela.update()` e `janela.after()`), mas o
# processo continuou travando -- e travou byte a byte IDÊNTICO nas duas
# vezes seguintes (mesmo módulo `tcl86t.dll`, mesmo código de exceção
# 0x80000003, MESMO deslocamento de falha 0x...fee74; ver
# claude/fix_timeout_duro_travamento_rede_22092026.md). Ou seja: mudar o
# código que toca a `janela` não mudou nada no crash -- a causa
# provavelmente não estava ali. O que NÃO mudou nas três tentativas foi
# justamente este trecho: `_executar_com_timeout_duro` criava um
# `ThreadPoolExecutor` NOVO a cada requisição (mais de 70 por rodada),
# ou seja, criava e destruía dezenas de threads do sistema operacional em
# sequência rápida, no mesmo processo que também roda o loop de eventos
# do Tcl/Tk na thread principal. Como experimento controlado, passamos a
# reaproveitar um único executor entre todas as chamadas, eliminando essa
# criação repetida de threads.
_executor_hard_timeout = concurrent.futures.ThreadPoolExecutor(
    max_workers=1, thread_name_prefix="clickup-timeout-duro"
)


def _executar_com_timeout_duro(fazer_requisicao, timeout=_TIMEOUT_DURO_SEGUNDOS):
    # Reaproveita sempre o mesmo worker (não cria/destrói um
    # ThreadPoolExecutor por chamada -- ver comentário acima). Efeito
    # colateral aceito: se uma requisição travar de verdade no nível de
    # rede, o único worker fica ocupado pra sempre, e toda chamada
    # SEGUINTE também vai estourar este mesmo timeout (porque
    # future.result(timeout=...) conta o tempo mesmo que a tarefa ainda
    # nem tenha começado a rodar) -- pior pra throughput nesse cenário
    # raro, mas continua gerando o aviso de log normalmente, em vez de
    # travar ou crashar silenciosamente. Isso nunca aconteceu de verdade
    # em nenhuma das execuções de teste até agora (0 avisos de "travou
    # além de 15s" em ~10 rodadas).
    future = _executor_hard_timeout.submit(fazer_requisicao)
    return future.result(timeout=timeout)


def request_com_retry(fazer_requisicao, tentativas=5, espera_inicial=1.0):
    """
    Executa uma chamada HTTP ao ClickUp com repetição automática inteligente.
    Atualizado para interceptar os cabeçalhos X-RateLimit-Remaining e X-RateLimit-Reset
    nativos da API do ClickUp, controlando o bloqueio 429 de forma precisa.

    Cada tentativa roda sob um teto de tempo absoluto (ver
    _TIMEOUT_DURO_SEGUNDOS acima) além do timeout= interno do requests --
    rede/proxy travada vira uma falha tratada (retry, e por fim uma
    exceção visível), nunca mais um travamento silencioso e infinito.
    """
    resp = None
    for tentativa in range(1, tentativas + 1):
        try:
            resp = _executar_com_timeout_duro(fazer_requisicao)
        except concurrent.futures.TimeoutError:
            print(f"  (ClickUp: tentativa {tentativa}/{tentativas} -- requisição travou além de "
                  f"{_TIMEOUT_DURO_SEGUNDOS}s sem resposta nem erro (provável trava de rede/proxy, "
                  f"não é erro da API)...)")
            if tentativa < tentativas:
                espera = espera_inicial * (2 ** (tentativa - 1)) * random.uniform(0.7, 1.3)
                print(f"  aguardando {espera:.1f}s e tentando de novo...")
                time.sleep(espera)
                continue
            raise requests.exceptions.Timeout(
                f"Requisição travou além de {_TIMEOUT_DURO_SEGUNDOS}s em todas as {tentativas} "
                f"tentativas (trava de rede/proxy -- a thread presa fica pra trás em segundo plano)."
            )
        except requests.exceptions.RequestException as e:
            if tentativa < tentativas:
                espera = espera_inicial * (2 ** (tentativa - 1)) * random.uniform(0.7, 1.3)
                print(f"  (ClickUp: tentativa {tentativa}/{tentativas} falhou -- {type(e).__name__}, aguardando {espera:.1f}s e tentando de novo...)")
                time.sleep(espera)
                continue
            raise

        # Analisa a resposta bem-sucedida ou erros que não são rate limit (400-499 excluindo 429)
        if resp.status_code == 200 or (400 <= resp.status_code < 500 and resp.status_code != 429):

            # Controle Preemptivo: Se a requisição deu certo, mas restam poucas chamadas na cota do minuto
            if resp.status_code in (200, 201):
                remaining = resp.headers.get("X-RateLimit-Remaining")
                reset = resp.headers.get("X-RateLimit-Reset")

                # Se restarem 3 ou menos requisições, calculamos o tempo até a renovação e pausamos
                if remaining is not None and int(remaining) <= 3 and reset is not None:
                    espera_inteligente = max(0, float(reset) - time.time()) + 1.0
                    print(f"  [Rate Limit] Cota da API quase no fim (restam {remaining}). Pausando preventivamente {espera_inteligente:.1f}s...")
                    time.sleep(espera_inteligente)

            return resp

        # Tratamento de erro 429 (Rate Limit atingido) ou 5xx (Erro de Servidor)
        if tentativa < tentativas:
            reset = resp.headers.get("X-RateLimit-Reset")

            # Se for 429 e o servidor informar o tempo de liberação, esperamos o tempo exato
            if resp.status_code == 429 and reset is not None:
                espera = max(0, float(reset) - time.time()) + 1.5
                print(f"  (ClickUp: HTTP 429 Rate Limit atingido! Pausando exatos {espera:.1f}s ditados pelo servidor...)")
            else:
                # Fallback para o backoff tradicional caso o cabeçalho não venha
                espera = espera_inicial * (2 ** (tentativa - 1)) * random.uniform(0.7, 1.3)
                print(f"  (ClickUp: tentativa {tentativa}/{tentativas} falhou -- HTTP {resp.status_code}, aguardando {espera:.1f}s e tentando de novo...)")

            time.sleep(espera)

    return resp


def get_tasks(list_id, include_closed=False, due_date_from=None, due_date_to=None):
    """
    Retorna tarefas de uma lista, com custom fields e proteção contra ciclos infinitos.
    """
    tasks = []
    page = 0

    while page < 50: # Trava de segurança máxima (impede bloqueio silencioso)
        params = {
            "page": page,
            "include_closed": str(include_closed).lower(),
            "subtasks": "true",
        }
        if due_date_from:
            params["due_date_gt"] = _data_para_ms(due_date_from, fim_do_dia=False)
        if due_date_to:
            params["due_date_lt"] = _data_para_ms(due_date_to, fim_do_dia=True)

        resp = request_com_retry(
            lambda: requests.get(f"{CLICKUP_API}/list/{list_id}/task", headers=CLICKUP_HEADERS, params=params, timeout=20)
        )

        if resp is None or resp.status_code != 200:
            status = resp.status_code if resp is not None else "sem resposta"
            print(f"[ERRO GRAVE] Falha ao buscar tarefas da lista {list_id}... HTTP {status}")
            break

        data = resp.json()
        novas_tarefas = data.get("tasks", [])
        tasks.extend(novas_tarefas)

        # Se a API devolver uma página vazia, encerra imediatamente
        if not novas_tarefas:
            break

        if data.get("last_page", True):
            break

        page += 1
        # Dá feedback no ecrã para o utilizador saber que não está travado
        print(f"    (ClickUp: Lendo página {page+1} de tarefas na lista...)")

    return tasks


def get_folders(space_id):
    """Retorna as pastas (normalmente uma por parceiro) de um Space."""
    resp = request_com_retry(
        lambda: requests.get(f"{CLICKUP_API}/space/{space_id}/folder", headers=CLICKUP_HEADERS, timeout=15)
    )
    if resp is None or resp.status_code != 200:
        status = resp.status_code if resp is not None else "sem resposta"
        texto = resp.text[:300] if resp is not None else ""
        print(f"[ERRO GRAVE] Falha ao buscar pastas do Space {space_id} mesmo após retries: {status} {texto} "
              f"-- a lista de parceiros desta rodada pode estar incompleta.")
        return []
    return resp.json().get("folders", [])


def get_lists_in_folder(folder_id):
    resp = request_com_retry(
        lambda: requests.get(f"{CLICKUP_API}/folder/{folder_id}/list", headers=CLICKUP_HEADERS, timeout=15)
    )
    if resp is None or resp.status_code != 200:
        status = resp.status_code if resp is not None else "sem resposta"
        texto = resp.text[:300] if resp is not None else ""
        print(f"[ERRO GRAVE] Falha ao buscar listas da pasta {folder_id} mesmo após retries: {status} {texto} "
              f"-- essa pasta pode ficar de fora desta rodada.")
        return []
    return resp.json().get("lists", [])


def get_folderless_lists(space_id):
    """Listas soltas direto no Space, sem pasta."""
    resp = request_com_retry(
        lambda: requests.get(f"{CLICKUP_API}/space/{space_id}/list", headers=CLICKUP_HEADERS, timeout=15)
    )
    if resp is None or resp.status_code != 200:
        status = resp.status_code if resp is not None else "sem resposta"
        texto = resp.text[:300] if resp is not None else ""
        print(f"[ERRO GRAVE] Falha ao buscar listas soltas do Space {space_id} mesmo após retries: {status} {texto} "
              f"-- listas soltas podem ficar de fora desta rodada.")
        return []
    return resp.json().get("lists", [])


def get_field_value(task, field_id):
    for cf in task.get("custom_fields", []):
        if cf["id"] == field_id:
            return cf
    return None


def get_dropdown_selected_name(task, field_id):
    """Para um campo drop_down, retorna o nome da opção selecionada (ou None)."""
    cf = get_field_value(task, field_id)
    if not cf or "value" not in cf:
        return None
    idx = cf["value"]
    options = cf.get("type_config", {}).get("options", [])
    for opt in options:
        if opt.get("orderindex") == idx:
            return opt["name"]
    return None


def get_text_value(task, field_id):
    cf = get_field_value(task, field_id)
    if not cf:
        return None
    return cf.get("value")


def set_task_experience_status(task_id, status_name):
    """Atualiza o campo Experience no ClickUp para o status indicado. Retorna True/False."""
    option_id = EXPERIENCE_OPTIONS.get(status_name)
    if not option_id:
        raise ValueError(f"Status Experience desconhecido: {status_name}")
    body = {"value": option_id}
    resp = request_com_retry(
        lambda: requests.post(
            f"{CLICKUP_API}/task/{task_id}/field/{FIELD_EXPERIENCE}",
            headers=CLICKUP_HEADERS,
            json=body,
            timeout=15,
        )
    )
    sucesso = resp is not None and resp.status_code in (200, 201)
    if not sucesso:
        status = resp.status_code if resp is not None else "sem resposta"
        texto = resp.text[:300] if resp is not None else ""
        print(f"  [AVISO] Falha ao atualizar campo Experience na tarefa {task_id} mesmo após retries: HTTP {status} -- {texto}")
    return sucesso


def marcar_tarefa_como_nao_executada(task_id):
    """
    Atualiza a tarefa no ClickUp para refletir que ela foi jogada na
    Lixeira do Experience: status NATIVO da tarefa (não o campo customizado
    Experience) vira "não executado" e a data de vencimento (due_date) é
    limpa. Aplicado sempre que Experience = "Lixeira", independente de ter
    sido encontrado (e excluído) um lançamento correspondente no Experience.

    Retorna True/False.
    """
    body = {"status": STATUS_NAO_EXECUTADO, "due_date": None}
    resp = request_com_retry(
        lambda: requests.put(
            f"{CLICKUP_API}/task/{task_id}",
            headers=CLICKUP_HEADERS,
            json=body,
            timeout=15,
        )
    )
    sucesso = resp is not None and resp.status_code in (200, 201)
    if not sucesso:
        status = resp.status_code if resp is not None else "sem resposta"
        texto = resp.text[:300] if resp is not None else ""
        print(f"  [AVISO] Falha ao marcar tarefa {task_id} como '{STATUS_NAO_EXECUTADO}' / limpar data de vencimento mesmo após retries: HTTP {status} -- {texto}")
    return sucesso
