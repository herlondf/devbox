<h1 align="center">Devbox</h1>

<p align="center">
  <b>A caixa de ferramentas do dev na bandeja do Windows.</b><br>
  Clipboard com histórico, expansor de texto, Gmail e Agenda, containers, limpeza, rede, agendador, IA e mais, num app só.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows" alt="Windows 10 e 11">
  <img src="https://img.shields.io/badge/Delphi-VCL%20%2B%20Skia-E62431" alt="Delphi VCL + Skia">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licen%C3%A7a-MIT-blue" alt="Licença MIT"></a>
</p>

<p align="center">
  <img src="docs/images/clipboard.png" width="820" alt="Clipboard do Devbox">
</p>

---

## O que tem

**Dia a dia**
- **Clipboard:** histórico de texto, imagem e arquivos, com busca e snippets fixos. Win+Alt+B abre de qualquer programa e Enter cola onde você estava.
- **Conversores:** JSON formatado ou numa linha, Base64, URL, JWT, timestamp, SHA-256, MD5, maiúsculas, ordenar e tirar linhas repetidas, GUID.
- **Imagem e arquivos copiados:** OCR (texto da imagem pelo próprio Windows), salvar PNG, SHA-256 e zip dos arquivos.
- **Expansor de texto:** `;atalho` em qualquer programa vira o snippet. Campos `{{nome}}` são perguntados antes de colar. Já vem com `;data`, `;hora`, `;agora`, `;guid` e `;ts`.
- **Foco e reunião:** clipboard em pausa e avisos guardados para o fim. Liga por 25 ou 50 minutos, até você desligar, ou sozinho quando a câmera ou o microfone estão em uso. Mostra o tempo de foco por dia.
- **Ferramentas:** captura de tela para bug (seta, retângulo, texto, número de passo e borrar), comparar `.env` com `.env.example` e log ao vivo com erro em vermelho.

**E-mail e agenda**
- **E-mail:** caixa de entrada das suas contas numa lista só, com cor por conta. Gmail pelo login do Google; Yahoo, iCloud e IMAP de empresa com senha de app. Aviso na hora para e-mail importante não lido.
- **Organizar com IA:** a IA lê os e-mails e sugere rótulo (pasta, no IMAP), arquivar ou marcar como lido. Nada muda sem você clicar em Aplicar.
- **Agenda:** dia, semana, mês ou lista da agenda principal. Aviso antes de cada reunião e um botão para entrar no Meet. Também aceita agenda por link iCal (sem login), de qualquer serviço.
- **Resumo do dia:** numa hora marcada, a IA junta a agenda de hoje e os e-mails importantes num texto curto.

**Voz**
- **Frase de ativação:** diga a sua frase (padrão "Oi Java") e o pedido, junto ou depois de uma pausa ("Oi Java, resuma meus e-mails importantes", "qual minha próxima reunião", "liga o modo foco", "abre a agenda"). Um HUD com visualizador de áudio aparece no canto da tela e o Devbox responde falando.
- **Conversa ao vivo** (opcional): depois da frase, você conversa direto com a OpenAI Realtime ou a Gemini Live, ouve a resposta enquanto ela é gerada e pode interromper falando por cima. A IA usa as ferramentas do Devbox (e-mails, agenda, próxima reunião, modo foco, abrir tela) e encerra quando você se despede ou fica 20 s em silêncio.
- A frase é conferida no próprio computador (Vosk). O pedido vira texto pelo motor que você escolher: whisper local (processador ou placa NVIDIA) ou nuvem (Groq ou OpenAI).

**Ambiente**
- **Serviços:** containers do Docker no Windows e do Podman ou Docker nas distros WSL ligadas, com iniciar, parar, reiniciar e logs. Distros WSL. Portas em escuta com o processo dono.
- **Limpeza:** lixo de build de projetos parados (`node_modules`, `bin/obj`, `dcu`, `target`...), temporários e caches, arquivos grandes com gráfico por tipo, pastas vazias, imagens órfãs de container e programas que iniciam com o Windows.
- **Rede:** monitor de URLs com tempo e vencimento do certificado, aviso de VPN e um receptor de webhook local para testar integrações.
- **Sistema:** CPU, memória, discos e processos ao vivo. Editor do PATH do usuário que acha pastas que não existem e repetidas.

