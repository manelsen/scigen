# Repository Guidelines

## Project Structure & Module Organization

This repository contains the original SCIgen Perl codebase. Core grammar expansion lives in `scigen.pm`; command-line entry points are top-level Perl scripts such as `scigen.pl`, `make-latex.pl`, `make-graph.pl`, `make-diagram.pl`, and `make-talk-figure.pl`. `scigend` is the TCP daemon, with `test-scigend.pl` as its smoke-test client.

Grammar and asset inputs are top-level `.in` files: `scirules.in`, `talkrules.in`, `system_names.in`, `functions.in`, `graphviz.in`, and `svg_figures.in`. LaTeX support files (`IEEEtran.cls`, `IEEE.bst`) are checked in. There is no separate `src/` or `test/` tree.

## Build, Test, and Development Commands

- `perl -I. -c scigen.pl` checks syntax for the main grammar expander.
- `perl -I. -c make-latex.pl` checks the paper/talk generator.
- `perl -I. scigen.pl --filename scirules.in --start SCI_TITLE --pretty 0` generates a sample title from the paper grammar.
- `perl -I. make-latex.pl --author "Ada Lovelace" --seed 123 --savedir /tmp/scigen-out` writes generated LaTeX without the full rendering pipeline.
- `./scigend` starts the daemon on the port defined in `scigen.pm`; in another shell, run `perl -I. test-scigend.pl`.
- `raku -Ilib t/01-core.rakutest` runs the Raku rewrite tests.
- `./bin/scigen-raku paper --savedir /tmp/scigen-paper --seed 5 --force` generates Raku LaTeX output.

Full PDF/PostScript generation may require LaTeX, BibTeX, `dvips`, `ps2pdf`, `gnuplot`, Graphviz (`dot`/`neato`), Inkscape, ImageMagick `convert`, and `gv`.
Raku `--render` commands perform dependency pre-flight and report missing commands before executing external tools.
Optional LLM analysis is provider-neutral: use OpenAI-compatible settings via `SCIGEN_LLM_BASE_URL`, `SCIGEN_LLM_API_KEY`/`OPENAI_API_KEY`, and `SCIGEN_LLM_MODEL`.
The `analyze` command also reads `.env` or `--env-file`; explicit CLI flags override environment variables, which override `.env` values.

## Coding Style & Naming Conventions

Use Perl with `use strict`; keep the existing procedural style and package names. Follow the repository’s tab-based indentation in legacy blocks. Script filenames use lowercase hyphenated names ending in `.pl`; modules use established `.pm` names. Grammar rule names are uppercase tokens such as `SCI_TITLE` and `SYSTEM_NAME`.

## Testing Guidelines

There is no formal test framework. Validate changes with Perl syntax checks and at least one deterministic generation command using `--seed` where supported. For grammar edits, exercise the changed start rule directly with `scigen.pl`. For daemon behavior, run `scigend` and `test-scigend.pl`. Current Perl versions may emit legacy regex/comment warnings during syntax checks; do not introduce new warnings.

## Commit & Pull Request Guidelines

The history is minimal and uses short, sentence-style commit subjects, for example `Original SCIgen code from 2005.` Keep commits focused and describe the changed behavior or file family. Pull requests should include a summary, commands run, external tool requirements, and sample generated output when grammar or rendering behavior changes.

## Security & Configuration Tips

Generated files are written under `/tmp` by default, and some scripts shell out to external commands. Quote user-provided paths and names carefully, keep generated artifacts out of the repository, and avoid changing the daemon port unless coordinating with users of `scigend`.
