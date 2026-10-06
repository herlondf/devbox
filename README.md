<h1 align="center">Devbox</h1>

<p align="center">
  <b>A caixa de ferramentas do dev na bandeja do Windows.</b><br>
  Clipboard com histórico, expansor de texto, containers, limpeza, rede, agendador, IA e mais, num app só.
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
- O que apaga ou encerra pede confirmação. Lixo de build sai de vez; arquivos grandes e pastas vazias vão para a Lixeira.
- O expansor de texto e a captura de tela rodam num exe separado, `DevboxHelper.exe`, que o Devbox abre e fecha junto.

## IA

Funciona com a Anthropic (Claude) ou com qualquer endpoint compatível com OpenAI, como Ollama ou um gateway próprio. Configure em **Configurações › IA**.

## Compilar do código

> **Aviso:** o Devbox usa a suíte de componentes [ComponentesUI](https://github.com/herlondf/componentesui), que hoje é **privada**. Sem acesso a ela não dá para compilar.

Precisa do RAD Studio 12 (Studio 22.0) e da ComponentesUI em `..\Delphi\ComponentesUI`. Para outro lugar, mude a propriedade `CUI` do projeto.

Na IDE: abra `src\Devbox.dproj` e `src\DevboxHelper.dproj` (os dois saem em `bin\Win32\<config>`). O self-check fica em `tests\DevboxTests.dproj` e termina com `TUDO OK`.

## Feito com a ComponentesUI

O Devbox também é vitrine da suíte. Usa menu lateral (`TUISidebar`), tabelas com selos e minigráficos (`TUIDataTable`), gráficos (`TUIChart`: treemap, barras), `TUIStat`, `TUISparkline`, `TUITimeline`, `TUISteps`, `TUICountdown`, `TUIRadialProgress`, `TUIVirtualList`, `TUICode`, `TUIImage`, `TUIDropdown`, `TUITabs`, `TUIFilterChip`, `TUIToggle`, `TUICheckbox`, `TUISelect`, `TUIInput`, `TUITextArea`, `TUIBadge`, `TUIStatus`, `TUIEmptyState`, `TUISwap` e `TUIToastManager`.

## Licença

[MIT](LICENSE).

> 🇺🇸 English version: [README_en.md](README_en.md)
