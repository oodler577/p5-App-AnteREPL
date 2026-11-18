# Shortcuts and shorthand

These features are available from the main branch. Human grammar and terminal
review continues with the [QA/QC session](HUMAN-QAQC.md). This source update does
not create a new CPAN release.

## Perl remains Perl

Shorthand requires an equals sign **followed by a space**. There is no mode to
switch off before typing ordinary Perl. These are deliberately different:

```text
E = s triple return 3 * shift
say triple 14
42

E s /old/new/
= a one, two, threee
```

The first entry defines a function; the fourth is a real Perl substitution.
The last assigns persistent `@a`, preserving all three spellings exactly.
Even `s triple return 3 * shift` is valid Perl: it is a substitution using `t`
as its delimiter. The explicit marker avoids guessing between those meanings.

Unmarked expressions, including calls, quote operators, prototypes, and Perl
errors, stay with Perl. `E` evaluates ordinary Perl unless followed by the
marker; `EVAL` always takes ordinary Perl. `=word` without the space is left to
Perl, including POD. The existing uppercase command names and shortcuts remain
REPL commands; this change adds no new bareword interception.

## Command shortcuts

Shortcuts are exact and uppercase. Digits distinguish commands sharing an
initial; `V` groups environment variables. Existing `?`, `!`, and `!!` forms
are unchanged. Arguments keep their full-command meaning.

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
`V1 NAME "hello world"`, `S demo.pl`. Separate arguments with a space:
`L1 file.pl` loads; `L 1` lists line 1. `L10` does neither.

Wrong-case bareword hints say `REPL commands must be uppercase; try, "CLS".`
They do not say `use CLS`, which could be confused with a Perl statement.

## Destructive shortcuts: confirm or append !

A shortcut that discards or replaces state asks `Continue? [y/N]`.
Only `y` or `yes` approves, ignoring case and surrounding whitespace.
Enter, No, Ctrl-D, and Esc in screen mode cancel. Ctrl-C interrupts and shows
exit directions. Append `!` to bypass the question:

| Protected operation | Forced example |
|---|---|
| Delete source lines | `D1! 10-30` |
| Clear source / replace from file | `N!`, `L1! demo.pl`, `I! demo.pl` |
| Apply an editor replacement | `E1!` |
| Renumber / undo source | `R1! 10 10`, `U!` |
| Discard live workspace | `R2!` |
| Clear / restore screen | `C!`, `R3!` |
| Overwrite a file | `S! demo.pl`, `E2! standalone.pl` |
| Replace / remove environment values | `V1! NAME value`, `V2! NAME` |
| Reset / edit / load / reload environment | `V0!`, `V3!`, `V5! vars.env`, `V6!` |
| Overwrite environment file | `V4! vars.env` |
| Environment operation through V | `V! SET NAME value` |
| Replace a shorthand function | `E! = s triple return 4 * shift` |
| Replace a shorthand container | `E! = a colors green` |
| Replace a named list | `= colors! green, blue` |
| Exit | `Q!` |

New files and new definitions do not prompt. Replacing existing values does;
unchanged values and no-op deletions do not. Q always asks, even when source is
saved, because exiting also discards live variables and functions. Editors
prepare changes before asking to apply a replacement. Invalid input is rejected
before prompting. Declining leaves the protected state intact and does not
evaluate replacement expressions. Prompts themselves occupy screen rows like
other output, so ordinary screen scrolling still applies.

Piped input cannot confirm: it fails with a hint to append `!`, and does not
consume another input line as an answer. `!` is supported only by the forms
above, not by arbitrary shortcuts such as `R!` or `H!`.

Full-length commands retain their prior behavior, including `QUIT!` and the
unsaved-source guards. Ordinary Perl through E/EVAL or RUN, and shell commands,
has normal side effects; the REPL does not try to classify that code as safe
or destructive. Forced function redefinition still emits Perl's usual warning.

## Immediate definitions

| Input | Destination |
|---|---|
| `E = s triple return 3 * shift` | Function `triple` |
| `E = a colors red, blue` | Array `@colors` |
| `E = ar names Ada, Bob` | Array reference `$names` |
| `E = h options color => blue, count => 3` | Hash `%options` |
| `E = hr record name => Ada, tags => [one, two]` | Hash reference `$record` |

Tags are lowercase, after `E = `. Names are ASCII identifiers without sigils
or namespaces. Functions need a body; data definitions may omit values for an
empty container. Functions contain ordinary Perl. Advanced declarations such
as prototypes remain ordinary Perl: `E sub twice ($) { 2 * $_[0] }`.

Definitions execute immediately, including during AUTO, and leave AUTO active.
They do not enter LIST or SAVE. Variables persist as workspace package values;
they are not `my` variables scoped to a single evaluation.

## Named lists and implicit quoting

With AUTO off:

```text
= a one, two, threee
D \@a
= settings color => blue, count => 3
D \%settings
= mixed one, q{two,three}, qq{home:$ENV{HOME}}, qw(four five)
```

