## What this changes

<!-- One paragraph. What behaviour is different afterwards? -->

## Why

<!-- The decision or the bug behind it. If it fixes something, what did the
     user experience before? -->

## Checklist

- [ ] A test failed first, and I watched it fail for the right reason
- [ ] `dart format --output=none --set-exit-if-changed .` is clean
- [ ] `dart analyze --fatal-infos` is clean
- [ ] The full suite passes
- [ ] Documentation updated if I changed its subject matter

## Things that must stay in step

- [ ] Relay logic unchanged, **or** changed in Dart, Kotlin and Swift together
      with regenerated `testvectors/`
- [ ] Pigeon contracts unchanged, **or** regenerated and checked in
- [ ] No cryptographic domain separator changed (`relay-*-v1`)

## Security

- [ ] This does not widen the threat model
- [ ] …or it does, and `docs/SECURITY.md` is updated in this same change

<!-- If this removes or weakens a guard, say so here. That is the most
     interesting line in the diff and it should not have to be discovered. -->
