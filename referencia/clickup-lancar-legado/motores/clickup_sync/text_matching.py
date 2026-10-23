"""
Utilitários de comparação de texto tolerante a variações de escrita:
acentos, pontuação, maiúsculas/minúsculas, e pequenos erros de digitação
(via distância de edição Damerau-Levenshtein, palavra por palavra).

Usado para casar nomes digitados pelo usuário (parceiro, pessoa) com os
nomes reais cadastrados no ClickUp/Experience, sem exigir digitação exata.
"""

import re
import unicodedata


def normalizar_texto(s):
    """Remove acentos, pontuação e espaços extras, deixa tudo minúsculo -- para comparação tolerante a variações de escrita."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode("ascii")
    s = s.replace(".", "")  # remove pontos sem deixar espaço: "M.S" -> "MS", não "M S"
    s = re.sub(r"[^a-zA-Z0-9\s]", " ", s)  # demais pontuações (hífen, barra, etc.) viram espaço
    s = re.sub(r"\s+", " ", s).strip().lower()
    return s


def distancia_edicao(a, b):
    """Distância de Damerau-Levenshtein (conta transposição de letras
    adjacentes, ex: 'pro'/'por', como 1 única diferença -- erro de
    digitação muito comum -- em vez de 2 como no Levenshtein simples)."""
    if a == b:
        return 0
    la, lb = len(a), len(b)
    d = [[0] * (lb + 1) for _ in range(la + 1)]
    for i in range(la + 1):
        d[i][0] = i
    for j in range(lb + 1):
        d[0][j] = j
    for i in range(1, la + 1):
        for j in range(1, lb + 1):
            custo = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(
                d[i - 1][j] + 1,        # remoção
                d[i][j - 1] + 1,        # inserção
                d[i - 1][j - 1] + custo,  # substituição
            )
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)  # transposição
    return d[la][lb]


def palavras_parecidas(pt, pn):
    """
    Duas palavras são consideradas a mesma coisa se forem iguais, ou se
    tiverem no máximo 1-2 letras de diferença (tolerância cresce um
    pouco com o tamanho da palavra). Substring (uma dentro da outra)
    também conta, MAS só entre palavras com pelo menos 3 letras cada.

    BUG real corrigido em 25/08/2026 (caso Vó Ermínia FAP 31348, Módulo
    "Caixas e Bancos" ainda não mapeado em MODULOS_METODOLOGIA_5_0): a
    checagem de substring antes não tinha piso de tamanho, então uma
    palavra de 1 letra -- como "e", "a", "o", conjunções/artigos soltos
    em nomes compostos -- batia como substring de QUALQUER palavra que
    contivesse aquela letra (ex: "e" é substring de "contabilidade" só
    por coincidência de letra, sem relação nenhuma entre as palavras).
    Isso fazia um Módulo ainda NÃO mapeado (como "Caixas e Bancos")
    casar por engano com outro Módulo já mapeado (como "Contabilidade"),
    em vez de corretamente não achar nada e cair em "Módulo não
    resolvido" -- o pior tipo de falha aqui, porque lança a tarefa no
    módulo ERRADO do Experience em vez de travar pra revisão manual.
    """
    if pt == pn:
        return True
    if len(pt) >= 3 and len(pn) >= 3 and (pt in pn or pn in pt):
        return True
    tolerancia = 1 if max(len(pt), len(pn)) <= 5 else 2
    return distancia_edicao(pt, pn) <= tolerancia


def bate_aproximada(termo_norm, texto_norm):
    """
    Compara palavra por palavra (não a frase inteira) -- lida melhor com
    erros de digitação isolados (ex: 'Pro-Info' vs 'Por-Info' no cadastro)
    do que comparar a string inteira, que é derrubada por diferenças de
    tamanho (nome curto digitado vs. nome com números/sufixos).
    Todas as palavras do termo digitado precisam ter uma correspondente
    (exata ou aproximada) em algum lugar do texto comparado.
    """
    palavras_termo = termo_norm.split()
    palavras_texto = texto_norm.split()
    if not palavras_termo:
        return False
    for pt in palavras_termo:
        if not any(palavras_parecidas(pt, pn) for pn in palavras_texto):
            return False
    return True
