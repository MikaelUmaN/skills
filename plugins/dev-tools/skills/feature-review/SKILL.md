---
name: feature-review
description: Reviews a new feature branch of a repository against a target branch, covering technology choices, architecture, code style, and tests, then summarizes key contributions and areas needing careful review.
license: Apache-2.0
compatibility: Cross-platform. Requires git.
argument-hint: [target-branch]
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash
context: fork
---

Review the current feature branch for merging.

Target branch: $ARGUMENTS (if empty, use "main")

Perform a code review of the current feature branch as compared to the target branch (normally main). If the target branch is unclear even with provided arguments, ask the user for confirmation.

# Steps

1. Identify we are in the correct branch and the target branch is known.
2. Review the repository for architectural, code style and quality guidelines.
3. Review the existing code base in the target branch as compared to the feature branch.
4. Identify the key contributions by this feature branch.
5. Identify any possible regressions or violations of guidelines.
6. Identify any low-hanging fruit clear problems and fixes that should be rectified.
7. Provide a TLDR summary and suggestion of areas needing more careful review.

# Detailed Instructions

## Technical Considerations

- Does the feature add any new technologies, libraries, frameworks etc.?
- Given the functionality added, is this motivated?
- Were there already similar dependencies and tools available that could have been used instead?
- What is the added overhead of including these technologies?

## Architectural Considerations

- Does the feature follow the architectural design and guidelines as laid out by documentation, and as evidenced by the existing code base?
  - Concerning modularity, separation of concerns, persistence layer versus domain layer versus API layer.
  - Concerning performance and optimization versus clarity and readability.
- If not, is there a key motivation for this in the feature branch?

## Code Style

- Does the written code follow the design and guidelines as laid out by documentation, and as evidenced by the existing code base?
  - If guidelines and code specify functional programming patterns over object-oriented or imperative programming patterns, is that generally followed?
  - If guidelines and code emphasize object-oriented programming patterns is that generally followed?
- Does the feature branch follow the pre-set formatting and other cleanliness rules dictated by the repository and tools in it?
  - Would any continuous integration script or pipeline give a failed result if executed on this feature branch as it stands currently?
- Is the code written to be testable?
- Does the code use dependency injection patterns?
- Does the code follow SOLID patterns where applicable?
- Are there any obvious code smells such as unused code, global variables and state etc. that is generally uncommon in the given language in the given context?

## Tests

- Are there any tests for the new features?
  - If not, is it understandable? Perhaps only manual testing is applicable?
- Are there any integration tests for the features (if that is reasonable given the actual features)?
  - If not, is that understandable? Perhaps only manual tests on actual data is applicable?
- Are there any regressions of existing tests?
  - If yes, can that be traced to features added in this feature branch or other refactorings made?
