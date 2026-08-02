# スナップショットテストのトピック別分割 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `test/cli_test.rb`（1410 行・85 シナリオ）を共通ヘルパー + トピック別 10 ファイルに分割し、スナップショットもファイル単位に分ける。テストの挙動は変えない。

**Architecture:** ヘルパーを `test/support/helper.rb` に切り出し、各テストファイルが `require_relative "support/helper"` する。`spin test` は `test/*.rb` を個別にビルドして各 `.expected` と突き合わせるため、複数テストファイルは元からサポートされている。`test/support/` はグロブ（非再帰）に掛からないのでテスト扱いされない。移動の正しさは、分割後の `.expected` 群を元の順に組み直して旧スナップショットと byte 比較することで機械的に証明する。

**Tech Stack:** Ruby（Spinel が受け付けるサブセット）、Spinel（`spin` / `spinel` / `spinel-doctor`）、GitHub Actions

**設計:** `docs/superpowers/specs/2026-08-02-test-suite-split-design.md`。シナリオの振り分けはその付録の表が唯一の正である。

## Global Constraints

- テストコードは Spinel が受け付ける Ruby サブセットで書く。`File` / `Dir` / `tmpdir` は使わない。外部コマンドはバッククォートと `system` で呼ぶ。
- Task 2〜3 では**セクション本文（直前の rationale コメントを含む）を逐語で移動する。一文字も書き換えない。** 例外は Task 3 Step 2 の `flags_test.rb` に足す `new_repo` 1 行だけで、それは明示的に扱う。ハーネスの解説コメントに含まれるファイル名の更新は Task 3 Step 18 でまとめて行う。
- Task 4 は `.expected` を **1 バイトも変えてはならない**。
- シナリオの振り分けは設計付録の表どおり。判断で変えない。
- 照合スクリプトは使い捨てであり、リポジトリにコミットしない。scratchpad に置く。
- 以降のコマンドは `SCRATCH` が scratchpad ディレクトリを指している前提で書いてある。作業開始時に `export SCRATCH=<scratchpad>` しておくこと。
- 作業ブランチは `refactor/split-cli-test`（作成済み、設計コミット 2 本が載っている）。
- Ruby / Spinel コマンドは実行前に `.claude/hooks/session-start.sh` が案内する版管理ツールで有効化してから走らせる。

## File Structure

作成:

| ファイル | 責務 |
|---|---|
| `test/support/helper.rb` | ハーネスの解説コメント、グローバル初期化、`section` / `setup` / `gsq` / `run` / `show` / `gval` / `new_repo` / `commit` |
| `test/init_test.rb` (+`.expected`) | trunk 検出と init の引数検証（8） |
| `test/trunk_test.rb` (+`.expected`) | 複数 trunk の振る舞い（12） |
| `test/tree_test.rb` (+`.expected`) | tree の描画（4） |
| `test/nav_test.rb` (+`.expected`) | up / down / parent の走査（12） |
| `test/restack_test.rb` (+`.expected`) | restack（4） |
| `test/sync_test.rb` (+`.expected`) | sync（10） |
| `test/drop_test.rb` (+`.expected`) | drop（9） |
| `test/track_test.rb` (+`.expected`) | create / track / untrack / parent 設定（9） |
| `test/refnames_test.rb` (+`.expected`) | タグ衝突・HEAD / refname の綴り（12） |
| `test/flags_test.rb` (+`.expected`) | version / グローバルフラグ / 引数アリティ（5） |

削除: `test/cli_test.rb`、`test/cli_test.rb.expected`

変更: `.github/workflows/ci.yml`、`README.md`、`test/binary_test.sh`（コメントのみ）、`bin/git-stack.rb`（コメントのみ）

無変更: `test/binary_test.sh.expected`、`test/git-stack.rbs.expected`、`rbs/git-stack.rbs`

---

### Task 1: 照合ハーネスを用意し、現状で往復することを証明する

移動の正しさを機械的に検証する道具を、移動を始める前に用意して信用できることを確かめる。スナップショットは唯一のオラクルなので、この道具なしに動かすとシナリオを落としても緑になる。

**Files:**
- Create: `<scratchpad>/verify_split.rb`（コミットしない）
- Create: `<scratchpad>/baseline.expected`（コミットしない）

