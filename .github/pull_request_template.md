## Summary

## Release note

<!-- Required: the MNSCloud merge gate refuses a PR without this block (contract: docs/release-notes.md
in the MNSCloud workspace). Keep ONE shape and delete the others:
A) user-visible change: the fields below, short text for the customer in pt-BR, en and es;
   `breaking` also needs action.pt-BR (what the customer must do).
B) another PR of a feature whose text is in a different repository's PR: only
   `feature-key: <task-slug>` and `lead: false`.
C) nothing a user notices (refactor, tests, CI, docs, dependencies): only `visibility: internal`.
Never write server names, IPs, host names, e-mails, paths, credentials, customers or vulnerability
details. -->

```text
visibility: public
feature-key: <task-slug>
lead: true
type: new | improvement | fix | security | breaking | deprecated
audience: tenant | admin | developer
modules: module.<code> | platform
title.pt-BR: <short title for the customer>
title.en: <...>
title.es: <...>
text.pt-BR: <what changed for the customer>
text.en: <...>
text.es: <...>
```

## Validation

- [ ] `bash -n scripts/*.sh scripts/lib/*.sh`

## Security

- [ ] No secrets, customer data, production domains, or private topology were added.
