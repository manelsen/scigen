# Mapeamento de Funcionalidades

## Nucleo de geracao

O sistema atual tem um motor pequeno em `scigen.pm`. Ele le arquivos de regras, expande um simbolo inicial e aplica pos-processamento de texto.

- `read_rules`: carrega regras, blocos `{ ... }`, includes, pesos `REGRA+N` e marcadores de nao repeticao `REGRA!`.
- `compute_re`: prepara a busca de tokens conhecidos dentro de cada expansao.
- `generate`: expande a partir de uma regra inicial e opcionalmente chama `pretty_print`.
- `expand`: escolhe alternativas aleatorias, substitui tokens, controla contadores `NOME+` e referencias `NOME#`, e evita repeticoes para regras marcadas com `!`.
- `pretty_print`: ajusta espacos, artigos indefinidos e capitalizacao em trechos LaTeX.

## Gramaticas e dados

As gramaticas ficam em arquivos `.in` no topo do repositorio.

- `scirules.in`: artigo cientifico, citacoes, secoes, figuras e BibTeX.
- `talkrules.in`: apresentacoes; inclui `scirules.in`.
- `system_names.in`: nomes de sistemas.
- `functions.in`: expressoes numericas para graficos.
- `graphviz.in`: diagramas Graphviz.
- `svg_figures.in`: figuras SVG para apresentacoes.

## Interfaces executaveis

- `scigen.pl`: CLI generica para expandir uma regra.
- `make-latex.pl`: orquestra artigo/apresentacao, figuras, BibTeX e pipeline LaTeX.
- `make-graph.pl`: gera grafico EPS via gnuplot.
- `make-diagram.pl`: gera diagrama EPS via Graphviz e `ps2epsi`.
- `make-talk-figure.pl`: gera SVG, converte para PNG/EPS.
- `scigend`: daemon TCP para nomes de sistemas.
- `test-scigend.pl`: cliente simples do daemon.

## Dependencias externas

O nucleo precisa apenas da linguagem e dos arquivos `.in`. Renderizacao completa depende de LaTeX, BibTeX, `dvips`, `ps2pdf`, `gnuplot`, Graphviz, Inkscape, ImageMagick e visualizadores como `gv`.

## Fronteiras para o rewrite

A reescrita deve separar quatro camadas: parser de regras, motor de expansao, formatacao/renderizacao e comandos. O primeiro contrato a preservar e a compatibilidade de leitura dos arquivos `.in`; o comportamento aleatorio exato do Perl pode mudar, desde que haja seeds deterministicas na nova implementacao.
