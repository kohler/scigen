# SCIgen

SCIgen generates random Computer Science research papers, complete with
figures, graphs, and citations. It was written in 2005 by Jeremy Stribling,
Max Krohn, and Dan Aguayo; see the
[original SCIgen page](https://pdos.csail.mit.edu/archive/scigen/) for the
history, including the papers that got accepted to real conferences.

This repository is the original source, updated to run on a modern
toolchain: it produces PDFs directly (rather than going through DVI and
PostScript), it is warning-clean under current Perl, and `make-latex.pl`
can dump the generated title and abstract as JSON.

## Requirements

* **Perl 5.** Everything but `JSON` ships with Perl; `Autoformat.pm` and
  `Reform.pm` are bundled here, so you do *not* need `Text::Autoformat`.
  Install `JSON` if you don't have it:

  ```sh
  cpan JSON        # or: cpanm JSON, or your OS package (perl-JSON, libjson-perl)
  ```

* **A TeX distribution** providing `pdflatex` and `bibtex` (TeX Live or
  MacTeX). `IEEEtran.cls` and `IEEE.bst` are bundled. The generated
  documents also use `graphicx`, `inputenc`, `geometry`, `cite`, and one of
  `times`/`helvet`/`palatino`, all standard.

* **gnuplot**, for the evaluation graphs. Not optional; without it
  `make-latex.pl` gives up after a few tries and tells you what failed.

  ```sh
  brew install gnuplot          # macOS
  apt install gnuplot           # Debian/Ubuntu
  ```

* **Graphviz** (`neato`), optional. If present, system-architecture
  diagrams are drawn with it; if not, another gnuplot graph is substituted.

**Run everything from the top of this checkout.** The scripts `require
"./scigen.pm"` and open `scirules.in`, `system_names.in`, and friends by
relative path, so they only work with this directory as the working
directory.

## Quick start

```sh
./make-latex.pl --author "Jane Q. Researcher"
```

That writes a complete PDF paper, six pages or so, into the current
directory, and prints the seed it used:

```
seed=1234 author=Jane Q. Researcher
wrote scigen-1234.pdf
```

The default file name is `scigen-<seed>.pdf`; `--file` overrides it.
Generation takes a couple of seconds on a modern machine, most of it in
gnuplot and the three `pdflatex` passes.

Every intermediate file — the LaTeX source, the figures, the gnuplot and
Graphviz scratch files — goes into one temporary directory under `$TMPDIR`,
which is removed when the program exits, successfully or not. Only the PDF
is left behind.

## `make-latex.pl` options

| Option | Meaning |
| --- | --- |
| `--author <name>` | Add an author. Repeat for multiple authors. Authors are also salted into the bibliography, so they cite themselves. |
| `--file <file>` | Write the finished PDF here. Defaults to `./scigen-<seed>.pdf`. |
| `--json <file>` | Also write the title and abstract to this file as JSON (see below). |
| `--seed <seed>` | Seed the PRNG. The same seed reproduces the same paper. Defaults to a random 32-bit value. The seed is printed on exit, or written to `seed.txt` under `--tar`/`--savedir`. |
| `--title <title>` | Force the paper's title instead of generating one. |
| `--enable <section>` | Turn on a named grammar section (see [Sections](#sections)). Repeat for several. Passed through to the figure generators. |
| `--sysname <name>` | Force the name of the system the paper is about (normally something like `GueZope`). |
| `--tar <file>` | Also write a `.tgz` of the LaTeX source, figures, `.bib` file, class files, and a `seed.txt`. |
| `--savedir <dir>` | Write those same source files into `<dir>` and *skip* LaTeX entirely. No PDF is produced. Fast, and useful if you want to edit the paper before building it. **Warning: an existing `<dir>` is deleted first.** |
| `--talk` | Generate a slide deck instead of a paper. Currently broken; see [Known breakage](#known-breakage). |
| `--remote` | Get system names from a `scigend` daemon. Currently broken; see [Known breakage](#known-breakage). |
| `--help` | Usage summary. |

`--savedir` and `--tar` are the way to get at the LaTeX itself. `--savedir`
is much faster than a full run because it never invokes `pdflatex`; `--tar`
runs LaTeX as usual, so it leaves you a PDF as well as the archive.

## JSON output

`--json <file>` writes the paper's title and abstract to `<file>` as
pretty-printed UTF-8 JSON:

```sh
./make-latex.pl --seed 1234 --author "Jane Q. Researcher" \
    --file paper.pdf --json paper.json
```

```json
{
   "title" : "An Analysis of Cache Coherence",
   "abstract" : "Recent advances in authenticated communication and wearable algorithms\nare rarely at odds with extreme programming. In our research, we demonstrate\nthe synthesis of 802.11 mesh networks, which embodies the key principles\nof robotics. GueZope, our new system for trainable information, is the\nsolution to all of these issues."
}
```

The object has exactly two keys, `title` and `abstract`, both strings.

Things worth knowing:

* **The JSON matches the PDF.** `SCI_TITLE` and `SCI_ABSTRACT` are declared
  *fixed* rules in `scirules.in` (the bare `SCI_TITLE.` and `SCI_ABSTRACT.`
  lines), so
  they expand once and are memoized; the JSON re-reads that stored
  expansion rather than generating a second, different title.

* **The text is LaTeX, lightly.** It is mostly plain prose, but generated
  markup does leak through: `\emph{...}` and `{BracedSystemName}` around
  system names, `\cite{cite:0}` where the abstract cites something, and
  math like `O($2^n$)`. Strip or render it if you are feeding this to
  something that isn't TeX.

* **Line breaks are hard-wrapped.** The abstract is formatted as text
  before it is stored, so it contains `\n` at roughly 70 columns. Collapse
  whitespace if you want a single paragraph.

* `--title` overrides the `title` field, since it overrides the underlying
  rule.

* `--json` works with `--savedir`, which is the fast path if you want
  metadata but no PDF:

  ```sh
  ./make-latex.pl --seed 1234 --savedir /tmp/scipaper --json paper.json
  ```

### JSON without building anything

To generate titles and abstracts in bulk, drive the grammar directly and
skip figures and LaTeX altogether:

```perl
#!/usr/bin/perl
# run from the top of this checkout
require "./scigen.pm";
use IO::File;
use JSON;

srand($ARGV[0]) if @ARGV;

my $names = scigen->new;
$names->read_rules(new IO::File("<system_names.in"), 0);
my $sysname = $names->generate("SYSTEM_NAME");
chomp $sysname;

my $paper = scigen->new;
$paper->def("SYSNAME", $sysname);
$paper->read_rules(new IO::File("<scirules.in"), 0);

print JSON->new->utf8->pretty->encode({
    title    => scalar $paper->expand("SCI_TITLE"),
    abstract => scalar $paper->expand("SCI_ABSTRACT")
});
```

`SYSNAME` must be supplied before the rules are read, as above; the paper
grammar expects it to come from the caller.

## Figures on their own

Both figure generators are standalone:

```sh
./make-graph.pl --file graph.pdf --seed 42 [--color]
./make-diagram.pl --file diagram.pdf --seed 42 --sysname "GueZope"
```

`make-graph.pl` writes a gnuplot-drawn evaluation graph; `make-diagram.pl`
writes a Graphviz system diagram and needs `neato`.

Both take `--tmpdir <dir>`, which is how `make-latex.pl` keeps their
scratch files in its own temporary directory, and `--enable <section>`,
which `make-latex.pl` also forwards so that an enabled section restyles the
figures along with the prose. Each cleans up after itself and leaves only
the file named by `--file`.

## Grammar files

The generator is a weighted context-free grammar expander (`scigen.pm`).
Rules live in the `.in` files:

| File | Contents |
| --- | --- |
| `scirules.in` | The paper grammar, including the LaTeX preamble. Start rule `SCIPAPER_LATEX`. |
| `system_names.in` | System names. Start rule `SYSTEM_NAME`. |
| `talkrules.in` | The talk grammar. Start rule `SCITALK_LATEX`. |
| `functions.in` | Curve shapes (`EXPR`) for `make-graph.pl`, which builds the plot itself from the `GNUPLOT` rule in `scirules.in`. |
| `graphviz.in` | Diagram grammar for `make-diagram.pl`. Start rule `GRAPHVIZ`. |
| `svg_figures.in` | Talk-figure grammar for `make-talk-figure.pl`. Start rule `SVG_FIG`. |

Rule syntax, one rule per line as `NAME expansion`, with these extras:

* `NAME { ... }` on its own lines for a multi-line expansion.
* `NAME+5 expansion` weights an alternative 5x.
* `NAME.` declares `NAME` *fixed*: it expands once and every later
  reference reuses that value (this is what makes the title consistent).
* `NAME!` declares `NAME` *non-duplicating*: repeated expansions avoid
  repeating a value (up to 50 tries).
* `NAME=title`, `NAME=text`, `NAME=bibtex` set output formatting. Names
  containing `_PAR` or `_PARAGRAPH` default to `text`.
* `NAME+` expands to a fresh sequential integer; `NAME#` expands to a
  random previously issued one. This is how citation labels are kept
  consistent.
* `.include file` pulls in another rule file, at most once. This is how
  `talkrules.in` reuses the paper grammar.
* `[NAME]` on a line by itself starts a *section*; see below.

The `scigen` object API is `new`, `enable(@sections)`,
`read_rules($fh, $debug)`, `def($name, @options)`, `expand($name)`, and
`generate($name, $pretty)`. `def` before `read_rules` pins a name against
anything the grammar says about it. `generate` is `expand` plus, if
`$pretty` is true, a whole-output reflow; the paper grammar leaves
`$pretty` off and relies on per-rule `=text` and `=title` formatting
instead.

### Sections

A line reading `[NAME]` starts a section, and the rules after it apply only
when that section is turned on with `--enable NAME`. A bare `[]` returns to
the default, unsectioned rules. Sections may be opened in an included file,
and an `.include` inside a section is read in that section's context.

```
SCI_ACT      the study of SCI_THING
[eval]
SCI_ACT      the exhaustive evaluation of SCI_THING
```

When a name is defined in more than one place, the strongest definition
wins:

1. **The caller.** Whatever `make-latex.pl` sets for itself — the system
   name, `--title` — beats every grammar rule for that name.
2. **Enabled sections.** The first enabled section to define a name
   *replaces* the default rules for it; further enabled sections *add*
   alternatives, so `--enable a --enable b` draws from both.
3. **Default rules**, used when no enabled section defines the name.

A section that is not enabled is skipped in its entirety — not just its
rules, but its `.include`, `NAME.`, and `NAME=fmt` lines too. Enabling a
name that no grammar defines is accepted silently and does nothing.

## Known breakage

`scigen.pm` was converted to an object API in the modernization pass, and
these callers were never updated. They fail immediately, or, in the case of
`--talk`, spin forever retrying a figure that cannot be built:

* `scigen.pl`, the standalone grammar expander
* `scigend` and `test-scigend.pl`, the system-name daemon, and therefore
  `make-latex.pl --remote`
* `make-talk-figure.pl`, and therefore `make-latex.pl --talk`

Use the Perl snippet above in place of `scigen.pl` for now.

## License

GNU GPL v2 or later; see `COPYING`.