**Automação**
- **Ambientes de projeto:** um roteiro de passos liga distro, containers, terminal, editor e navegador num clique.
- **Comando por IA:** diga o que quer; a IA escreve o comando, você confere e decide se roda.
- **Agendador:** comandos a cada N minutos, todo dia ou em dias da semana, com histórico e aviso de falha.
- **Avisos de fim:** avisa quando um processo termina, uma porta fecha ou um container para.

<p align="center">
  <img src="docs/images/rede.png" width="410" alt="Rede">
  <img src="docs/images/foco.png" width="410" alt="Foco">
</p>

## Teclas

| Tecla | Faz |
|---|---|
| Win+Alt+B | Abre ou esconde a busca do clipboard |
| Win+Alt+S | Captura de tela para bug |
| ↑ ↓ e Enter | Escolhem e colam na janela de antes |
| Esc | Esconde a janela |

Fechar a janela só esconde. Para sair, use **Sair** no menu da bandeja.

## Privacidade e segurança

- Tudo fica em `%LOCALAPPDATA%\Devbox\devbox.db` (SQLite), só na sua máquina.
- Senha marcada pelo gerenciador de senhas e texto com cara de token ou chave não entram no histórico.
- A chave da IA fica no Credential Manager do Windows. O texto só vai para a IA quando você clica.
- O acesso às contas Google (refresh token), a senha de app do IMAP, os links iCal e a chave do cliente OAuth também ficam no Credential Manager. Organizar com IA e o resumo do dia mandam o texto inteiro dos e-mails para a IA que você configurou.
- O que apaga ou encerra pede confirmação. Lixo de build sai de vez; arquivos grandes e pastas vazias vão para a Lixeira.
- O expansor de texto e a captura de tela rodam num exe separado, `DevboxHelper.exe`, que o Devbox abre e fecha junto.

## IA

Funciona com a Anthropic (Claude) ou com qualquer endpoint compatível com OpenAI, como Ollama ou um gateway próprio. Configure em **Configurações › IA**.

## Google

Em **Contas › Google**, clique em **Adicionar conta** e entre com o Google no navegador. O Devbox fala direto com o Google, sem servidor no meio. O app não é verificado pelo Google, então o login mostra um aviso: siga por **Avançado**. Acesso pedido: ler e organizar o Gmail (`gmail.modify`) e ler a Agenda (`calendar.readonly`). O retorno do login usa a porta 4083 desta máquina.

Só a agenda, sem login: no Google Agenda, em Configurações da agenda, copie o **Endereço secreto em formato iCal** e cole em **Contas › Agenda por link**. Serve qualquer link `.ics`.

Outro e-mail: em **Contas › Outro e-mail (IMAP)**, informe o e-mail e uma **senha de app** (gerada na segurança da conta, com verificação em 2 etapas). O servidor é sugerido pelo domínio. A conexão usa o TLS do próprio Windows (SChannel). Outlook e Hotmail não aceitam senha no IMAP.

### Cliente OAuth

O build oficial já traz um cliente OAuth. Quem compila do código pode usar o seu: o build lê `GOOGLE_OAUTH_CLIENT_ID` e `GOOGLE_OAUTH_CLIENT_SECRET` (variáveis de ambiente ou um arquivo fora do repo, em `DEVBOX_VAULT`) e gera o include na pasta `dcu`, que não vai para o git. Sem eles, o app pede o cliente na tela (Contas › Google). Para criar um (uns 10 minutos):

