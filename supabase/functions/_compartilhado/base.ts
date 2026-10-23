// Peças comuns às Edge Functions: cliente do banco com a chave de serviço, CORS,
// respostas JSON e conferência de quem está chamando (gestor logado ou agendamento).
// Este arquivo não conhece a ferramenta externa (D10).

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export type Banco = SupabaseClient;

// Permite chamar as funções a partir das telas (GitHub Pages).
export const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-chave-agendamento",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function responder(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" },
  });
}

/** Variável de ambiente obrigatória (segredos do Supabase). */
export function ambiente(nome: string): string {
  const valor = Deno.env.get(nome);
  if (!valor) throw new Error(`Falta configurar o segredo ${nome} no Supabase.`);
  return valor;
}

/** Cliente com a chave de serviço: ignora o RLS. Usar só aqui no servidor. */
export function bancoAdmin(): Banco {
  return createClient(ambiente("SUPABASE_URL"), ambiente("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Chama uma função do banco e devolve o resultado (ou lança o erro com a mensagem do banco). */
export async function rpc<T = unknown>(banco: Banco, funcao: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await banco.rpc(funcao, args);
  if (error) throw new Error(`Banco (${funcao}): ${error.message}`);
  return data as T;
}

export interface UsuarioLogado {
  id: string;
  email: string;
  nome: string;
  papel: "admin" | "gestor" | "consultor";
}

/**
 * Lê o login de quem chamou (token do Supabase Auth no cabeçalho Authorization) e confere
 * o cadastro em usuarios_sistema. Devolve null se não houver login válido e ativo.
 */
export async function usuarioDaRequisicao(req: Request, banco: Banco): Promise<UsuarioLogado | null> {
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data, error } = await banco.auth.getUser(jwt);
  if (error || !data.user) return null;
  const { data: cadastro } = await banco
    .from("usuarios_sistema")
    .select("id, email, nome, papel, ativo")
    .eq("id", data.user.id)
    .maybeSingle();
  if (!cadastro || !cadastro.ativo) return null;
  return { id: cadastro.id, email: cadastro.email, nome: cadastro.nome, papel: cadastro.papel };
}

export function ehGestor(u: UsuarioLogado | null): u is UsuarioLogado {
  return !!u && (u.papel === "admin" || u.papel === "gestor");
}

/** Chamada feita pelo pg_cron (cabeçalho x-chave-agendamento conferido no banco)? */
export async function chamadaDoAgendamento(req: Request, banco: Banco): Promise<boolean> {
  const chave = req.headers.get("x-chave-agendamento");
  if (!chave) return false;
  return await rpc<boolean>(banco, "conferir_chave_agendamento", { p_chave: chave });
}

// Supabase permite continuar trabalhando depois de responder (tarefa em segundo plano).
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

/** Roda em segundo plano quando possível; no teste local, espera terminar. */
export async function emSegundoPlano(trabalho: Promise<unknown>): Promise<void> {
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
    EdgeRuntime.waitUntil(trabalho);
  } else {
    await trabalho;
  }
}

export function mensagemDeErro(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
