# Shortcuts and shorthand: review draft

This is an unpublished implementation draft. It does not change the published
release until the grammar and human terminal checks have been reviewed.
The first word in a bare list is assumed to be the destination name:
`a one, two, threee` assigns persistent `@a`, preserving `threee` exactly.

## Command shortcuts

Shortcuts are exact and uppercase. Arguments and unsaved-source safeguards are
the same as the full command. Digits distinguish commands sharing an initial;
`V` groups environment variables. Existing punctuation forms `?`, `!`, and
`!!` are unchanged.

| Shortcut | Full operation |
|---|---|
| A | AUTO |
| A0 | AUTO OFF |
| A1 / A2 | AUTO ECHO ON / AUTO ECHO OFF |
| C / C1 | CLS / CD (CHDIR) |
| D / D1 | DUMP / DEL (DELETE) |
| E / E1 / E2 | EVAL / EDIT / EXPORT |
| F / H / I | FUNCTIONS / HELP / IMPORT |
| L / L1 | LIST / LOAD |
| L2 / L3 | LIST SLOW / LIST PAUSE |
| N / P / Q | NEW (CLEAR) / PEEK / QUIT (EXIT) |
| R / R1 | RUN / RENUM (REORDER) |
| R2 / R3 | RESET / RECOVER |
| S / S1 / U | SAVE / STATUS / UNDO |
| V / V0 | ENV / ENV RESET |
| V1 / V2 / V3 | ENV SET / ENV UNSET / ENV EDIT (EDIT ENV) |
| V4 / V5 / V6 | ENV SAVE / ENV LOAD / ENV RELOAD |

Examples: `E say "hi"`, `L 5-20`, `L2 5-20`, `C1 ..`,
`V1 NAME "hello world"`, `S demo.pl`. Only `L1!`, `I!`, `N!`, and
`Q!` bypass an unsaved-source guard. Separate arguments with a space:
`L1 file.pl` loads; `L 1` lists line 1. `L10` does neither.

Wrong-case bareword hints say `REPL commands must be uppercase; try, "CLS".`
They do not contain `use CLS`, which could be confused with a Perl statement.

## Immediate definitions

| Input | Destination |
|---|---|
| `E s triple return 3 * shift` | Function `triple` |
| `E a colors red, blue` | Array `@colors` |
| `E ar names Ada, Bob` | Array reference `$names` |
| `E h options color => blue, count => 3` | Hash `%options` |
| `E hr record name => Ada, tags => [one, two]` | Hash reference `$record` |

Tags are lowercase and are recognized only after uppercase `E`.
Names are ASCII identifiers without a sigil or namespace. Functions need a
body; data definitions may omit values to create an empty container.

Definitions execute immediately, including during AUTO, and leave AUTO active.
They do not add source to LIST or SAVE. Variables persist in the workspace;
they are not `my` variables scoped to a single evaluation. Function bodies are
ordinary Perl, including recursion and redefinition warnings. Advanced
declarations such as prototypes and attributes remain literal Perl:
`EVAL sub twice ($) { 2 * $_[0] }`.

`E` is an EVAL shortcut with these five reserved definition prefixes.
`EVAL` always bypasses shorthand. For example, `E s /old/new/` is rejected
as an incomplete definition; `EVAL s /old/new/` is a Perl substitution.
`E s/old/new/` also remains a substitution because there is no spaced tag.

## Implicit quoting

With AUTO off:

```text
a one, two, threee
D \@a
settings color => blue, count => 3
D \%settings
```

The first word names the destination. A top-level comma selects an array;
a top-level arrow selects a hash. Commas/arrows inside strings or nested
containers do not select an implicit definition by themselves. A one-item
array can use `E a colors red` or the bare `colors red,` form.

Actual Perl keywords and existing workspace functions have priority. Thus
`say "one", "two"` remains Perl, and a defined function named `colors`
still runs when called. `E a colors red, blue` explicitly assigns the array
even if a function has that name. Unrecognized destination names must start
with a lowercase letter or underscore; explicit typed forms accept either case.

Bare destination shorthand is rejected during AUTO with an explanation, so it
cannot quietly become invalid source. Use `E a ...` / `E h ...` or `A0`
first. Numbered input, colon input, EDIT, IMPORT, LOAD, and RUN remain literal
Perl. There is no shorthand rewriting inside stored programs.

