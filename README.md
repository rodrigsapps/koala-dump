# KOALA DUMP

Remote Scanner + Spy + Webhook (Discord). UI: [WindUI](https://github.com/Footagesus/WindUI).

## Versao ofuscada (recomendada)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/rodrigsapps/koala-dump/refs/heads/main/kd"))()
```

## Versao limpa (codigo legivel)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/rodrigsapps/koala-dump/refs/heads/main/koala"))()
```

## O que faz

- **Scan** — varre o jogo atras de RemoteEvent / RemoteFunction / BindableEvent / BindableFunction / UnreliableRemoteEvent
- **Spy** — hook em `__namecall`: registra toda chamada de remote (nome, caminho, argumentos) em tempo real
- **Dump** — gera um `.lua` com tudo e envia pro seu Discord via webhook (anexo de arquivo). Tambem copia pro clipboard e salva com `writefile()`

## Como usar

1. Rode o script
2. Va na aba **Webhook** e cole a URL do seu canal do Discord
3. Deixe o **Spy** ligado enquanto joga
4. Clique em **Gerar e enviar dump**