The word after `= ` names the destination. A top-level comma selects an array;
a top-level arrow selects a hash. Separators inside quotes and nested containers
do not select a definition by themselves. A one-item array can use
`E = a colors red` or `= colors red,`. Named destinations start with a lowercase
letter or underscore; explicit typed forms accept either case.

A marked destination remains explicit even if a function has that name.
Unmarked `a "one", "two"` stays a Perl call. During AUTO, marked named lists
are rejected with guidance to use `E = a ...`, `E = h ...`, or `A0` first.
Numbered input, colon input, EDIT, IMPORT, LOAD, and RUN remain literal Perl.

## Consistent value grammar

The same rules apply recursively to arrays, arrayrefs, hashes, and hashrefs:

- Commas separate items. One trailing comma and one final semicolon are allowed.
- Every hash item is `key => value`. Lists and pairs cannot be mixed.
- Bare words contain letters, digits, or underscores, starting with a letter or
  underscore. They become exact strings, with no spelling correction.
- `undef` is the undefined value; quote it for the string `"undef"`.
- Signed decimal numbers, fractions, and exponents stay numbers. Quote leading
  zeroes (`"042"`) or write an explicit Perl expression.
- Single/double quotes and native Perl quote operators keep their semantics:
  `q{a,b}`, `qq{hi $name}`, `qw(one two)`, `qr/pattern/`, substitutions,
  transliterations, backticks, and `qx`. Command quotes execute normally.
- Quote operators take precedence over implicit words. Write `"q", "s"` for
  those literal words next to delimiters; `q,hello,` is Perl's quoted `hello`.
- Quote spaces, punctuation, and empty strings: `"two words"`, `"red-blue"`, `""`.
- A simple scalar (`$count`) refers to its live value.
- `[one, two]` constructs an arrayref; `{color => blue}` constructs a hashref.
  Nest them freely. Container literals cannot be hash keys.
- Parentheses accept other Perl expressions: `(1 + 2)`, `(1..3)`, `($ENV{HOME})`,
  `(\%ENV)`. Arrays give expressions list context; each hash key/value gets
  scalar context. Use an arrayref for a hash value containing multiple items.
- Duplicate hash keys keep the last value, following Perl.
- Implicit quoting does not apply inside parenthesized expressions or function
  bodies. Strings there retain ordinary Perl syntax.
- Inline shorthand comments, unquoted punctuation, extra operators, and
  multiword values are not guessed. Quote text or use an ordinary Perl expression.

## Errors, continuation, and execution

Malformed marked input receives an `Ambiguous shorthand:` explanation before
evaluation. Open quotes/containers continue; a mismatched closing delimiter
reports an error. Ctrl-N or bracketed paste can group a multiline entry.

No code is compiled or run merely to classify input. Once accepted, expressions
and function bodies retain Perl execution, warnings, and errors. Runtime or
compile-time side effects are not transactions and are not rolled back.
Typing, rerunning, and pasting follow the same grammar.

## Human QA/QC checklist

Validation on the DC VM, November 18, 2026: all 1,115 tests in 13 files and all
24 terminal check groups passed. POD checks and a local distribution build/test
also passed. Confirmation checks cover screen and plain input, cancellation,
approval, forced exit, and preserved state. Human grammar/UX review remains pending.

1. Enter `E = s triple return 3 * shift`, then `say triple 14`. Expect 42.
   Edit 14 to 13 above and rerun; expect 39 in place.
2. Enter `= a one, two, threee`, then `D \@a`. All spellings must survive.
3. Enter each typed definition above; inspect with D. Try empty containers and
   nested values mixing implicit words, single/double quotes, q/qq/qw, and regexes.
4. Try `E = a colors red-blue`; expect an explanation. Retry with `"red-blue"`.
   Redefine colors: Enter should cancel, `y` should replace, and `E! = a ...`
   should replace without asking.
5. Define an ordinary function named ar with `E sub ar { say $_[0] }`.
   `E ar "real call"` must call it. Try `E s /old/new/` on a prepared `$_`.
   Neither requires disabling shorthand.
6. Try `E = s triple return 4 * shift`. Decline and verify `say triple 14`
   is still 42; force it with `E! = s ...`, then expect 56 and the normal warning.
7. Start `A`, enter an ordinary Perl call, then `E = a live one,two`.
   Only the ordinary call should enter LIST. Finish with `A0`.
8. In a disposable session, enter `10 say "keep"`, then `D1 10`. Test Enter,
   No, Ctrl-D, Esc (screen mode), and Ctrl-C; LIST must retain the line.
   Try `y` to delete, `U!` to restore, and `D1! 10` to delete without asking.
9. Save to a temporary file with S. Modify source and S again: decline and
   confirm the file is unchanged. S! should overwrite. Test E1 replacements.
10. Test V1/V2 and V5 with disposable environment values; declining must keep
    existing values. Repeat with `!` and verify the intended replacement.
11. Q must ask even with saved source. No keeps the session; Q! exits on a fresh
    line. Repeat confirmation checks with `anterepl --plain`.
12. In piped input, a destructive shortcut without `!` must fail without
    treating a following `yes` line as approval. Explicit forced forms work.

For a step-by-step session, follow the [human QA/QC walkthrough](HUMAN-QAQC.md).
