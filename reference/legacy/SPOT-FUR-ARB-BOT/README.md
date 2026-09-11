# Legacy Reference Quarantine

## Canonical location

Place the previous project under:

`reference/legacy/SPOT-FUR-ARB-BOT/`

Suggested safe structure:

```text
reference/legacy/SPOT-FUR-ARB-BOT/
├── README.md
├── source/          # Reviewed .mq5/.mqh and other readable source
├── configs/         # Sanitized example .set files only
├── docs/            # Prior design notes and version history
└── samples/         # Small, anonymized log/data samples when needed
```

## Greenfield boundary

Legacy material is optional evidence for:

- learning from prior failure modes;
- comparing implementation techniques;
- extracting test cases;
- identifying useful telemetry;
- validating whether a new design avoids known problems.

It is not the baseline, source of truth, approved architecture, or justification for a strategy assumption. New design decisions must stand on independent economic, execution, and risk evidence.

## Access rule for Claude

Do not read this directory automatically. Access it only when the user explicitly requests a legacy review/comparison or when an approved task names specific files here. Read the smallest relevant file set and label every extracted item as `observation`, `hypothesis`, `reusable pattern`, or `rejected pattern`.

No legacy code may be copied into production source without:

1. identifying its original purpose and assumptions;
2. mapping it to an approved design requirement;
3. reviewing safety and broker-specific behavior;
4. adding tests;
5. recording reuse in the decision log.

## Do not commit before review

- passwords, API keys, tokens, or broker credentials;
- account numbers, personal data, or unredacted terminal logs;
- `.ex5` and other compiled binaries;
- large raw tick/log datasets;
- screenshots or spreadsheets containing account information;
- `.DS_Store`, `__MACOSX`, caches, or temporary files;
- nested ZIP archives.

Keep raw private material outside Git. Add only sanitized, intentionally selected evidence.
