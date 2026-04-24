# Repository guidance

This repository is organized as a layered project with three major concerns:

- scheduling_theory/: Rocq theory, semantics, invariants, refinement obligations, proofs
- awkernel/: Rust implementation, runtime behavior, instrumentation, tests
- awkernel_refinemnet_doc/: layer documents, public design notes, roadmap text, refinement-facing explanations

## Primary project principle

Treat refinement as a first-class cross-layer concern.

This means:
- theory work must state what abstract interface and obligations downstream code must satisfy
- runtime work must state what observable behavior and hooks can support those obligations
- design work must explain the refinement boundary between common theory, downstream adapters, and concrete runtime code

## Layering rules

Always distinguish the following three layers:

1. Common layer
   - reusable theory-facing interface
   - no concrete OS assumptions unless explicitly intended
   - no adapter-specific details

2. Adapter layer
   - connects a concrete OS or runtime to the common interface
   - discharges downstream proof obligations
   - may mention concrete event sources or runtime-specific mappings

3. Concrete runtime layer
   - actual implementation structure, hooks, queues, scheduling paths, interrupts, timers, tracing, etc.

Do not collapse these layers in code comments or design docs.

## Refinement rules

When a task affects more than one layer, structure the result around refinement.

Always answer:
1. What is the abstract interface being preserved or introduced?
2. What concrete behavior is being projected or related to it?
3. Which obligations belong to the common layer?
4. Which obligations belong to downstream adapters?
5. Which runtime details are intentionally *not* part of the common interface?

## Document-writing rules

For awkernel_refinemnet_doc/ documents:
- explain the purpose of a layer before listing files
- explain what is abstracted away and why
- state what remains for downstream adapters
- avoid concrete-OS-specific language in common-layer documents unless the document is explicitly about adapters

## Document self-containedness

Refinement-heavy documents must be self-contained by default.

This means:
- define nontrivial terms on first use or in a glossary
- state the abstract interface locally instead of assuming the reader will open theory files
- state adapter obligations as local, checkable responsibilities rather than vague prose
- explain projection boundaries locally instead of referring to unnamed packages or theorem layers
- avoid phrases such as "this package" or "the common contract" unless the document has already defined what that term means

## Expected output for cross-layer tasks

When proposing a cross-layer change, include:

1. Goal
2. Interface delta
3. Observable events or projection points
4. Common-layer proof obligations
5. Downstream adapter obligations
6. Runtime implementation impact
7. Design-document impact
8. Open risks

## Change discipline

Prefer minimal common interfaces.
Prefer pushing concrete details to adapters when possible.
Prefer wording that makes refinement obligations explicit instead of implicit.

## Git discipline

Use detailed git commit messages.

Run git commits without GPG signing.
Use a non-GPG-signed commit invocation such as
`git -c commit.gpgsign=false commit ...`.

A commit message should include:
- a clear subject line that summarizes the semantic or structural change
- a body that explains the main behavioral, proof, interface, or document changes
- enough rationale that another engineer can see why the change was needed

Do not use one-line commit messages for nontrivial changes.

## Multi-agent preference

Please spawn exactly three subagents and wait for all three results.

Subagent 1: Rocq specialist
- Focus on scheduling_theory/ and proof-facing semantics.
- Determine the minimal abstract interface, required observables, and proof obligations.

Subagent 2: Rust specialist
- Focus on awkernel/.
- Propose implementation hooks, API delta, and tests.

Subagent 3: Design specialist
- Focus on awkernel_refinemnet_doc/.
- Review refinement wording, layer boundaries, and adapter placement.
