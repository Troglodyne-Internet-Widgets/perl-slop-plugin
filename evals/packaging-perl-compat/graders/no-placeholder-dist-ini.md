---
type: regex
pattern: '\{\{[A-Z_]+\}\}'
match: not_contains
target: { source: file, path: "Text-Rot13/dist.ini" }
---
