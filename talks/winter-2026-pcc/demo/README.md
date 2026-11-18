# Rehearsal and workshop session

The main tutorial starts in a **fresh AnteREPL session with AUTO off**.
REPL commands and subcommands must be uppercase, including DUMP and PEEK.
Lowercase and mixed-case input follows ordinary Perl and AUTO rules.
Use a disposable working directory. Commands here run inside AnteREPL unless
explicitly marked “system shell.” Transcript results appear separately from
input so the command blocks can be copied without copying output.

The opening example on slide 2 is a separate illustration; do not enter it
into the continuous tutorial session.

## 1. Immediate values and data (slides 5–7)

```perl
$n = 14
say $n * 3
? $n * 3
$FOO = {
    bar   => 1,
    names => [qw(Alice Bob)],
};
DUMP $FOO
? $FOO->{names}[0]
PEEK $FOO, 10
```

The arithmetic outputs are both `42`. The name query displays `'Alice'`.
Dumper shows the structure; Peek output varies with Perl and runtime state.
The slides also show `DUMP \%ENV` as syntax; do not project a real environment
that may contain secrets.

## 2. Session function and screen editing (slides 8–10)

```perl
EVAL sub triple {
    return 3 * shift;
}
say triple(14)
FUNCTIONS
```

The closing brace plus Enter completes the definition. The call prints `42`.
FUNCTIONS includes `triple`.

For the screen demo, enter these as two separate entries:

```perl
say triple(14)
say "keep this line below"
```

Move to the first entry, change `14` to `13`, and press Enter. Expect `39`
in place of `42`, followed immediately by the later command and its output.
No blank spacer should appear. Typing inserts by default. At the beginning
of a row, Left moves to the previous row's end. Esc returns to fresh input.

Then submit this whole multiline entry:

```perl
EVAL do {
    my @values = (3, 7, 14);
    for my $value (@values) {
        say triple($value);
    }
};
```

Expect `9`, `21`, `42`. Move inside the block and use Ctrl-N to insert a new
line, such as `say "done";` after the loop. Enter from any row in the complete
group reruns the group. Shift+Enter works only if the terminal distinguishes
it; Ctrl-N is the fallback. No source is added to LIST.

## 3. Numbered source and AUTO (slides 11–13)

```text
10 say triple(14)
5 say "Results"
LIST
RUN
AUTO
say triple(3)
say triple(7)
AUTO OFF
LIST 15-
```

LIST initially shows `5  say "Results";` and `10 say triple(14);` with aligned
code. RUN prints `Results` and `42`. AUTO adds lines 15 and 20 without a
second numbered echo. Try Ctrl-D as an alternative to AUTO OFF: the app stays
open and stored lines remain.

Move into a LIST row, edit its Perl, and press Enter. Then RUN to confirm that
the stored source changed. Use UNDO if desired. LIST ranges include endpoints.

## 4. EDIT and a portable file (slides 14–17)

Choose an installed editor, for example:

```perl
$ENV{EDITOR} = 'vi'
EDIT
```

Replace the editor buffer with the contents of the accompanying `portable.pl`:

```perl
use v5.16;
use strict;
use warnings;
sub triple { return 3 * shift; }
my @values = (3, 7, 14);
for my $value (@values) {
    say triple($value);
}
```

Save and close the editor, then RUN. Expect `9`, `21`, `42`; redefinition of
the already-live triple can produce the usual warning. Changed source is
numbered 10, 20, 30, and so on. EDIT changed memory; it has not written the
final program file.

```text
SAVE demo.pl
NEW
LOAD demo.pl
LIST
RESET
RUN
```

Expect the same three values. RESET made a fresh workspace, and RUN installed
the function from source. The plain source can run in the system shell:

```sh
perl demo.pl
```

Or use `!! perl demo.pl` inside AnteREPL for a separate process with normal
terminal I/O. Press Enter after it exits to return.

## 5. Function lifetime (slides 18–19)

```perl
EVAL sub triple { return 4 * shift; }
say triple(14)
FUNCTIONS
```

Expect a redefinition warning and then `56`. LIST still contains `3 * shift`.
RUN reinstalls the source definition and prints `9`, `21`, `42`.

```perl
EVAL do {
    $setups++;
    sub twice { return 2 * shift; }
    say "Setup $setups";
}
EVAL say twice(21)
```

Expect `Setup 1`, then `42`. Reexecuting the first group increments `$setups`
again and may warn about redefining twice. Calling twice alone does not rerun
the setup. SAVE does not include the session-only definition of twice.

## 6. Environment and shell (slides 20–21)

```text
ENV SET EXAMPLE_COLOR blue
ENV EXAMPLE_COLOR
ENV SAVE session.env
ENV SET EXAMPLE_COLOR red
ENV RELOAD
ENV EXAMPLE_COLOR
```

Expect `EXAMPLE_COLOR=blue` before saving and after reload. The snapshot holds
the entire environment, not just this variable. Keep it private and remove it
after the rehearsal. EDIT ENV lets you change the snapshot text in an editor;
its result changes memory until ENV SAVE writes a file.

On Unix:

```text
! pwd
! cat demo.pl
! echo "$EXAMPLE_COLOR"
```

The echo prints `blue`. On native Windows, use commands and variable expansion
for cmd.exe, for example `! echo %EXAMPLE_COLOR%`. Use Perl `chdir` for persistent
working-directory changes; a child-shell `! cd` does not change AnteREPL.

## 7. State checkpoint (slides 22–24)

```text
CLS
LIST
RESET
FUNCTIONS
RUN
FUNCTIONS
```

CLS retains source. RESET makes FUNCTIONS report no functions in the current
workspace. RUN prints `9`, `21`, `42` and installs triple again. FUNCTIONS now
includes `triple`. The temporary twice function is absent from this fresh
workspace because it was never in the source.

A new EVAL-defined sub would still not enter SAVE. Quit with QUIT once the
source is saved, or deliberately use QUIT! to discard source edits.

## Optional long LIST exercise

In the system shell, create a disposable 100-line source file with Perl:

```sh
perl -E 'say qq{say "row $_";} for 1..100' > long-demo.pl
```

In AnteREPL, save current source first, then:

```text
LOAD long-demo.pl
LIST PAUSE
```

Try Space, S, Enter, and Q. Try stopping with a cursor key and editing a row.
This needs screen mode. Plain mode prints the requested range without pauses.

## Optional old-code-reference exercise

Use a fresh workspace to avoid an initial redefinition warning:

```perl
RESET
EVAL sub triple { return 3 * shift; }
$old = \&triple
EVAL sub triple { return 4 * shift; }
say $old->(14)
say triple(14)
```

Expect a warning on redefinition, then `42` and `56`. The reference retains
the earlier body while the named call uses the replacement.
