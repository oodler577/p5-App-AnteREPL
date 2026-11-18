# AnteREPL: Perl at the BASIC prompt

A Beamer tutorial and implementation overview by Brett Estrade, prepared as a
possible Winter 2026 PCC talk. This is a talk draft, not a claim of conference
acceptance. It describes App::AnteREPL at implementation commit
[`6a9c90f7f189`](https://github.com/oodler577/p5-App-AnteREPL/commit/6a9c90f7f189907b6c75911871b015fd8cb5582d)
and wiki commit `8b190d3` (November 18, 2026).

**44 slides:** 32 main slides and 12 reference slides. The main route is intended
for about 45 minutes, including short demonstrations, with questions afterward.
The reference slides support questions or a longer workshop.

## Files

- `main.tex`: presentation entry point; select this in Overleaf.
- `ante-theme.sty`: colors, typography, transcript styling, and layout.
- `slides/tutorial.tex`: continuous hands-on session, slides 1–24.
- `slides/overview.tex`: implementation, limits, packaging, and discussion, 25–32.
- `slides/reference.tex`: command, keyboard, and behavior reference, 33–44.
- `notes.tex`: optional slide-and-speaker-note layout.
- `AnteREPL-Winter-2026-PCC.pdf`: rendered audience deck in the repository
  and separate download; the source ZIP omits compiled output.
- `demo/README.md`: rehearsal and workshop instructions with expected results.
- `demo/portable.pl`: the complete standalone program developed in the tutorial.

All source, transcripts, tables, and speaker notes are editable LaTeX. There
are no screenshot-only code examples, external fonts, or downloaded assets.
The dark transcript style distinguishes input in white from output in green.
Some slides explicitly omit command acknowledgements or abbreviate warnings.
The notes give the context needed to present those examples accurately.

## Overleaf

1. Upload the supplied Overleaf ZIP as a new project, or zip the source files
   listed below and upload that archive.
2. Set **Main document** to `main.tex` and **Compiler** to **pdfLaTeX**.
3. Use a recent TeX Live version and recompile. No shell escape is needed.
4. Edit `main.tex` for the author, subtitle, and event wording. Edit the three
   files under `slides/` for content and `ante-theme.sty` for appearance.
5. Select `notes.tex` as Main document to render speaker notes beside each
   slide. Switch back to `main.tex` for the audience PDF.

Source-only ZIP, run from this directory:

```sh
zip -r AnteREPL-Overleaf.zip main.tex notes.tex ante-theme.sty \
    slides demo README.md
```

Do not include build products, the repository checkout, environment snapshots,
or the entire application in the Overleaf project.

## Local build

A normal TeX Live installation with Beamer, Latin Modern, listings, booktabs,
and tabularx is sufficient. These are standard Overleaf packages.

```sh
latexmk -pdf -halt-on-error -interaction=nonstopmode \
    -jobname=AnteREPL-Winter-2026-PCC main.tex
```

Without latexmk, run this twice:

```sh
pdflatex -halt-on-error -interaction=nonstopmode \
    -jobname=AnteREPL-Winter-2026-PCC main.tex
```

For presenter notes:

```sh
latexmk -pdf -halt-on-error -interaction=nonstopmode notes.tex
```

The notes PDF is twice the slide width, with the audience slide on the left.
It is optional and is not the tracked audience PDF. The `.gitignore` excludes
auxiliary files and scratch output; the canonical rendered audience PDF is
intentionally tracked. Update it when changing the LaTeX.

## Presentation routes

| Slides | Subject | Suggested time |
|---|---|---:|
| 1–4 | Motivation, state model, setup | 5 minutes |
| 5–10 | Immediate Perl, inspection, functions, screen editing | 8 minutes |
| 11–17 | Numbered source, AUTO, LIST, EDIT, files | 12 minutes |
| 18–24 | Function lifecycle, environment, shell, recovery, exercise | 10 minutes |
| 25–32 | Implementation, terminal limits, packaging, discussion | 10 minutes |
| 33–44 | Reference; select in response to questions | As needed |

For a 20–25 minute overview, use 1–3, 5, 8–9, 11–12, 14–17, 22, 26, 29, and
32. Show one short screen edit and one file round trip. For a 60–75 minute
workshop, follow the main tutorial with participants typing, then add the
optional LIST and function-reference exercises in `demo/README.md`.

Keep the three kinds of state central: the displayed screen, numbered source
(the user-facing “VRAM” metaphor), and live workspace. `SAVE` writes source.
`RESET` selects a fresh workspace package. `CLS` clears the display. This
explains most behavior more clearly than introducing commands in isolation.

## Before presenting

Rehearse in the actual terminal and projector configuration. Confirm insert
mode, Left crossing to the previous row, multiline grouping, Ctrl-N, LIST
pause, and EDIT returning successfully. Use Ctrl-N if Shift+Enter is not
reported distinctly by the terminal. Keep a plain-mode fallback available,
but do not use it to demonstrate screen editing.

Start the tutorial in a new disposable directory. The workflow writes
`demo.pl` and, optionally, `session.env`; choose names that will not overwrite
real work. A real environment snapshot can contain credentials. Do not
project, share, or commit it. The example environment variable is harmless.

The opening two-line example is separate from the continuous tutorial.
The tutorial starts at slide 5 in a fresh session and assumes AUTO is off.
Use `demo/portable.pl` as a fallback if a live EDIT demonstration takes too long.
Expected answers to the checkpoint are in its speaker notes and the demo guide.

## Accuracy and project status

The deck reflects implemented behavior, including in-place output replacement,
insert editing by default, and Left crossing a screen-row boundary. It clearly
identifies active UX testing and unverified native Windows screen behavior.
The application and file-format/banner versions are separate: distribution
0.01, banner/file-format 0.1. Installation examples use the source repository
rather than assuming a published CPAN or GitHub release.

Main sources are the module's implementation/HELP/POD, the project wiki, tests,
and `CONTRIBUTING.md`. The final slide links to the pinned implementation.
If behavior changes before the talk, update the examples, notes, snapshot hash,
and rendered PDF together.

## Distribution boundary

`dist.ini` uses an explicit `GatherFile` list. Nothing in `talks/` belongs in
the CPAN archive. Keep presentation assets and build output out of that list.
The deck follows the repository's license (the same terms as Perl itself).
