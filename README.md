# App::AnteREPL

`anterepl` combines immediate Perl execution with an in-memory, numbered
program and an editable scrolling screen inspired by the C64 BASIC prompt.
The startup banner is `*** BASIC PERL V0.1 ***`.

```text
AUTO
say "hi"
say "there!"
AUTO OFF
LIST
5  say "hi";
10 say "there!";
RUN
hi
there!
```

`AUTO` supplies numbers in increments of 5. `AUTO OFF` or Ctrl-C ends entry.
Outside AUTO, ordinary Perl executes immediately. `EDIT` opens the stored
program in `$EDITOR`; `EDIT ENV` edits `%ENV` using `VAR=value` lines.

## Install and run

Requires Perl 5.16 or newer. Install a release archive:

```sh
cpanm ./App-AnteREPL-0.01.tar.gz
anterepl
```

Or install from this checkout:

```sh
perl Makefile.PL
make test
make install
```

Run without installing with `perl -Ilib script/anterepl`. Native Windows
screen mode also needs `Term::ReadKey` and an ANSI-capable terminal. Unix can
use the core POSIX backend. `anterepl --plain` disables screen editing.

## Learn to use it

- [User guide and tutorials](https://github.com/oodler577/p5-App-AnteREPL/wiki)
- [First session](https://github.com/oodler577/p5-App-AnteREPL/wiki/First-session)
- [Commands](https://github.com/oodler577/p5-App-AnteREPL/wiki/Command-reference)
- [Troubleshooting](https://github.com/oodler577/p5-App-AnteREPL/wiki/Troubleshooting)
- Offline: `HELP`, `anterepl --help`, or `perldoc App::AnteREPL`.

`LOAD program.pl` reads ordinary Perl; `SAVE` remembers that file and format.
`.bperl` files preserve editing numbers. `LIST` supports ranges, slow output,
and pause/step controls. Move up into a listed row, edit it, and press Enter to
replace that program line. `dump` and `peek` inspect live values.

Source files do not save runtime variables. `my` variables last for one
evaluation; use package variables for values shared across commands. Native
Windows screen behavior has not yet been verified on Windows.

## Development

`prove -lr t` runs the tests. `dzil test` and `dzil build` use `dist.ini`.
Dist::Zilla is a maintainer dependency, not needed to install or run a release.
See [CONTRIBUTING.md](https://github.com/oodler577/p5-App-AnteREPL/blob/main/CONTRIBUTING.md)
for release contents and optional terminal checks.

Copyright (c) 2026 Brett Estrade. Licensed under the same terms as Perl itself.