**Interfaces:**
- Produces: `ruby <scratchpad>/verify_split.rb <baseline> <expected...>` が、渡された `.expected` 群のブロックを baseline の順に組み直して stdout に出す。欠けや余りがあれば stderr に名指しして exit 1。

- [ ] **Step 1: baseline を退避する**

Task 3 の途中で `test/cli_test.rb.expected` は縮んでいくので、元のスナップショットを先に確保する。

```bash
cp test/cli_test.rb.expected "$SCRATCH/baseline.expected"
wc -l "$SCRATCH/baseline.expected"   # 915 行であること
```

- [ ] **Step 2: 照合スクリプトを書く**

`<scratchpad>/verify_split.rb`:

```ruby
# 分割後の .expected 群を、元の cli_test.rb.expected の順に組み直して stdout に出す。
# 使い方:  ruby verify_split.rb <baseline> <expected files...> | diff -u <baseline> -
#
# ブロックは "### <title>" で始まり、次の "### " の直前までを1単位とする。
# セクション間の空行はハーネスの `puts ""` が作る区切りであってブロックの中身では
# ないので、末尾の改行だけを剥がして "\n\n" で綴じ直す。末尾の空白は剥がさない
# ("stack.trunk: " のように空値を出す行がブロック末尾に来ることがある)。

baseline_path = ARGV.shift
baseline = File.read(baseline_path)
order = baseline.scan(/^### (.*)$/).flatten

blocks = {}
ARGV.each do |path|
  File.read(path).split(/^(?=### )/).each do |chunk|
    next if chunk.strip.empty?
    title = chunk[/\A### (.*)$/, 1]
    abort "block with no title in #{path}" if title.nil?
    abort "duplicate block #{title.inspect} (#{path})" if blocks.key?(title)
    blocks[title] = [chunk.sub(/\n+\z/, ""), path]
  end
end

missing = order - blocks.keys
extra = blocks.keys - order
abort "missing from the split: #{missing.inspect}" unless missing.empty?
abort "not in the baseline: #{extra.inspect}" unless extra.empty?

print "\n"
print order.map { |t| blocks[t][0] }.join("\n\n")
print "\n"
```

- [ ] **Step 3: 現状で往復することを確認する**

自分自身を材料に組み直して baseline と一致すること。ここが通らなければブロック分割の regexp が現実と合っていない。

```bash
ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" test/cli_test.rb.expected \
  | diff -u "$SCRATCH/baseline.expected" -
```

Expected: 差分なし、exit 0

- [ ] **Step 4: 複数ファイルに割れても往復することを確認する**

実際の用途は「複数ファイルに散ったブロックを組み直す」なので、そこを確かめる。ブロックを交互に 2 ファイルへ振り分けて再構成する。

```bash
ruby -e '
b = File.read("test/cli_test.rb.expected")
ch = b.split(/^(?=### )/).reject { |c| c.strip.empty? }
even = ch.each_with_index.select { |_, i| i.even? }.map(&:first)
odd  = ch.each_with_index.select { |_, i| i.odd?  }.map(&:first)
{ "a" => even, "b" => odd }.each do |name, list|
  File.write("#{ENV["SCRATCH"]}/sim_#{name}.expected",
             "\n" + list.map { |c| c.sub(/\n+\z/, "") }.join("\n\n") + "\n")
end'
ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" \
  "$SCRATCH/sim_a.expected" "$SCRATCH/sim_b.expected" | diff -u "$SCRATCH/baseline.expected" -
```

Expected: 差分なし、exit 0

- [ ] **Step 5: 落としたときに検出することを確認する**

道具が「通る」ことだけ確かめても意味がない。壊したときに落ちることを確かめる。

```bash
ruby -e 'c = File.read("#{ENV["SCRATCH"]}/sim_a.expected").split(/^(?=### )/)
         c.delete_at(3)
         File.write("#{ENV["SCRATCH"]}/sim_drop.expected", c.join)'
ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" \
  "$SCRATCH/sim_drop.expected" "$SCRATCH/sim_b.expected"
echo "exit=$?"
```

Expected: `missing from the split: ["init resolves the remote's default branch to the spelling git stores"]` と出て `exit=1`

- [ ] **Step 6: コミットしない**

scratchpad の 4 ファイルはリポジトリに入れない。確認だけする。

```bash
git status --short   # test/ 配下に変更がないこと
```

---

