# Work Log

## 2026-10-05 名前を xtranslator-llm-proxy に変更

Record:

- リポジトリ名・本体・systemd ユニット・データのパスを `llama-openai-proxy` から `xtranslator-llm-proxy` に変えた。xTranslator 専用（実質 Bethesda ゲーム向け）であることが名前からわからなかったため。
- 本体: `xtranslator-llm-proxy.rb`。ユニット: `xtranslator-llm-proxy.service` / `xtranslator-llm-proxy-dict.{path,service}`。
- データ: `~/.local/share/xtranslator-llm-proxy/`（辞書スナップショット・作業中辞書）、`~/.cache/xtranslator-llm-proxy/`（訳キャッシュ）。旧パスへのフォールバックはない。
- 環境変数（`XTRANSLATOR_*`）とポート（8091）は変えていない。
- README に ollama で使う場合の節を足した（上流と model 名の差し替え、`num_ctx` と keep-alive の設定）。ollama での動作は未検証。
- ベンチマークを追加した（`scripts/bench.sh`）。RTX 3060 と Cloudflare Workers AI（`@cf/google/gemma-4-26b-a4b-it`）の結果を README に載せた。RTX 4070 は未計測。
- `models.ini` の `reasoning = on` で gemma-4 が思考してしまい、訳が空や遅延になっていた。上流へのリクエストに `chat_template_kwargs: {enable_thinking: false}` を付けた（Cloudflare でも有効）。
- 上流の https と `XTRANSLATOR_API_KEY`（Bearer）に対応した。
- 辞書なしで訳の質を比べた（README の Quality 節）。短文はローカルが安定、Cloudflare は 50 件中 4 件で意味崩れ・内容の追加・タイ文字混入。辞書ありの比較は、自宅機の `dictionary.jsonl` をこのマシンにコピーしてから `BENCH_DICTIONARY=1` でやる（未実施）。
- 辞書なしの固有名詞を公式訳（日本語版 Wikipedia で確認できた 9 か所）と照合した（`docs/quality/no-dictionary/proper-nouns.md`）。公式訳どおりはローカル 2、Cloudflare 3。どちらも公式訳はほぼ知らず、音写どおりの名前だけ当たる。
- Google AI Studio を比較に足した。`gemini-3.5-flash-lite` は長文が速く安定（2748 字で 4.0 秒）、固有名詞は 9 か所中 8 か所が公式訳どおり。AI Studio の `gemma-4-26b-a4b-it` は思考を止められず（1 文で 12〜20 秒）測っていない。
- Google の API が `chat_template_kwargs` を 400 で弾くため、上流に足すフィールドを `XTRANSLATOR_EXTRA_BODY`（JSON）で変えられるようにした。既定は従来どおり。
- 未対応: プロキシの検証がラテン文字以外の外国文字（タイ文字など）の混入を検出しない。
- 未対応: 検証は小文字始まりのラテン文字の単語しか見ないので、Flash-Lite が残した「Jarl」は通った。
- 長文だけ別の上流へ送れるようにした（`XTRANSLATOR_LONG_*`）。辞書で引けなかった残りが 1000 字以上なら長文。エラー（429 など）ならローカルで訳し直す。振り分け前のローカルのキャッシュも使う。8093 番の一時プロキシで、振り分け・キャッシュ・無効なキーでのフォールバックを確認した（429 そのものは未確認）。
- `docs/spec.md` の古い記述を直した（`max_tokens` の上限 4096 → 8192、キャッシュは問題が残った訳も保存する）。
- 今後の課題: 訳す前に一言コンテキストを渡したい（例: 「発話者は女性」）。案は、プロキシが毎回読むファイル（`~/.local/share/xtranslator-llm-proxy/context.txt` など）をプロンプトに足す方式。xTranslator は話者情報を API に送らないので、1 行ごとの自動付与は無理そう。キャッシュのキーにコンテキストを含める必要がある。
- 以下のエントリは当時の名前のまま残している。

Handoff（サービスを動かしている自宅機での移行手順。未実施）:

