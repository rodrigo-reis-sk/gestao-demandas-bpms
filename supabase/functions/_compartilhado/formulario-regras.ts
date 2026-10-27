// Regras do formulário externo (consultor e, depois, portal do cliente) que não dependem do banco.
// Ficam separadas para poderem ser testadas sem Supabase (supabase/testes/formulario.test.ts).

/** Limites padrão; o banco pode sobrescrever em configuracoes.formulario (D60). */
export const LIMITES = {
  maxArquivos: 30,
  maxArquivoBytes: 5 * 1024 * 1024,     // igual ao limite do bucket "evidencias"
  maxTotalBytes: 15 * 1024 * 1024,
  maxPassos: 40,
};

export const TIPOS_ACEITOS: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/gif": "gif",
  "application/pdf": "pdf",
};

/** IP de quem chamou: primeiro endereço de x-forwarded-for (o Supabase preenche). */
export function ipDaRequisicao(req: Request): string {
  const encaminhado = req.headers.get("x-forwarded-for") ?? "";
  const ip = encaminhado.split(",")[0].trim() || req.headers.get("x-real-ip") || req.headers.get("cf-connecting-ip") || "";
  return /^[0-9a-fA-F:.]{3,45}$/.test(ip) ? ip : "desconhecido";
}

/**
 * Tipo real do arquivo pelos primeiros bytes (não confia no nome nem no tipo que o navegador mandou).
 * Devolve null se não for imagem nem PDF.
 */
export function tipoPelosBytes(b: Uint8Array): string | null {
  const comeca = (...sig: number[]) => sig.every((v, i) => b[i] === v);
  if (comeca(0xff, 0xd8, 0xff)) return "image/jpeg";
  if (comeca(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return "image/png";
  if (comeca(0x47, 0x49, 0x46, 0x38)) return "image/gif";
  if (comeca(0x52, 0x49, 0x46, 0x46) && b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return "image/webp";
  if (comeca(0x25, 0x50, 0x44, 0x46)) return "application/pdf"; // %PDF
  return null;
}

export interface PassoRecebido {
  texto: string;
  arquivos: string[];           // nomes dos campos de arquivo do FormData, na ordem
}

export interface ArquivoConferido {
  campo: string;
  bytes: Uint8Array;
  tipo: string;
  tamanho: number;
}

export class ErroFormulario extends Error {
  constructor(public status: number, mensagem: string) { super(mensagem); }
}

/**
 * Confere os passos e os arquivos vindos do FormData.
 * `dados.evidencias` = [{ texto, arquivos: ["a0", "a1"] }]; cada "aN" é um campo de arquivo.
 * Devolve os passos e os arquivos já lidos e conferidos (ou lança ErroFormulario).
 */
export async function conferirEvidencias(
  evidencias: unknown, form: FormData, limites = LIMITES,
): Promise<{ passos: PassoRecebido[]; arquivos: Map<string, ArquivoConferido> }> {
  const lista = Array.isArray(evidencias) ? evidencias : [];
  if (lista.length > limites.maxPassos) throw new ErroFormulario(400, `No máximo ${limites.maxPassos} passos.`);
  const passos: PassoRecebido[] = [];
  const arquivos = new Map<string, ArquivoConferido>();
  let total = 0;
  for (const p of lista) {
    const texto = typeof p?.texto === "string" ? p.texto : "";
    const campos: string[] = Array.isArray(p?.arquivos) ? p.arquivos.filter((c: unknown) => typeof c === "string") : [];
    const usados: string[] = [];
    for (const campo of campos) {
      if (arquivos.has(campo)) continue;                 // mesmo arquivo citado duas vezes
      const f = form.get(campo);
      if (!(f instanceof File)) continue;                // citado mas não enviado: ignora
      if (arquivos.size >= limites.maxArquivos) throw new ErroFormulario(400, `No máximo ${limites.maxArquivos} arquivos por envio.`);
      if (f.size > limites.maxArquivoBytes) {
        throw new ErroFormulario(400, `O arquivo ${f.name || campo} passa de ${Math.round(limites.maxArquivoBytes / 1048576)} MB.`);
      }
      total += f.size;
      if (total > limites.maxTotalBytes) {
        throw new ErroFormulario(400, `Os arquivos passam de ${Math.round(limites.maxTotalBytes / 1048576)} MB no total. Envie menos prints.`);
      }
      const bytes = new Uint8Array(await f.arrayBuffer());
      const tipo = tipoPelosBytes(bytes);
      if (!tipo) throw new ErroFormulario(400, `O arquivo ${f.name || campo} não é imagem nem PDF.`);
      arquivos.set(campo, { campo, bytes, tipo, tamanho: bytes.byteLength });
      usados.push(campo);
    }
    if (!texto.trim() && !usados.length) continue;       // passo vazio
    passos.push({ texto, arquivos: usados });
  }
  return { passos, arquivos };
}

/** Caminho do arquivo no bucket: <chamado>/<prefixo><passo>-<n>.<ext> */
export function caminhoNoBucket(chamadoId: string, prefixo: string, passo: number, n: number, tipo: string): string {
  return `${chamadoId}/${prefixo}${String(passo).padStart(2, "0")}-${String(n).padStart(2, "0")}.${TIPOS_ACEITOS[tipo] ?? "bin"}`;
}
