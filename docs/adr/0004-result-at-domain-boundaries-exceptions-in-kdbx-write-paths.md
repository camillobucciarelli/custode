---
status: accepted
date: 2026-11-19
---

# Result at domain boundaries, exceptions inside KDBX write paths

Custode is being aligned to the stack and architecture of the owner's other Flutter app, Postino (repo `email-client`), so conventions and agent skills are shared between the two. Implementation starts only after store approval of 1.0.0 and completion of spec 023.

Repository and use-case contracts return a sealed `Result<T>` (`Ok` / `Err(Failure)`) with a sealed `Failure`. The safe-writer, backup and KDBX merge internals keep their typed exceptions, because rollback depends on that control flow and a mistake there costs user data. Conversion from exception to `Failure` happens at the boundary.

## Considered Options

- `Result` everywhere: rejected, it would rewrite the rollback control flow of the code that protects vault files.
- Keep exceptions everywhere: rejected, domain contracts would not state their failures in their return types.
- `fpdart` `Either`: rejected, a sealed `Result` covers the need without the extra dependency.
