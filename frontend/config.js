// IMDPot frontend configuration.
// Fill these in after the launch. The app shows a "not configured" banner until the contract address is set.
window.IMDPOT_CONFIG = {
  // Address of the deployed IMDPot contract (from the launch handoff). Leave empty until known.
  contractAddress: "",
  // Chain the contract lives on. Ethereum mainnet = 1.
  chainId: 1,
  // Optional read-only RPC used before a wallet connects (any public Ethereum JSON-RPC endpoint).
  readRpcUrl: "",
  // Optional Privy app id. When set and the Privy SDK is loaded on the page, the "Privy" button appears.
  privyAppId: "",
  // Display settings
  tokenSymbol: "IMD",
  explorerBase: "https://etherscan.io",
};
