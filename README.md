# xtranslator-llm-proxy

Bethesda ゲーム（Skyrim SE など）の MOD を日本語化するための、xTranslator 用の翻訳プロキシ（Ruby）。xTranslator の OpenAI API 枠に挿して使う。

**短文はローカル LLM、長文はクラウド LLM** で訳し分ける。

- 短文（アイテム名・セリフなど、数が多い）: ローカル LLM（llama.cpp）。ネットワークの往復がないぶん速く（100 字以内で 1 件 0.6 秒前後）、訳の崩れも少ない
- 長文（本・手紙・日記。既定では辞書で引けなかった残りが 1000 字以上）: クラウド LLM（Gemini 3.5 Flash-Lite など）。2748 字でローカル 14.2 秒（RTX 3060）に対して 4.0 秒で、xTranslator が約 20 秒で切断するのに余裕を持って間に合う。訳もやや自然
- クラウド LLM がエラー（回数制限など）を返したらローカルで訳し直す。クラウド LLM を設定しなければローカルだけで動く

数字は [Benchmark](#benchmark) と [Quality](#quality-辞書なし)。

xTranslator の辞書（`UserDictionaries/*.sst`）から書き出したスナップショットを使い、辞書で確定できる訳は辞書から返し、
残りは用語集と公式訳の類似例文をプロンプトに添えて LLM に訳させる。

```
xTranslator (wine) ──POST──▶ proxy 127.0.0.1:8091
                               ├ 辞書スナップショット: 完全一致 / 用語 / 類似例文
                               ├ 短文 ─▶ ローカル LLM（llama-server router 127.0.0.1:8080）
                               ├ 長文 ─▶ クラウド LLM（Gemini API など。エラーならローカルへ）
                               ├ 検証 → 指摘付き再試行
                               └ キャッシュ ~/.cache/xtranslator-llm-proxy/translations.jsonl

SST 保存 ─▶ xtranslator-llm-proxy-dict.path ─▶ xtranslator_sst_glossary.rb --format jsonl
          ─▶ ~/.local/share/xtranslator-llm-proxy/dictionary.jsonl ─▶ proxy が mtime を見て再読込
```

仕様の詳細は [`docs/spec.md`](docs/spec.md)、作業履歴と引き継ぎは [`WORKLOG.md`](WORKLOG.md)。

## Files

| パス | 役割 |
| --- | --- |
| `xtranslator-llm-proxy.rb` | プロキシ本体 |
| `systemd/xtranslator-llm-proxy.service` | プロキシの user サービス |
| `systemd/xtranslator-llm-proxy-dict.{path,service}` | SST の変更を監視して辞書スナップショットを書き出す |
| `xtranslator_sst_glossary.rb` | SST の書き出しツール（`--format jsonl` でスナップショット、`tsv` で用語 TSV） |
| `lib/sst.rb` | SST リーダ / 有効辞書の列挙（書き出しツール用） |
| `lib/dictionary.rb` | スナップショットを読み、翻訳メモリ・用語照合・類似例文検索をする |
| `xtranslator-glossary.local.tsv` | 手動の上書き辞書（スナップショットより優先） |
| `xtranslator` | xTranslator を日本語ロケールで起動する wine ラッパ |
| `scripts/try.sh` / `scripts/samples.txt` | 動作確認用 |
| `scripts/bench.sh` / `scripts/bench-*.txt` | ベンチマーク（[Benchmark](#benchmark)） |
| `scripts/compare.rb` | `BENCH_OUT` の JSONL を原文ごとに並べた Markdown にする |

## Start

systemd の user サービスとして常駐させている（`systemd/`）。

```sh
# 初回インストール
cp systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now xtranslator-llm-proxy-dict.path xtranslator-llm-proxy

systemctl --user restart xtranslator-llm-proxy   # コード変更後
journalctl --user -u xtranslator-llm-proxy -f -o cat   # 訳のログ（--brief 形式）
```

サービスでは `XTRANSLATOR_WARMUP=0` にしている（ログイン直後に VRAM を掴まないため）。
モデルが載っていない状態での最初の 1 件は xTranslator の timeout を超えることがある。その場合はもう一度翻訳すればキャッシュから返る。

手で起動する場合（サービスを止めてから）:

```sh
ruby ~/src/xtranslator-llm-proxy/xtranslator-llm-proxy.rb --brief
```

- `--brief` / `-b`: 原文・訳文・どこで訳したか（`glossary` / `cache` / モデル名）だけ表示
- `--dump PATH`: xTranslator からの生リクエストを JSONL で追記（仕様確認用）

起動時にモデルを warmup でロードする。初回だけ数十秒かかる。

## xTranslator settings

OpenAI API タブ（または `UserPrefs/commonApiPrefs.ini`。xTranslator 終了中に編集）:

```txt
OpenAI_URL=http://127.0.0.1:8091/v1/chat/completions
OpenAI_Key=no-key
```

`OpenAI_Model` と `OpenAI_Query` はプロキシが差し替えるので何でもいい。
ただしプロキシは「user メッセージの 1 行目 = クエリ、2 行目以降 = 原文」として扱うので、`OpenAI_Query` は 1 行にする。

`commonApiPrefs.ini` は xTranslator の終了時に上書きされるので、必ず閉じてから編集する（GUI からは URL を変えられない）。

`Misc/ApiTranslator.txt`（xTranslator は書き戻さない。変更後は xTranslator 再起動）:

```txt
OpenAI_CharLimit=6000
OpenAI_ArrayLimit=2
OpenAI_ArrayTimePause=0
```

`OpenAI_CharLimit` を超える文字列は xTranslator が送る前に捨てる（「API の文字数上限を越えているため一部の文字列は無視されます」）。

xTranslator は応答を約 20 秒しか待たない（設定項目なし）。約 2700 文字の本で 16 秒程度なので、それより長い文は 1 回目は切断されて訳が反映されない。
長文を[クラウド LLM へ](#長文をクラウド-llm-へ)回せば、2700 文字で 4 秒程度なので切断されにくい。
プロキシは切断後も訳を最後まで作ってキャッシュするので、**もう一度同じ文を翻訳すれば即座に反映される**。

## Workflow

xTranslator は辞書の完全一致だけ、残りは全部このプロキシで訳す。

1. xTranslator で mod を開き、辞書（SST）の**完全一致だけ**を適用する（メニュー名はバージョンによって違うかもしれないので要確認）
2. **ヒューリスティック翻訳は使わない**。辞書の中から編集距離で一番近い原文を探して、その訳を貼るだけなので、意味が変わる
3. 残りの未翻訳を API 翻訳（OpenAI 枠 = このプロキシ）で一括翻訳する
   - xTranslator が拾わなかった完全一致も、プロキシが辞書から返す（ログのラベルは `glossary`）
   - 訳した名前や文は作業中辞書に入って、同じ mod の以降の訳に使われる
4. 反映されなかった長文（約 20 秒の timeout）は、もう一度翻訳すればキャッシュから返る
5. 訳を確認・修正して、mod 1 本分が終わったら辞書を保存する
   - 保存するとスナップショットが書き出し直され、作業中辞書は空になる

## Dictionary

プロキシは SST を直接読まない。`xtranslator_sst_glossary.rb --format jsonl` が書き出した
`~/.local/share/xtranslator-llm-proxy/dictionary.jsonl`（1 行 1 件、`source` / `target` / `file`）を読む。

- 書き出し元: `~/.local/bin/_xTranslator/UserDictionaries/SkyrimSE/*_english_japanese.sst` 全部
  - `UserPrefs/SkyrimSE/prefs_vocab_english_japanese.ini` で `name|1` の辞書は除外、並び順が優先順。同じ原文は先勝ち
- 自動更新: `xtranslator-llm-proxy-dict.path` が SST のディレクトリと ini を監視（`PathChanged`）し、
  変更があれば 2 秒待ってから書き出す。書き出しは一時ファイル経由で差し替えるので、読み込み途中に壊れたファイルは見えない
- プロキシの起動時にも 1 回書き出す（ログアウト中の変更を拾う）
- プロキシはスナップショットの mtime が変わったら、次のリクエストで読み直す（再起動不要）
- 手動で今すぐ更新: `systemctl --user start xtranslator-llm-proxy-dict`
- 手動で直したい訳は `xtranslator-glossary.local.tsv` に `原文<TAB>訳文` で書く（これも自動で読み直す）

### 作業中辞書（session）

SST を保存するのは mod を訳し終えてからが多いので、それまでの訳をプロキシ自身が貯めて使い回す。

- 検証を通った LLM の訳を 1 行ずつ `~/.local/share/xtranslator-llm-proxy/session.jsonl` に追記する
- 優先度は 手動 TSV ＞ スナップショット ＞ 作業中辞書。完全一致・用語・類似例文のすべてに使う
  - mod 固有の NPC 名やアイテム名を一度訳すと、以降の文ではその訳を用語として強制する
  - 類似例文 3 件のうち最大 2 件を作業中辞書から優先して選ぶ（`XTRANSLATOR_SESSION_EXAMPLE_LIMIT`）
- SST を保存してスナップショットの**中身が変わったら**空にする（訳は SST 側に入ったとみなす）。再起動による同じ内容の書き出し直しでは消さない
- 手動で捨てる: `command rm -f ~/.local/share/xtranslator-llm-proxy/session.jsonl`（次のリクエストでプロキシが気づく）
- xTranslator 上で手直しした訳は、SST を保存するまでプロキシには見えない

## Try

```sh
scripts/try.sh 8091 < scripts/samples.txt
```

## Benchmark

`scripts/bench.sh` は計測用のプロキシを 8092 番で別に起動して、応答時間を測る。
キャッシュ・作業中辞書・再試行・辞書スナップショットは切るので、機材の差だけが出る（手動 TSV の 14 語だけ使う）。
モデルのロード時間は含まない。

```sh
scripts/bench.sh                                                    # 長さ別 5 件 × 3 回
BENCH_RUNS=1 BENCH_SUMMARY=1 scripts/bench.sh scripts/bench-short.txt   # 100 字以内 50 件
```

条件: `gemma-4-12b-it-qat-imatrix`（`gemma-4-12B-it-qat-ja-Q4_K_M.gguf`）、`c = 32768`、`parallel = 1`、
MTP の投機的デコード（`spec-type = draft-mtp`）、思考なし。llama.cpp b11223。
Cloudflare は Workers AI の `@cf/google/gemma-4-26b-a4b-it`（モデルが違う）。ばらつきが大きく、2748 字は 3 回中 8.3〜22.6 秒で、20 秒を超えることがある。
Gemini 3.5 Flash-Lite は Google AI Studio の OpenAI 互換 API（`XTRANSLATOR_EXTRA_BODY={}`）。何も指定しなくても思考せずに返る。
AI Studio の `gemma-4-26b-a4b-it` は思考を止める指定がどれも 400 になり、本文に `<thought>` を出してから訳すので、短い 1 文でも 12〜20 秒かかる。xTranslator では使えないので測っていない。

```sh
XTRANSLATOR_UPSTREAM=https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/ai/v1/chat/completions \
XTRANSLATOR_MODEL=@cf/google/gemma-4-26b-a4b-it \
XTRANSLATOR_API_KEY=$(cat ~/.config/cloudflare-ai-token) \
scripts/bench.sh
```

長さ別（中央値、秒）。xTranslator は約 20 秒で切断する。

| 文字数 | RTX 3060 12GB | RTX 4070 | Cloudflare | Gemini 3.5 Flash-Lite |
| ---: | ---: | ---: | ---: | ---: |
| 65 | 0.5 | | 0.9 | 1.4 |
| 117 | 0.9 | | 1.9 | 1.2 |
| 376 | 2.5 | | 2.3 | 1.6 |
| 1350 | 8.3 | | 4.3 | 3.0 |
| 2748 | 14.2 | | 19.1 | 4.0 |

100 字以内 50 件（`scripts/bench-short.txt`）。

| | RTX 3060 12GB | RTX 4070 | Cloudflare | Gemini 3.5 Flash-Lite |
| --- | ---: | ---: | ---: | ---: |
| 合計（秒） | 30.5 | | 52.8 | 61.1 |
| 中央値 / 最大（秒） | 0.6 / 0.8 | | 1.0 / 4.2 | 1.2 / 1.5 |
| 問題あり | 0 | | 0 | 0 |

## Quality (辞書なし)

上の Benchmark と同じ条件（辞書スナップショットなし、手動 TSV の 14 語だけ）で、同じ 55 件を
RTX 3060 のローカル（`gemma-4-12b-it-qat-imatrix`）、Cloudflare（`@cf/google/gemma-4-26b-a4b-it`）、Google AI Studio（`gemini-3.5-flash-lite`）で訳し、読み比べた。
用語集も公式訳の類似例文も渡らない「素の訳」の比較で、実運用の質ではない。判定は Claude が目で読んだもので、再現できる採点ではない。
全件の対訳は [`docs/quality/no-dictionary/comparison.md`](docs/quality/no-dictionary/comparison.md)（生データは同じディレクトリの JSONL）。

```sh
BENCH_RUNS=1 BENCH_OUT=local.jsonl scripts/bench.sh scripts/bench-short.txt   # 訳を JSONL に保存
scripts/compare.rb local.jsonl cloudflare.jsonl google.jsonl > comparison.md  # 並べて Markdown に
```

100 字以内 50 件:

| | ローカル | Cloudflare | Gemini 3.5 Flash-Lite |
| --- | ---: | ---: | ---: |
| 意味が壊れた / 内容を足した / 他の文字が混ざった | 0 | 4 | 3 |
| 固有名詞が公式訳どおり（確認できた 9 か所） | 2 | 3 | 8 |

- Cloudflare の例:
  - `My brother joined the Thalmor` → 「タロスを信じる者を弾圧するサマート・ド・タロスに加わり」（内容を足した）
  - `Falkreath` → 「ファルクリーธ」（タイ文字が混ざった。プロキシの検証はラテン文字の混入しか見ていないので通った）
  - `Belethor will buy anything, as long as you don't ask where he sells it.` → 「何でも買い取るが、どこで売っているのかを聞かない限り。」（文が壊れた）
  - `This ebony dagger once belonged to …` → 「〜エボニーダガー」（文が終わっていない）
  - `Ulfric` → 「ウルフレリック」
- Gemini 3.5 Flash-Lite の例:
  - `I used to be an adventurer like you, …` → 「お前も昔は冒険者だったが、…」（意味が逆）
  - `… the Jarl will reward you.` → 「Jarlから報酬がもらえる。」（英語が残った。プロキシの検証は小文字始まりの語だけを見ているので通った）
  - `Cicero keeps talking to the Night Mother …` → 「夜母語りかけている」（助詞が抜けた）
  - `Solitude` → 「ソリュディュード」
- ローカルの例: 意味が壊れた訳はなかった
- ローカルと Cloudflare: `my Thane` を「領主様」「従者殿」と誤訳（公式訳は「従士」のはず。要確認）。Flash-Lite は「従士」

長さ別 5 件（65〜2748 字）は、3 つとも意味の通る訳だった。長文は Cloudflare と Flash-Lite の方がやや自然。
ローカルは `lose its charge` を「電荷を失う」、Cloudflare は `the Jarl's steward` の Jarl を落とした。

まとめ: 文の崩れはローカルが一番少ない。固有名詞はローカルと Cloudflare は公式訳をほとんど知らず、Flash-Lite はよく知っている
（[固有名詞の分析](docs/quality/no-dictionary/proper-nouns.md)）。長文の速さと安定は Flash-Lite が一番。
モデルが違う（ローカル 12B、Cloudflare 26B の MoE、Flash-Lite は非公開）ことに注意。

## Environment

| 変数 | 既定値 | |
| --- | --- | --- |
| `XTRANSLATOR_LISTEN_PORT` | `8091` | |
| `XTRANSLATOR_UPSTREAM` | `http://127.0.0.1:8080/v1/chat/completions` | |
| `XTRANSLATOR_MODEL` | `gemma-4-12b-it-qat-imatrix` | router の model ID（`/etc/llama.cpp/models.ini` のセクション名） |
| `XTRANSLATOR_SHORT_MODEL` | 空 | 設定すると短文だけこのモデルへ。`--models-max 1` だと載せ替えが頻発するので非推奨 |
| `XTRANSLATOR_TEMPERATURE` | `0` | |
| `XTRANSLATOR_UPSTREAM_TIMEOUT` | `30` | 秒。read timeout は `これ + max_tokens/25` 秒。超えたら原文をそのまま返す |
| `XTRANSLATOR_API_KEY` | 空 | 設定すると上流に `Authorization: Bearer` で送る（Cloudflare など） |
| `XTRANSLATOR_EXTRA_BODY` | `{"chat_template_kwargs":{"enable_thinking":false}}` | 上流へのリクエストに足す JSON。思考を止める指定。Google は知らないフィールドを 400 で弾くので `{}` にする |
| `XTRANSLATOR_LONG_MODEL` | 空 | 設定すると長文だけこのモデルへ（[長文をクラウド LLM へ](#長文をクラウド-llm-へ)） |
| `XTRANSLATOR_LONG_MIN_CHARS` | `1000` | 辞書で引けなかった残りがこの文字数（空白を除く）以上なら長文 |
| `XTRANSLATOR_LONG_UPSTREAM` / `_LONG_API_KEY` / `_LONG_EXTRA_BODY` | 通常の上流と同じ | 長文を送るクラウド LLM |
| `XTRANSLATOR_RETRIES` | `1` | 検証 NG 時の再試行回数 |
| `XTRANSLATOR_CLIENT_BUDGET` | `18` | 秒。再試行してもこの時間に収まりそうなときだけ再試行する（xTranslator は約 20 秒で切断する） |
| `XTRANSLATOR_GLOSSARY_LIMIT` | `40` | プロンプトに入れる用語の上限 |
| `XTRANSLATOR_EXAMPLE_LIMIT` | `3` | プロンプトに入れる類似例文の数（0 で無効） |
| `XTRANSLATOR_CACHE` | `~/.cache/xtranslator-llm-proxy/translations.jsonl` | 空文字で無効 |
| `XTRANSLATOR_WARMUP` | `1` | `0` で起動時ロードしない |
| `XTRANSLATOR_DICTIONARY` | `~/.local/share/xtranslator-llm-proxy/dictionary.jsonl` | 辞書スナップショット |
| `XTRANSLATOR_SESSION` | `~/.local/share/xtranslator-llm-proxy/session.jsonl` | 作業中辞書。空文字で無効 |
| `XTRANSLATOR_SESSION_EXAMPLE_LIMIT` | `2` | 類似例文のうち作業中辞書から優先して入れる件数 |
| `XTRANSLATOR_GLOSSARY_PREPEND` | リポジトリ内 `xtranslator-glossary.local.tsv` | `:` 区切りで複数可 |

## 長文をクラウド LLM へ

短文はローカル LLM が速く崩れも少ないが、長文はクラウド LLM の方が速い（[Benchmark](#benchmark)）。
`XTRANSLATOR_LONG_MODEL` を設定すると、辞書で引けなかった残りが `XTRANSLATOR_LONG_MIN_CHARS` 字以上のときだけクラウド LLM へ送る。
長文は数が少ないので、Gemini の無料枠の回数制限にはまず当たらない。

```sh
XTRANSLATOR_LONG_UPSTREAM=https://generativelanguage.googleapis.com/v1beta/openai/chat/completions \
XTRANSLATOR_LONG_MODEL=gemini-3.5-flash-lite \
XTRANSLATOR_LONG_API_KEY=$(cat ~/.config/google-ai-studio-key) \
XTRANSLATOR_LONG_EXTRA_BODY='{}' \
ruby xtranslator-llm-proxy.rb --brief
```

- クラウド LLM がエラー（回数制限の 429 など）を返したら、ローカル LLM で訳し直す。ログに `long upstream failed, fall back to ...` が出る
- 振り分けを入れる前にローカルで訳した長文は、キャッシュからそのまま返す
- systemd で使うなら、キーは `EnvironmentFile=` で読ませる（ユニットファイルに直接書かない）

## Ollama

OpenAI 互換 API だけを使っているので、ollama でも上流を差し替えれば動くはず（未検証）。

```sh
XTRANSLATOR_UPSTREAM=http://127.0.0.1:11434/v1/chat/completions \
XTRANSLATOR_MODEL=<ollama のモデル名> \
ruby xtranslator-llm-proxy.rb --brief
```

ollama 側で次の 2 つを設定しておく。

- コンテキスト長: 既定の `num_ctx` は小さく、OpenAI 互換 API からは変えられない。用語・類似例文・長文が入るとプロンプトの前半が黙って切られ、指示が消える。`OLLAMA_CONTEXT_LENGTH` か Modelfile の `PARAMETER num_ctx` で 32768 程度にする。
- keep-alive: 既定では 5 分使わないとモデルを降ろす。降ろした後の最初の 1 件は xTranslator の timeout（約 20 秒）を超えやすい。`OLLAMA_KEEP_ALIVE=-1` か長めの値にする。

## Reload

- プロキシのコードを変えたら: `systemctl --user restart xtranslator-llm-proxy`
- 辞書（SST / local TSV）を変えたら: 不要（path unit が書き出し、プロキシが自動で再読込）
- `systemd/` を変えたら: `cp systemd/* ~/.config/systemd/user/ && systemctl --user daemon-reload`
- プロンプトや既定モデルを変えて過去訳を捨てたいとき: `rm ~/.cache/xtranslator-llm-proxy/translations.jsonl`
- `Misc/ApiTranslator.txt` を変えたら: xTranslator 再起動
- `/etc/llama.cpp/models.ini` を変えたら: llama.cpp 再起動
