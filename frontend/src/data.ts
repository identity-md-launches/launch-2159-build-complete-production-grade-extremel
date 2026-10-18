import { useQuery } from '@tanstack/react-query';
import { erc20Abi, getAddress, isAddressEqual, keccak256, zeroAddress, type Address } from 'viem';
import { potAbi } from './abi';
import { DEPLOYMENT_BLOCK, POT_ADDRESS, readClient, RUNTIME_HASH } from './config';
import type { Round } from './game';

export async function verifyDeployment() {
  const [chainId, code] = await Promise.all([readClient.getChainId(), readClient.getCode({ address: POT_ADDRESS })]);
  if (chainId !== 1 || !code || keccak256(code) !== RUNTIME_HASH) {
    throw new Error('Contract verification failed. Transactions are disabled. Check the deployment on Etherscan.');
  }
}

export async function fetchGame() {
  await verifyDeployment();
  const block = await readClient.getBlock();
  const read = <N extends 'currentRoundId' | 'isConfigured' | 'paused' | 'token' | 'ticketPrice' | 'totalLocked' | 'pendingBurn' | 'pendingTreasury' | 'DEAD_ADDRESS' | 'TREASURY'>(functionName: N) => readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName, blockNumber: block.number });
  const [roundId, configured, paused, token, ticketPrice, locked, pendingBurn, pendingTreasury, burnAddress, treasury] = await Promise.all([
    read('currentRoundId'), read('isConfigured'), read('paused'), read('token'), read('ticketPrice'), read('totalLocked'), read('pendingBurn'), read('pendingTreasury'), read('DEAD_ADDRESS'), read('TREASURY'),
  ]);
  const round = await readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'getRound', args: [roundId], blockNumber: block.number });
  const hasToken = !isAddressEqual(token, zeroAddress);
  const decimals = hasToken ? await readClient.readContract({ address: token, abi: erc20Abi, functionName: 'decimals', blockNumber: block.number }) : 18;
  return { roundId, configured, paused, token: hasToken ? getAddress(token) : undefined, ticketPrice, locked, pendingBurn, pendingTreasury, burnAddress, treasury, round: round as Round, decimals, block: block.number, chainTime: Number(block.timestamp), fetchedAt: Date.now(), verified: true as const };
}

export type Game = Awaited<ReturnType<typeof fetchGame>>;
export function useGame() {
  return useQuery({ queryKey: ['game'], queryFn: fetchGame, refetchInterval: 15_000, retry: 1, staleTime: 10_000 });
}

export async function fetchPlayer(address: Address, game: Game) {
  const [player, tickets, boost, claimable, balance, allowance] = await Promise.all([
    readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'getPlayer', args: [address] }),
    readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'ticketsOf', args: [game.roundId, address] }),
    readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'roundBoostBps', args: [game.roundId, address] }),
    readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'claimable', args: [address] }),
    game.token ? readClient.readContract({ address: game.token, abi: erc20Abi, functionName: 'balanceOf', args: [address] }) : undefined,
    game.token ? readClient.readContract({ address: game.token, abi: erc20Abi, functionName: 'allowance', args: [address, POT_ADDRESS] }) : undefined,
  ]);
  return { points: player[0], roundsPlayed: player[1], pendingBoost: player[2], canRedeem: player[3], tickets, boost, claimable, balance, allowance };
}
export type Player = Awaited<ReturnType<typeof fetchPlayer>>;

export function usePlayer(address: Address | undefined, game: Game | undefined) {
  return useQuery({ queryKey: ['player', address, game?.roundId.toString()], queryFn: () => fetchPlayer(address!, game!), enabled: !!address && !!game, retry: 1, staleTime: 10_000, refetchInterval: 15_000 });
}

export function useRecentRounds(game: Game | undefined) {
  return useQuery({
    queryKey: ['recent-rounds', game?.roundId.toString()],
    enabled: !!game,
    queryFn: async () => {
      const size = Number(game!.roundId > 10n ? 10n : game!.roundId - 1n);
      return Promise.all(Array.from({ length: size }, async (_, index) => {
        const id = game!.roundId - 1n - BigInt(index);
        const round = await readClient.readContract({ address: POT_ADDRESS, abi: potAbi, functionName: 'getRound', args: [id] });
        return { id, round: round as Round };
      }));
    },
    staleTime: 30_000,
    retry: 1,
  });
}

export const HISTORY_WINDOW = 2_000n;
export async function fetchFees(toBlock: bigint) {
  const fromBlock = toBlock - HISTORY_WINDOW + 1n > DEPLOYMENT_BLOCK ? toBlock - HISTORY_WINDOW + 1n : DEPLOYMENT_BLOCK;
  const ranges: { fromBlock: bigint; toBlock: bigint }[] = [];
  for (let start = fromBlock; start <= toBlock; start += 500n) ranges.push({ fromBlock: start, toBlock: start + 499n < toBlock ? start + 499n : toBlock });
  const batches = await Promise.all(ranges.map(async range => {
    const [sent, deferred] = await Promise.all([
      readClient.getContractEvents({ address: POT_ADDRESS, abi: potAbi, eventName: 'FeeTransferred', ...range }),
      readClient.getContractEvents({ address: POT_ADDRESS, abi: potAbi, eventName: 'FeeTransferDeferred', ...range }),
    ]);
    return [...sent.map(log => ({ ...log, deferred: false })), ...deferred.map(log => ({ ...log, deferred: true }))];
  }));
  return { fromBlock, toBlock, events: batches.flat().filter(log => log.args.to && log.args.amount !== undefined && !log.removed).sort((a, b) => a.blockNumber === b.blockNumber ? b.logIndex - a.logIndex : a.blockNumber > b.blockNumber ? -1 : 1) };
}
