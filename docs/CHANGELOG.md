# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).

## [0.4.0] - 2026-10-09

### Adicionado
- Hoje: primeira tela do menu, numa grade. Números do dia (compromissos, e-mails não lidos, issues pedindo atenção, foco), listas de agenda, e-mails e issues que pedem atenção (atrasada, vence hoje, impedida, CI falhou, review, menção), atividade recente nas issues, issues por status e minutos de foco na semana. Cada linha abre a tela certa.
- Pomodoro (grupo Produtividade): trabalho e pausa em ciclos, pausa longa a cada N, liga o modo foco no trabalho, conta os pomodoros do dia. Também na bandeja (menu e tempo na dica do ícone).
- Paleta de comandos do Devbox inteiro (Ctrl+K em qualquer tela): telas, foco, pomodoro, captura, voz, novo snippet, "Resumo do meu dia" e as issues.
- Rodapé de atalhos em todas as telas, com os atalhos de cada uma. F5 atualiza a tela da frente.
- Painel lateral fora da janela: e-mail aberto, logs de container e detalhe da issue abrem ao lado da janela.
- Assistente (botão redondo) em todas as telas, no canto do rodapé. Vê o que está aberto (item do Clipboard, e-mail, log), copia o resultado, roda comando com confirmação e faz o resumo do dia (agenda e e-mails não lidos) quando pedido.
- Chat do assistente com formatação: título, listas, negrito, itálico, código e link (markdown).
- Gemini como provedor de IA.
- Voz: agenda de qualquer dia (amanhã, AAAA-MM-DD) e issues abertas (todas, vencendo, atrasadas, impedidas, mencionado, detalhe por chave).
- Configuração › Issues: contas e preferências das Issues. A tela Issues fica só com a lista.

### Mudado
- Menu: Início (Hoje, Issues), E-mail e agenda, Produtividade (Foco e reunião, Pomodoro), Ferramentas, Ambiente, Automação, Configuração.
- Clipboard e Expansor de texto viraram abas de Ferramentas. Win+Alt+B continua abrindo o Clipboard.
- Uma IA só: a config do assistente vale também para ações de texto e voz (Configuração › IA › Provedor). A config antiga só vale se a nova não estiver pronta.
- Botões de IA das telas (IA… do Clipboard, Explicar com IA dos logs, tela Comando por IA) deram lugar ao assistente.
- Resumo do dia automático saiu; o assistente resume quando pedido.
- Configuração › IA: aba Voz em cartões explicados; Custos com os dois painéis de custo, cada um dizendo a que se refere.
- Limpeza: onde procurar e Analisar numa linha; ações embaixo da tabela.
- Foco e Pomodoro com o mesmo anel, cartões e alturas.
- Serviços: cartões de números com a mesma largura e cor.
- Botões "Atualizar" trocados pelo F5.
- E-mail: clicar só abre o e-mail. Aplicar sugestões vale para todas; Delete descarta a do e-mail aberto.

### Corrigido
- O microfone do próprio Devbox (voz) não liga mais o modo reunião.
- Painel lateral sem partes transparentes e sem a sombra translúcida.

## [0.3.0] - 2026-10-08

