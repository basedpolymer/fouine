# Which licence covers what

Short on purpose. The legal detail is in the files themselves; this says which
one applies where, and it exists because a project that announces a closed
licence on one side and «MIT» on the other has to say which wins when the two
meet inside the same executable.

## The core, the application, the command line, the agent

**Fouine Source-Available Licence**, version 1.0. Rights holder: Mathis Demory,
2026. Text: [`LICENSE`](LICENSE), whose **English version is authoritative**,
followed by a French translation. SPDX identifier to use everywhere, file
headers included: `LicenseRef-Fouine-Source-Available`. That is not a registry
identifier, since none exists for a project's own licence; the `LicenseRef-`
prefix is exactly what SPDX provides for the case.

The code is **readable and compilable by anyone**, for personal use or to
propose a contribution; it is **not redistributable**, neither the sources,
modified or not, nor a binary. The application is sold under a perpetual
licence, updates included: one licence per person, up to three Macs in the same
household, after a 30-day trial.

This covers `Sources/FouineCore`, `FouineCrawl`, `FouineExtract`, `FouineOCR`,
`FouineIndex`, `FouineEmbed`, `FouineLicense`, `FouineMCP`, `FouineApp`,
`FouineAgent` and `fouine`, therefore `Fouine.app` and everything it embeds,
therefore the published DMG.

## The redistributed third-party components

Three packages travel inside the binary or beside it. Their full notices are in
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md), copied into
`Fouine.app/Contents/Resources/` and into the disk image.

| Component | Version | Licence | How it ships |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | MIT | statically linked |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | statically linked (CLI) |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | MIT (plus its own components' licences) | binary XCFramework, in `Contents/Frameworks/` |

None of those three prevents distributing Fouine under a closed licence: MIT
and Apache-2.0 are permissive, they require their notices to accompany the
software and nothing more, and they impose neither opening nor redistributing
the combined work. The only obligation that follows is the one
`THIRD_PARTY_LICENSES.md` fulfils.

## The semantic model

[`multilingual-e5-small`](https://huggingface.co/intfloat/multilingual-e5-small),
**MIT, Microsoft Corporation**. It is **not** redistributed inside the
application: it is an optional 220 MB download, requested explicitly by the
user (Settings ▸ Semantic search, or `fouine model download`). The archive the
project publishes carries its own copy of the MIT notice.

## The MCP server, and why «MIT» does not mean what it looks like

Two targets, and the split is not cosmetic.

**`Sources/FouineMCPKit` is MIT**, rights holder Mathis Demory, 2026. Text:
[`Sources/FouineMCPKit/LICENSE`](Sources/FouineMCPKit/LICENSE), with a
`// SPDX-License-Identifier: MIT` line at the head of every file. Line-based
transport, the `stdout` guard, JSON-RPC, the two-era router, the result
envelopes, the token budget, the pagination cursors and the log: **no
dependency**, not even on `FouineCore` (`Package.swift`: `.target(name:
"FouineMCPKit", …)`, with no `dependencies`). That target is the one a third
party can reuse in their own project, someone taking the router and
the test frame to plug a different engine underneath, and it is **all** the MIT
buys.

**`Sources/FouineMCP` is under the Fouine licence**: the read-only store, the
server lifecycle and the tools, which link `FouineCore` and `FouineEmbed`.

**The shipped executable falls under the Fouine licence**, whatever the headers
of its files say: it links the core, and the MIT of `FouineMCPKit` does not
extend to what it accompanies. Announcing «MIT MCP server» without that
precision would be misleading, and without the split above the MIT would be
purely decorative. What the MIT does allow: **copying the files of
`FouineMCPKit`** into another project, including a commercial one, on the MIT
terms. What it does not allow: redistributing the `fouine` binary, or the other
targets.

`FouineMCPKit` adds **no** third-party dependency, so
[`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md) is unchanged by it.
`Foundation` and `CryptoKit`, which it imports, are system frameworks
redistributed by Apple with macOS, not by Fouine.

## In practice

- A new file opens with an SPDX line, right after the title of its header
  ([`CONTRIBUTING.md`](CONTRIBUTING.md)):
  `// SPDX-License-Identifier: LicenseRef-Fouine-Source-Available`, or `MIT`
  for `FouineMCPKit`.
- `fouine licenses` prints the notices from the terminal, and the full text
  when the binary runs from the bundle.
- The macOS «About» panel shows `NSHumanReadableCopyright`
  (`Packaging/Info.plist`): `© 2026 Mathis Demory — source-available`.
