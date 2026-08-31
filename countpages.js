// Usage: mutool run countpages.js file.pdf [...]
// Prints the number of pages in each PDF.
if (scriptArgs.length < 1) {
    print("usage: mutool run countpages.js FILE...");
    quit(1);
}
for (var i = 0; i < scriptArgs.length; ++i) {
    var doc = Document.openDocument(scriptArgs[i]);
    print(doc.countPages());
}
