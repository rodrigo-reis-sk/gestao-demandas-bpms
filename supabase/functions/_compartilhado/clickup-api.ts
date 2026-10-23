// Cliente da API v2 do ClickUp, com as lições do pacote legado
// (referencia/clickup-lancar-legado/motores/clickup_sync/clickup_client.py):
//   • tempo máximo por chamada (rede travada vira erro tratado, não trava a função);
//   • pausa preventiva quando X-RateLimit-Remaining está no fim;
//   • espera exata no HTTP 429 (X-RateLimit-Reset) e repetição com espera crescente;
//   • trava de páginas (nunca fica paginando para sempre).

import { type Banco, rpc } from "./base.ts";

const API = "https://api.clickup.com/api/v2";
const TEMPO_MAXIMO_MS = 20_000;
const TENTATIVAS = 5;
const MAX_PAGINAS = 100;

export class ErroClickUp extends Error {
  constructor(public status: number, mensagem: string) {
    super(mensagem);
  }
}

const esperar = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Espera até o horário de renovação da cota (X-RateLimit-Reset, em segundos). Máximo 65 s. */
function esperaAteRenovar(reset: string | null): number | null {
  if (!reset) return null;
  const ms = Number(reset) * 1000 - Date.now() + 1000;
  return Number.isFinite(ms) ? Math.min(Math.max(ms, 0), 65_000) : null;
}

type Consulta = Record<string, string | number | boolean | (string | number)[] | undefined | null>;

export class ClienteClickUp {
  /** Quantas chamadas esta execução fez (vai para o log da sincronização). */
  chamadas = 0;

  constructor(private token: string) {}

  /** Token pessoal (pk_...) vai puro; token do OAuth vai com "Bearer". */
  private autorizacao(): string {
    return this.token.startsWith("pk_") ? this.token : `Bearer ${this.token}`;
  }

  async chamar<T = any>(metodo: string, caminho: string, consulta: Consulta = {}, corpo?: unknown): Promise<T> {
    const url = new URL(API + caminho);
    for (const [chave, valor] of Object.entries(consulta)) {
      if (valor === undefined || valor === null) continue;
      if (Array.isArray(valor)) valor.forEach((v) => url.searchParams.append(`${chave}[]`, String(v)));
      else url.searchParams.set(chave, String(valor));
    }

    let ultimoErro = "";
    for (let tentativa = 1; tentativa <= TENTATIVAS; tentativa++) {
      let resp: Response;
      try {
        resp = await fetch(url, {
          method: metodo,
          headers: { Authorization: this.autorizacao(), "Content-Type": "application/json" },
          body: corpo === undefined ? undefined : JSON.stringify(corpo),
          signal: AbortSignal.timeout(TEMPO_MAXIMO_MS),
        });
      } catch (e) {
        // rede fora, tempo esgotado: tenta de novo com espera crescente
        ultimoErro = `falha de rede (${e instanceof Error ? e.name : e})`;
        await esperar(1000 * 2 ** (tentativa - 1));
        continue;
      }
      this.chamadas++;

      if (resp.ok) {
        const restantes = resp.headers.get("X-RateLimit-Remaining");
        if (restantes !== null && Number(restantes) <= 3) {
          const ms = esperaAteRenovar(resp.headers.get("X-RateLimit-Reset"));
          if (ms) await esperar(ms);
        }
        const texto = await resp.text();
        return (texto ? JSON.parse(texto) : {}) as T;
      }

      if (resp.status === 429 || resp.status >= 500) {
        ultimoErro = `HTTP ${resp.status}`;
        await resp.body?.cancel();
        const ms = resp.status === 429 ? esperaAteRenovar(resp.headers.get("X-RateLimit-Reset")) : null;
        await esperar(ms ?? 1000 * 2 ** (tentativa - 1));
        continue;
      }

      // 4xx (fora o 429): não adianta repetir
      const texto = (await resp.text()).slice(0, 300);
      throw new ErroClickUp(resp.status, `ClickUp ${metodo} ${caminho}: HTTP ${resp.status} ${texto}`);
    }
    throw new ErroClickUp(0, `ClickUp ${metodo} ${caminho}: sem resposta após ${TENTATIVAS} tentativas (${ultimoErro})`);
  }

  // ---------------------------------------------------------------- consultas

  /** Dono do token (confere o e-mail na conexão). */
  usuario() {
    return this.chamar<{ user: { id: number; username: string; email: string } }>("GET", "/user");
  }

  /** Workspaces ("teams") que o token enxerga, com os membros. */
  async equipes(): Promise<any[]> {
    return (await this.chamar("GET", "/team")).teams ?? [];
  }

  /** Pastas do espaço (cada pasta já vem com as listas). */
  async pastas(espacoId: string): Promise<any[]> {
    return (await this.chamar("GET", `/space/${espacoId}/folder`, { archived: false })).folders ?? [];
  }

  /** Listas soltas no espaço (sem pasta). */
  async listasSemPasta(espacoId: string): Promise<any[]> {
    return (await this.chamar("GET", `/space/${espacoId}/list`, { archived: false })).lists ?? [];
  }

