// Senha temporária para os acessos criados pela tela Consultores (D75).
// 12 caracteres em 3 blocos (ex.: "kq7m-Xp4z-9tRw"), sem letras e números que se confundem (0/O, 1/l/I).

const ALFABETO = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";

export function gerarSenhaTemporaria(): string {
  const bytes = new Uint32Array(12);
  crypto.getRandomValues(bytes);
  const c = Array.from(bytes, (b) => ALFABETO[b % ALFABETO.length]);
  return [c.slice(0, 4), c.slice(4, 8), c.slice(8, 12)].map((p) => p.join("")).join("-");
}
