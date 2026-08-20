---
name: hierarchical-document
description: Create or restructure a document as a recursively hierarchical, isolated tree — an overview plus nested sections where every section owns only its subtree, parent overviews exactly enumerate their direct children, cross-branch links are forbidden, and narrative flow never leaks between branches. Builds and freezes a hierarchy manifest before writing, derives every overview from that manifest, writes each node in isolation, and validates hierarchy, completeness, and scope before delivering. Reports the planned structure and asks before restructuring an existing document. Use when asked to write, split, or restructure documentation into a hierarchy, an overview page with sub-pages, or a docs tree.
license: Apache-2.0
compatibility: Cross-platform. Requires no external tools; operates on markdown or plain-text documents in the working tree.
argument-hint: "[document-or-directory-path]"
allowed-tools: Read, Write, Edit, Glob, Grep, AskUserQuestion
user-invocable: true
---

# Hierarchical Document

Write documents as a tree, not as a continuous stream of prose.

The hierarchy is the source of truth. Every section is a node. Every node owns exactly one subtree. A node may organize and narrate its descendants, but it must not take ownership of siblings, cousins, or any other branch.

## When to apply this

Apply this when a document has two or more sibling sections that a reader navigates independently, or when a document has grown large enough that readers need an index to find their way.

Do not impose it on a single-topic document, a short README, a changelog, a release note, or a reference table. Below roughly two levels of real structure the nesting costs more than the isolation buys, and forcing a tree onto flat material produces overviews with one entry.

## Core model

Model the document as a rooted tree:

```text
Document
├── Overview -> [Section 1, Section 2, Section 3]
├── Section 1
│   └── local nested structure
├── Section 2
│   └── local nested structure
└── Section 3
    └── local nested structure
```

Apply the same model recursively at every depth:

```text
Document
├── Overview -> [Section 1, Section 2]
├── Section 1
│   ├── Overview -> [Section 1.1, Section 1.2]
│   ├── Section 1.1
│   └── Section 1.2
│       ├── Overview -> [Section 1.2.1, Section 1.2.2]
│       ├── Section 1.2.1
│       └── Section 1.2.2
└── Section 2
    └── local nested structure
```

Treat `Overview` specially: it is not an ordinary peer content node. It is the parent node's index or projection of its direct children. The `->` notation matters — an overview *points at* its parent's children, it does not contain them as a second copy. Drawing those children underneath `Overview` as well would place each of them under two parents, which invariant 1 forbids.

For every non-leaf node `N`:

```text
overview_entries(N) == direct_children(N)
```

The overview must be derived from the hierarchy. Never invent the overview independently from the tree.

## Non-negotiable invariants

Maintain all of these invariants at every depth.

### 1. Single parent

Every node except the document root has exactly one parent.

Do not create a section that conceptually belongs to two branches.

If content belongs to multiple branches, move it to the lowest common ancestor that owns those branches, or create a new child under that ancestor.

### 2. Exact overview

For every non-leaf node, its overview must contain every direct child exactly once, in the same order as the hierarchy manifest.

The following must always hold:

```text
overview_entries(N) == direct_children(N)   # same items, exactly once each, same order
```

Never omit a child.
Never invent an extra child.
Never list grandchildren in place of direct children.
Never let the overview drift from the actual section structure.

### 3. Subtree isolation

A section owns only itself and its descendants.

For a node `N`, all substantive content in `N` must belong to `subtree(N)`.

Do not:

- explain the internals of a sibling section;
- continue the workflow into a sibling section;
- summarize what a sibling section will later do;
- link to a sibling, cousin, uncle, or other external branch;
- add "see also" links to another branch;
- use a sibling as required context for understanding the current section.

A node may describe and organize its own descendants because they are inside its subtree.

### 4. Parent owns sibling order

Only the parent establishes ordering or narrative flow between its children.

A child must not say things such as:

```text
Next, continue to Section 2.
After completing this section, configure Section 3.
As described in the previous sibling section...
```

The parent overview owns that relationship.

A child may establish ordering among its own direct children because those children belong to its subtree.

### 5. Overview is a map, not the journey

An overview tells the reader what its direct children are and, when useful, gives a short scope description for each child.

Do not let an overview absorb the procedural or explanatory content of its children.