### Adicionado
- Contas Google: login OAuth pelo navegador (PKCE, retorno na porta 4083), várias contas, ligar e desligar.
- E-mail: caixa de entrada das contas numa lista só (`TUIMailList`), corpo do e-mail, abrir no Gmail, marcar lido.
- Aviso na hora de e-mail importante não lido (a primeira checagem de cada conta não avisa o que já existia).
- Organizar com IA: sugestão de rótulo, arquivar ou marcar lido; aplica só os marcados, ao clicar.
- Agenda: agenda principal só para consulta (`TUIScheduler` com `ReadOnly`), próxima reunião, entrar no Meet, aviso N minutos antes.
- Resumo do dia: agenda de hoje e e-mails importantes resumidos pela IA numa hora marcada.
- Cliente OAuth embutido no build (`tools/google-client.ps1` lê fora do repo): entrar no Google é só um clique. Cliente próprio continua opcional.
- E-mail por IMAP com senha de app (Yahoo, iCloud, IMAP de empresa, Gmail): lista, corpo (MIME pelo Indy), aviso de não lido, marcar lido, arquivar e mover para pasta pela IA. TLS pelo SChannel do Windows, sem OpenSSL.
- Tela Contas com abas: Google, Outro e-mail (IMAP) e Agenda por link. Grupo do menu "E-mail e agenda".
- Voz com frase de ativação personalizável (padrão "Oi Java"): o Vosk (gramática só com a frase) confere o começo de cada fala; com palavra fora do vocabulário dele, o whisper confere. Comparação aproximada; aceita frase e pedido na mesma fala.
- Instalador por usuário (`installer/Devbox.iss`, Win64; voz como tarefa opcional) e scripts de release (`ci/build-release.ps1`, `ci/release.ps1`). Atualização automática pelas releases do Devbox (Configuração › Geral).
- Configuração › Geral ganha idioma das telas de Issues e atualizações; a aba de Issues deixa iniciar com o Windows, tema, idioma e atualizações para o Devbox.
- Telas não desenham mais o próprio título no meio quando sobra espaço (`ShowCaption` do TPanel).
- Tela **Issues** (o Vigia inteiro dentro do Devbox): Dashboard, Issues com detalhe, Contas, Configurações, Ctrl+K, assistente, janela mini, busca periódica e avisos; contador na bandeja; Win+Alt+V; modo foco segura os avisos. Primeira abertura importa o vigia.db e troca a inicialização com o Windows do Vigia pela do Devbox.
- SQLite em modo WAL: o Devbox e o ajudante leem e escrevem sem "database is locked".
- HUD: texto longo mostra o fim (o que está sendo dito), cabe na largura do painel e o painel cresce até 8 linhas.
- Voz: botão Testar saída e log de onde a voz sai (ou do erro ao abrir o aparelho).
- Unificação do Vigia, etapas 1 e 2: núcleo de issues (`Devbox.Issues.*`: GitHub, Jira Server/Cloud, GitLab, Azure DevOps, diff, tradução) e banco `issue_*` no devbox.db com importação única do vigia.db. Ainda sem tela.
- Menu com a seção Configuração: Geral e IA (abas Interna, Voz e Custos). `Devbox.exe -show -page <tela>` abre direto numa tela.
- Voz: escolha do microfone e da saída de voz (guardados pelo nome do aparelho) e log ao vivo do que o ouvido entende (memória, 300 linhas).
- Custos das IAs pagas: uso devolvido por cada API (tokens de texto e de áudio, minutos transcritos) em `ai_usage`, preço por modelo editável (`ai_price_<modelo>`, formato do Vigia com áudio) e teto do mês.
- Conversa ao vivo com OpenAI Realtime ou Gemini Live (WebSocket próprio sobre o SChannel): microfone sem eco em streaming, voz da IA em streaming (`TPcmStream`), interrupção falando por cima, ferramentas do Devbox (e-mails, agenda, próxima reunião, foco, abrir tela, encerrar) e fim por despedida ou 20 s de silêncio. Configurações › Voz: modo, modelo e chave.
- Devbox, ajudante e testes agora em 64 bits (Win64).
- Cancelamento de eco do WebRTC (AEC3 da `livekit_ffi.dll`, protobuf codificado à mão): a voz do Devbox sai do microfone antes do assistente ouvir. O DSP de eco do Windows foi testado e descartado (só 3,4 dB).
- Motor do pedido em Configurações › Voz: whisper base (processador), whisper large-v3-turbo (placa NVIDIA, `voice\whisper-cuda`), Groq ou OpenAI (chave no Credential Manager). `tools/voice-deps.ps1 -Gpu` baixa o da placa. Pedido gravado até o silêncio e transcrito localmente (whisper.cpp x64, `whisper-server` em 127.0.0.1:4085, fecha junto com o Devbox), ação escolhida pela IA (e-mails, agenda, próxima reunião, foco, abrir tela, conversa) e resposta falada pela voz pt-BR do Windows. HUD flutuante com `TUIAudioVisualizer` sobre disco escuro de borda nítida e sombra curta. `tools/voice-deps.ps1` baixa os arquivos de voz.
- Agenda por link iCal, sem login (repetição diária, semanal, mensal e anual, exceções, ocorrência movida, link de vídeo).

### Corrigido
- O Devbox fechava ao abrir pela bandeja (foco antes de a janela aparecer).
- Exceção na thread da captura de áudio derrubava a escuta sem aviso: agora é tratada (e registrada com `DEVBOX_VOICE_LOG`).
- Violação de acesso ao sair: resposta de tarefa de fundo (busca de e-mail) rodava depois de a tela ser destruída. Toda resposta de tarefa passa por `QueueUI`, que descarta o que chega na saída.

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
