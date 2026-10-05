#!/bin/sh
# ベンチマーク用のプロキシを別ポートで起動し、サンプルごとの応答時間（中央値）を Markdown の表で出す。
# キャッシュ・作業中辞書・再試行を切るので、上流（GPU / llama.cpp / API）の差だけが出る。
# usage: scripts/bench.sh [SAMPLES] [PORT]
#   BENCH_RUNS=3        1 サンプルあたりの回数（中央値を採る）
#   BENCH_SUMMARY=1     サンプルごとではなく、全体を 1 行に集計する
#   BENCH_DICTIONARY=1  辞書スナップショットを使う（既定は使わない。機材間で比べるため）
#   BENCH_OUT=PATH      訳を JSONL で追記する（source / translation / label / model）
cd "$(dirname "$0")/.." || exit 1
samples=${1:-scripts/bench-samples.txt}
port=${2:-8092}
runs=${BENCH_RUNS:-3}
upstream=${XTRANSLATOR_UPSTREAM:-http://127.0.0.1:8080/v1/chat/completions}
model=${XTRANSLATOR_MODEL:-gemma-4-12b-it-qat-imatrix}
tmp=$(mktemp -d)

if [ "${BENCH_DICTIONARY:-0}" = 1 ]; then
  dictionary=${XTRANSLATOR_DICTIONARY:-$HOME/.local/share/xtranslator-llm-proxy/dictionary.jsonl}
else
  dictionary=/nonexistent
fi

XTRANSLATOR_LISTEN_PORT=$port XTRANSLATOR_CACHE= XTRANSLATOR_SESSION= \
  XTRANSLATOR_DICTIONARY=$dictionary XTRANSLATOR_RETRIES=0 XTRANSLATOR_WARMUP=0 \
  ruby xtranslator-llm-proxy.rb > "$tmp/proxy.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM

request() {
  body=$(ruby -rjson -e 'puts JSON.dump(model: "x", messages: [{role: "user", content: "Translate to japanese:\n" + ARGV[0]}])' "$1")
  curl -s -m 300 -o "$tmp/out.json" -w '%{time_total}' "http://127.0.0.1:$port/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$body"
}

# 起動待ち → 1 件捨てて、モデルのロード時間を計測に含めない
i=0
until curl -s -o /dev/null "http://127.0.0.1:$port/"; do
  i=$((i + 1)); [ $i -gt 50 ] && { cat "$tmp/proxy.log" >&2; exit 1; }
  sleep 0.2
done
request "Hello there, traveler." > /dev/null

props=$(curl -s -m 5 "${upstream%/v1/chat/completions}/props?model=$model")
gpu=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)
terms=$(sed -n 's/.* terms=\([0-9]*\).*/\1/p' "$tmp/proxy.log")
printf '%s\n' "$props" | ruby -rjson -e '
  gpu, model, upstream, runs, terms = ARGV
  j = JSON.parse(STDIN.read) rescue {}
  if j["model_path"]
    puts "- GPU: #{gpu}", "- model: #{model} (#{File.basename(j["model_path"])})",
         "- llama.cpp: #{j["build_info"]}, n_ctx #{j.dig("default_generation_settings", "n_ctx")}"
  else
    puts "- upstream: #{upstream[%r{\Ahttps?://[^/]+}]}", "- model: #{model}"
  end
  puts "- dictionary terms: #{terms}", "- runs: #{runs}", ""' \
  "$gpu" "$model" "$upstream" "$runs" "${terms:-0}"

# 1 行 1 サンプル: 文字数 中央値 最小 最大 ラベル
while IFS= read -r line; do
  [ -z "$line" ] && continue
  : > "$tmp/times"
  n=0
  while [ $n -lt "$runs" ]; do
    request "$line" >> "$tmp/times"; echo >> "$tmp/times"
    n=$((n + 1))
  done
  label=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["model"] rescue puts "error"' "$tmp/out.json")
  [ -n "$BENCH_OUT" ] && ruby -rjson -e '
    j = JSON.parse(File.read(ARGV[0])) rescue {}
    File.open(ARGV[3], "a") { |f| f.puts JSON.dump(source: ARGV[1], translation: j.dig("choices", 0, "message", "content"), label: j["model"], model: ARGV[2]) }' \
    "$tmp/out.json" "$line" "$model" "$BENCH_OUT"
  sort -n "$tmp/times" | awk -v chars="${#line}" -v label="$label" '
    { t[NR] = $1 }
    END { printf "%d %.2f %.2f %.2f %s\n", chars, t[int((NR + 1) / 2)], t[1], t[NR], label }'
done < "$samples" > "$tmp/results"

if [ "${BENCH_SUMMARY:-0}" = 1 ]; then
  echo '| 件数 | 合計文字数 | 中央値 (秒) | p90 | 最大 | 合計 (秒) | 問題あり |'
  echo '| ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
  sort -k2 -n "$tmp/results" | awk '
    { t[NR] = $2; chars += $1; total += $2; if ($0 ~ /problem|timeout|error/) bad++ }
    END {
      p90 = t[int(NR * 0.9 + 0.999)]
      printf "| %d | %d | %.1f | %.1f | %.1f | %.1f | %d |\n", NR, chars, t[int((NR + 1) / 2)], p90, t[NR], total, bad
    }'
else
  echo '| 文字数 | 中央値 (秒) | 最小 | 最大 | 20 秒以内 | ラベル |'
  echo '| ---: | ---: | ---: | ---: | :---: | --- |'
  awk '{
    label = $5; for (i = 6; i <= NF; i++) label = label " " $i
    printf "| %d | %.1f | %.1f | %.1f | %s | `%s` |\n", $1, $2, $3, $4, ($4 < 20 ? "yes" : "no"), label
  }' "$tmp/results"
fi