Prefer:

```markdown
## Overview

- [Authentication](authentication.md) — identity, credentials, and session establishment.
- [Authorization](authorization.md) — permissions and access decisions.
- [Auditing](auditing.md) — recording and inspecting security-relevant events.
```

Do not turn that into:

```markdown
## Overview

1. Create credentials.
2. Exchange the credentials for a session.
3. Define roles.
4. Assign permissions.
5. Configure audit storage.
6. Inspect audit events.
```

Those steps belong inside the relevant child subtrees.

### 6. No cross-branch navigation by default

Structural links may point downward into the current node's subtree.

Do not create links from a node to sections outside its subtree.

A parent overview may link to its direct children because those children belong to the parent.

Do not add parent, sibling, previous/next, related-section, or cross-branch navigation unless the user explicitly requires that navigation model. Even when explicitly requested, keep substantive ownership unchanged: a link must never cause one branch to explain another branch's content.

External citations and links are not document-tree edges and are allowed when relevant.

### 7. Recursive application

Apply every invariant recursively without a fixed depth limit.

A section with children becomes a parent and must obey the same rules as the document root.

Do not weaken isolation because a section is deeply nested.

## Mandatory workflow

Follow this workflow whenever creating or restructuring a hierarchical document.

### Step 1 — Build the hierarchy manifest first