### Task 2: ヘルパーを `test/support/helper.rb` に切り出す

シナリオはまだ動かさない。ヘルパーだけを別ファイルにする。この段階では**スナップショットを再生成しない**ので、既存の `test/cli_test.rb.expected` がそのまま通ることが正しさの証明になる。

**Files:**
- Create: `test/support/helper.rb`
- Modify: `test/cli_test.rb`（1〜103 行目を `require_relative` に置き換え）

**Interfaces:**
- Produces: `test/support/helper.rb` が `section(title)` / `setup(cmd)` / `gsq(args)` / `run(args)` / `show(label, cmd)` / `gval(cmd)` / `new_repo` / `commit(file, msg)` と、グローバル `$root` / `$gs` / `$repo`、および `ENV["GIT_AUTHOR_DATE"]` / `ENV["GIT_COMMITTER_DATE"]` の固定を提供する。以降の全テストファイルが `require_relative "support/helper"` でこれを読む。

- [ ] **Step 1: helper.rb を作る**

`test/cli_test.rb` の 1〜103 行目（先頭の解説コメントから `commit` の定義まで、104 行目の `# --- scenarios ---` 区切りは含めない）を `test/support/helper.rb` へ**逐語で**移す。何も書き換えない。

解説コメント内には `test/cli_test.rb` を名指ししている箇所が 4 つある（9, 20, 21, 26 行目）が、この時点ではまだ `test/cli_test.rb` は存在しているので記述は正しい。ファイルが実際に消える Task 3 Step 18 でまとめて直す。

- [ ] **Step 2: cli_test.rb の先頭を require に差し替える**

`test/cli_test.rb` の 1〜103 行目を次で置き換える。104 行目以降（`# --- scenarios ---` と全シナリオ）はそのまま残す。

```ruby
# frozen_string_literal: true
#
# 分割途中の受け皿。Task 3 で全シナリオが各トピックのファイルへ移り、このファイルは消える。

require_relative "support/helper"
```

- [ ] **Step 3: スナップショットを再生成せずに通ることを確認する**

ここが本タスクの検証。`.expected` に触れていないので、通れば挙動が変わっていない証明になる。

```bash
ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -
```

Expected: 差分なし、exit 0

- [ ] **Step 4: Spinel でも通ることを確認する**

`require_relative` が Spinel のビルドを通ることを確かめる。

```bash
spin test
```

Expected: `ok   cli_test.rb` と `1/1 passed`。`test/support/helper.rb` はテストとして列挙されないこと（`test/*.rb` のグロブは非再帰）。

- [ ] **Step 5: spinel-doctor が通ることを確認する**

```bash
spinel-doctor test/cli_test.rb
```

Expected: `spinel-doctor: clean`、exit 0

- [ ] **Step 6: コミット**

```bash
git add test/support/helper.rb test/cli_test.rb
git commit -m "test: lift the snapshot harness into test/support/helper.rb

Pulled the header, the globals and the eight helpers out of cli_test.rb so
the topic files about to be split out can share them. The snapshot is not
regenerated: cli_test.rb.expected passing untouched is the proof that
nothing moved but the definitions."
```

---

### Task 3: 10 のトピックファイルへ分割する

設計付録の表どおりにシナリオを移す。1 ファイル抽出するたびに照合をかけ、常に証明された状態で進む。CI とドキュメントの追随も同じコミットに入れる（`test/cli_test.rb` が消えるため、分けると CI が壊れた状態が生まれる）。

**Files:**
- Create: `test/{init,trunk,tree,nav,restack,sync,drop,track,refnames,flags}_test.rb` と各 `.expected`
- Delete: `test/cli_test.rb`、`test/cli_test.rb.expected`
- Modify: `.github/workflows/ci.yml:24-25`、`.github/workflows/ci.yml:230`、`README.md:257-283`、`test/binary_test.sh`（5, 32, 153, 256 行目のコメント）、`bin/git-stack.rb:1485`（コメント）

**Interfaces:**
- Consumes: Task 1 の `verify_split.rb` と `baseline.expected`、Task 2 の `test/support/helper.rb`
- Produces: `test/*_test.rb` 群。各ファイルの先頭は次の形で揃える。

```ruby
# frozen_string_literal: true
#
# <このファイルが何を見ているかの1〜2行>。
# ハーネスの仕組みとスナップショットの再生成手順は test/support/helper.rb を見ること。

require_relative "support/helper"
```

