---
type: regex
pattern: '^\[TestingAndDebugging::RequireUseStrict\]$'
flags: m
match: not_contains
target: { source: file, path: "Text-Rot13/.perlcriticrc" }
---