Before writing prose, decide the output shape — one file per node, or one file with nested headings — and record that choice in the manifest. See [Physical files versus logical nodes](#physical-files-versus-logical-nodes) for how to choose. The choice affects how overview entries are written, so making it later means rewriting them.

Then construct a canonical hierarchy manifest.

Keep the manifest in context or in a scratch file. Do not add it to the delivered document or commit it unless the user asks for it.

Represent at least:

```text
- node path or stable identifier
- title
- parent
- ordered direct children
- one-sentence scope or responsibility
```

Example:

```yaml
document:
  title: Example
  children:
    - concepts
    - operations

nodes:
  concepts:
    title: Concepts
    parent: document
    scope: Explain the model and terminology.
    children:
      - concepts/core-model
      - concepts/terminology

  concepts/core-model:
    title: Core model
    parent: concepts
    scope: Explain the underlying model only.
    children: []

  concepts/terminology:
    title: Terminology
    parent: concepts
    scope: Define terms used inside the concepts subtree.
    children: []

  operations:
    title: Operations
    parent: document
    scope: Explain operational procedures.
    children: []
```

The exact serialization may vary. The tree semantics may not.

### Step 2 — Validate the manifest before prose

Confirm all of the following before drafting sections:

- there is exactly one root;
- every non-root node has exactly one parent;
- every referenced child exists;
- no node appears under multiple parents;
- no cycle exists;
- every node is reachable from the root;
- sibling scopes are distinct enough to avoid ownership ambiguity;
- cross-cutting material is owned by the appropriate common ancestor.

Repair the manifest before writing if any check fails.

### Step 3 — Freeze the structure

Treat the validated manifest as canonical.

Do not silently add, remove, rename, reparent, or reorder sections while writing prose.

If the content reveals that the hierarchy must change:

1. stop structural drafting;
2. update the manifest first;
3. revalidate it;
4. regenerate every affected overview from the new manifest;
5. continue writing against the updated structure.

Never patch an overview manually while leaving the manifest stale.

### Step 4 — Derive each overview from direct children

Generate an overview mechanically from the current node's ordered direct children.

Do not independently brainstorm overview entries.

Do not use the overview to preview grandchildren unless the user explicitly asks for a full-tree view. The default overview is one level deep.

### Step 5 — Write one node at a time in isolation

When writing node `N`, reason as if `N` is the root of a temporary local document.

Use only:

- the scope of `N`;
- inherited context necessary to understand `N`;
- the descendants of `N`;
- source material relevant to `N`.

Do not use sibling sections to create continuity.
Do not finish the thought of a sibling.
Do not prepare the reader for a sibling.
Do not move the global red thread into the local section.

Keep the local red thread inside `subtree(N)`.

### Step 6 — Place cross-cutting content at the lowest common ancestor

When a paragraph, concept, rule, prerequisite, or explanation genuinely applies to multiple branches, do not duplicate it into one branch and link from another.

Find the lowest common ancestor of the affected branches and place the shared material there, or add a dedicated child owned by that ancestor.

Example:

```text
Security
├── Authentication
└── Authorization
```

If a rule applies equally to Authentication and Authorization, place it in `Security` or in a new child of `Security`. Do not place it in Authentication and link to it from Authorization.

Needing a sibling as context is the signal that triggers this step. When a node cannot be understood without a definition, prerequisite, or concept that currently lives in a sibling, hoist that material to the lowest common ancestor. Do not read invariant 3 as a dead end and duplicate the material instead.

### Step 7 — Validate the rendered document

Before delivering, compare the rendered document against the manifest recursively.

For every node verify:

- the node exists exactly once;
- its parent is correct;
- its direct children are complete and ordered correctly;
- its overview exactly matches those direct children;
- its prose stays inside its subtree responsibility;
- it contains no accidental cross-branch links;
- it does not establish previous/next ordering among its siblings;
- it does not absorb detailed content owned by descendants.

If any invariant fails, repair the document before delivering it.

## Editing existing documents

When modifying an existing hierarchical document, do not begin by editing prose.

First reconstruct the existing hierarchy as a manifest.

Then:

1. identify structural violations;
2. decide which node should own each misplaced piece of content;
3. update the manifest if the intended structure changes;
4. report and confirm before touching any content (see below);
5. move or rewrite content into the correct subtree;
6. regenerate affected overviews;
7. validate the full tree recursively.

Preserve valid local structure whenever possible. Do not flatten a good subtree merely to simplify editing.

### Report and confirm before restructuring

Restructuring moves content the user already owns. Never do it silently.

Present, before step 5:

- the reconstructed hierarchy of the document as it stands;
- the structural violations found, each naming the node and the invariant it breaks;
- the proposed target hierarchy;
- which files will be created, renamed, moved, split, or deleted.

Then ask for explicit approval and wait for it. If the user narrows the scope, restructure only what they approved and leave the rest as it is.

Creating a new document needs no such gate — there is nothing to overwrite.

## Physical files versus logical nodes

Keep the tree model independent of storage format.

If the output supports multiple files, prefer one logical node per document or file and one parent overview that indexes its direct child documents.

If the output must be a single file, preserve the same ownership using headings and nested sections. A single physical file is still a logical tree.

Do not confuse file boundaries with hierarchy. The manifest defines ownership.

## Failure modes to reject

Reject and repair these patterns before delivering.

### Missing overview entry

```text
Manifest children: A, B, C
Overview entries:  A, B
```

Invalid. Add `C` to the overview or remove `C` from the manifest if it should not exist.

### Extra overview entry

```text
Manifest children: A, B
Overview entries:  A, B, C
```

Invalid. `C` must become a real child or be removed from the overview.

### Cross-sibling link

```markdown
# Authentication

For permission rules, see [Authorization](../authorization.md).
```

Invalid by default. Authentication does not own Authorization.

### Red-thread takeover

```markdown
# Authentication

After authentication succeeds, continue to Authorization, then configure Auditing.
```

Invalid. The parent owns the ordering among Authentication, Authorization, and Auditing.

### Overview takeover

```markdown
# Overview

Create a user, hash the password, generate a token, attach the token to the request,
validate the token, calculate permissions, and finally write the audit event.
```

Invalid. The overview is executing work owned by child subtrees.

### Correct recursive structure

```text
Document
├── Overview -> [Concepts, Operations]
├── Concepts
│   ├── Overview -> [Core model, Terminology]
│   ├── Core model
│   └── Terminology
└── Operations
    ├── Overview -> [Setup, Runtime]
    ├── Setup
    └── Runtime
        ├── Overview -> [Start, Stop]
        ├── Start
        └── Stop
```

Each overview lists direct children only.
Each branch owns only its subtree.
Each branch may recursively establish structure inside itself.
No child takes over the parent's red thread.

## Final rule

When prose quality conflicts with structural ownership, preserve structural ownership.

A locally elegant transition is wrong if it crosses a branch boundary.
A helpful cross-link is wrong if it breaks isolation.
A comprehensive overview is wrong if it takes over descendant content.

**The tree is authoritative. Derive navigation from the tree. Keep every node inside its subtree. Apply the rule recursively.**
