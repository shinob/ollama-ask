#!/usr/bin/env bash
#
# ollama-ask.sh
#
# 使い方:
#   ./ollama-ask.sh "質問文"
#   ./ollama-ask.sh -m qwen3.5:9b "質問文"
#   ./ollama-ask.sh -m gemma4:latest -s "あなたは親切なアシスタントです" "質問文"
#   ./ollama-ask.sh -d ./docs "このフォルダの資料の内容について要約して"
#   ./ollama-ask.sh "@notes.md の内容を要約して"   (質問文中に @ファイルパス と書くと
#                                                    その内容を展開してユーザーメッセージに含める。
#                                                    *.pdf は pdftotext があれば対応)
#
# オプション:
#   -m MODEL   使用するモデル名 (デフォルト: gemma4:latest)
#   -H HOST    Ollama のベースURL (デフォルト: http://localhost:11434)
#   -s SYSTEM  システムプロンプト (省略可)
#   -d DIR     参考資料フォルダのパス。配下の *.md / *.txt / *.csv を再帰的に読み込み、
#              システムプロンプトに参考資料として付与する (省略可)
#   -t TEMP    temperature (デフォルト: 0.7)
#   -T BOOL    思考(thinking)モードの有効/無効。true か false (デフォルト: false)
#              思考過程も含めたい場合は -T true で有効化する
#   -v         詳細情報を表示 (時刻・トークン使用量・警告など)。
#              指定しない場合は回答本文のみを出力する (エラーは常に表示)
#   -h         このヘルプを表示
#
# 事前準備:
#   - Ollama が起動していること (`ollama serve`)
#   - jq コマンドがインストール済みであること
#   - 使用したいモデルを事前に `ollama pull <model>` していること
#   - @file 参照で .pdf を読み込む場合は pdftotext (poppler) がインストール済みであること

set -euo pipefail

#MODEL="qwen3.5:9b"
MODEL="gemma4:latest"
OLLAMA_HOST="http://localhost:11434"
SYSTEM=""
DOCS_DIR="./data"
TEMP="0.7"
THINK="false"
VERBOSE="false"

usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "m:H:s:d:t:T:vh" opt; do
    case "$opt" in
        m) MODEL="$OPTARG" ;;
        H) OLLAMA_HOST="$OPTARG" ;;
        s) SYSTEM="$OPTARG" ;;
        d) DOCS_DIR="$OPTARG" ;;
        t) TEMP="$OPTARG" ;;
        T)
            if [[ "$OPTARG" != "true" && "$OPTARG" != "false" ]]; then
                echo "エラー: -T には true か false を指定してください。" >&2
                exit 1
            fi
            THINK="$OPTARG"
            ;;
        v) VERBOSE="true" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
    echo "エラー: プロンプトを指定してください。" >&2
    usage
fi
PROMPT="$*"

if ! command -v jq >/dev/null 2>&1; then
    echo "エラー: jq コマンドが見つかりません。'brew install jq' などでインストールしてください。" >&2
    exit 1
fi

if ! curl -s --max-time 2 "${OLLAMA_HOST}/api/version" >/dev/null 2>&1; then
    echo "エラー: ${OLLAMA_HOST} で Ollama に接続できません。'ollama serve' が起動しているか確認してください。" >&2
    exit 1
fi

if [[ -n "$DOCS_DIR" ]]; then
    if [[ ! -d "$DOCS_DIR" ]]; then
        echo "エラー: 指定されたフォルダが見つかりません: ${DOCS_DIR}" >&2
        exit 1
    fi

    CONTEXT_DOC=""
    while IFS= read -r f; do
        CONTEXT_DOC+=$'\n\n---- ファイル: '"$f"$' ----\n'
        CONTEXT_DOC+="$(cat "$f")"
    done < <(find "$DOCS_DIR" -type f \( -name "*.md" -o -name "*.txt" -o -name "*.csv" \) | sort)

    if [[ -z "$CONTEXT_DOC" ]]; then
        [[ "$VERBOSE" == "true" ]] && echo "警告: ${DOCS_DIR} 内に .md / .txt / .csv ファイルが見つかりませんでした。" >&2
    else
        NOTE="以下はユーザーが指定した参考資料です。回答にはこの資料の内容を優先して用い、資料に書かれていないことは推測で断定せず、その旨を伝えてください。"
        SYSTEM="${SYSTEM:+${SYSTEM}$'\n\n'}${NOTE}${CONTEXT_DOC}"
    fi
fi

# プロンプト中の @ファイルパス をファイル内容に展開する
for _w in $PROMPT; do
    [[ "$_w" == @* ]] || continue
    _fp="${_w#@}"

    if [[ ! -f "$_fp" ]]; then
        echo "エラー: ファイルが見つかりません: ${_fp}" >&2
        echo "  フルパスで指定してください。例: @\$HOME/Downloads/${_fp##*/}" >&2
        exit 1
    fi

    if [[ "$_fp" == *.pdf ]]; then
        if ! command -v pdftotext >/dev/null 2>&1; then
            echo "エラー: PDF を読むには pdftotext が必要です。'brew install poppler' でインストールしてください。" >&2
            exit 1
        fi
        [[ "$VERBOSE" == "true" ]] && echo "PDFを読み込み中: ${_fp##*/} ..." >&2
        _fc=$(pdftotext "$_fp" -)
    else
        _fc=$(cat "$_fp")
    fi

    PROMPT="${PROMPT//$_w/$'\n\n---- ファイル: '"$_fp"$' ----\n'"$_fc"$'\n---- ファイル終端 ----\n'}"
