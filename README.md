# ollama-ask.sh

`ollama-ask.sh` is a small Bash CLI for asking one-shot questions to a local
Ollama model through the `/api/chat` endpoint.

It is intended for quick terminal use: pass a prompt, optionally attach local
documents, and get a single response. By default only the answer itself is
printed; timestamps and token usage are available on request.

## Features

- Ask a local Ollama model from Bash using `curl` and `jq`
- Select the model with `-m`
- Select the Ollama host with `-H`
- Add a system prompt with `-s`
- Add reference documents from a directory with `-d`
- Expand `@file` references inside the prompt
- Read PDF files via `pdftotext` when available
- Toggle thinking mode with `-T true|false`
- Show a "考え中... (Ns経過)" spinner while waiting, so a slow/thinking model
  doesn't look stalled
- Prints only the answer by default; show request/response timestamps,
  measured token usage, and the list of reference files loaded via `-d` with
  `-v`

## Requirements

- Bash
- `curl`
- `jq`
- Ollama
- A pulled Ollama model
- Optional: `pdftotext` from Poppler for PDF `@file` references

On macOS, the optional PDF dependency can be installed with:

```sh
brew install poppler
```

## Setup

Start Ollama:

```sh
ollama serve
```

Pull the model you want to use:

```sh
ollama pull gemma4:latest
```

Make the script executable:

```sh
chmod +x ollama-ask.sh
```

## Usage

Ask a simple question:

```sh
./ollama-ask.sh "日本語でOllamaの概要を説明して"
```

Use a specific model:

```sh
./ollama-ask.sh -m gemma4:latest "量子コンピュータを短く説明して"
```

Use a different Ollama host:

```sh
./ollama-ask.sh -H http://localhost:11434 "接続確認を兼ねて短く返答して"
```

Add a system prompt:

```sh
./ollama-ask.sh -s "あなたは簡潔に答えるアシスタントです" "Dockerとは何ですか？"
```

Change temperature:

```sh
./ollama-ask.sh -t 0.2 "この文章を校正して"
```

Enable thinking mode:

```sh
./ollama-ask.sh -T true "考え方も含めて説明して"
```

Show timestamps and token usage:

```sh
./ollama-ask.sh -v "日本語でOllamaの概要を説明して"
```

## Reference Documents

By default, the script reads `./data`. It recursively loads
`.md`, `.txt`, and `.csv` files from that directory and appends them to the
system prompt as reference material.

Use another directory:

```sh
./ollama-ask.sh -d ./docs "このフォルダの資料を要約して"
```

The loaded reference documents are treated as higher-priority context. If the
answer is not present in the documents, the model is instructed not to state
guesses as facts.

With `-v`, the list of loaded files is printed before the answer:

```text
---- 読み込んだ資料ファイル (3件) ----
  - ./docs/a.md
  - ./docs/c.csv
  - ./docs/sub/b.txt
```

## `@file` References

You can include local file contents directly in the user prompt by writing
`@path/to/file`.

```sh
./ollama-ask.sh "@notes.md の内容を要約して"
```

PDF files are supported when `pdftotext` is installed:

```sh
./ollama-ask.sh "@paper.pdf の要点を3つにまとめて"
```

File paths without spaces are recommended for `@file` references.

## Options

```text
-m MODEL   Model name. Default: gemma4:latest
-H HOST    Ollama base URL. Default: http://localhost:11434
-s SYSTEM  System prompt
-d DIR     Reference document directory. Reads *.md, *.txt, and *.csv recursively.
-t TEMP    Temperature. Default: 0.7
-T BOOL    Thinking mode. Use true or false. Default: false
-v         Verbose output: show timestamps, token usage, and warnings.
           Without it, only the answer is printed. Errors are always shown.
-h         Show help
```

## Publishing Notes

If you publish this script on GitHub, check any files committed under `data/`
beforehand. The script reads `./data` by default, so sample files should not
contain private notes, local network information, credentials, or other
environment-specific details.

## Troubleshooting

If Ollama is not running:

```text
エラー: http://localhost:11434 で Ollama に接続できません。
```

Start Ollama with:

```sh
ollama serve
```

If the model is not installed, pull it first:

```sh
ollama pull gemma4:latest
```

If PDF reading fails, install Poppler:

```sh
brew install poppler
```
