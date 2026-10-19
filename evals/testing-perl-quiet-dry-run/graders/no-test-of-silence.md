---
type: regex
pattern: '\b(?:is|cmp_ok)\(\s*\$\w+\s*,\s*(?:\x27eq\x27\s*,\s*)?(?:q\{\}|\x27{2}|"{2}|undef)|\b(?:stdout|stderr|output|combined)_(?:is|isnt|like|unlike)\b|\bunlike\(|\blength\s*\(?\s*\$\w+\s*\)?\s*,\s*0\b|!\s*length\b|\bopen\(\s*[^,]+,\s*\x27>\x27\s*,\s*\\'
match: not_contains
target: { source: file, path: "t/Scratch-Sweep.t" }
---