## Complete value grammar

The same grammar applies recursively to arrays, arrayrefs, hashes, and hashrefs.

- Commas separate items. One trailing comma and one final statement semicolon
  are allowed; missing items are errors.
- Every hash item is `key => value`. Lists and pairs cannot be mixed.
- Bare words contain letters, digits, or underscores and start with a letter
  or underscore. They become exact strings. No spelling correction occurs.
- `undef` is the special undefined value; quote it to get the string "undef".
- Signed decimal numbers, fractions, and decimal exponents stay numbers.
  Quote leading zeroes, such as `"042"`, or write an explicit Perl expression.
- Single and double quotes behave as in Perl. Double quotes interpolate.
  Quote spaces, punctuation, and empty text: `"two words"`, `"red-blue"`, `""`.
- A simple scalar such as `$count` refers to its live value.
- `[one, two]` constructs an arrayref; `{color => blue}` constructs a hashref.
  Nest them freely. Container literals cannot be hash keys.
- Parentheses mark explicit Perl expressions: `(1 + 2)`, `(1..3)`,
  `($ENV{HOME})`, `(\%ENV)`, `(qw/one two/)`.
  Arrays give expressions list context. Each hash key/value gives scalar context.
  For a hash value containing several items, use an arrayref such as `[one,two]`.
- Duplicate hash keys keep the last value, following Perl.
- Implicit quoting does not apply inside parenthesized expressions or function
  bodies. Their strings still use ordinary Perl syntax.
- Inline shorthand comments, unquoted punctuation, extra operators, and
  multiword values are not guessed. Quote literal text or use literal EVAL.

## Errors, continuation, and execution

Malformed shorthand gets `Ambiguous shorthand: ... Try EVAL with explicit Perl
syntax.` before evaluation. A rejected literal definition leaves prior
variables intact. Open quotes and containers continue; a mismatched closing
delimiter reports an error rather than trapping the user in continuation.
Ctrl-N or bracketed paste can group a multiline list.

No user code is compiled or run to classify input. Accepted expressions and
function bodies use normal Perl execution, warnings, and errors. Runtime or
compile-time side effects are not transactions and are not rolled back.
Typing, rerunning, and pasting follow the same grammar.

## Review checklist

Validation on the DC VM, November 18, 2026: all 934 tests in 11 test files and
all 22 terminal check groups passed. POD checks and the distribution build also
passed. Human grammar/UX review is still pending; this branch has not been pushed.

Automated coverage must pass for:

- All command operations, argument preservation, force guards, and uppercase rules.
- All five definitions, recursive functions, redefinition, and literal EVAL escape.
- All four empty container forms; nested containers; quoted separators;
  interpolation; scalar values; numeric versus string values; expression context.
- Ambiguous and malformed input, including missing items, wrong delimiters,
  leading zeroes, punctuation, and function/keyword collisions.
- AUTO behavior, persistent values, and unchanged stored source.
- Multiline continuation, screen rerunning, and a clean shortcut exit.

Human checks before publication:

1. At a fresh row, enter `E s triple return 3 * shift`, then `say triple 14`.
   Expect 42. Edit 14 to 13 above and rerun; expect 39 in place.
2. Enter `a one, two, threee`, then `D \@a`. All three spellings must survive.
3. Enter each typed definition above and inspect it with D.
4. Try `E ar empty`, `E hr empty_hash`, and nested/quoted values.
5. Try `E a colors red-blue`; expect a helpful ambiguity error. Retry with
   `"red-blue"`, then with `(1 + 2)`, and inspect the resulting values.
6. Define a function named colors with EVAL. Confirm a call still runs it and
   `E a colors red, blue` still defines the array.
7. Start `A`, define a value with `E a live one,two`, and inspect with D.
   `S1` should show no stored source. Try a bare list and check its explanation.
   Finish with `A0`.
8. Try `H`, `L`, `L2`, `L3`, `E1`, `V1`, and `Q` / `Q!` in a
   disposable test session. Confirm their full-command behavior and guards.

No new release, main-branch push, or wiki publication is part of this draft.

