import { useEffect, useRef } from 'react';
import { PrivyProvider, usePrivy, useWallets, useCreateWallet, useLogin, useModalStatus } from '@privy-io/react-auth';
import type { EIP1193Provider } from 'viem';
import { chain } from './config';
import { readableError } from './game';

type Props = { appId: string; onConnect: (provider: EIP1193Provider) => Promise<void>; onError: (message: string) => void; onLogoutReady: (logout: (() => Promise<void>) | undefined) => void };

function Session({ onConnect, onError, onLogoutReady }: Omit<Props, 'appId'>) {
  const { ready, authenticated, logout } = usePrivy();
  const { isOpen } = useModalStatus();
  const { login } = useLogin({ onError: () => onError('Privy sign-in did not complete. You can try again or choose a browser wallet.') });
  const { wallets, ready: walletsReady } = useWallets();
  const { createWallet } = useCreateWallet();
  const opened = useRef(false);
  const connected = useRef(false);
  const creating = useRef(false);
  const sawModal = useRef(false);
  useEffect(() => { onLogoutReady(logout); return () => onLogoutReady(undefined); }, [logout, onLogoutReady]);
  useEffect(() => {
    if (isOpen) sawModal.current = true;
    if (sawModal.current && !isOpen && !authenticated) onError('Privy sign-in was closed. Choose Continue with Privy to try again.');
  }, [isOpen, authenticated, onError]);
  useEffect(() => {
    if (!ready || authenticated || opened.current) return;
    opened.current = true;
    login();
  }, [ready, authenticated, login]);
  useEffect(() => {
    if (!ready || !authenticated || !walletsReady || connected.current) return;
    const wallet = wallets.find(item => item.walletClientType === 'privy') ?? wallets[0];
    if (!wallet && !creating.current) {
      creating.current = true;
      void createWallet().catch(error => onError(readableError(error)));
      return;
    }
    if (!wallet) return;
    connected.current = true;
    void wallet.getEthereumProvider().then(provider => onConnect(provider as EIP1193Provider)).catch(error => { connected.current = false; onError(readableError(error)); });
  }, [ready, authenticated, walletsReady, wallets, createWallet, onConnect, onError]);
  return !ready || authenticated && !connected.current ? <div className="connection-status" role="status"><span>{authenticated ? 'Connecting your Privy wallet…' : 'Loading Privy sign-in…'}</span><button type="button" className="text-button" onClick={() => onError('Privy sign-in was stopped. You can try again or choose another wallet.')}>Return to wallet options</button></div> : null;
}

export default function PrivySession({ appId, ...props }: Props) {
  return <PrivyProvider appId={appId} config={{
    appearance: { theme: 'dark', accentColor: '#d3f36a', walletChainType: 'ethereum-only' },
    // Email is enabled for this app. Do not advertise a disabled social provider.
    loginMethods: ['email'],
    defaultChain: chain,
    supportedChains: [chain],
    embeddedWallets: { ethereum: { createOnLogin: 'off' } },
  }}><Session {...props}/></PrivyProvider>;
}
