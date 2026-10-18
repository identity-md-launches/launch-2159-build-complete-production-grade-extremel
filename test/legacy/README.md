# Immutable deployment regression fixture

`LegacyIMDPot.sol` reproduces the IMDPot source from pinned deployment commit `059348dfd390d659027fb4586a8b3f756a8e18ba`, with only import paths relocated. Its original contract/type names are retained for exact canonical ABI reproduction. The companion interface and deployment helper are historical test fixtures. They are not imported by revised application source.

The compiled ABI canonical keccak remains `704db1f4052e00f1a56022661009122fddefd3531acb6d932a7385bce63ba140`; runtime keccak remains `a9c960870ecc1ed218a7e9dc888e089a18dbe9444b6e523241589786bbfcb355`. `frontend/scripts/verify-contract.mjs` checks both and checks the revised release separately.

The pre-existing `IMDPot*.t.sol` tests now explicitly import this fixture, retaining coverage for live claims, refunds and admin calls. New implementation coverage is in `FutureBlockhash.t.sol` and `FutureAccountingInvariant.t.sol`. Select `src/IMDPot.sol:IMDPot` explicitly when building the revised game artifact.