各ファイル抽出の手順は共通で、次の 4 つを 1 セットとする。

1. 新ファイルを作り、上のヘッダを置く
2. 対象セクションを `test/cli_test.rb` から**逐語で**（直前の rationale コメントごと）切り取って新ファイルへ貼る。付録の表の順（元ファイルでの出現順）を保つ
3. 両方のスナップショットを生成し直す
   ```bash
   ruby test/<name>_test.rb > test/<name>_test.rb.expected
   ruby test/cli_test.rb    > test/cli_test.rb.expected
   ```
4. 照合する
   ```bash
   ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" test/*_test.rb.expected \
     | diff -u "$SCRATCH/baseline.expected" -
   ```
   Expected: 差分なし、exit 0

- [ ] **Step 1: `tree_test.rb` を抽出する（4 セクション）**

手順どおり。まず一番小さく素直なもので流れを確かめる。

ヘッダの説明: `tree that renders the stack: untracked subtrees, detached stacks, a hand-edited parent cycle.`

移すセクション（この順）:
1. `tree renders the whole stack`
2. `tree keeps the subtree of a branch that was untracked`
3. `a detached stack is drawn once, from its top, whatever its branches are named`
4. `tree renders a hand-edited parent cycle instead of dropping it`

照合まで通ったら次へ。

- [ ] **Step 2: `flags_test.rb` を抽出する（5 セクション）— 既知の例外あり**

ヘッダの説明: `version, the global flags, and the arity/flag checks every command shares.`

移すセクション（この順）:
1. `version shows the program version`
2. `global flags are parsed with optparse`
3. `an unknown flag is rejected`
4. `commands reject extra arguments and flags they do not take`
5. `an empty argument is not counted as a positional`

**このファイルだけ追加の作業がある。** 先頭 3 セクションは元ファイルで `new_repo` を持たず、直前の drop シナリオが残したリポジトリで動いている（意図した依存ではなく追記の副作用）。新ファイルでは最初のセクションの直後に `new_repo` を 1 行足す:

```ruby
section "version shows the program version"
new_repo
run("version")
```

これは Global Constraints の「逐語」の唯一の例外なので、コミットメッセージで明示する。

照合の結果:
- 差分が出なければ、この 3 ブロックの出力はリポジトリ非依存だったということ。想定どおり。そのまま進む。
- 差分が出た場合は**止まって内容を確認する**。新しい出力を黙って承認しない。差分がリポジトリ状態に由来するなら、`new_repo` ではなく元の依存を再現する形（直前の drop シナリオと同じ fixture を組む）に変えて、baseline と一致させる。

- [ ] **Step 3: `restack_test.rb` を抽出する（4 セクション）**

ヘッダの説明: `restack: replaying descendants onto an updated parent, and what it declines to touch.`

移すセクション（この順）:
1. `restack replays descendants onto the updated parent`
2. `restack aborts cleanly on a conflict`
3. `restack leaves an untracked branch alone`
4. `restack falls back to merge-base when stackBase is unrecorded`

- [ ] **Step 4: `drop_test.rb` を抽出する（9 セクション）**

ヘッダの説明: `drop: splicing a branch out and reconnecting its children.`

移すセクション（この順）:
1. `drop reconnects children to the trunk the dropped branch rested on`
2. `drop splices the bottom branch out, reparenting children onto trunk`
3. `drop a middle branch reconnects children to the grandparent`
4. `drop reparents every child of a branch with multiple children`
5. `drop --delete removes the branch ref after splicing`
6. `drop falls back to trunk when the dropped branch's own parent is gone`
7. `drop --delete on the current branch survives a dead recorded parent`
8. `drop refuses a trunk and a non-existent branch`
9. `drop with no argument splices the current branch`

- [ ] **Step 5: `track_test.rb` を抽出する（9 セクション）**

ヘッダの説明: `create / track / untrack / parent: the commands that write the stack metadata, and the edges they refuse.`

移すセクション（この順）:
1. `track with no argument picks the trunk the branch rests on`
2. `create records the parent and checks out the branch`
3. `create rejects an existing branch`
4. `parent shows and sets the parent`
5. `untrack removes the metadata`
6. `parent rejects an indirect cycle`
7. `track rejects an indirect cycle`
8. `track refuses to track a trunk`
9. `parent refuses to reparent a trunk`

