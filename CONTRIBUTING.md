# Contributing

## Build and test

```bash
brew install xcodegen
tools/test.sh
```

## Rules

- Read `SAFETY.md` first. Its invariants are not negotiable.
- Never add a raw "write key" call. Writes go through `ControlWrite`, `VerifiedWriter` and `KeyWhitelist`.
- Do not state a key's meaning from memory. Verify it on hardware, or mark it UNVERIFIED and make the feature degrade.
- Hardware access stays behind protocols, and logic gets tests against mocks.
- Nothing polls unless something visible asks for it.
- No telemetry and no network calls.
- Warnings are errors.
