import { useEffect, useRef } from 'react';
import { PrivyProvider, usePrivy, useWallets, useCreateWallet, useLogin } from '@privy-io/react-auth';
import type { EIP1193Provider } from 'viem';
import { chain } from './config';
import { readableError } from './game';

type Props = { appId: string; onConnect: (provider: EIP1193Provider) => Promise<void>; onError: (message: string) => void };

function Session({ onConnect, onError }: Omit<Props, 'appId'>) {
  const { ready, authenticated } = usePrivy();
  const { login } = useLogin({ onError: () => onError('Privy sign-in did not complete. You can try again or choose a browser wallet.') });
  const { wallets, ready: walletsReady } = useWallets();
  const { createWallet } = useCreateWallet();
  const opened = useRef(false);
  const connected = useRef(false);
  const creating = useRef(false);
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
  return null;
}

export default function PrivySession({ appId, ...props }: Props) {
  return <PrivyProvider appId={appId} config={{
    appearance: { theme: 'dark', accentColor: '#d3f36a', walletChainType: 'ethereum-only' },
    loginMethods: ['email', 'google'],
    defaultChain: chain,
    supportedChains: [chain],
    embeddedWallets: { ethereum: { createOnLogin: 'users-without-wallets' } },
  }}><Session {...props}/></PrivyProvider>;
}
