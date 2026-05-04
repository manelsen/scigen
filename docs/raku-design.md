# Desenho Raku

## Objetivo

Reescrever o SCIgen como um sistema Raku modular, mantendo as gramaticas `.in` como formato de entrada inicial. O rewrite nao tenta imitar cada detalhe acidental do Perl; ele define uma base limpa para testar, estender e substituir geradores.

## Modulos propostos

- `SCIgen::RuleBook`: armazena alternativas por regra, regras sem repeticao, arquivos incluidos e contadores.
- `SCIgen::RuleParser`: le arquivos `.in`, blocos multilinha, includes, pesos e marcadores `!`.
- `SCIgen::Expander`: expande uma regra inicial usando um gerador pseudoaleatorio deterministico.
- `SCIgen::Formatter`: aplica normalizacao textual e formatacao LaTeX.
- `SCIgen::Paper`: monta artigos, BibTeX e lista de artefatos a renderizar.
- `SCIgen::Figure`: descreve graficos, diagramas e figuras sem acoplar diretamente a shell.
- `SCIgen::Daemon`: expoe geracao por TCP quando necessario.

## Esqueleto de funcoes

```raku
sub load-rules(IO::Path $path --> RuleBook)
sub parse-rule-line(Str $line --> RuleSpec)
sub add-rule(RuleBook $book, Str $name, Str $body, Int $weight = 1)
sub generate(RuleBook $book, Str $start, :$seed, :$pretty --> Str)
sub expand-token(RuleBook $book, Str $token --> Str)
sub find-next-token(RuleBook $book, Str $input --> TokenMatch)
sub format-output(Str $text, :$latex --> Str)
sub build-paper(%options --> GeneratedPaper)
sub render-artifact(Artifact $artifact --> IO::Path)
sub serve-names(:$host, :$port)
```

## Decisoes iniciais

- Seeds devem ser deterministicas dentro do Raku, mesmo que nao coincidam com `srand` do Perl.
- Includes devem ser resolvidos relativos ao arquivo que os declarou, com fallback para o diretorio atual.
- Comandos externos devem ser chamados por listas de argumentos, nao por strings concatenadas.
- O CLI principal deve ser unico: `bin/scigen-raku generate --file scirules.in --start SCI_TITLE --seed 123`.

## CLI consolidado

O rewrite expõe uma única entrada:

```sh
bin/scigen-raku generate --file scirules.in --start SCI_TITLE --seed 123 --no-pretty
bin/scigen-raku name --seed 7 --no-effects
bin/scigen-raku paper --savedir /tmp/scigen-paper --seed 5 --force
bin/scigen-raku graph --file /tmp/graph.eps --seed 3
bin/scigen-raku diagram --sysname TestSys --file /tmp/diagram.eps --seed 4
bin/scigen-raku talk-figure --type anything --file /tmp/talkfig.eps --seed 6
bin/scigen-raku analyze --text "abstract..." --env-file .env --llm-model model-id
bin/scigen-raku daemon --host 127.0.0.1 --port 4724
```

Sem `--render`, os comandos escrevem fontes intermediarias testaveis (`.tex`, `.gnuplot`, `.dot`, `.svg`) e evitam depender de ferramentas externas. Com `--render`, os adaptadores fazem pre-flight das dependencias e falham antes de executar se faltar algum comando. Dependencias por modo:

- `paper --render`: `latex`, `bibtex`, `dvips`; talks tambem usam `ps2pdf`.
- `graph --render`: `gnuplot`.
- `diagram --render`: programa Graphviz escolhido pela gramatica (`dot` ou `neato`) e `ps2epsi`.
- `talk-figure --render`: `inkscape` e ImageMagick `convert`.

## Estado da reescrita

Implementado: parser `.in`, expansor, CLI consolidado, geração de nomes, geração de paper/talk em LaTeX, fontes de grafico, fontes Graphviz, fontes SVG de talk figure e daemon TCP.

Ainda deliberadamente separado: compatibilidade bit a bit com `srand` do Perl e renderizacao sempre-on. O rewrite prefere determinismo interno, limites de expansao e comandos externos opt-in.

## API OpenAI-compatible

A analise LLM e generica para qualquer provedor compativel com `/v1/chat/completions`. Configuracao pode vir de flags, ambiente real ou `.env`, nessa ordem de prioridade:

- `SCIGEN_LLM_BASE_URL`: base URL, padrao `https://api.openai.com/v1`.
- `SCIGEN_LLM_API_KEY` ou `OPENAI_API_KEY`: chave.
- `SCIGEN_LLM_MODEL`: modelo.
- `--env-file`: caminho do arquivo dotenv; padrao `.env`.

Formato `.env` aceito:

```dotenv
SCIGEN_LLM_BASE_URL=https://provider.example/v1
SCIGEN_LLM_API_KEY=...
SCIGEN_LLM_MODEL=model-id
```

O comando `analyze` monta e valida a requisicao, mas chamadas de rede permanecem isoladas para evitar acoplar o gerador a um provedor especifico. A regra de produto continua: o LLM pode analisar abstracts/metadados, mas nao pode inventar citacoes; DOI, autores e titulos devem vir de bases bibliograficas.