```sh
# 1. 旧サービスを止めて外す
systemctl --user disable --now llama-openai-proxy llama-openai-proxy-dict.path
rm ~/.config/systemd/user/llama-openai-proxy{.service,-dict.path,-dict.service}

# 2. 作業ツリーとデータを新しい名前に移す
mv ~/src/llama-openai-proxy ~/src/xtranslator-llm-proxy
mv ~/.local/share/llama-openai-proxy ~/.local/share/xtranslator-llm-proxy
mv ~/.cache/llama-openai-proxy ~/.cache/xtranslator-llm-proxy

# 3. 最新を取り込み、remote を新しい URL にする
cd ~/src/xtranslator-llm-proxy
git remote set-url origin git@github.com:kusanaginoturugi/xtranslator-llm-proxy.git
git pull

# 4. symlink を貼り直す（旧 symlink はリンク切れになる）
rm ~/.local/bin/llama-openai-proxy.rb
ln -s ~/src/xtranslator-llm-proxy/xtranslator-llm-proxy.rb ~/.local/bin/

# 5. 新しいユニットを入れて起動
cp systemd/* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now xtranslator-llm-proxy-dict.path xtranslator-llm-proxy
journalctl --user -u xtranslator-llm-proxy -f -o cat
```

- 確認: xTranslator から 1 件訳して、ログに出ること、`~/.cache/xtranslator-llm-proxy/translations.jsonl` に追記されること。
- xTranslator 側の設定（`127.0.0.1:8091`）は変更不要。
- 自宅機（RTX 4070）: pull 後に `systemctl --user restart xtranslator-llm-proxy`（思考無効化の反映）。`scripts/bench.sh` と `BENCH_RUNS=1 BENCH_SUMMARY=1 scripts/bench.sh scripts/bench-short.txt` を流して README の 4070 列を埋める。

## 2026-10-01 実運用ログの分析と検証の改善

Findings（812 リクエスト / 1620 行）:

- 内訳: LLM 548、辞書+LLM 195、辞書のみ 30、問題あり 39（4.8%）。
- 問題ありの大半は検証側の誤検出だった: タイトルケースのパーク名で 1 語の用語（`Your = あなたの`、`Fire = 発射`）を強制していた。2 行目の行頭を文中と誤判定していた。`(Laughing.)` のようなセリフ断片が用語になっていた。タグ内の英字を未翻訳と数えていた。
- 逆に、訳文に混ざった外国語（`At will` → `voluntadで` ×6、`wielderに`）は見逃していた。
- 作業中辞書の用語が後続の行で同じ訳になったのは 122 回中 103 回（84%）。`Dragonbone = ドラゴンボーン` のような 1 語の誤訳も広がっていた。

Record:

- 1 語の用語はカタカナ訳の固有名詞だけにした。全部小文字の句は用語にしない。セリフ断片は用語にしない。
- 作業中辞書からは 2 語以上の用語だけを使う。
- 未翻訳判定で `<...>` と `[...]` の中は数えない。混入した小文字のラテン文字の単語を問題として検出する。
- 同じログを再判定した結果: 問題あり 39 件（大半が誤検出）→ 10 件（9 件は本物、1 件は `Spiders = クモ` の誤検出）。

Handoff:

- 未確認: `voluntad` がリトライで直るか（再現できなかった）。`At will` は「意志で」と訳されがちなので、気になるなら `xtranslator-glossary.local.tsv` に `At will<TAB>任意で` を足す。

## 2026-09-30 作業中辞書（session）

Plan:

- SST を保存するのは mod を訳し終えてからなので、それまでのプロキシの訳を一時的な辞書として使い回し、似た文や mod 固有の名前の訳を揃える。

Record:

- `lib/dictionary.rb` に作業中辞書の層（優先度最低）を追加した。`remember` で 1 件ずつ差分追加し、`session.jsonl` に追記する。
- 類似例文は、作業中辞書から最大 2 件を優先して入れる。見出しは公式訳だけではないことが分かる文言に変えた。
- スナップショットの中身の SHA256 が変わったら（SST が保存されたら）作業中辞書を空にする。再起動による同じ内容の書き出し直しでは消さない。
- 架空の mod で確認した: NPC 名 → 場所名 → それを含む文 → 似た文 の順に流すと、3 件目以降は名前が用語として強制され、4 件目は 3 件目の訳を例文として使った。再起動しても保持され、スナップショットを変えると空になり、`session.jsonl` を手動で消すと次のリクエストで捨てられた。

