# YARD Documentation Style Guide

This guide defines documentation standards for the dr-scripts codebase using
[YARD](https://yardoc.org/) syntax. It covers what to document, how to document
it, and what to skip.

This guide adapts the
[lich-5 YARD Style Guide](https://github.com/elanthia-online/lich-5/blob/main/docs/YARD-STYLE-GUIDE.md)
for standalone `.lic` scripts. YARD syntax is used purely as a human-readable
convention — no HTML documentation is generated.

## Principles

1. **Document as you touch** — Add YARD docs when creating or modifying code.
   No retroactive documentation sweeps required.
2. **Accuracy over completeness** — A concise, correct doc block is better than
   a comprehensive, stale one.
3. **Examples over prose** — Show usage with `@example` blocks rather than
   explaining behavior in paragraphs.
4. **Types are required** — Every `@param` and `@return` must include a type
   annotation.
5. **Enforce through PR review** — No CI enforcement. Reviewers check that new
   or modified methods have appropriate documentation.

---

## Documentation Tiers

Methods fall into one of four tiers based on their role within the script.
When a file defines multiple classes, apply these tiers per class.

### Entry Points (Full Documentation)

`initialize` and the top-level orchestration methods it calls directly.
These define the script's public behavior and CLI interface.

**Required tags**: summary line, `@param`, `@return`

**Encouraged tags**: `@example` (CLI invocations), `@note` (settings
dependencies, guild restrictions), `@see`

```ruby
# Automates astrology training for Moon Mage characters.
#
# Handles observation, prediction, and ritual cycles based on
# user YAML configuration.
#
# @note Requires Moon Mage guild membership.
#
# @note Required settings keys:
#   - `astrology_training` [Array<String>] training methods to cycle
#   - `have_telescope` [Boolean] whether character owns a telescope
#   - `telescope_name` [String] telescope item noun
#   - `astral_plane_training` [Hash, nil] astral plane config (optional)
#
# @example Basic usage
#   ;astrology
#
# @example Run Read the Ripples only
#   ;astrology rtr
#
# @see DRCA Arcana operations for buff management
# @see DRCMM Moon Mage operations for observation
# @see https://elanthipedia.play.net/Lich_script_repository#astrology
class Astrology
```

### Functional Units (Standard Documentation)

Public methods that perform one discrete task — the methods `initialize`
delegates to (e.g., `train_astrology`, `do_buffs`, `train_engineering`).

**Required tags**: summary line, `@param`, `@return`

```ruby
# Trains outfitting by selecting a recipe appropriate for the
# character's current skill rank.
#
# @return [void]
def train_outfitting
```

```ruby
# Executes one combat round for the current game state.
#
# @param game_state [GameState] current combat state tracker
# @return [Boolean] true if processing should continue
def execute(game_state)
```

### Helpers (Developer Documentation)

Private or internal methods that support functional units.

**Required tags**: summary line, `@param`, `@return`

```ruby
# Selects the next weapon skill to train based on experience rates
# and rank, excluding blacklisted or mindlocked skills.
#
# @param options [Array<String>] candidate skill names
# @return [String, nil] skill name to train, or nil if none available
def sort_by_rate_then_rank(options)
```

### Skip (No Documentation Needed)

The following do not require YARD documentation:

- Trivial one-line delegation methods
- `attr_reader` / `attr_accessor` declarations
- Aliases where the target method is already documented
- Constants with self-evident names and values (e.g., `MAX_RETRIES = 3`)

---

## Tag Reference

### Always Use

| Tag | Format | Notes |
|-----|--------|-------|
| `@param` | `@param name [Type] description` | One per parameter. Type is required. |
| `@return` | `@return [Type] description` | What the method returns. Use `[void]` for no return value. |

### Use When Relevant

| Tag | Format | When |
|-----|--------|------|
| `@example` | Code block follows on next line(s) | CLI invocations on class docs; complex method usage |
| `@note` | `@note text` | Guild restrictions, required settings keys, important caveats |
| `@see` | `@see ClassName` or `@see #method_name` | Cross-reference lich-5 modules or related methods |
| `@raise` | `@raise [ExceptionType] when...` | Only if the method raises exceptions |
| `@deprecated` | `@deprecated Use {#new_method} instead` | Marks superseded code |

### Method Reference Syntax

Most dr-scripts methods are instance methods. Use `#method_name` in `@see`
tags and `{#method_name}` in inline references.

```ruby
# Instance method reference (most script methods)
# @see #train_outfitting

# Cross-reference to lich-5 module
# @see DRCI Common item operations
# @see DRCA Arcana operations
```

### Do Not Use

| Tag | Why |
|-----|-----|
| `@author` | Use `git blame` instead |
| `@version` | dr-scripts has no meaningful versioning; use git history |
| `@todo` | Use GitHub issues instead |
| `@abstract` | Ruby does not have abstract methods |
| `@api private` | dr-scripts classes are not consumed as libraries; use `private` keyword instead |
| `@since` | No versioned releases; use git history |

---

## Type Notation

YARD uses a specific syntax for type annotations.

### Common Types

```ruby
@param name [String]              # simple type
@param count [Integer]            # numeric
@param enabled [Boolean]          # true/false
@param name [String, nil]         # nilable
@param id [String, Integer]       # union
@param items [Array<String>]      # typed array
@param opts [Hash{Symbol => String}]  # typed hash
@return [void]                    # no meaningful return
@return [Boolean]                 # predicate method
```

### Game-Specific Types

```ruby
@param item [String]               # item noun ("sword", "backpack")
@param item [DRC::Item]            # item object from gear configuration
@param container [String, nil]     # container noun or nil for default
@param pattern [Regexp]            # regex for game output matching
@param settings [OpenStruct]       # user settings from get_settings
@param game_state [GameState]      # combat trainer state object
@param args [OpenStruct]           # parsed CLI arguments from parse_args
```

---

## Documenting Classes

Every `.lic` file defines at least one class. Each class should have a doc
block summarizing its purpose.

### Single-Class Scripts

```ruby
# Automates crafting training by selecting recipes appropriate
# for the character's current skill rank.
#
# @note Required settings keys:
#   - `craft_max_mindstate` [Integer] XP threshold to stop training
#   - `crafting_container` [String] bag noun for crafting supplies
#   - `craft_overrides` [Hash, nil] manual recipe overrides by discipline
#
# @example Train forging
#   ;craft forging
#
# @example Train outfitting
#   ;craft outfitting
#
# @see https://elanthipedia.play.net/Lich_script_repository#craft
class Craft
```

### Multi-Class Scripts

When a file defines multiple classes, document each class individually.
The top-level "runner" class gets the CLI examples and settings notes.
Supporting classes document their role within the script.

```ruby
# Manages combat setup: stance selection, weapon cycling, and
# armor rotation between training targets.
#
# @see GameState State tracker this process reads and updates
class SetupProcess
```

```ruby
# Tracks mutable combat state shared across all process classes.
#
# Holds current weapon, target, stance, and training progress.
# Updated by process classes each combat round.
class GameState
```

```ruby
# Top-level combat training orchestrator.
#
# Loads settings, initializes process classes, and runs the
# main combat loop until training goals are met or interrupted.
#
# @note Required settings keys:
#   - `weapon_training` [Hash{String => String}] skill → weapon mapping
#   - `combat_trainer_retreat_weapons` [Array<String>] retreat weapon skills
#   - `priority_defense` [String, nil] defense to prioritize in stance
#
# @example Basic usage
#   ;combat-trainer
#
# @see https://elanthipedia.play.net/Lich_script_repository#combat-trainer
class CombatTrainer
```

---

## Documenting Constants

### Pattern Arrays and Hashes

Pattern constants should document what strings they match or what values
they map.

```ruby
# Pool understanding level patterns for predict state parsing.
#
# Maps game output patterns to numeric understanding levels (0-10)
# for tracking celestial prediction pool progress.
#
# @example Matches
#   "You have a feeble understanding of the celestial influences over"  => 1
#   "You have a complete understanding of the celestial influences over" => 10
#
# @see #check_pools
POOL_PATTERNS = {
  /You have no understanding of the celestial influences over/     => 0,
  /You have a feeble understanding of the celestial influences/    => 1,
  # ...
}.freeze
```

### Simple Constants

A one-line comment is sufficient.

```ruby
# Perceive targets for attunement training.
PERCEIVE_TARGETS = ['', 'mana', 'moons', 'planets'].freeze
```

---

## Documenting Settings Dependencies

Many scripts depend heavily on YAML settings loaded via `get_settings`.
Document required settings on the class doc block using `@note`.

Organize settings into **required** (script fails without them) and
**optional** (script has defaults or skips the feature).

```ruby
# @note Required settings keys:
#   - `hometown` [String] character's home town
#   - `weapon_training` [Hash{String => String}] skill-to-weapon mapping
#
# @note Optional settings keys:
#   - `combat_trainer_retreat_weapons` [Array<String>] retreat weapon skills
#   - `cycle_armors` [Array<Hash>] armor cycling configuration
#   - `stance_override` [Hash{String => Hash}, nil] per-weapon stance overrides
```

---

## Documenting CLI Arguments

Scripts define their CLI interface via `arg_definitions` arrays passed to
`parse_args`. Document these as `@example` blocks on the class.

```ruby
# @example CLI invocations
#   ;astrology           # Default training cycle
#   ;astrology rtr       # Run Read the Ripples only
#   ;astrology debug     # Enable debug output
```

For scripts with complex argument combinations, show each valid form:

```ruby
# @example CLI invocations
#   ;craft forging       # Train forging
#   ;craft outfitting    # Train outfitting
#   ;craft engineering   # Train engineering
#   ;craft alchemy       # Train alchemy
#   ;craft enchanting    # Train enchanting
```

---

## Tag Order

When multiple tags appear on a method or class, use this order:

1. `@param` (in parameter order)
2. `@return`
3. `@example`
4. `@note`
5. `@raise`
6. `@see`
7. `@deprecated`

---

## Anti-Patterns

### Do Not Restate the Obvious

```ruby
# BAD: Restates the method name
# This method trains outfitting.
#
# @return [void] Returns void
def train_outfitting

# GOOD: Adds context beyond the name
# Trains outfitting by selecting a recipe appropriate for the
# character's current skill rank.
#
# @return [void]
def train_outfitting
```

### Do Not Use Prose Where Examples Suffice

```ruby
# BAD: Wall of text
# The method accepts a craft argument which must be one of the
# five supported crafting disciplines. The argument is parsed
# using parse_args and matched against the options list.

# GOOD: Show it
# @example
#   ;craft forging
#   ;craft outfitting
```

### Do Not Document Internals That Change Frequently

```ruby
# BAD: Implementation detail that will go stale
# Uses tier-based rank thresholds: 0-25 socks, 25-50 mittens,
# 50-100 hat, 100-175 gloves, 175-300 hose, 300-425 cloak.

# GOOD: Document the contract
# Selects a recipe at the appropriate difficulty tier for the
# character's current Outfitting rank.
```

---

## Summary

| Question | Answer |
|----------|--------|
| When do I add docs? | When creating or modifying code |
| What's required for public methods? | Summary, `@param`, `@return` |
| Are `@example` blocks required? | Encouraged on classes, not required on methods |
| Do I document private methods? | Summary + types (brief) |
| What about trivial helpers? | Skip them |
| How is this enforced? | PR review |
| Do I document settings? | `@note` on class doc for required/optional keys |
| What about multi-class files? | Document each class individually |
| Is HTML documentation generated? | No — YARD syntax is a convention only |
