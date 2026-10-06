# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [0.2.0] - 2026-10-06

### Adicionado
- Menu lateral com telas por assunto (Dia a dia, Ambiente, Automação).
- Clipboard guarda imagem (PNG) e arquivos copiados; OCR do Windows, salvar PNG, SHA-256 e zip.
- Conversores no clipboard: JSON, Base64, URL, JWT, timestamp, hashes, linhas, GUID.
- Expansor de texto (`;atalho` em qualquer programa) com campos `{{nome}}` e atalhos prontos.
- Foco e reunião: pausa clipboard e avisos, liga sozinho com câmera/microfone, minutos de foco por dia.
- Ferramentas: captura de tela para bug com marcação, comparar `.env`, log ao vivo.
- Limpeza: lixo de build, temporários e caches, arquivos grandes (treemap), pastas vazias, imagens órfãs, inicialização.
- Rede: monitor de URLs com certificado, aviso de VPN, receptor de webhook local (porta 4081).
- Sistema: CPU, memória, discos e processos ao vivo; editor do PATH do usuário com desfazer.
- Ambientes de projeto, Comando por IA, Agendador e Avisos de fim.
- IA: Anthropic ou endpoint compatível com OpenAI; chave no Credential Manager.
- `DevboxHelper.exe`: expansor e captura de tela num exe separado, aberto e fechado pelo Devbox.

### Mudado
- Uma instância por pasta de dados (antes, por usuário).

### Removido
- Histórico dos terminais (chegou a existir durante o desenvolvimento): ler o histórico do PowerShell fazia o antivírus apagar o Devbox.exe.

## [0.1.0] - 2026-10-05

### Adicionado
- Histórico do clipboard (200 textos) com busca, prévia e filtro de snippets.
- Snippets: fixar e desafixar um item do histórico.
- Win+Alt+B abre a busca de qualquer programa. Enter cola na janela de antes.
- Filtro de segredo: pula o que gerenciador de senha marca como sigiloso e texto com cara de token, chave privada ou JWT.
- Aba Serviços: containers do Docker Desktop e do Podman ou Docker dentro das distros WSL ligadas, com iniciar, parar, reiniciar e logs.
- Distros WSL: estado, abrir terminal, desligar uma, desligar o WSL todo.
- Portas TCP em escuta com processo, PID e container que publica a porta. Abrir no navegador e encerrar processo com confirmação no aviso.
- Configurações: guardar clipboard, atalho global, iniciar com o Windows, limpar histórico.
- Tema claro e escuro.
