export const OPEN_IN: ReadonlyArray<{ id: string; name: string; href: (url: string) => string }> = [
  { id: 'metamask', name: 'MetaMask', href: url => `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, '')}` },
  { id: 'coinbase', name: 'Coinbase Wallet', href: url => `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}` },
  // Rabby Mobile's universal-link handler reads _cmd=open-dapp and the dapp URL.
  { id: 'rabby', name: 'Rabby', href: url => `https://go.rabby.io/mobile/?_cmd=open-dapp&dapp=${encodeURIComponent(url)}` },
  { id: 'phantom', name: 'Phantom', href: url => `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}` },
];
export const isMobileBrowser = () => /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) && !('ethereum' in window);
