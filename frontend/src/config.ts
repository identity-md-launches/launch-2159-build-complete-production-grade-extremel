import { createConfig } from 'wagmi';
import { injected, coinbaseWallet } from 'wagmi/connectors';
import { createPublicClient, defineChain, fallback, http } from 'viem';

// Verified deployment and public network facts from the launch handoff.
export const POT_ADDRESS = '0x37cb0333a2fea358ae057bd85c4437803e5bcbfa' as const;
export const IMD_ADDRESS = '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7' as const;
export const DEPLOYMENT_BLOCK = 26219034n;
export const ABI_HASH = '0x704db1f4052e00f1a56022661009122fddefd3531acb6d932a7385bce63ba140';
export const RUNTIME_HASH = '0xa9c960870ecc1ed218a7e9dc888e089a18dbe9444b6e523241589786bbfcb355';
export const EXPLORER = 'https://etherscan.io';
export const RPC_URLS = ['https://ethereum-rpc.publicnode.com', 'https://eth.drpc.org'] as const;
export const chain = defineChain({
  id: 1,
  name: 'Ethereum',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: RPC_URLS } },
  blockExplorers: { default: { name: 'Etherscan', url: EXPLORER } },
});
export const readTransport = () => fallback(RPC_URLS.map(url => http(url, { timeout: 12_000, retryCount: 1 })), { rank: false });
export const readClient = createPublicClient({ chain, transport: readTransport(), batch: { multicall: false } });
export const walletConfig = createConfig({
  chains: [chain],
  multiInjectedProviderDiscovery: true,
  connectors: [injected(), coinbaseWallet({ appName: 'IMDPot', preference: { options: 'all' } })],
  transports: { [chain.id]: readTransport() },
});

export type SiteConfig = { privyAppId: string };
export async function loadSiteConfig(): Promise<SiteConfig> {
  const response = await fetch(`${import.meta.env.BASE_URL}site-config.json`, { cache: 'no-cache' });
  if (!response.ok) throw new Error('Could not load sign-in settings. Browser wallets are still available.');
  const value: unknown = await response.json();
  if (!value || typeof value !== 'object' || !('privyAppId' in value) || typeof value.privyAppId !== 'string') {
    throw new Error('Invalid sign-in settings. Browser wallets are still available.');
  }
  return { privyAppId: value.privyAppId.trim() };
}