- [ ] **Step 6: `init_test.rb` を抽出する（8 セクション）**

ヘッダの説明: `init: detecting the trunk, and validating the trunks it is handed.`

移すセクション（この順）:
1. `init auto-detects the trunk`
2. `init prefers the remote's default branch over main`
3. `init ignores the remote's default branch when it has no local ref`
4. `init reads the remote's default branch past a local branch named origin/<name>`
5. `init dies when the remote's default branch is the only candidate`
6. `init records multiple trunks and lists them`
7. `init rejects a non-existent trunk`
8. `init rejects a duplicate trunk name`

綴り解決の 2 件（`init resolves the remote's default branch to the spelling git stores` と `init rejects a trunk whose spelling is not the stored refname`）はここではなく `refnames_test.rb` へ行く。取り違えないこと。

- [ ] **Step 7: `trunk_test.rb` を抽出する（12 セクション）**

ヘッダの説明: `multiple trunks: how the list is read, kept live, and treated as a set of roots.`

移すセクション（この順）:
1. `an already-duplicated trunk list is deduped on read`
2. `sync re-detects a renamed trunk instead of reparenting onto its old name`
3. `a vanished secondary trunk is dropped from the trunk list`
4. `a trunk that is gone with no replacement is an error, and config is kept`
5. `a branch one level down does not stand in for its parent name`
6. `tree renders each trunk as its own root`
7. `an emptied stackParent is read as untracked, not as the primary trunk`
8. `restack stops at the secondary trunk it rests on`
9. `down and parent treat every trunk as a bottom`
10. `sync heals an orphan onto the trunk its stack rests on`
11. `sync still heals a main-based orphan onto main when a second trunk exists`
12. `a trunk's recorded parent is ignored by tree and restack`

- [ ] **Step 8: `sync_test.rb` を抽出する（10 セクション）**

ヘッダの説明: `sync: healing orphans, fast-forwarding merged branches, and clamping a stale base.`

移すセクション（この順）:
1. `restack and sync name the same root tree draws, with an untracked parent`
2. `sync reparents an orphaned branch onto trunk and restacks it`
3. `sync heals a multi-level orphan chain in one pass`
4. `sync reports a conflict the same way restack does`
5. `tree shows a branch whose parent was deleted, then sync fixes it`
6. `sync heals an orphan in another stack when run from the trunk`
7. `sync heals every orphaned stack in one pass, without repeating its own`
8. `sync recovers a branch whose parent was squash-merged and deleted`
9. `sync fast-forwards a branch fully merged into its parent`
10. `sync clamps a stale stackBase to the merge-base instead of re-applying parent commits`

- [ ] **Step 9: `refnames_test.rb` を抽出する（12 セクション）**

ヘッダの説明: `name resolution: a tag shadowing a branch name, and HEAD / trunk names whose spelling is not the one git stores.`

移すセクション（この順）:
1. `init resolves the remote's default branch to the spelling git stores`
2. `init rejects a trunk whose spelling is not the stored refname`
3. `a trunk whose stored spelling is not the refname is not live`
4. `trunk auto-detect will not store a name the refs do not have`
5. `tree keeps a branch whose name collides with a tag`
6. `trunk detection ignores a tag sharing a branch's name`
7. `commands read HEAD past a tag sharing the branch's name`
8. `a detached HEAD is still detached without --short`
9. `HEAD spelled differently from the ref still names the branch`
10. `HEAD spelled differently outside ASCII still names the branch`
11. `restack replays onto the parent branch, not a tag that shadows it`
12. `reparenting anchors the base to the parent branch, not a tag that shadows it`

- [ ] **Step 10: `nav_test.rb` を抽出する（12 セクション）— これで cli_test.rb は空になる**

ヘッダの説明: `up / down / parent: walking the stack, including through untracked parents and detached roots.`

移すセクション（この順）:
1. `down and parent walk an untracked branch to the trunk it rests on`
2. `down / up navigate the stack`
3. `up with multiple children requires a choice`
4. `up and down round-trip through an untracked parent`
5. `parent and down name the untracked parent they walk to`
6. `up lists a detached root alongside the trunk's tracked children`
7. `up offers a detached root only from the trunk its stack rests on`
8. `parent notes a parent whose ref is gone`
9. `up <name> reaches another trunk's detached root; the menu still refuses it`
10. `tree and up agree on which trunk a detached root belongs to`
11. `up refuses a detached root whose ref no longer exists (a phantom node)`
12. `up orders a trunk's tracked child before its detached roots, sorted`

