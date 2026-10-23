"""Grava o token PESSOAL do ClickUp no Gerenciador de Credenciais do Windows."""
import tkinter as tk
from tkinter import messagebox

import keyring
import requests

raiz = tk.Tk()
raiz.title("Token do ClickUp")
raiz.resizable(False, False)
tk.Label(raiz, text="Cole o seu token pessoal do ClickUp (começa com pk_):", padx=12, pady=8).pack(anchor="w")
campo = tk.Entry(raiz, width=60, show="•")
campo.pack(padx=12)
campo.focus_set()


def gravar():
    token = campo.get().strip()
    if not token.startswith("pk_"):
        messagebox.showerror("Token do ClickUp", "O token precisa começar com pk_.")
        return
    try:
        r = requests.get("https://api.clickup.com/api/v2/user", headers={"Authorization": token}, timeout=20)
        nome = r.json().get("user", {}).get("username") if r.status_code == 200 else None
    except requests.RequestException:
        nome = None
    if not nome:
        messagebox.showerror("Token do ClickUp", "O ClickUp não aceitou esse token. Confira e tente de novo.")
        return
    keyring.set_password("sankhya_experience_sync", "CLICKUP_TOKEN", token)
    messagebox.showinfo("Token do ClickUp", f"Token gravado no cofre do Windows.\nConectado como: {nome}")
    raiz.destroy()


tk.Button(raiz, text="Gravar", command=gravar, padx=16).pack(pady=10)
raiz.bind("<Return>", lambda e: gravar())
raiz.mainloop()