done

JQ_TMP_DIR=$(mktemp -d)
RESPONSE_FILE=$(mktemp)
trap 'rm -rf "$JQ_TMP_DIR"; rm -f "$RESPONSE_FILE"; printf "\033[?25h" >&2' EXIT

# SYSTEM/PROMPT はフォルダ資料や @ファイル展開で巨大になりうるため、
# jq の引数(--arg)ではなく --rawfile でファイル経由で渡し、ARG_MAX 超過を回避する
MESSAGES_FILE="${JQ_TMP_DIR}/messages.json"
echo "[]" > "$MESSAGES_FILE"
if [[ -n "$SYSTEM" ]]; then
    printf '%s' "$SYSTEM" > "${JQ_TMP_DIR}/system.txt"
    jq -n --rawfile s "${JQ_TMP_DIR}/system.txt" '[{role: "system", content: $s}]' > "$MESSAGES_FILE"
fi
printf '%s' "$PROMPT" > "${JQ_TMP_DIR}/prompt.txt"
jq -n --slurpfile base "$MESSAGES_FILE" --rawfile p "${JQ_TMP_DIR}/prompt.txt" \
    '$base[0] + [{role: "user", content: $p}]' > "${JQ_TMP_DIR}/messages_new.json"
mv "${JQ_TMP_DIR}/messages_new.json" "$MESSAGES_FILE"

REQUEST_BODY_FILE="${JQ_TMP_DIR}/request_body.json"
jq -n \
    --arg model "$MODEL" \
    --slurpfile messages "$MESSAGES_FILE" \
    --argjson temp "$TEMP" \
    --argjson think "$THINK" \
    '{model: $model, messages: $messages[0], stream: false, think: $think, options: {temperature: $temp}}' > "$REQUEST_BODY_FILE"

show_model_not_found_hint() {
    local err="$1"
    if [[ "$err" == *"not found"* ]]; then
        echo "" >&2
        echo "モデル '${MODEL}' がインストールされていない可能性があります。" >&2
        echo "次のコマンドでダウンロードしてから再実行してください:" >&2
        echo "  ollama pull ${MODEL}" >&2

        local installed
        installed=$(curl -s "${OLLAMA_HOST}/api/tags" | jq -r '.models[]?.name')
        if [[ -n "$installed" ]]; then
            echo "" >&2
            echo "現在インストール済みのモデル:" >&2
            echo "$installed" | sed 's/^/  - /' >&2
        fi
    fi
}

REQUEST_TIME=$(date '+%Y-%m-%d %H:%M:%S')
REQUEST_START=$(date '+%s')

curl -s "${OLLAMA_HOST}/api/chat" -d @"$REQUEST_BODY_FILE" > "$RESPONSE_FILE" 2>&1 &
CURL_PID=$!

SPINNER='|/-\'
SPIN_I=0
printf '\033[?25l' >&2
while kill -0 "$CURL_PID" 2>/dev/null; do
    ELAPSED=$(( $(date '+%s') - REQUEST_START ))
    printf '\r\033[2;90m考え中... %s (%ds経過)\033[0m' "${SPINNER:$((SPIN_I % ${#SPINNER})):1}" "$ELAPSED" >&2
    SPIN_I=$((SPIN_I + 1))
    sleep 0.2
done
wait "$CURL_PID"
printf '\r\033[K\033[?25h' >&2

RESPONSE_TIME=$(date '+%Y-%m-%d %H:%M:%S')

RESPONSE_LINE=$(cat "$RESPONSE_FILE")

if ! echo "$RESPONSE_LINE" | jq -e . >/dev/null 2>&1; then
    echo "エラー: Ollama から不正な応答を受け取りました (通信エラーの可能性があります)。" >&2
    echo "$RESPONSE_LINE" >&2
    exit 1
fi

ERROR_MSG=""
PROMPT_TOKENS=""
OUTPUT_TOKENS=""
if echo "$RESPONSE_LINE" | jq -e 'has("error")' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$RESPONSE_LINE" | jq -r '.error')
else
    printf '%s\n' "$(echo "$RESPONSE_LINE" | jq -r '.message.content // empty')"
    PROMPT_TOKENS=$(echo "$RESPONSE_LINE" | jq -r '.prompt_eval_count // empty')
    OUTPUT_TOKENS=$(echo "$RESPONSE_LINE" | jq -r '.eval_count // empty')
fi

if [[ -n "$ERROR_MSG" ]]; then
    echo "エラー: ${ERROR_MSG}" >&2
    show_model_not_found_hint "$ERROR_MSG"
    exit 1
fi

if [[ "$VERBOSE" == "true" ]]; then
    echo "" >&2
    echo "---- 時刻 ----" >&2
    echo "入力時刻: ${REQUEST_TIME}" >&2
    echo "出力時刻: ${RESPONSE_TIME}" >&2

    if [[ -n "$PROMPT_TOKENS" ]]; then
        echo "" >&2
        echo "---- トークン使用量 (実測値) ----" >&2
        echo "入力 (資料 + システムプロンプト + 質問): ${PROMPT_TOKENS} トークン" >&2
        echo "出力 (応答)                          : ${OUTPUT_TOKENS:-不明} トークン" >&2
    fi
fi
