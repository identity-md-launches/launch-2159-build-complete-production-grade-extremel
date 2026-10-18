import { Component, createContext, lazy, Suspense, useContext, useState, type ReactNode } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useConnection, useConnect, useConnectors, useDisconnect, useWalletClient, type Connector } from 'wagmi';
import { injected } from 'wagmi/connectors';
import { getAddress, type EIP1193Provider } from 'viem';
import { chain, EXPLORER, loadSiteConfig } from './config';
import { shortAddress, readableError } from './game';
import { Icon } from './Icons';
import { Modal } from './Modal';
import { isMobileBrowser, OPEN_IN } from './open-in';

const PrivySession = lazy(() => import('./PrivySession'));
class PrivyBoundary extends Component<{ children: ReactNode; onError: (message: string) => void }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch() { this.props.onError('Privy sign-in could not load. Try again or choose a browser wallet.'); }
  render() { return this.state.failed ? null : this.props.children; }
}
const useWalletState = () => {
  const connection = useConnection();
  const client = useWalletClient();
  return { ...connection, client: client.data };
};
type WalletContextType = ReturnType<typeof useWalletState> & { openWallet: () => void; switchNetwork: () => Promise<void> };
const WalletContext = createContext<WalletContextType | null>(null);
export const useWallet = () => useContext(WalletContext)!;

function WalletMark({ id, icon }: { id: string; icon?: string }) {
  const url = icon || `${import.meta.env.BASE_URL}wallets/${id === 'coinbaseWalletSDK' ? 'coinbase' : id}.svg`;
  if (id === 'injected' && !icon) return <span className="wallet-mark browser-mark"><Icon name="wallet" size={24}/></span>;
  return <img className="wallet-mark" src={url} width="28" height="28" alt=""/>;
}

export function WalletProvider({ children }: { children: ReactNode }) {
  const state = useWalletState();
  const connect = useConnect();
  const connectors = useConnectors();
  const disconnect = useDisconnect();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState('');
  const [pending, setPending] = useState<string>();
  const [startPrivy, setStartPrivy] = useState(false);
  const [privyAttempt, setPrivyAttempt] = useState(0);
  const settings = useQuery({ queryKey: ['site-config'], queryFn: loadSiteConfig, staleTime: Infinity, retry: 1 });
  const mobile = isMobileBrowser();
  const named = connectors.some(c => c.type === 'injected' && c.id !== 'injected');
  const listed = [...connectors.filter(c => c.type === 'injected'), ...connectors.filter(c => c.type !== 'injected')]
    .filter(c => !(c.id === 'injected' && named) && (!mobile || c.type !== 'injected'));

  const switchNetwork = async () => {
    if (!state.connector) return;
    setError('');
    setPending('switch');
    try {
      const provider = await state.connector.getProvider() as EIP1193Provider;
      try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x1' }] }); }
      catch (caught) {
        if ((caught as { code?: number }).code !== 4902) throw caught;
        await provider.request({ method: 'wallet_addEthereumChain', params: [{ chainId: '0x1', chainName: chain.name, nativeCurrency: chain.nativeCurrency, rpcUrls: [...chain.rpcUrls.default.http], blockExplorerUrls: [EXPLORER] }] });
        await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: '0x1' }] });
      }
    } catch (caught) { setError(readableError(caught)); setOpen(true); }
    finally { setPending(undefined); }
  };

  async function connectWallet(connector: Connector) {
    setPending(connector.uid); setError('');
    try { await connect.mutateAsync({ connector }); setOpen(false); }
    catch (caught) { setError(readableError(caught)); }
    finally { setPending(undefined); }
  }

  async function connectPrivy(provider: EIP1193Provider) {
    await connect.mutateAsync({ connector: injected({ target: { id: 'privy', name: 'Privy', provider } }) });
    setOpen(false);
  }

  return <WalletContext.Provider value={{ ...state, openWallet: () => { setError(''); setOpen(true); if (settings.isError) void settings.refetch(); }, switchNetwork }}>
    {children}
    {open && <Modal title={state.isConnected ? 'Your wallet' : 'Connect a wallet'} onClose={() => setOpen(false)} className="wallet-modal">
      {state.isConnected && state.address ? <>
        <p className="muted">Connected on {state.chainId === 1 ? 'Ethereum' : `chain ${state.chainId}`}.</p>
        <a className="address-link" href={`${EXPLORER}/address/${state.address}`} target="_blank" rel="noreferrer">{getAddress(state.address)}<Icon name="external" size={16}/></a>
        {state.chainId !== 1 && <button className="button primary full" onClick={() => void switchNetwork()} disabled={!!pending}>{pending === 'switch' ? 'Switching…' : 'Switch to Ethereum'}</button>}
        <button className="button secondary full" onClick={async () => { await disconnect.mutateAsync({}); setStartPrivy(false); setOpen(false); }}>Disconnect wallet</button>
      </> : <>
        <p className="muted wallet-intro">Choose how to enter the jackpot room.</p>
        <div className="wallet-rows">
          {mobile && OPEN_IN.map(wallet => <a className="wallet-row" key={wallet.id} href={wallet.href(location.href)}><WalletMark id={wallet.id}/><span>Open in {wallet.name}</span><Icon name="external" size={16}/></a>)}
          {listed.map(connector => <button className="wallet-row" key={connector.uid} onClick={() => void connectWallet(connector)} disabled={!!pending}>
            <WalletMark id={connector.id} icon={connector.icon}/><span>{connector.id === 'injected' ? 'Browser wallet' : connector.id === 'coinbaseWalletSDK' && mobile ? 'Coinbase Smart Wallet' : connector.name}{pending === connector.uid ? ' · opening…' : ''}</span><Icon name="arrow" size={16}/>
          </button>)}
          <button className="wallet-row" disabled={!settings.data?.privyAppId || !!pending} onClick={() => { setOpen(false); setPrivyAttempt(attempt => attempt + 1); setStartPrivy(true); }}>
            <span className="wallet-mark privy-mark"><Icon name="lock" size={22}/></span><span>Continue with Privy<small>Email & social sign-in</small></span><Icon name="arrow" size={16}/>
          </button>
        </div>
        {!settings.data?.privyAppId && <p className="small muted">{settings.isError ? 'Sign-in settings could not be loaded. Close and reopen to try again.' : 'Privy sign-in is awaiting the site owner’s app ID. Browser wallets and Coinbase are available.'}</p>}
        <p className="small muted">Wallet connection is free. Transactions require ETH for network gas.</p>
      </>}
      <p className="inline-error" role="alert">{error}</p>
    </Modal>}
    {startPrivy && settings.data?.privyAppId && <PrivyBoundary onError={message => { setError(message); setOpen(true); setStartPrivy(false); }}><Suspense fallback={<div className="connection-status" role="status">Loading Privy sign-in…</div>}>
      <PrivySession key={privyAttempt} appId={settings.data.privyAppId} onConnect={connectPrivy} onError={message => { setError(message); setOpen(true); setStartPrivy(false); }}/>
    </Suspense></PrivyBoundary>}
  </WalletContext.Provider>;
}

export function WalletButton() {
  const wallet = useWallet();
  const wrongChain = wallet.isConnected && wallet.chainId !== 1;
  return <button className="button wallet-button" onClick={wrongChain ? () => void wallet.switchNetwork() : wallet.openWallet}>
    <Icon name="wallet" size={18}/><span>{wrongChain ? 'Switch to Ethereum' : wallet.address ? shortAddress(getAddress(wallet.address)) : 'Connect wallet'}</span>
    {wallet.address && <Icon name="chevron" size={16}/>}
  </button>;
}