Handoff:

- 未確認: 実際の mod 1 本分でどれだけ表記が揃うか。作業中辞書の訳を用語として強制するので、LLM の最初の訳が悪いとそれが広まる。気になったら xTranslator で直して SST を保存する（保存で作業中辞書は空になる）。

## 2026-09-30 辞書をスナップショット方式に変更

Plan:

- プロキシが SST を直接読むのをやめ、書き出したスナップショットを読む形に分ける。
- SST の更新をスナップショットに自動で反映する。

Record:

- `xtranslator_sst_glossary.rb` に `--format jsonl` を追加した。全件を優先順・原文ごとに先勝ちで、一時ファイル経由で書き出す。既定の出力先は `~/.local/share/llama-openai-proxy/dictionary.jsonl`（7.8 万件、21MB、約 1 秒）。
- `lib/dictionary.rb` はスナップショットと local TSV だけを読むようにした（読み込み 1.3 秒）。SST への依存は書き出しツール側だけ。
- プロキシの `XTRANSLATOR_ROOT` / `GAME` / `SOURCE_LANG` / `DEST_LANG` をやめて、`XTRANSLATOR_DICTIONARY` にした。
- `llama-openai-proxy-dict.path` を追加した。`PathChanged` で SST のディレクトリと `prefs_vocab` ini を監視し、変更があれば `.service` が 2 秒待ってから書き出す。プロキシのユニットは起動前に 1 回書き出す（`Wants=`）。
- 事前の実験で、`PathChanged` がディレクトリ内の既存ファイルの上書き・追記でも発火することを確認した。テスト用ファイルの作成と削除では、書き出しは 1 回だけ走った。

Handoff:

- 未確認: xTranslator で実際に辞書を保存したときに、path unit が発火するか（保存方式が上書きか置き換えかは未確認。どちらでも `PathChanged` で拾える想定）。確認するには `journalctl --user -u llama-openai-proxy-dict -f`。

## 2026-09-30 llama.cpp router 対応と精度向上

Plan:

- ollama 時代の設定（port 18080、`translategemma-4B/12B`、`/tmp` の TSV）を今の llama.cpp router 構成に合わせる。
- SST を直接読み、翻訳メモリ・用語・類似例文で LLM に基準データを渡す。
- 検証と再試行、キャッシュで品質と速度を上げる。

Findings（着手時の状態）:

- router の model ID は小文字（`translategemma-12b`）で、旧設定の `translategemma-12B` は `model not found` になっていた。
- `/tmp/xtranslator-glossary.tsv` は再起動で消えていて、実際に効いていたのは手動 TSV の 14 件だけだった。
- router は `--models-max 1` なので、4B と 12B を振り分けるとモデルの載せ替えが頻発する。timeout の原因である可能性が高い。
- `8090` は voicenews の http.server と tailscale serve が使っているので、`8091` にした。

Record:

- `lib/sst.rb`: SST リーダを切り出した。ini にない SST も読み、`name|1` だけを除外、ini 順を優先順にした。
- `lib/dictionary.rb`: 翻訳メモリ（77k）、用語（20k）、類似例文（57k）。起動 2 秒、照合は数 ms。mtime を見て自動で再読込する。
- `llama-openai-proxy.rb`:
  - port 8091
  - 既定モデルを `gemma-4-12b-it-qat-imatrix` に（比較結果は `docs/spec.md`）
  - temperature 0、行単位の部分解決、検証と再試行、JSONL キャッシュ、warmup、`--dump` を追加
- `xtranslator_sst_glossary.rb` は `lib/sst.rb` を使うようにした。生成物の `xtranslator-glossary.tsv` は追跡から外した。
- `scripts/try.sh` と `scripts/samples.txt` を追加。
- `README.md` を書き直し、`docs/spec.md` を新規作成。

Record（xTranslator 実機確認）:

- `commonApiPrefs.ini` は GUI から変えられず、xTranslator を閉じて編集した（`OpenAI_URL=http://127.0.0.1:8091/...`）。
- `--dump` の結果: 配列の要素は `\r\n` 区切りで 1 リクエストにまとまる。応答を `\n` で返していたので、受け取った改行コードで返すようにした。
- 「4 件中 2 件で止まる」: xTranslator が `OpenAI_CharLimit=1500` を超える文字列を送らずに捨てていた（警告が出る）。`Misc/ApiTranslator.txt` を 6000 に上げた（要 xTranslator 再起動）。改行コードの件が止まった原因にどこまで関わっていたかは未確定。
- 長文向け: `max_tokens` の上限を 8192 にし、read timeout を `UPSTREAM_TIMEOUT + max_tokens/25` 秒に。約 3100 文字の本で 35 秒（再試行 1 回を含む）。
- 用語照合と例文検索で `<img src=...>` などのタグの中を無視するようにした（`Books` → `本` の誤検出）。

- 長文が「21 秒で終わるのに反映されない」: xTranslator が約 20 秒で切断していた（`EPIPE`）。1 回 17 秒のところを、用語の誤検出（`an Imperial sword` → `Imperial Sword = 帝国軍の剣`）でリトライして 34 秒かかっていた。
  - 2 語以上の用語は、2 語目以降の大文字小文字が一致したときだけ採用するようにした。
  - 再試行は `XTRANSLATOR_CLIENT_BUDGET`（18 秒）に収まりそうなときだけにした。
  - 問題が残った訳もキャッシュするようにした（temperature 0 なので再実行しても同じ）。切断された長文も、再翻訳で即座に返る。
  - 同じ日記（2702 文字）: 1 回目 16.5 秒（問題なし）、2 回目はキャッシュから 0 秒。
- systemd user サービス `llama-openai-proxy.service` を作って有効化した（`After=llama.cpp.service`、`XTRANSLATOR_WARMUP=0`、`--brief`）。定義は `systemd/` にも置いた。

Handoff:

- プロキシは `systemctl --user` で常駐中。コードを変えたら `systemctl --user restart llama-openai-proxy`。ログは `journalctl --user -u llama-openai-proxy -f -o cat`。
- 約 2700 文字を超える文は、1 回目は xTranslator の timeout に間に合わない。再翻訳すればキャッシュから返る。根本的に直すなら、応答を chunked で少しずつ送って接続を保つ方法がある（Delphi 側で効くかは未検証）。
- 未検証: `prefs_vocab_*.ini` の `|1` が「無効」を意味するという前提（旧実装からの引き継ぎ）。
- `~/.local/bin/llama-openai-proxy.rb` はリポジトリへの symlink にした（7/13 の古い版は置き換え済み）。
- 今後の候補: 類似例文の選び方を embedding（`embeddinggemma-300M` が router にある）に置き換える。キャッシュのキーに辞書の版を含める。

## 2026-07-15 xTranslator proxy hardening

Plan:

- Keep xTranslator API prompts minimal and move translation control into the proxy.
- Bypass llama.cpp when glossary entries fully cover the request.
- Add response cleanup for common LLM formatting drift.
- Add brief translation logs for bulk translation checks.
- Route short requests to `translategemma-4B` and longer requests to `translategemma-12B`.

Record:

- Added glossary direct responses, including `Spell Tome: <spell>` handling.
- Added proxy-side prompt injection even when no glossary term matches.
- Added cleanup for Markdown/code fences, extra tags, added terminal periods, and line count drift.
- Added `--brief` / `-b` logging with source, translation, and selected model.
- Added short/long model routing with environment overrides:
  - `XTRANSLATOR_SHORT_MODEL`
  - `XTRANSLATOR_LONG_MODEL`
  - `XTRANSLATOR_SHORT_MODEL_MAX_LINES`
  - `XTRANSLATOR_SHORT_MODEL_MAX_CHARS`
- Added local glossary overrides for observed bad translations.
- Updated `README.md` with current proxy behavior and xTranslator settings.

Handoff:

- Restart the proxy after `llama-openai-proxy.rb` changes.
- Restart xTranslator after changing `Misc/ApiTranslator.txt`.
- Restart llama.cpp after changing `/etc/llama.cpp/models.ini`.
- Current recommended xTranslator API batch settings are `OpenAI_CharLimit=2000` and `OpenAI_ArrayLimit=2`.
- `--brief` logs should show `モデル: translategemma-4B`, `モデル: translategemma-12B`, or `モデル: glossary`.
