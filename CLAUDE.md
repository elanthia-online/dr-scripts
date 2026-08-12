# dr-scripts Project Instructions

DragonRealms automation scripts for the Lich engine. Each `*.lic` file is a
standalone Ruby script executed inside the Lich runtime, not a normal gem. These
scripts depend on the separate **lich-5** framework repo (typically checked out
alongside this one), which provides the runtime, game-state objects, and the
commons library the scripts call into — a cross-repository dependency to keep in
mind when a symbol appears "undefined" here.

## Runtime environment (read before flagging "bugs")

- **Ruby 4.0.0 floor, no ceiling.** Code must run on Ruby `>= 4.0.0`
  (`.ruby-version` pins `4.0.0` as the minimum; any newer patch/version is fine —
  don't flag a mismatch against an exact version). The only real constraint is:
  don't rely on APIs introduced *after* 4.0.0. Stdlib classes autoloaded since
  Ruby 3.2 (e.g. `Set`) need no `require` — a missing `require 'set'` is **not**
  a bug here.
- **`.lic` scripts run inside Lich**, which injects a large global API. Do not
  flag "undefined method/constant" for host-provided globals such as `fput`,
  `put`, `echo`, `respond`, `pause`, `waitfor`, `matchwait`, `get_settings`,
  `UserVars`, `Script`, `Flags`, `DownstreamHook`, `Vars`, or the game-object
  and commons modules listed below — they exist at runtime even though they are
  not defined in the file.
- **Commons layer (cross-repo dependency).** Scripts call shared helpers via
  `DRC`, `DRCI`, `DRCC`, `DRCM`, `DRCT`, `DRCH`, `DRCA`, `DRCS`, `DRCMM`,
  `DRCTH`, and messaging via `Lich::Messaging`. Game state comes from `DRStats`,
  `DRSkill`, `DRSpells`, `DRRoom`, `GameObj`, `Room`, `Map`, `XMLData`,
  `EquipmentManager`. **None of these are defined in dr-scripts** — they live in
  the separate **lich-5** framework repo under `lib/dragonrealms/commons/`
  (namespace `Lich::DragonRealms::*`; e.g. `DRCC` is in `common-crafting.rb`,
  the SlackBot in `slackbot.rb`, `EquipmentManager` in `equipmanager.rb`). They
  exist at runtime — do not flag them as undefined. To confirm a commons
  method's existence or signature, verify it in lich-5; never guess it in or out.

## Rubocop (CRITICAL)

**Run `rubocop -A` locally before committing.** The rubocop floor is set by
`TargetRubyVersion: 4.0` in `.rubocop.yml` (not `.ruby-version`), with
`NewCops: disable` and a custom `ascii_only_source` cop; `LineLength` and most
`Metrics` are off. CI (`.github/workflows/rubocop.yml`) runs **check-only**
`bundle exec rubocop` under Ruby 4.0 against only the **changed top-level**
`*.lic`/`*.rb` files of a PR — it does not lint the whole repo or nested files
(e.g. `spec/*.rb`). Run locally under any interpreter at/above the floor (e.g.
`RBENV_VERSION=4.0.1 rubocop -A` under rbenv). Assume CI runs the linter; do not
re-flag pure formatting/style rubocop would catch.

## Spec suite integrity (hard rule)

The RSpec suite must stay green. A PR that fails the "Run tests on Ruby 4.0" CI
job when `main` is green is an **automatic blocking issue** — verify with
`gh pr checks <n> --repo elanthia-online/dr-scripts` (or run `bundle exec rspec`
locally) as a first step of any review.

The whole suite runs in **one process on shared, centrally-defined doubles**
(see `spec/spec_helper.rb`). A single spec that reopens/redefines a harness
module (e.g. `Lich`, `DRC`) or registers a global `RSpec.configure` hook can
break **unrelated** specs by load order. So when tests fail, do NOT assume the
failing spec is the culprit — a new spec commonly breaks pre-existing ones
(`uninitialized constant Lich::Messaging` across untouched files is the classic
symptom). Fix by overriding with `allow(...).to receive(...)` and adding new
doubles to `test/test_harness.rb`, never by reopening a module in a spec.

## PR rules

- PRs target `main` on `elanthia-online/dr-scripts`, sent from a contributor's
  own fork.
- Prefer small, focused PRs. Bundling multiple independent bug fixes with a large
  refactor makes review unreliable — split bug fixes (each with a regression
  spec) from structural changes where practical.

## Testing

Full conventions live in **`spec/spec_helper.rb`** and the shared doubles in
**`test/test_harness.rb`** — read those first; the notes below are the summary.

- One spec per script: `spec/<script-name>_spec.rb`.
- Style is **DAMP** (readable, self-documenting tests) over strict DRY; extract
  shared assertions into `shared_examples`, not deep inheritance.
- `.lic` files cannot be `require`d (they need the full runtime). Extract the
  unit under test with `load_lic_class('file.lic', 'ClassName')` or
  `load_lic_constant('file.lic', 'CONST')`, then build bare instances with
  `ClassName.allocate` and inject ivars.
- Game objects and commons modules are stubbed **once, centrally** in
  `test/test_harness.rb`. Do **not** reopen/redefine them in a spec — override
  per-example with `allow(DRC).to receive(:bput)...`. Add missing commons methods
  to the harness, not to a single spec.
- Guard `exit` paths with `expect { ... }.to raise_error(SystemExit)`.

## Data & profile YAML

Scripts read config from `data/*.yaml` and character/setup files under
`profiles/**/*.yaml`. **Two CI gates cover YAML:** the `validate-yaml` job
(`.github/workflows/yamllint.yml`) runs `yamllint` on changed `data/*.yaml` and
`profiles/**.yaml`, and `spec/valid_yaml_spec.rb` Ruby-parses every
`profiles/**/*.yaml` in the rspec suite — so a malformed profile fails CI twice.
Profiles are loaded permissively (`YAML.unsafe_load_file`) because they use
`!ruby/regexp` tags and aliases — do not "fix" them into plain safe-load YAML.
When a PR adds or edits YAML, confirm it parses and that any new setting is
actually read by the script that consumes it.

## Review guidance & common false positives

**Review stance: a senior engineer who hates this implementation.** Approach
every change adversarially — assume it is flawed until proven otherwise, and
actively hunt for the edge cases, failure modes, and unstated assumptions the
author did *not* consider: empty/nil/missing inputs, zero/negative/huge counts,
partial failures mid-batch, retries and timeouts, concurrent runs sharing state,
malformed or unexpected game output, and resumability after a crash. Be
demanding about correctness and robustness; a green spec suite is the floor, not
proof of correctness — ask what the tests *don't* cover. This rigor is precisely
what lets you clear the noise quickly: the items below are genuinely **not**
flaws, so verify them and move on rather than padding the review with them.

The following are usually **not** real issues — verify against the runtime
before flagging:

- Missing `require` for autoloaded stdlib (see Ruby 4.0 note).
- "Undefined" host globals / commons modules — injected by the lich-5 runtime;
  commons live in lich-5 `lib/dragonrealms/commons/`, not this repo. A `DRC*`
  method missing from dr-scripts is defined there — verify in lich-5 before
  flagging, and don't guess its existence either way.
- Formatting/style rubocop already enforces.
- Missing documentation or general UX suggestions (not required here).
- A concern that the code already guards against — check for the guard (and its
  spec) before flagging.

Genuine things worth flagging:

- **Cross-file duplicated invariants.** When logic must match across two files
  (e.g. a DB schema, or a normalization routine copied into a paired script),
  comments saying "must stay in sync" are a latent bug. Prefer extracting the
  shared logic into one module both files load. Flag new copy-paste of
  invariants that will silently diverge.
- Mutating a caller's argument (`gsub!`, `<<`, `sort!`) when a pure transform is
  expected.
- Unbounded growth of long-lived collections/ivars.
- Unclosed file/db handles, and errors that escape a per-item loop and abort a
  resumable batch instead of being logged and skipped.
- Regressions of previously-fixed behavior — check `git log`/`git blame` on the
  touched lines when a change removes a guard.