- [ ] **Step 11: 空になった cli_test.rb を消す**

この時点で `test/cli_test.rb` にはヘッダと `require_relative` しか残っていないはず。残骸があれば移し漏れなので、先に付録の表と突き合わせる。

```bash
grep -c '^section ' test/cli_test.rb   # 0 であること
git rm test/cli_test.rb test/cli_test.rb.expected
```

- [ ] **Step 12: 全 85 シナリオが揃っていることを確認する**

```bash
grep -h '^section ' test/*_test.rb | wc -l          # 85
ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" test/*_test.rb.expected \
  | diff -u "$SCRATCH/baseline.expected" -
```

Expected: 85、差分なし、exit 0

- [ ] **Step 13: CI のスナップショット diff をループにする**

`.github/workflows/ci.yml` の 24〜25 行目を置き換える。`set -e` は使わない — 1 ファイル目で止めず、落ちた全ファイルを 1 回の実行で見せるため。

```yaml
      - name: Diff transcripts against snapshots
        run: |
          set -uo pipefail
          status=0
          for f in test/*_test.rb; do
            ruby "$f" | diff -u "$f.expected" - || status=1
          done
          exit $status
```

- [ ] **Step 14: CI の spinel-doctor を全テストファイルに広げる**

`.github/workflows/ci.yml:230` の `spinel-doctor test/cli_test.rb` を置き換える。

```yaml
          for f in test/*_test.rb; do
            spinel-doctor "$f"
          done
```

`test/support/helper.rb` は個別にはかけない。各テストファイルの `requires` チェックを通じて見られており、単体でかけると呼び出し元が分からないぶん `def section: (untyped) -> nil` のような広がりを `[info]` で出すだけになるため。

- [ ] **Step 15: CI をローカルで再現して確認する**

```bash
status=0
for f in test/*_test.rb; do ruby "$f" | diff -u "$f.expected" - || status=1; done
echo "snapshot status=$status"
for f in test/*_test.rb; do spinel-doctor "$f" || echo "DOCTOR FAILED: $f"; done
spin test
```

Expected: `snapshot status=0`、doctor は全て `clean`、`spin test` は `10/10 passed`

- [ ] **Step 16: 変わっていないはずのものが変わっていないことを確認する**

```bash
spin build
test/binary_test.sh | diff -u test/binary_test.sh.expected -
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output="$SCRATCH/emitted.rbs"
diff -u test/git-stack.rbs.expected "$SCRATCH/emitted.rbs"
```

Expected: どちらも差分なし。RBS golden は `bin/git-stack.rb` 由来なので、テストの構成を変えても動かないはず。動いたら `bin/git-stack.rb` に触れている。

- [ ] **Step 17: README を更新する**

`README.md` の `## Tests` 節（257〜283 行目）を、1 ファイル前提の記述から複数ファイル前提に直す。`spin test` / `spin test --regen` の説明は変わらない。CRuby の節を次のように直す:

```markdown
The suite lives in `test/`, split by topic (`init_test.rb`, `sync_test.rb`,
`drop_test.rb`, …), with the shared harness in `test/support/helper.rb`. Each
file is a Spinel **snapshot test**: it drives its commands in throwaway
repositories and prints a transcript of exactly what they emit (output + exit
status). `spin test` compiles each one with Spinel and diffs its transcript
against the committed snapshot beside it — any change in behaviour shows up as
a diff.
```

```sh
ruby test/sync_test.rb                                 # print one file's transcript
ruby test/sync_test.rb > test/sync_test.rb.expected    # regenerate that snapshot
```

```sh
GIT_STACK="$PWD/build/bin/git-stack" ruby test/sync_test.rb   # compiled Spinel binary
```

- [ ] **Step 18: 残った `cli_test.rb` の名指しを直す**

コメント内の参照。挙動には関係しないが、存在しないファイルを指したままにしない。

```bash
grep -rn "cli_test" --exclude-dir=.git --exclude-dir=vendor --exclude-dir=build .
```

直す先は 3 つ:

1. `test/support/helper.rb` の解説コメント。`test/cli_test.rb` の名指しは 5 行 6 箇所ある（9, 20, 21 の 2 箇所, 26, 32 行目）。1 本を前提にした再生成手順を、ファイルごとの手順に直す:

```ruby
# committed snapshot beside it (`test/<name>_test.rb.expected`). Any
```

```ruby
#     ruby test/sync_test.rb                              # print one transcript
#     ruby test/sync_test.rb > test/sync_test.rb.expected # regenerate that one
```

```ruby
#     GIT_STACK="$PWD/build/bin/git-stack" ruby test/sync_test.rb   # spinel binary
```

`$root` の説明にある「`spin test` と `ruby test/cli_test.rb` はどちらもプロジェクトルートから走る」も `ruby test/<name>_test.rb` に一般化する。

2. `test/binary_test.sh` の 5, 32, 153, 256 行目。いずれも「CRuby のスナップショットテスト」を指しているので `test/*_test.rb` を指す書き方にする。**コードは変えない** — `test/binary_test.sh.expected` が動いてはならない。

3. `bin/git-stack.rb:1485` のコメント。`cli_test.rb asserts these very ...` を、そのアサーションが実際に置かれたファイル名に直す。

```bash
test/binary_test.sh | diff -u test/binary_test.sh.expected -
```

Expected: 差分なし

- [ ] **Step 19: コミット**

```bash
git add -A test .github README.md bin/git-stack.rb
git commit -m "test: split the snapshot suite into ten topic files

cli_test.rb had reached 1410 lines and 85 scenarios appended in fix order,
so drop sat in two places, sync in three, and the 915-line snapshot was one
block. Scenarios move verbatim into a file per topic, each with its own
snapshot beside it; spin test already builds test/*.rb one by one.

The move is proved rather than trusted: the new snapshots reassembled in the
old order are byte-identical to the old one, so no scenario was dropped or
altered on the way. The one deliberate exception is the first three flags
sections, which had no new_repo and ran on whatever repo the preceding drop
scenario left behind; they get one of their own, and the transcript is
unchanged by it."
```

---

### Task 4: コメントを整理する

`.expected` を 1 バイトも変えない。ここで書き換えるのはコメントだけであり、スナップショットはコメントの破壊を検出できないので、目視レビューが唯一の防御になる。

**Files:**
- Modify: `test/init_test.rb`、`test/trunk_test.rb`、`test/refnames_test.rb`、`test/sync_test.rb`、`test/flags_test.rb`

**Interfaces:**
- Consumes: Task 3 で分割済みの `test/*_test.rb`

- [ ] **Step 1: ファイルをまたぐ参照を名指しに直す**

設計の表にある 8 箇所（位置語 7 + セクション名の直接参照 1）。`above` / `below` / `elsewhere` をやめ、セクション名で名指しする。参照先が別ファイルなら `<file>.rb の "<section>"` の形にする。

| 移動先 | 直す内容 |
|---|---|
| `init_test.rb` | 旧 111 行目、`init prefers the remote's default branch over main` の前にある「the sections below point it at a remote-tracking ref」。対象が init と refnames に割れたので、「このファイルと refnames_test.rb の綴りのセクションは origin/HEAD を remote-tracking ref に直接向ける」と書く |
| `refnames_test.rb` | 旧 152 行目、「worse than the miss above」。参照先は `init_test.rb` の `init reads the remote's default branch past a local branch named origin/<name>` なので名指しする |
| `refnames_test.rb` | 旧 157 行目、「the HEAD and trunk-spelling sections elsewhere」。参照先は同じファイルに集まったので「このファイルの HEAD 綴りのセクション」と書く |
| `refnames_test.rb` | 旧 265 行目、「The liveness re-check above」。参照先は `trunk_test.rb` の `a trunk that is gone with no replacement is an error, and config is kept` |
| `refnames_test.rb` | 旧 271 行目、「the note above」。同上のセクションを名指しする |
| `trunk_test.rb` | 旧 301 行目、「unlike the two above」。参照先は `refnames_test.rb` の `a trunk whose stored spelling is not the refname is not live` と `trunk auto-detect will not store a name the refs do not have` |
| `flags_test.rb` | 旧 503 行目、`(see "drop --delete removes the branch ref after splicing")` に `drop_test.rb` のファイル名を添える |
| `sync_test.rb` | 旧 999 行目、直前セクションへの参照。参照先は `restack_test.rb` の `restack falls back to merge-base when stackBase is unrecorded` |
| `track_test.rb` | 冒頭の「The three commands below have to answer "which trunk is this branch on?"」。分割前は 3 セクションを束ねる見出しだったが、その 3 つは `track_test.rb` / `sync_test.rb` / `drop_test.rb` に分かれた。今は 1 セクションしか率いていないので、残り 2 つを名指しする（`sync_test.rb` の `sync heals an orphan onto the trunk its stack rests on` と `drop_test.rb` の `drop reconnects children to the trunk the dropped branch rested on`） |

