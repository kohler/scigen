// Usage: mutool run corpus-genpaper.js [options] CORPUS.pdf
//
// Assemble one paper out of a corpus built by make-corpus.pl and write it to
// standard output. Page k of the paper is page k of some corpus entry, so its
// printed page numbers stay in sequence. Page 1 comes from any entry, which
// also supplies the title, abstract, and authors; the pages up to the basis
// are drawn separately from entries with an interior; and the entry drawn last
// runs to its own final page, so the paper ends on references and that entry
// sets the length.
//
// An option's value may be joined, separated, or given with an `=`: -B10,
// -B 10, -B=10, --basis 10, and --basis=10 are all the same.
//
//   -B N         the page basis, how many pages are drawn independently.
//                Required unless the index carries page_basis.
//   -s N         seed the prng with this. Two papers with the same seed and
//                corpus are identical, and the default seed only has
//                millisecond resolution, so processes started in parallel
//                should each be given one.
//   -C N,N,...   fix the entries chosen for each basis position
//   -i FILE      the corpus index; the default is CORPUS.json
//   -o FILE      where the PDF goes; the default is /dev/stdout
//   -m FILE      where the paper's JSON metadata goes; the default is
//                /dev/stderr, and -m none writes none

// Standard output carries the PDF, so diagnostics go to standard error.
function fail(msg) {
    var buf = new Buffer();
    if (msg) {
        buf.write(msg + "\n");
    }
    buf.write("usage: mutool run corpus-genpaper.js CORPUS.pdf [-i INDEX] [-s SEED] [-o OUT]\n");
    buf.write("                      [-m METADATA] [-C CHOICES] [-B PAGEBASIS]\n");
    buf.save("/dev/stderr");
    quit(1);
}

if (scriptArgs.length < 1) {
    fail();
}

var optmap = {
    index: "i", i: "i", seed: "s", s: "s", output: "o", o: "o", metadata: "m", m: "m", choices: "C", C: "C",
    basis: "B", B: "B"
};

var opt = {}, corpus_file = null;
for (var i = 0; i < scriptArgs.length; ++i) {
    var argname, argvalue;
    if (scriptArgs[i] == "") {
        fail("bad argument");
    } else if (scriptArgs[i].charAt(0) != "-") {
        corpus_file && fail("too many arguments");
        corpus_file = scriptArgs[i];
        continue;
    }
    var eq = scriptArgs[i].indexOf("=");
    if (scriptArgs[i].charAt(1) == "-") {
        argname = eq < 0 ? scriptArgs[i].substring(2) : scriptArgs[i].substring(2, eq);
        argvalue = eq < 0 ? null : scriptArgs[i].substring(eq + 1);
    } else {
        argname = scriptArgs[i][1];
        argvalue = eq == 2 ? scriptArgs[i].substring(3) : (scriptArgs[i].length == 2 ? null : scriptArgs[i].substring(2));
    }
    if (!optmap[argname]) {
        fail("unknown option `" + (argname.length > 1 ? "--" : "-") + argname + "`");
    } else if (argvalue == null) {
        if (i + 1 >= scriptArgs.length) {
            fail("need option for `-" + argname + "`");
        }
        ++i;
        argvalue = scriptArgs[i];
    }
    opt[optmap[argname]] = argvalue;
}

if (!corpus_file) {
    fail();
}

// read index
if (opt.i == null) {
    opt.i = corpus_file.replace(/\.pdf$/i, "") + ".json";
}
var index = JSON.parse(read(opt.i)), contents;
if (!index || !(contents = index.contents)) {
    fail(opt.i + ": not JSON");
} else if (!contents.length) {
    fail(opt.i + ": no contents");
}
if (index.title_count == null) {
    index.title_count = 0;
}
if ((index.title_count | 0) != index.title_count || index.title_count > contents.length || index.title_count < 0) {
    fail(opt.i + ": invalid title_count");
}
if ((index.count | 0) != index.count || index.count > contents.length || index.count < index.title_count) {
    fail(opt.i + ": invalid count");
}

// read page basis
if (opt.B == null) {
    if (!index.page_basis || (index.page_basis | 0) != index.page_basis || index.page_basis <= 0) {
        fail(opt.i + ": invalid page_basis (or provide `-B BASIS`)");
    }
    opt.B = index.page_basis;
} else {
    if (!/^\d+$/.test(opt.B)) {
        fail("invalid -B");
    }
    opt.B = opt.B | 0;
    if (index.page_basis && opt.B > index.page_basis) {
        fail("`-B " + opt.B + "` is larger than index page_basis `" + index.page_basis + "`");
    }
}

if (index.count == index.title_count && opt.B > 1) {
    fail("only -B 1 works with this corpus");
}

// randomness
// mujs seeds Math.random() the same way in every process, so papers would not
// differ between runs. Date.now() only moves once a millisecond; spinning on it
// separates processes that started within the same one.
var state;
function seed(s) {
    state = (s >>> 0) || 0x9e3779b9;
}
function rnd() {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state;
}

if (opt.s != null) {
    if (!/^\d+$/.test(opt.s)) {
        fail("invalid seed");
    }
    opt.s >>>= 0;
} else {
    var t0 = Date.now(), spin = 0;
    while (Date.now() === t0) {
        ++spin;
    }
    opt.s = (t0 ^ (spin * 2654435761 % 4294967296)) >>> 0;
}
seed(opt.s);

// choices
if (opt.C != null) {
    if (!/^\d+(?:,\d+)*$/.test(opt.C)) {
        fail("invalid `-C`, expected `N,N,N,...`");
    }
    opt.C = opt.C.split(/,/);
    for (i = 0; i != opt.C.length; ++i) {
        opt.C[i] = opt.C[i] | 0;
    }
} else {
    opt.C = [];
}
while (opt.C.length < opt.B) {
    opt.C.push(rnd());
}

// assemble plan
var first_page = contents[opt.C[0] % index.count], plan = [first_page.first_page];
for (var i = 1; i < opt.B; ++i) {
    var tries = 0;
    while (tries < 5) {
        var page = contents[index.title_count + opt.C[i] % (index.count - index.title_count)];
        if (i < page.pages) {
            plan.push(page.first_page + i);
            if (i + 1 == opt.B) {
                for (var j = i + 1; j < page.pages; ++j) {
                    plan.push(page.first_page + j);
                }
            }
            break;
        }
        opt.C[i] = rnd();
        ++tries;
    }
    if (tries == 5) {
        fail("bad page_basis, could not find page " + (i + 1));
    }
}

// complete plan
var corpus = Document.openDocument(corpus_file);
var doc = new PDFDocument(), map = doc.newGraftMap();
for (var i = 0; i < plan.length; ++i) {
    map.graftPage(-1, corpus, plan[i] - 1);
}
if (first_page.title) {
    doc.setMetaData("info:Title", first_page.title);
}
doc.saveToBuffer("compress").save(opt.o || "/dev/stdout");

if (opt.m !== "none") {
    var meta = { "pages": plan.length, "seed": opt.s };
    var keys = ["title", "abstract", "authors", "source"];
    for (var i = 0; i < keys.length; ++i) {
        if (first_page[keys[i]] != null)
            meta[keys[i]] = first_page[keys[i]];
    }
    var buf = new Buffer();
    buf.write(JSON.stringify(meta) + "\n");
    buf.save(opt.m || "/dev/stderr");
}
