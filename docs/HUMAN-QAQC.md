# AnteREPL human QA/QC session

Run from an updated checkout:

```sh
perl -Ilib script/anterepl
```

Enter each line separately unless instructed to paste a block. Answer confirmation
questions separately. Use Ctrl-End to return to fresh input after editing an older
screen row. Record the first unexpected result, exact input, and terminal dimensions.

## 1. Screen editing and output replacement

```text
E s triple return 3 * shift
say triple 14
say "keep this line below"
```

Expect 42 and the keeper line. Move up, change 14 to 13, and press Enter.
Expect 39 to replace 42 directly below the edited command, without an extra blank
line; the later command remains. Typing inserts by default. At the start of a
row, Left moves to the previous row's end; the top row is the boundary.

## 2. Uppercase commands and HELP

```text
cls
H
```

Expect `REPL commands must be uppercase; try, "CLS".` and no raw bareword error.
H displays complete HELP with screenful pauses. Stop the listing with lowercase
`q`; this listing key does not quit the REPL.

## 3. Implicit words and real quotes

```text
$count = 2
a one, two, threee
D \@a
colors red, q{dark blue}, qq{value:$count}, qw(green white)
D \@colors
E ar names Ada, Bob
E h options color => blue, count => 3
E hr record name => Ada, tags => [one, two]
D $names
D \%options
D $record
P $record
```

Expect exact spellings, including `threee`; colors contains `red`, `dark blue`,
`value:2`, `green`, `white`. D shows the expected structures; P shows Devel::Peek
internals. These values are absent from LIST.

## 4. Multiline immediate code

Type this block, editing a middle line with the cursor before closing the brace:

```text
EVAL do {
    $runs++;
    say "block $runs";
}
```

Expect `block 1` once the block is submitted. LIST remains empty. Repeat with a
bracketed paste: it waits for Enter. Ctrl-N inserts a newline without submitting;
Shift-Enter should do likewise if the terminal sends a distinct key sequence.

## 5. Ordinary Perl remains available

```text
$_ = "red"
EVAL s /red/blue/
say $_
E sub ar ($) { say $_[0] }
EVAL ar "ordinary call"
say join q{:}, qw(one two)
E sub twice ($) { 2 * $_[0] }
say twice 21
```

Expect `blue`, `ordinary call`, `one:two`, and 42. EVAL evaluates literal Perl;
E reserves the five shorthand tags. No persistent mode change is needed.

## 6. Redefinition and cancellation

Enter `E s triple return 4 * shift`. At `[y/N]`, press Enter.
`say triple 14` must still print 42. Repeat the definition and answer `y`;
expect the usual redefinition warning, and then 56.

```text
E! s triple return 3 * shift
say triple 14
E a colors (die "must not run")
```

The forced definition does not ask, still warns, and restores 42. Decline the
colors replacement: the expression must not run and colors must remain intact.
Then try `colors! green, blue`; it replaces colors without asking.

`E a bad red-blue` must give a friendly ambiguity explanation. Retry as
`E a bad "red-blue"`; D should show the literal string.

## 7. AUTO, numbering, and aligned LIST

```text
A 5 5
say "first"
say "second"
E a live one, two
```

Press Ctrl-D to end AUTO, then:

```text
L
R
D \@live
```

Expect only these stored lines, with code starting in the same column:

```text
5  say "first";
10 say "second";
```

RUN prints first and second; live contains one and two. AUTO does not echo a
second numbered copy by default. Start A again, then Ctrl-C: AUTO ends and exit
instructions appear; the REPL stays open. A0 also ends AUTO.

## 8. Delete, undo, ranges, and forced actions

Enter `D1 5`. Test cancellation with Enter, `n`, Ctrl-D, Esc, and Ctrl-C,
reissuing the command each time. After each cancellation, L must retain both
lines. Then issue D1 again and answer `y`: line 5 disappears.

```text
U!
L 5-10
D1! 5
U!
R1 20 20
```

Forced deletion and undo do not ask. Decline R1: numbers stay 5 and 10.
`R1! 20 20` changes them to 20 and 40; `U!` restores 5 and 10.

For a long LIST, start `A 15 5` and paste enough complete `say "scroll";` lines
to exceed the terminal height. End AUTO and try L, L2, and
L3: listing scrolls; slow/pause modes respond to their displayed controls. Use
`D1! 15-` afterward to remove the extra lines, retaining 5 and 10.

## 9. SAVE, LOAD, and the local editor

Use a fresh temporary directory:

```text
use File::Temp qw(tempdir)
$qa_dir = tempdir(CLEANUP => 1)
chdir $qa_dir
S session.pl
10 say "changed"
S session.pl
```

Decline the overwrite; the file still contains the earlier first/second program.
`S! session.pl` writes the changed program without asking.

E1 opens the program in EDITOR. Change a line, save, and close the editor; decline
the REPL confirmation and verify L still shows the original source. Repeat with
E1!; the editor's changes apply without another question. E1 numbers edited
source 10,20,... . Test `L1 session.pl`: No preserves current source; Yes reloads.
`L1! session.pl` reloads without asking. Saved files contain source, not session
functions, variables, or screen text.

## 10. Environment values and snapshots

Use the test-only name ANTE_REPL_QA:

```text
V1 ANTE_REPL_QA old
V4 vars.env
V1 ANTE_REPL_QA new
```

Decline the replacement; `V ANTE_REPL_QA` still shows old. Then:

```text
V1! ANTE_REPL_QA new
V6
```

Decline reload; the value remains new. V6! restores old from the snapshot.
V2 asks before removal; No retains it, while `V2! ANTE_REPL_QA` removes it.
V3 opens VAR=value text in EDITOR; edit one test value and verify declining the
prepared replacement leaves the live environment unchanged.

## 11. Screen clearing, resizing, and workspace reset

C asks before clearing; decline and check the screen remains usable. C! clears
the screen and resize bank. L still shows the program, and `say triple 14` is 42.

Shrink the terminal: expect a crop warning. Enlarge it: lost text must not return
automatically. R3 asks before recovery; No retains the active screen. R3! restores
the saved screen when the terminal is large enough. This never changes source
or executes displayed text. A later C! discards the recovery copy.

R2 asks before discarding live variables/functions. No preserves triple. R2!
resets the workspace without asking; F is empty while L retains the program.

## 12. Exit and plain mode

Q always asks, even with saved source. No keeps the session. Q! exits without
asking, restores the terminal, and leaves the shell on a fresh line.

Restart with:

```sh
perl -Ilib script/anterepl --plain
```

Repeat a small definition, numbered line, deletion cancellation, and Q/Q!.
Screen movement and Esc cancellation are screen-mode checks. Enter, No, Ctrl-D,
and Ctrl-C should still cancel destructive questions in plain mode.

Piped input is covered by automated tests: it cannot confirm, never consumes the
next command as an answer, and requires explicit `!` for destructive shortcuts.

Automated baseline: 1,112 tests in 13 files; 24 terminal check groups passed.