1. Em [console.cloud.google.com](https://console.cloud.google.com), crie um projeto.
2. Em **APIs e serviços › Biblioteca**, ative a **Gmail API** e a **Google Calendar API**.
3. Em **Tela de consentimento OAuth**, escolha "Externo", preencha nome e e-mail e mude a publicação para **Em produção**. Em "Teste", o Google derruba o acesso a cada 7 dias.
4. Em **Credenciais › Criar credenciais › ID do cliente OAuth**, escolha **App para computador**.
5. Passe o ID e a chave pelo build (acima) ou cole em **Contas › Google › Cliente OAuth próprio**.

## Voz

Em **Configurações › Voz**, ligue "Ouvir a frase de ativação", escreva a sua frase e escolha quem transcreve o pedido:

| Motor | Tempo por pedido (medido) | Onde roda |
| --- | --- | --- |
| Local rápido (whisper base) | ~1,2 s | processador |
| Local preciso (whisper large-v3-turbo) | ~0,7 a 1,5 s com RTX 3050; 7 a 25 s sem placa | placa NVIDIA |
| Nuvem: Groq (whisper-large-v3-turbo) | não medido | o áudio do pedido sai do PC |
| Nuvem: OpenAI (gpt-4o-transcribe) | não medido | o áudio do pedido sai do PC |

Os arquivos de voz não vêm no repositório. Rode `tools\voice-deps.ps1`: ele baixa o Vosk (~100 MB), o cancelamento de eco (~25 MB) e o whisper base (~75 MB) para a pasta `voice` ao lado do exe. Com `-Gpu`, também baixa o whisper com CUDA e o modelo grande (~1,8 GB). A chave da nuvem fica no Credential Manager.

Para a conversa ao vivo, escolha OpenAI Realtime ou Gemini Live em **Configurações › Voz**, cole a chave (fica no Credential Manager) e, se quiser, troque o modelo (padrão `gpt-realtime-2.1` e `gemini-3.8-live`). O áudio do microfone vai para a empresa escolhida durante a conversa.

A voz que o Devbox toca é tirada do microfone pelo cancelamento de eco do WebRTC (o mesmo do Chrome): o assistente não ouve a própria resposta, sem fone. A frase passa pelo Vosk, que só conhece a sua frase (~60 a 110 ms por fala). Se uma palavra da frase não estiver no vocabulário dele (ex.: "Jarvis"), a frase é conferida pelo whisper, que é mais lento. Com a voz ligada, o Windows mostra o microfone em uso o tempo todo.

## Compilar do código

> **Aviso:** o Devbox usa a suíte de componentes [ComponentesUI](https://github.com/herlondf/componentesui), que hoje é **privada**. Sem acesso a ela não dá para compilar.

Precisa do RAD Studio 12 (Studio 22.0) e da ComponentesUI em `..\Delphi\ComponentesUI`. Para outro lugar, mude a propriedade `CUI` do projeto.

Na IDE: abra `src\Devbox.dproj` e `src\DevboxHelper.dproj` (plataforma **Win64**; os dois saem em `bin\Win64\<config>`). O self-check fica em `tests\DevboxTests.dproj` e termina com `TUDO OK`.

## Feito com a ComponentesUI

O Devbox também é vitrine da suíte. Usa menu lateral (`TUISidebar`), lista de e-mails (`TUIMailList`), agenda (`TUIScheduler`), visualizador de áudio (`TUIAudioVisualizer`, com `TUIAudioCapture`), tabelas com selos e minigráficos (`TUIDataTable`), gráficos (`TUIChart`: treemap, barras), `TUIStat`, `TUISparkline`, `TUITimeline`, `TUISteps`, `TUICountdown`, `TUIRadialProgress`, `TUIVirtualList`, `TUICode`, `TUIImage`, `TUIDropdown`, `TUITabs`, `TUIFilterChip`, `TUIToggle`, `TUICheckbox`, `TUISelect`, `TUIInput`, `TUITextArea`, `TUIBadge`, `TUIStatus`, `TUIEmptyState`, `TUISwap` e `TUIToastManager`.

## Licença

[MIT](LICENSE).

> 🇺🇸 English version: [README_en.md](README_en.md)