これは Task 3 の実施中に見つかった 9 件目で、当初の 8 件の表には無かったもの。位置語ではなく「below」で複数セクションを束ねる見出しだったため、最初の洗い出しで「セクション内を指すもの」に誤分類していた。

セクション内の近くのコードを指している 16 箇所は触らない。

- [ ] **Step 2: refnames_test.rb に共有テーマの前置きを書く**

「ユーザが打った名前ではなく git が保存している綴りに解決する」という話が 6 セクションに重複して書かれている。ファイル冒頭のヘッダに一度だけ書き、各セクションの rationale からはその共通部分を落として固有の部分だけ残す。**固有の部分は逐語で保つ** — issue 番号、症状の描写、どのプラットフォームで再現するかの注記は削らない。

特に次は各セクション側に残す:
- `a trunk whose stored spelling is not the refname is not live` の「case-sensitive なファイルシステムでは no-op になり、CI では回帰ガードとして働かない」という注記
- `init resolves the remote's default branch to the spelling git stores` の「これは他と違い case-sensitive でも落ちる」という注記（上と逆の性質なので、まとめない）

- [ ] **Step 3: 他ファイルを指す位置語が残っていないことを確認する**

```bash
grep -n 'above\|below\|elsewhere' test/*_test.rb test/support/helper.rb
```

出た行を 1 つずつ見て、参照先が同じセクション内であることを確かめる。別セクションを指しているものが残っていたら Step 1 の漏れ。

- [ ] **Step 4: スナップショットが 1 バイトも変わっていないことを確認する**

本タスクの検証の核。

```bash
git status --short test/          # *.expected が出ないこと
for f in test/*_test.rb; do ruby "$f" | diff -u "$f.expected" -; done
```

Expected: `git status` に `.expected` が 1 件も出ない。diff も全て差分なし。`.expected` が変わっていたらコメント以外に手が入っている。

- [ ] **Step 5: コメント差分を目視でレビューする**

```bash
git diff test/
```

追加/削除された行が全てコメント（`#` 始まり）であることを確認する。コード行が 1 行でも出ていたら止めて戻す。

- [ ] **Step 6: Spinel で通ることを確認する**

```bash
spin test
for f in test/*_test.rb; do spinel-doctor "$f"; done
```

Expected: `10/10 passed`、doctor は全て `clean`

- [ ] **Step 7: コミット**

```bash
git add test
git commit -m "test: name the cross-file references the split broke

Seven comments pointed at other sections with above/below/elsewhere; six of
those sections now live in a different file, where the direction words say
nothing. They name their target instead. The spelling story that six
sections each retold now sits once in the refnames_test.rb header, with the
platform notes left on the sections they are actually true of.

No .expected moved: comments are all that changed, and the snapshot cannot
police that on its own."
```

---

## 完了条件

- `for f in test/*_test.rb; do ruby "$f" | diff -u "$f.expected" -; done` が全て通る
- `spin test` が `10/10 passed`
- `ruby "$SCRATCH/verify_split.rb" "$SCRATCH/baseline.expected" test/*_test.rb.expected | diff -u "$SCRATCH/baseline.expected" -` が差分なし（flags の 3 ブロックを除く場合は、その差分を説明できること）
- `test/binary_test.sh | diff -u test/binary_test.sh.expected -` が通る
- `diff -u test/git-stack.rbs.expected "$SCRATCH/emitted.rbs"` が通る
- 全テストファイルで `spinel-doctor` が `clean`
- Task 4 の `git diff` にコード行の変更が 1 行も含まれていない
- 分割後のファイルに、他ファイルを指す `above` / `below` / `elsewhere` が残っていない
- `grep -rn "cli_test"` がリポジトリ内で何も返さない（`.git` / `vendor` / `build` を除く）
