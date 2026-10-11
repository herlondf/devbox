# Design system do Devbox

Padrões de cor, texto, medida e disposição para toda tela nova ou mexida. As cores e
fontes vêm do tema da ComponentesUI (`UITheme.Tokens`); as medidas, de constantes em
`Devbox.UI.Kit` (prefixo `DS`). Nunca escrever cor em hex ou medida solta numa tela.

## 1. Princípios

1. **Uma ação principal por área.** Só um botão `bvPrimary` por barra ou cartão.
2. **O que é, o que faz.** Toda opção tem título curto e uma linha dizendo o efeito.
3. **Ler antes de agir.** Ações que apagam ou mudam algo fora do Devbox pedem confirmação.
4. **IA pelo assistente.** Nada de botão "com IA" na tela. O assistente (botão redondo)
   vê o que está aberto (`PageContext`) e age pelas ferramentas `devbox_*`.
5. **Detalhe ao lado.** Conteúdo de um item (e-mail, log, issue) abre no painel lateral
   (`TSidePeek`), e a lista fica com a tela toda.

## 2. Cores

Sempre pelos tons semânticos (`TUISemanticTone` / `UITheme.Tokens.Color`).

| Tom | Claro | Escuro | Quando usar |
| --- | --- | --- | --- |
| `Primary` | `#4F46E5` | `#6366F1` | Ação principal, item ativo, número neutro de destaque |
| `Info` | `#2563EB` | `#3B82F6` | Informação, e-mail, conta |
| `Success` | `#16A34A` | `#22C55E` | Feito, ligado, foco, espaço liberado |
| `Warning` | `#D97706` | `#F59E0B` | Atenção sem urgência: prazo perto, pedindo atenção |
| `Error` | `#DC2626` | `#EF4444` | Atrasado, falhou, perigo |
| `FG` / `FGMuted` | tema | tema | Texto / texto secundário e dicas |
| `Border`, `BGSubtle` | tema | tema | Divisórias, fundo de bolha e de código |

Regras:
- Cartão de número (`TUIStat`) sempre com tom. O tom diz o tipo do número, não enfeita.
- Um número que piora muda de tom (`Warning` para `Error`), não de lugar.
- Badge de estado em tabela: `Success` ligado, `FGMuted` desligado, `Error` falhou.

## 3. Texto

Fonte do tema: **Inter** para tudo, **JetBrains Mono** para código, log e comando.

| Uso | Tamanho | Peso | Componente |
| --- | --- | --- | --- |
| Título da tela | 20 | negrito | cabeçalho da janela (Caption da página) |
| Subtítulo da tela | 13 | normal, `FGMuted` | Hint da página |
| Título de seção ou cartão | 14 | negrito | `NewSection`, título de widget |
| Texto | 12 a 13 | normal | `TUILabel` |
| Dica / explicação | 12 | itálico, `FGMuted` | `NewHint` |
| Número de destaque | do `TUIStat` | negrito | `TUIStat` |

Escrita:
- Português simples, frases curtas, sem jargão. Termo técnico só quando é o nome da coisa.
- Rótulo de botão é verbo: "Analisar", "Avisar", "Remover aviso". Nada de "OK" ou "Executar".
- Estado vazio: título curto (até 4 palavras) + uma linha dizendo o que fazer.
  `EmptyState.Title` e `EmptyState.Description`, nunca a frase inteira no título.
- Sem travessão nos textos da tela.

## 4. Medidas

Constantes em `Devbox.UI.Kit` (px a 96 dpi; usar com `ScaleValue`).

| Constante | Valor | Uso |
| --- | --- | --- |
| `DSGap` | 12 | Entre cartões, entre colunas, entre números |
| `DSSectionTitleH` | 30 | Altura do título de cartão |
| `DSRowH` | 72 | Linha de configuração |
| `DSFieldH` | 44 | Campo, select e botão dentro da linha |
| `DSCardPadH` / `DSCardPadV` | 16 / 12 | Folga interna do cartão |

Grade do painel (`TUIDashboardGrid`): 12 colunas, linha de 36 px, folga 16.

## 5. Anatomia de uma tela

De cima para baixo:

1. **Cabeçalho** (da janela): título e subtítulo da página.
2. **Faixa de números** (opcional): 2 a 4 `TUIStat` com a mesma largura, dividindo a linha
   (`OnResize` reparte). Clicar num número leva ao detalhe dele.
3. **Abas** (opcional): `TUITabs`, uma por assunto. Uma linha de dica no topo de cada aba.
4. **Linha de busca ou formulário** (opcional): o campo principal ocupa o espaço; filtros à
   direita dele; a ação principal (`bvPrimary`) na ponta direita.
5. **Conteúdo**: tabela (`TUIDataTable`), lista (`TUIVirtualList`) ou grade.
6. **Barra de ações** (embaixo do conteúdo, `alBottom`): o que fazer com o que está
   selecionado. Ação que apaga na ponta direita; secundárias à esquerda (`bvGhost`).
7. **Rodapé** (da janela): atalhos da tela (`PageShortcuts`), F5 se a tela atualiza
   (`Refreshable`), e o assistente no canto direito.

Telas de configuração: cartões (`NewSection`) com linhas (`NewSettingRow`): título e
explicação à esquerda, controle à direita (toggle 60, select 300, botão 200).

## 6. Componentes e quando usar

| Precisa de | Use | Não use |
| --- | --- | --- |
| Número do dia, contagem | `TUIStat` com tom | Label solto |
| Lista com várias colunas | `TUIDataTable` (densidade compacta) | ListBox |
| Lista de itens com título e subtítulo | `TUIVirtualList` | Tabela de 1 coluna |
| Grupo de opções | `NewSection` + `NewSettingRow` | Toggles soltos na tela |
| Detalhe de um item | `TSidePeek` (painel lateral) | Painel fixo dividindo a tela |
| Confirmação de ação | aviso com botão de confirmar | Diálogo modal para tudo |
| Resultado de ação | toast (`TUIToastManager`) | Diálogo |
| Aviso fora da janela | `Notify` (balão da bandeja) | Toast |
| Atalho de teclado na tela | `PageKey` + `PageShortcuts` | Botão só para atalho |

## 7. Botões

- `bvPrimary`: a ação principal da área. Uma só.
- `bvOutline`: ações normais.
- `bvGhost`: secundárias e destrutivas (Remover, Excluir), sempre na ponta direita da barra.
- Botão de fechar: ícone X (`LineIcon('M6 18 18 6M6 6l12 12')`), com dica "Fechar (Esc)".
- Botão com só ícone sempre tem dica (`Hint`).

## 8. Movimento

- Painel lateral desliza 40 px em 160 ms (`aeEaseOutCubic`), movendo a janela pintada.
- Números do `TUIStat` animam só quando mudam.
- Nada de animação em lista grande; troca de aba sem animação.

## 9. Checklist de tela nova

- [ ] Caption e Hint da página preenchidos (Hint diz para que serve, em uma linha).
- [ ] Números (se houver) com tom e mesma largura.
- [ ] Uma ação principal por área; destrutiva na ponta direita.
- [ ] Estado vazio com título curto e descrição.
- [ ] `Refreshable`/`PageRefresh` se os dados mudam fora do Devbox.
- [ ] `PageShortcuts` com as teclas da tela.
- [ ] `PageContext` se a tela mostra algo que o assistente deve poder ler.
- [ ] Nada de botão "com IA": a ação vira ferramenta do assistente.
- [ ] Conferida em 1180 × 840 e na largura mínima (860).
