import { useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { encodeFunctionData, erc20Abi, isAddressEqual, type Abi, type Address, type Hash } from 'viem';
import { potAbi } from './abi';
import { chain, POT_ADDRESS, readClient } from './config';
import { entryReason, readableError } from './game';
import { fetchGame, verifyDeployment } from './data';
import { useWallet } from './Wallet';

export type TransactionState = { title: string; phase: 'pending' | 'success' | 'error'; message: string; hashes: Hash[] };
type Send = (to: Address, abi: Abi, functionName: string, args?: readonly unknown[], step?: string) => Promise<void>;

export function useTransactions() {
  const wallet = useWallet();
  const query = useQueryClient();
  const lock = useRef(false);
  const [busy, setBusy] = useState(false);
  const [state, setState] = useState<TransactionState>();
  const [visible, setVisible] = useState(false);

  async function run(title: string, action: (send: Send) => Promise<string>) {
    if (lock.current) return;
    if (!wallet.address) { wallet.openWallet(); return; }
    if (wallet.chainId !== 1) { await wallet.switchNetwork(); return; }
    if (!wallet.client) { wallet.openWallet(); return; }
    const account = wallet.address;
    const client = wallet.client;
    lock.current = true; setBusy(true); setVisible(true);
    const hashes: Hash[] = [];
    const update = (message: string) => setState({ title, phase: 'pending', message, hashes: [...hashes] });
    update('Checking the contract and your wallet…');
    const send: Send = async (to, abi, functionName, args = [], step = title) => {
      await verifyDeployment();
      const [chainId, accounts] = await Promise.all([client.getChainId(), client.getAddresses()]);
      if (chainId !== 1 || !accounts[0] || !isAddressEqual(accounts[0], account)) throw new Error('Your wallet account or network changed. Reconnect and review the action again.');
      const data = encodeFunctionData({ abi, functionName, args });
      update(`${step}: checking the transaction…`);
      await readClient.call({ account, to, data });
      update(`${step}: confirm in your wallet.`);
      const hash = await client.sendTransaction({ account, chain, to, data });
      hashes.push(hash);
      update(`${step}: waiting for Ethereum confirmation…`);
      let replaced = false;
      const receipt = await readClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 180_000, onReplaced: replacement => { if (replacement.reason !== 'repriced') replaced = true; hashes[hashes.length - 1] = replacement.transactionReceipt.transactionHash; update(`${step}: waiting for Ethereum confirmation…`); } });
      if (replaced) throw new Error('The transaction was replaced or cancelled in your wallet. Refresh and review before trying again.');
      if (receipt.status !== 'success') throw new Error('The transaction reverted on Ethereum. Refresh the round and try again.');
    };
    try {
      const message = await action(send);
      setState({ title, phase: 'success', message, hashes: [...hashes] });
    } catch (error) { setState({ title, phase: 'error', message: readableError(error), hashes: [...hashes] }); }
    finally {
      lock.current = false; setBusy(false);
      await query.invalidateQueries({ predicate: item => ['game', 'player', 'recent-rounds', 'fees', 'refund'].includes(String(item.queryKey[0])) });
    }
  }

  function buy(count: bigint, reviewedRound: bigint, reviewedCost: bigint) {
    return run('Buy tickets', async send => {
      const fresh = await fetchGame();
      const check = (game: typeof fresh) => {
        const reason = entryReason(game.round, game.configured, game.paused, game.chainTime);
        if (reason) throw new Error(reason);
        if (game.roundId !== reviewedRound || game.ticketPrice * count !== reviewedCost) throw new Error('The round or ticket cost changed. Close this window and review your purchase again.');
        if (!game.token) throw new Error('IMD is not configured. Entries are closed.');
      };
      check(fresh);
      const token = fresh.token!;
      const [balance, allowance] = await Promise.all([
        readClient.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [wallet.address!] }),
        readClient.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [wallet.address!, POT_ADDRESS] }),
      ]);
      if (balance < reviewedCost) throw new Error('Not enough IMD for this purchase. Choose fewer tickets.');
      if (allowance < reviewedCost) await send(token, erc20Abi, 'approve', [POT_ADDRESS, reviewedCost], 'Approve IMD');
      // Approval does not buy a ticket. A round may close while approval is pending.
      check(await fetchGame());
      await send(POT_ADDRESS, potAbi, 'buyTickets', [count], 'Buy tickets');
      return `${count.toLocaleString('en-US')} ${count === 1n ? 'ticket is' : 'tickets are'} confirmed in round #${reviewedRound}. Good luck.`;
    });
  }

  function action(functionName: 'finalizeRound' | 'claim' | 'redeemMultiplier' | 'retryRandomness' | 'cancelRound' | 'flushPendingFees' | 'refund', title: string, message: string, args: readonly bigint[] = []) {
    return run(title, async send => { await send(POT_ADDRESS, potAbi, functionName, args); return message; });
  }
  return { busy, state, visible, setVisible, buy, action };
}
