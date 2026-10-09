Manifests that exist only to be disagreed about.

Each file is parsed by both `fyolod/src/agent/fixture.rs` and
`Tests/fyoloTests/AgentManifestFixtureTests.swift`, and both must produce the
record in `../expected.json`. They cover the defaults, the validation refusals,
and the two legacy shapes still accepted from manifests written against the
earlier RFC — the places where a second parser is most likely to drift.

They are not agents. Nothing loads them at runtime.
