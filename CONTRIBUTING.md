# Development and releases

The implementation and full offline manual live in `lib/App/AnteREPL.pm`.
`script/anterepl` is the only installed executable. User tutorials live in
the [separate wiki repository](https://github.com/oodler577/p5-App-AnteREPL/wiki).

```sh
prove -lr t
perl -Ilib script/anterepl
```

For a release, install the maintainer tools and then run:

```sh
cpanm Dist::Zilla Dist::Zilla::Plugin::Metadata
dzil test
dzil build
tar tzf App-AnteREPL-0.01.tar.gz
```

`dist.ini` uses Dist::Zilla's bundled plugins plus Metadata, which marks the
platform-dependent installer correctly. Its explicit `GatherFile` list ships
the module, executable, tests, Makefile.PL, README, Changes, LICENSE,
and dist.ini. Dist::Zilla generates MANIFEST and CPAN metadata. Keep that list
current when adding tests or runtime files. Bump both the module's `$VERSION`
and `version` in dist.ini for a release; the BASIC PERL banner/file-format
version is independent. `dzil release` tests and asks for confirmation before
uploading with the maintainer's PAUSE credentials.

The tracked Makefile.PL remains usable without Dist::Zilla; the
`MakeMaker::Runner` plugin reuses it. Runtime prerequisites are declared there,
and AutoPrereqs scans only release files for metadata. Term::ReadKey is
recommended generally and required by Makefile.PL on native Windows.

Do not commit generated archives, build trees, blib, Makefile, MYMETA,
MANIFEST, terminal recordings, environment snapshots, or standalone copies.
They are not source dependencies. The repo-only terminal test tool
is intentionally absent from the CPAN release.

Optional Unix integration checks use Python's standard library and a real vi:

```sh
python3 tools/terminal-smoke.py
```

The test covers editable LIST output, AUTO cancellation, actual program and
environment editor round trips, subprocess environment propagation, terminal
interrupts, and mode restoration. Native Windows still needs its own test run.

When adding a command or changing a default, update built-in HELP and POD,
then the relevant wiki workflow and command reference. Keep examples generic.
