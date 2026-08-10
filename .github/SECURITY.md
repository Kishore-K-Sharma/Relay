# Reporting a security problem

**Do not open a public issue.** Relay is a messaging app; a public report of a
flaw in it is a public instruction for exploiting everyone running it.

**Report it here:**
[github.com/Kishore-K-Sharma/relay/security/advisories/new](https://github.com/Kishore-K-Sharma/relay/security/advisories/new)

That form is private. Only the maintainers can read it, and it stays hidden
until we publish an advisory — so a report costs you nothing if it turns out to
be a misunderstanding, and does not arm anyone if it turns out to be real.

There is deliberately no email address here. A published address is a permanent
target for spam and automated bounty-farming, and the noise is what makes a
genuine report get missed.

## What to expect

Relay has **not** been reviewed by anyone outside the project. The threat model,
including the parts the authors are least confident about, is written down in
[../docs/SECURITY.md](../docs/SECURITY.md). Read it first — several things that
look like flaws are stated limitations, and several things that look fine are
listed there as doubts.

## Scope

In scope: the cryptography, the mesh protocol, the storage layer, the panic
wipe, and anything that makes a device or a person more attributable than the
threat model claims.

Out of scope for now: denial of service against the mesh. Anyone with a radio
can jam a radio, and the design does not claim otherwise.

## What Relay does not yet claim

Until the external review is finished, Relay must not be described — by anyone,
including us — as safe for activism, journalism or protest.
