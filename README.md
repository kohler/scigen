# SCIgen

SCIgen generates random Computer Science research papers, complete with
figures, graphs, and citations. It was written in 2005 by Jeremy Stribling,
Max Krohn, and Dan Aguayo; see the
[original SCIgen page](https://pdos.csail.mit.edu/archive/scigen/) for the
history, including the papers that got accepted to real conferences.

This repository is the original source, updated to run on a modern
toolchain: it produces PDFs directly (rather than going through DVI and
PostScript), it is warning-clean under current Perl, and `make-latex.pl`
can dump the generated paper's metadata as JSON.

## Requirements

* **Perl 5.** Everything but `JSON` ships with Perl; `Autoformat.pm` and
  `Reform.pm` are bundled here, so you do *not* need `Text::Autoformat`.
  Install `JSON` if you don't have it, and `Math::Random::MT` for
  `make-review.pl`:

  ```sh
  cpan JSON Math::Random::MT   # or: cpanm, or your OS package (perl-JSON, libjson-perl, libmath-random-mt-perl)
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
| `--json <file>` | Also write the paper's metadata to this file as JSON (see below). |
| `--seed <seed>` | Seed the PRNG. The same seed reproduces the same paper. Defaults to a random 32-bit value. The seed is printed on exit, or written to `seed.txt` under `--tar`/`--savedir`. |
| `--title <title>` | Force the paper's title instead of generating one. |
| `--title-only` | Print the title this seed selects, and exit without building anything. |
| `--seed-count <n>` | With `--title-only`, print the titles for `n` consecutive seeds starting at `--seed`, one `seed<TAB>title` line each. |
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

`--json <file>` writes the paper's metadata to `<file>` as
pretty-printed UTF-8 JSON:

```sh
./make-latex.pl --seed 1234 --author "Jane Q. Researcher" \
    --file paper.pdf --json paper.json
```

```json
{
   "title" : "An Analysis of Cache Coherence",
   "abstract" : "Recent advances in authenticated communication and wearable algorithms\nare rarely at odds with extreme programming. In our research, we demonstrate\nthe synthesis of 802.11 mesh networks, which embodies the key principles\nof robotics. GueZope, our new system for trainable information, is the\nsolution to all of these issues.",
   "sysname" : "GueZope",
   "seed" : 1234,
   "enable" : [],
   "commit" : "d371997",
   "pages" : 10,
   "authors" : [
      "Jane Q. Researcher"
   ]
}
```

`title` and `abstract` are strings. `sysname` is the name of the system the
paper is about, as the grammar saw it (so it may carry `\emph{...}`).
`seed` is the PRNG seed. `enable` lists the grammar sections turned on
with `--enable`, one per element even if they were given comma-separated;
it is `[]` when none were. `commit` is the first seven hex digits of the
git HEAD the paper was generated with, and is absent when `make-latex.pl`
is not run from a git checkout. `long` and `talk` are `true` when the
corresponding option was given, and absent otherwise. `pages` is the
PDF's page count, and is absent unless a PDF was written. `authors` lists
the `--author` names in the order given, and is absent when no authors
were supplied.

Together, `seed`, `enable`, `commit`, `long`, `talk`, and `authors` are
what it takes to regenerate the paper: the grammar changes between
commits, and enabled sections and the paper's length change which rules
are available, so the same seed produces a different paper under a
different combination. Authors do not affect the title or abstract, but
they are salted into the bibliography.

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

## Reviews

`make-review.pl` writes a conference-style review of a paper: an Overall
Merit score, a Reviewer Expertise score, a paper summary of about 100
words, and comments to the authors of about 300 words. It is plain text,
no LaTeX involved, and runs in well under a second.

```sh
./make-latex.pl --seed 1234 --savedir /tmp/p --json paper.json
./make-review.pl --paper paper.json
```

```
Overall Merit: 2
Reviewer Expertise: 3

Paper Summary:
This paper presents GueZope, a framework for analyzing cache coherence.
The motivation is that existing systems for cache coherence ...

Comments to Author:
I lean toward rejecting this paper. The problem is timely and the paper
is generally clear, but I was not convinced that the evaluation supports
the central claim.

Strengths:
- ...

Weaknesses:
- ...

Detailed comments:
- ...

I recommend rejection, but I would encourage the authors to compare
against a modern baseline and resubmit.
```

The scores are drawn first and steer the text. Overall Merit is 1 to 5
with probabilities 30%, 40%, 15%, 10%, and 5%; Reviewer Expertise is
uniform on 1 to 4. A merit of 1 or 2 produces a review that recommends
rejection and finds three to five weaknesses; a 4 or 5 recommends
acceptance and treats its complaints as camera-ready suggestions. An
expertise of 3 or 4 names specific prior work and argues with the design;
a 1 or 2 hedges and asks for background.

`--paper <file>` points at a JSON file from `make-latex.pl --json`. The
review then refers to the paper's title and system name, and its summary
paraphrases the paper's topics: any of the grammar's `SCI_THING` and
`SCI_FIELD` phrases that appear in the title or abstract become the
review's idea of what the paper is about. A JSON file without `sysname`
still works; the name is recovered from the abstract or the title where
possible, and invented otherwise. Without `--paper`, the review is of a
paper that exists only in the reviewer's imagination, and the title and
system name are generated fresh.

| Option | Meaning |
| --- | --- |
| `--paper <file>` | Review the paper described by this `make-latex.pl --json` file. |
| `--papers <file>` | Review every paper in this JSON array of such objects (see below). |
| `--shard <k>/<n>` | With `--papers`, review only papers whose index is `k` mod `n`. Run `n` shards in parallel and concatenate the results. |
| `--title <title>`, `--sysname <name>` | Set the paper's title or system name, overriding `--paper`. |
| `--merit <n>`, `--expertise <n>` | Force a score instead of drawing it. |
| `-n`, `--count <n>` | Write several reviews of the same paper, with independent scores. |
| `--seed <a>[,<b>]` | Seed the PRNG. Each review has its own seed sequence of two 32-bit integers, and review `j` of paper `i` is seeded with `[a + i, b + j]` (`b` defaults to 0), so a shard produces exactly what the unsharded run would. Without `--seed`, each review's sequence is read from `/dev/urandom` and printed to stderr as `seed=a,b`. |
| `-o`, `--file <file>` | Write here instead of to stdout. |
| `--json [<file>]` | Write JSON instead of text, to `<file>` or to stdout. |
| `--enable <section>` | Turn on a grammar section, as for `make-latex.pl`. |

In text form, several reviews are separated by a line of `=`. In JSON
form the output is always an array, one object per review:

```json
[
   {
      "merit" : 2,
      "expertise" : 3,
      "summary" : "This paper presents GueZope, ...",
      "comments" : "I lean toward rejecting this paper. ...",
      "title" : "An Analysis of Cache Coherence",
      "sysname" : "GueZope",
      "seed" : [ 1234, 2 ]
   }
]
```

`summary` and `comments` are hard-wrapped at about 72 columns, like the
abstract in the paper JSON, and `comments` contains the `Strengths:` and
`Weaknesses:` headings and `- ` bullets shown above. The LaTeX that leaks
into the paper JSON has been stripped from all the strings here.

`seed` is the review's seed sequence. A review depends only on its seed
and the paper, so `--seed 1234,2 --paper paper.json` regenerates the
review above exactly. The PRNG is the Mersenne Twister of
`Math::Random::MT`, seeded with the two-integer array. When the paper
lacks a title or system name, each review invents its own, so `-n 3`
without `--paper` reviews three different imaginary papers.

### Reviewing a corpus

`--papers <file>` takes a JSON array of paper objects, each with at least
`title` and `abstract`, such as the index that `make-corpus.pl` writes or a
HotCRP batch-upload file, and writes one result per paper:

```sh
for k in 0 1 2 3; do
    ./make-review.pl --seed 1 --papers papers.json -n 10 --shard $k/4 \
        --json reviews-$k.json &
done; wait
```

```json
[
   {
      "index" : 0,
      "title" : "Contrasting Voice-over-IP and Access Points Using Alp",
      "sysname" : "Alp",
      "content_file" : "0000.pdf",
      "reviews" : [ { "merit" : 2, "expertise" : 3, "summary" : "...", "comments" : "...", "seed" : [ 1, 0 ] }, ... ]
   }
]
```

`index` is the paper's position in the input array. `content_file` is
copied from the paper's `submission` object when there is one. Each shard
writes only its own papers, in index order; merge the shards by `index`.
A corpus of 5000 papers with ten reviews each takes a few minutes on
eight cores.

The grammar is `scireview.in`, which includes `scirules.in` for its
vocabulary. Tone lives in sections: `make-review.pl` enables
`merit<n>` and `expertise<n>` for the drawn scores, plus one of
`negative`, `middling`, or `positive` and one of `novice` or `expert`, and
the grammar defines the verdict sentences, the number of bullets, and the
severity of each complaint per section. The driver also defines
`PAPER_TITLE`, `PAPER_THING` (the topic phrases), `PAPER_SUBJECT` (one
topic, with `PAPER_IS_ARE` and `PAPER_HAS_HAVE` for verb agreement), and
`PAPER_FIELD`. Bullets that share a template are regenerated, since the
grammar's own no-duplicate check only catches identical text.

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

## Corpora

`make-corpus.pl` and `corpus-genpaper.js` build papers fast enough to feed a
load test, by generating a corpus once and then assembling papers out of its
pages.

```sh
# a large pool of first pages, and a smaller pool of whole papers
seq 1 1000 | xargs -P 8 -I% ./make-latex.pl --enable usenix,nosubset,truncated \
    --seed % --file titles/t%.pdf --json titles/t%.json
seq 1001 1100 | xargs -P 8 -I% ./make-latex.pl --enable usenix,nosubset --long \
    --seed % --file bodies/b%.pdf --json bodies/b%.json

./make-corpus.pl titles bodies             # -> scicorpus-<date>.{pdf,json}
mutool run corpus-genpaper.js scicorpus-<date>.pdf > paper.pdf
```

`make-corpus.pl <title_dir> <full_dir>` concatenates the first page of every
PDF in the first directory and all of every PDF in the second, deduplicates
the result with `mutool clean -gggg`, and writes an index beside it:

```json
{"title_count": 1000, "count": 1100, "page_basis": 9,
 "contents": [{"first_page": 1, "pages": 1, "title": "...", "abstract": "..."},
              ...]}
```

`first_page` is where the entry starts in the corpus PDF and `pages` is how
many pages it contributed, so a title-only entry has `"pages": 1`. Everything
else in an entry is copied from its JSON sidecar. Entries are ordered
title-only first, so the first `title_count` of them have no interior.

`page_basis` is one less than the shortest paper in `<full_dir>`, so every one
of them can supply every page a paper draws separately. It is left out, with a
warning, if the shortest paper is a single page.

### `corpus-genpaper.js`

Writes one paper to standard output and its metadata, as a line of JSON, to
standard error.

```sh
mutool run corpus-genpaper.js [options] CORPUS.pdf > paper.pdf
```

| | |
| --- | --- |
| `-B`, `--basis <n>` | The page basis: how many pages are drawn independently. Defaults to the index's `page_basis`, and may not exceed it. |
| `-s`, `--seed <n>` | Seed the prng. |
| `-i`, `--index <file>` | The corpus index; the default is `CORPUS.json`. |
| `-o`, `--output <file>` | Where the PDF goes; the default is `/dev/stdout`. |
| `-m`, `--metadata <file>` | Where the JSON goes; the default is `/dev/stderr`, and `-m none` writes none. |
| `-C`, `--choices <n,n,…>` | Fix the entries chosen for each basis position, rather than drawing them. |

Options take their value joined, separated, or with an `=`: `-B10`, `-B 10`,
`-B=10`, `--basis 10`, and `--basis=10` are all the same.

Page *k* of the paper is page *k* of some corpus entry, so the page numbers
printed on it stay in sequence. Page 1 comes from any entry, and also supplies
the paper's metadata; pages 2 through `-B` come from entries with an interior,
each drawn separately; and the entry drawn for the last basis position runs to
its own final page, so the paper ends on references. That last entry sets the
length, so papers come out as long as the entries they end on: a corpus of
9-to-13-page bodies gives 9-to-13-page papers.

**Pass a `-s` from any driver that runs several at once.** mujs seeds
`Math.random()` identically in every process, so the script carries its own
prng; without `-s` it takes a seed from the clock, which only moves once a
millisecond. The seed it used is reported in the metadata, and feeding that
back reproduces the paper exactly.

The `title` and `abstract` in the metadata are LaTeX, so they can contain
`\emph{...}` and braced system names — see [JSON output](#json-output). Strip
that before posting them anywhere.

Assembling a paper costs about 70ms, nearly all of it opening the corpus:
2311 pages and 36MB in the case measured. Which entries a paper draws from
barely affects its size, because `--enable nosubset` leaves the whole corpus
sharing one set of font programs — ten, for that corpus — and outlined figures
leave no others behind.

## Grammar files

The generator is a weighted context-free grammar expander (`scigen.pm`).
Rules live in the `.in` files:

| File | Contents |
| --- | --- |
| `scirules.in` | The paper grammar, including the LaTeX preamble. Start rule `SCIPAPER_LATEX`. |
| `system_names.in` | System names. Start rule `SYSTEM_NAME`. |
| `talkrules.in` | The talk grammar. Start rule `SCITALK_LATEX`. |
| `scireview.in` | The review grammar for `make-review.pl`; includes `scirules.in`. Start rules `REV_SUMMARY` and `REV_COMMENTS`. |
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

### `[nosubset]`

`--enable nosubset` defines `LATEX_MAPLINES`, a block of `\pdfmapline`
directives that tell pdfTeX to embed each font whole rather than as a
per-document subset. It is meant for building a corpus that will be
concatenated: subsetted papers embed a different byte stream of the same
typeface each, but papers built this way all embed the same one, so
`mutool merge` followed by `mutool clean -gggg` collapses the fonts to a
single copy. Six usenix papers carry 21 distinct font programs normally and
5 with `nosubset` — and the merged, cleaned corpus is smaller even though
each paper is about 90KB larger.

Every line names an encoding vector (`<8r.enc`, `<7t.enc`, `<texmsym.enc`,
…). That is not optional: pdfTeX cannot include a font whole from a map
entry with no encoding, and fails with `builtin glyph names is empty`.
Pages render identically either way.

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
