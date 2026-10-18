import { Component, type ErrorInfo, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { walletConfig } from './config';
import { WalletProvider } from './Wallet';
import App from './App';
import './styles.css';

class ErrorBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  componentDidCatch(error: Error, info: ErrorInfo) { console.error('Dashboard could not render', error, info.componentStack); }
  render() {
    if (this.state.failed) return <main className="fatal-error"><h1>The table could not load</h1><p>Reload to try again. Your wallet and funds stay on Ethereum.</p><button className="button primary" onClick={() => location.reload()}>Reload dashboard</button></main>;
    return this.props.children;
  }
}
const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: true } } });
createRoot(document.getElementById('root')!).render(<ErrorBoundary><WagmiProvider config={walletConfig}><QueryClientProvider client={queryClient}><WalletProvider><App/></WalletProvider></QueryClientProvider></WagmiProvider></ErrorBoundary>);
