# Relay documentation

| Document | Read it when | Kept current by |
|---|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | You want to know how any of it works | Whoever changes how it works |
| [PLANNING.md](PLANNING.md) | You want the phase-by-phase record of what was built and why | Appended to at the end of each phase |
| [SECURITY.md](SECURITY.md) | You are reviewing the cryptography, or deciding whether to trust it | Any change that widens the threat model, in the same commit |
| [RELEASE.md](RELEASE.md) | You are getting ready to ship | Whoever closes a gate |
| [FIELD-TEST.md](FIELD-TEST.md) | You are running a real-world test with real people | Whoever runs one and learns something |

`PLANNING.md` carries the reasoning behind each decision alongside the phase it
was made in, including the ones that turned out to be wrong. There is no
separate design archive: a second copy of the rationale is a second copy to keep
true, and the one nobody updates is the one people read.

## Documents that live elsewhere

- [../README.md](../README.md) — what Relay is, and how to build and test it
- [../CONTRIBUTING.md](../CONTRIBUTING.md) — how to work on it
- [../brand/README.md](../brand/README.md) — the mark, the name, and the rules
- [../.github/SECURITY.md](../.github/SECURITY.md) — how to report a flaw
  privately, as opposed to what the threat model is