  /** Tarefa completa (usada pelo webhook). */
  tarefa(id: string) {
    return this.chamar("GET", `/task/${id}`);
  }

  /** Tarefa completa com a lista das subtarefas diretas em "subtasks" (usada no "Sincronizar" da demanda). */
  tarefaComSubtarefas(id: string) {
    return this.chamar("GET", `/task/${id}`, { include_subtasks: true });
  }

  /**
   * Tarefas alteradas desde uma data, só dos responsáveis e listas informados.
   * Uma busca para vários consultores; paginada (100 por página).
   */
  async tarefasAlteradas(equipeId: string, filtro: { responsaveis: string[]; listas: string[]; desde: Date }) {
    const todas: any[] = [];
    for (let pagina = 0; pagina < MAX_PAGINAS; pagina++) {
      const resp = await this.chamar("GET", `/team/${equipeId}/task`, {
        page: pagina,
        assignees: filtro.responsaveis,
        list_ids: filtro.listas,
        date_updated_gt: filtro.desde.getTime(),
        include_closed: true,
        subtasks: true,
        order_by: "updated",
      });
      const tarefas = resp.tasks ?? [];
      todas.push(...tarefas);
      if (tarefas.length === 0 || resp.last_page !== false) break;
    }
    return todas;
  }

  /**
   * Registros de tempo do período, dos usuários informados, no espaço.
   * Busca em pedaços de 30 dias para não depender do limite de período da API.
   */
  async registrosTempo(equipeId: string, filtro: { usuarios: string[]; inicio: Date; fim: Date; espacoId: string }) {
    const todos: any[] = [];
    const PASSO = 30 * 86_400_000;
    for (let ini = filtro.inicio.getTime(); ini < filtro.fim.getTime(); ini += PASSO) {
      const fim = Math.min(ini + PASSO, filtro.fim.getTime());
      const resp = await this.chamar("GET", `/team/${equipeId}/time_entries`, {
        start_date: ini,
        end_date: fim,
        assignee: filtro.usuarios.join(","),
        space_id: filtro.espacoId,
      });
      todos.push(...(resp.data ?? []));
    }
    return todos;
  }

  async webhooks(equipeId: string): Promise<any[]> {
    return (await this.chamar("GET", `/team/${equipeId}/webhook`)).webhooks ?? [];
  }

  criarWebhook(equipeId: string, endpoint: string, espacoId: string, eventos: string[]) {
    return this.chamar("POST", `/team/${equipeId}/webhook`, {}, { endpoint, events: eventos, space_id: Number(espacoId) });
  }

  apagarWebhook(webhookId: string) {
    return this.chamar("DELETE", `/webhook/${webhookId}`);
  }
}

/** OAuth (D11): troca o código recebido no retorno do login do ClickUp pelo token. */
export async function trocarCodigoPorToken(clientId: string, clientSecret: string, codigo: string): Promise<string> {
  const url = new URL(`${API}/oauth/token`);
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("client_secret", clientSecret);
  url.searchParams.set("code", codigo);
  const resp = await fetch(url, { method: "POST", signal: AbortSignal.timeout(TEMPO_MAXIMO_MS) });
  const texto = await resp.text();
  if (!resp.ok) throw new ErroClickUp(resp.status, `ClickUp recusou o código de autorização: ${texto.slice(0, 200)}`);
  const token = JSON.parse(texto).access_token;
  if (!token) throw new ErroClickUp(500, "ClickUp não devolveu o token.");
  return token;
}

/**
 * Token usado pela varredura e pelo webhook:
 *   1. a "conta da sincronização" (token de um gestor, no Vault) — D11;
 *   2. senão, o token único nos segredos (CLICKUP_TOKEN) — plano B, D12.
 */
export async function clienteDaSincronizacao(banco: Banco): Promise<{ cliente: ClienteClickUp; contaId: string | null }> {
  const contas = await rpc<{ conta_id: string; token: string }[]>(banco, "ler_token_sincronizacao", {
    p_sistema: "clickup",
  });
  if (contas?.length) return { cliente: new ClienteClickUp(contas[0].token), contaId: contas[0].conta_id };
  const tokenUnico = Deno.env.get("CLICKUP_TOKEN");
  if (tokenUnico) return { cliente: new ClienteClickUp(tokenUnico), contaId: null };
  throw new Error("Nenhuma conta do ClickUp conectada para a sincronização (e sem CLICKUP_TOKEN de reserva).");
}

/** Workspace do PMO: CLICKUP_TEAM_ID, se configurado; senão o primeiro que o token enxerga (igual ao legado). */
export function escolherEquipe(equipes: any[]): any {
  const fixo = Deno.env.get("CLICKUP_TEAM_ID");
  const equipe = fixo ? equipes.find((e) => String(e.id) === fixo) : equipes[0];
  if (!equipe) throw new Error("O token não enxerga o workspace do ClickUp" + (fixo ? ` ${fixo}.` : "."));
  return equipe;
}
