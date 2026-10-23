# 05 — Agrupamento de tarefas (a "inteligência" do repositório)

## O problema

O consultor que atende a mesma demanda por 3 dias gera 3 tarefas no ClickUp (uma por dia,
dentro da subtarefa do mês). Para a gestão, isso é **uma** demanda com 3 atendimentos.

## Como funciona

Toda tarefa sincronizada entra no repositório como **pendente**. Em seguida o sistema chama
`sugerir_agrupamento()` e acontece uma de três coisas:

| Resultado | Quando | O gestor vê |
|---|---|---|
| **Agrupada sozinha** | Vínculo certo (regra 0) ou uma única demanda com pontuação ≥ 85 | Tarefa já dentro da demanda, com a marca "automático". Pode desfazer |
| **Sugestão** | Uma ou mais demandas entre 40 e 84 pontos | "Provável continuação da DEM-0042 (77%)" com os motivos e os botões Aceitar / Outra demanda / Nova demanda / Ignorar |
| **Sem sugestão** | Nada passou de 40 | Botões Nova demanda / Agrupar em… / Ignorar |

## Regras de pontuação (rascunho v0)

| Regra | Pontos | Observação |
|---|---|---|
| 0. Código da demanda (`DEM-0042`) no nome ou no detalhamento | agrupa direto | O mais forte. Ver "Ajuste de processo" abaixo |
| Mesmo ticket Sankhya citado | 60 | Só tickets com 4+ dígitos |
| Mesmo cliente | 15 | Demandas de outro cliente nem entram na comparação |
| Mesmo consultor | 10 | Responsável da demanda ou de alguma tarefa dela |
| Título parecido | até 40 | Semelhança de texto (`pg_trgm`) × 40, sem acento e sem pontuação |
| Mesmo usuário cliente | 5 | Campo "Usuário cliente" do ClickUp |
| Dentro da janela | 5 | Atividade da demanda até 5 dias antes ou depois |

Parâmetros em `configuracoes` → chave `agrupamento`: `janela_dias` (5), `limiar_sugestao`
(40), `limiar_automatico` (85). Ajustáveis sem mexer em código.

Exemplo real do teste:
"Ajuste comissão no pedido de venda" (dia 1) × "Ajuste comissao pedido venda - dia 2"
→ mesmo cliente 15 + mesmo consultor 10 + usuário 5 + janela 5 + título 30 = **65** (sugestão).

## Ajuste de processo recomendado (o que mais resolve)

1. Quando a demanda nasce no sistema e vira tarefa no ClickUp, o nome da tarefa leva o
   código: `DEM-0042 · Ajuste comissão pedido de venda`. Quem continuar a demanda no dia
   seguinte copia o nome. O vínculo fica automático.
2. Se possível, criar no ClickUp um campo personalizado de texto **"Demanda"** para guardar
   o código, sem poluir o nome.
3. Melhor ainda, quando o processo do Experience permitir: registrar o tempo do dia na mesma
   tarefa em vez de abrir outra.

## Evoluções possíveis (depois da fase 2, se as regras não bastarem)

- Aprender com as decisões: aumentar o peso das regras que mais acertam
  (usar `sugestoes_agrupamento.status`).
- Comparar também o **detalhamento** (descrição), não só o título.
- Usar IA (Claude) para sugerir quando a pontuação ficar na zona cinzenta (40–60).
