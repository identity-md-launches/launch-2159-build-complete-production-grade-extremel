/* IMDPot frontend. Dependency-free apart from the vendored ethers.js UMD bundle.
 * Wallets: every EIP-6963 announced wallet, the legacy window.ethereum injection, and any external EIP-1193
 * provider handed in through window.imdpot.connectProvider(provider) (this is how a Privy embedded wallet,
 * WalletConnect or any other SDK plugs in). */
(function () {
  "use strict";
  const cfg = window.IMDPOT_CONFIG || {};
  const { ethers } = window;

  const ABI = [
    "function token() view returns (address)",
    "function ticketPrice() view returns (uint256)",
    "function currentRoundId() view returns (uint256)",
    "function isConfigured() view returns (bool)",
    "function paused() view returns (bool)",
    "function timeRemaining() view returns (uint256)",
    "function pendingBurn() view returns (uint256)",
    "function pendingTreasury() view returns (uint256)",
    "function totalLocked() view returns (uint256)",
    "function claimable(address) view returns (uint256)",
    "function ticketsOf(uint256,address) view returns (uint256)",
    "function roundBoostBps(uint256,address) view returns (uint256)",
    "function getPlayer(address) view returns (uint256 points,uint256 roundsPlayed,uint256 pendingBoostBps,bool canRedeem)",
    "function getRound(uint256) view returns (tuple(uint8 status,uint64 startTime,uint64 endTime,uint64 randomnessRequestedAt,uint32 requestCount,uint256 pool,uint256 totalTickets,uint256 participantCount,uint256 vrfRequestId,uint256 randomWord,address[3] winners,uint256[3] prizes,uint256 burned,uint256 treasuryFee,uint256 locked))",
    "function requestRound(uint256) view returns (uint256)",
    "function MAX_RANDOMNESS_REQUESTS() view returns (uint32)",
    "function buyTickets(uint256 count)",
    "function finalizeRound()",
    "function retryRandomness()",
    "function cancelRound()",
    "function claim()",
    "function refund(uint256 roundId)",
    "function redeemMultiplier()",
    "function flushPendingFees()",
    "function syncPoints(address)",
    "function ROUNDS_FOR_MULTIPLIER() view returns (uint256)",
    "function MULTIPLIER_COST_POINTS() view returns (uint256)",
    "function VRF_RETRY_DELAY() view returns (uint256)",
    "function CANCEL_DELAY() view returns (uint256)",
    "function DEAD_ADDRESS() view returns (address)",
    "function TREASURY() view returns (address)",
  ];
  const ERC20_ABI = [
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address,address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
  ];
  const STATUS = ["Open", "Active", "Drawing", "Finalized", "Cancelled"];

  const $ = (id) => document.getElementById(id);
  const el = {
    banner: $("banner"), network: $("network"), connect: $("connect"), menu: $("wallet-menu"),
    roundId: $("round-id"), status: $("status"), timer: $("timer"), timerHint: $("timer-hint"),
    pool: $("pool"), tickets: $("tickets"), players: $("players"), finalize: $("finalize"), finalizeHint: $("finalize-hint"),
    qty: $("qty"), cost: $("cost"), balance: $("balance"), myTickets: $("my-tickets"), buy: $("buy"), buyMsg: $("buy-msg"),
    claimable: $("claimable"), claim: $("claim"), claimMsg: $("claim-msg"), lastWinners: $("last-winners"), refunds: $("refunds"),
    points: $("points"), roundsPlayed: $("rounds-played"), multiplier: $("multiplier"), roundsMeter: $("rounds-meter"),
    redeem: $("redeem"), redeemMsg: $("redeem-msg"), addresses: $("addresses"), pendingFees: $("pending-fees"),
  };

  const state = {
    readProvider: null, signer: null, account: null, pot: null, token: null, decimals: 18, symbol: cfg.tokenSymbol || "IMD",
    ticketPrice: 0n, round: null, roundId: 0n, endTime: 0, status: 0, roundsNeeded: 10n, redeemCost: 100n,
    retryDelay: 3600, cancelDelay: 86400, maxRequests: 4, wallets: new Map(), eip1193: null, busy: false,
  };
  // How many past rounds the refund scan covers. Cancelled rounds are rare; refunds never expire on-chain.
  const REFUND_SCAN_ROUNDS = 200;
  const REFUND_SCAN_BATCH = 10;

  // ------------------------------------------------------------------ helpers
  const fmt = (v, digits = 2) => {
    if (v === undefined || v === null) return "—";
    const s = ethers.formatUnits(v, state.decimals);
    const n = Number(s);
    return n >= 1000 ? n.toLocaleString(undefined, { maximumFractionDigits: digits }) : n.toLocaleString(undefined, { maximumFractionDigits: Math.max(digits, 4) });
  };
  const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "—");
  const link = (a) => `<a href="${cfg.explorerBase || "https://etherscan.io"}/address/${a}" target="_blank" rel="noopener">${short(a)}</a>`;
  const setMsg = (node, text, kind) => { node.textContent = text || ""; node.className = "msg" + (kind ? " " + kind : ""); };
  const banner = (text) => { if (!text) { el.banner.classList.add("hidden"); return; } el.banner.textContent = text; el.banner.classList.remove("hidden"); };
  const explain = (e) => {
    const raw = e?.shortMessage || e?.reason || e?.message || String(e);
    if (e?.data && state.pot) {
      try { const err = state.pot.interface.parseError(e.data); if (err) return err.name; } catch (_) { /* ignore */ }
    }
    if (/user rejected|denied/i.test(raw)) return "Transaction rejected in wallet.";
    return raw.length > 180 ? raw.slice(0, 180) + "…" : raw;
  };

  // ------------------------------------------------------------------ providers
  function buildReadProvider() {
    if (cfg.readRpcUrl) return new ethers.JsonRpcProvider(cfg.readRpcUrl, Number(cfg.chainId || 1));
    if (window.ethereum) return new ethers.BrowserProvider(window.ethereum);
    return null;
  }

  function attachContracts(runner) {
    state.pot = new ethers.Contract(cfg.contractAddress, ABI, runner);
  }

  async function connectProvider(eip1193, label) {
    try {
      const provider = new ethers.BrowserProvider(eip1193);
      await eip1193.request({ method: "eth_requestAccounts" });
      const net = await provider.getNetwork();
      if (Number(net.chainId) !== Number(cfg.chainId || 1)) {
        try {
          await eip1193.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + Number(cfg.chainId || 1).toString(16) }] });
        } catch (_) {
          banner(`Wrong network: switch your wallet to chain ${cfg.chainId || 1}.`);
          return;
        }
      }
      state.eip1193 = eip1193;
      state.signer = await provider.getSigner();
      state.account = await state.signer.getAddress();
      attachContracts(state.signer);
      await loadToken();
      el.connect.textContent = `${label ? label + " · " : ""}${short(state.account)}`;
      el.network.textContent = `chain ${cfg.chainId || 1}`;
      el.network.classList.remove("muted");
      el.menu.classList.add("hidden");
      banner("");
      eip1193.on?.("accountsChanged", () => location.reload());
      eip1193.on?.("chainChanged", () => location.reload());
      await refresh();
    } catch (e) {
      banner(explain(e));
    }
  }

  function discoverWallets() {
    window.addEventListener("eip6963:announceProvider", (ev) => {
      const { info, provider } = ev.detail;
      state.wallets.set(info.uuid, { info, provider });
      renderMenu();
    });
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    renderMenu();
  }

  function renderMenu() {
    el.menu.innerHTML = "";
    const add = (labelHtml, onClick) => {
      const b = document.createElement("button");
      b.className = "btn btn-ghost";
      b.innerHTML = labelHtml;
      b.onclick = onClick;
      el.menu.appendChild(b);
    };
    for (const { info, provider } of state.wallets.values()) {
      add(`<img src="${info.icon}" alt="" /> ${info.name}`, () => connectProvider(provider, info.name));
    }
    if (window.ethereum && state.wallets.size === 0) add("Injected wallet", () => connectProvider(window.ethereum, "Wallet"));
    if (cfg.privyAppId && window.Privy) add("Privy (email / social / embedded)", connectPrivy);
    if (!el.menu.children.length) add("No wallet detected — install one or use Privy", () => {});
  }

  // Privy: the page may load Privy's SDK; the embedded wallet exposes an EIP-1193 provider that plugs in here.
  async function connectPrivy() {
    try {
      const privy = window.Privy;
      const provider = await privy.getEthereumProvider?.({ appId: cfg.privyAppId });
      if (!provider) throw new Error("Privy SDK not initialised on this page.");
      await connectProvider(provider, "Privy");
    } catch (e) {
      banner(explain(e));
    }
  }

  // Public hook for any wallet SDK (Privy, WalletConnect, Coinbase, Safe…): hand us an EIP-1193 provider.
  window.imdpot = { connectProvider: (p, label) => connectProvider(p, label || "Wallet"), refresh: () => refresh() };

  // ------------------------------------------------------------------ data
  async function loadToken() {
    const tokenAddr = await state.pot.token();
    if (tokenAddr === ethers.ZeroAddress) { state.token = null; return; }
    state.token = new ethers.Contract(tokenAddr, ERC20_ABI, state.signer || state.readProvider);
    try { state.decimals = Number(await state.token.decimals()); } catch (_) { state.decimals = 18; }
    try { state.symbol = await state.token.symbol(); } catch (_) { /* keep configured */ }
  }

  async function refresh() {
    if (!state.pot) return;
    try {
      const [roundId, ticketPrice, configured, paused, roundsNeeded, redeemCost, pendingBurn, pendingTreasury, locked, retryDelay, cancelDelay, maxRequests] = await Promise.all([
        state.pot.currentRoundId(), state.pot.ticketPrice(), state.pot.isConfigured(), state.pot.paused(),
        state.pot.ROUNDS_FOR_MULTIPLIER(), state.pot.MULTIPLIER_COST_POINTS(), state.pot.pendingBurn(), state.pot.pendingTreasury(),
        state.pot.totalLocked(), state.pot.VRF_RETRY_DELAY(), state.pot.CANCEL_DELAY(), state.pot.MAX_RANDOMNESS_REQUESTS(),
      ]);
      state.roundId = roundId; state.ticketPrice = ticketPrice; state.roundsNeeded = roundsNeeded; state.redeemCost = redeemCost;
      state.retryDelay = Number(retryDelay); state.cancelDelay = Number(cancelDelay); state.maxRequests = Number(maxRequests);
      const round = await state.pot.getRound(roundId);
      state.round = round; state.status = Number(round.status); state.endTime = Number(round.endTime);

      el.roundId.textContent = `#${roundId}`;
      el.pool.innerHTML = `${fmt(round.pool)} <small>${state.symbol}</small>`;
      el.tickets.textContent = round.totalTickets.toString();
      el.players.textContent = round.participantCount.toString();
      el.pendingFees.textContent = `Locked forever: ${fmt(locked)} ${state.symbol}` + ((pendingBurn > 0n || pendingTreasury > 0n) ? " · fee transfer pending (anyone can flush)" : "");
      if (!configured) banner("The contract is deployed but the owner has not finished configuration (token / Chainlink VRF). Entries are closed.");
      else if (paused) banner("The game is paused by the operator. Claims and refunds still work.");
      else banner("");

      updateCost();
      renderStatus();
      await renderLastRound(roundId);
      if (state.account) await refreshAccount();
    } catch (e) {
      banner("Could not read the contract: " + explain(e));
    }
  }

  async function refreshAccount() {
    const a = state.account;
    const [claimable, myTickets, player, balance] = await Promise.all([
      state.pot.claimable(a), state.pot.ticketsOf(state.roundId, a), state.pot.getPlayer(a),
      state.token ? state.token.balanceOf(a) : Promise.resolve(0n),
    ]);
    el.balance.textContent = `${fmt(balance)} ${state.symbol}`;
    el.myTickets.textContent = myTickets.toString();
    el.claimable.textContent = `${fmt(claimable)} ${state.symbol}`;
    el.claim.disabled = claimable === 0n || state.busy;
    el.claim.textContent = claimable === 0n ? "Nothing to claim" : `Claim ${fmt(claimable)} ${state.symbol}`;
    el.points.textContent = player.points.toString();
    el.roundsPlayed.textContent = `${player.roundsPlayed} / ${state.roundsNeeded}`;
    const pct = Math.min(100, Number(player.roundsPlayed * 100n / state.roundsNeeded));
    el.roundsMeter.style.width = pct + "%";
    const boostInRound = await state.pot.roundBoostBps(state.roundId, a);
    const activeBoost = myTickets > 0n ? boostInRound : player.pendingBoostBps;
    el.multiplier.textContent = `${(1 + Number(activeBoost) / 10000).toFixed(2)}×` + (myTickets > 0n ? " (this round)" : " (next round)");
    el.redeem.disabled = !player.canRedeem || state.busy;
    el.redeem.textContent = player.canRedeem ? `Redeem ${state.redeemCost} points → +0.25× chance` : `Redeem ${state.redeemCost} points (needs ${state.roundsNeeded} rounds)`;
    const canBuy = (state.status === 0 || (state.status === 1 && state.endTime > now())) && !state.busy;
    el.buy.disabled = !canBuy;
    el.buy.textContent = canBuy ? "Buy tickets" : state.status === 2 ? "Drawing in progress" : "Round closed";
    await renderRefunds(a);
  }

  /* Every cancelled round in which the connected account still holds tickets gets its own refund button, however
   * many rounds have been played since. Refunds never expire on-chain. */
  async function renderRefunds(account) {
    const refundable = [];
    const newest = state.roundId - 1n;
    const oldest = newest - BigInt(REFUND_SCAN_ROUNDS) + 1n > 1n ? newest - BigInt(REFUND_SCAN_ROUNDS) + 1n : 1n;
    for (let id = newest; id >= oldest; id -= BigInt(REFUND_SCAN_BATCH)) {
      const ids = [];
      for (let k = 0n; k < BigInt(REFUND_SCAN_BATCH) && id - k >= oldest; k++) ids.push(id - k);
      const rounds = await Promise.all(ids.map((rid) => state.pot.getRound(rid)));
      const cancelled = ids.filter((rid, i) => Number(rounds[i].status) === 4);
      if (!cancelled.length) continue;
      const tickets = await Promise.all(cancelled.map((rid) => state.pot.ticketsOf(rid, account)));
      cancelled.forEach((rid, i) => { if (tickets[i] > 0n) refundable.push({ id: rid, tickets: tickets[i] }); });
    }
    if (!refundable.length) { el.refunds.classList.add("hidden"); el.refunds.innerHTML = ""; return; }
    el.refunds.innerHTML = refundable.map(({ id, tickets }) =>
      `<li class="muted">Round #${id} was cancelled: ${tickets} ticket${tickets === 1n ? "" : "s"} (${fmt(state.ticketPrice * tickets)} ${state.symbol}) refundable.
        <button class="btn btn-ghost" data-refund="${id}">Refund round #${id}</button></li>`).join("");
    el.refunds.classList.remove("hidden");
    el.refunds.querySelectorAll("button[data-refund]").forEach((b) => {
      const id = BigInt(b.dataset.refund);
      b.disabled = state.busy;
      b.onclick = () => tx(() => state.pot.refund(id), el.claimMsg, `Round #${id} refunded`);
    });
  }

  async function renderLastRound(roundId) {
    let shown = false;
    for (let id = roundId - 1n; id >= 1n && id >= roundId - 5n; id--) {
      const r = await state.pot.getRound(id);
      if (Number(r.status) === 3) {
        const items = [];
        const medals = ["🥇", "🥈", "🥉"];
        r.winners.forEach((w, i) => { if (w !== ethers.ZeroAddress) items.push(`<li>${medals[i]} ${link(w)} <b>${fmt(r.prizes[i])} ${state.symbol}</b></li>`); });
        items.push(`<li class="muted">Round #${id}: pool ${fmt(r.pool)}, burned ${fmt(r.burned)}, treasury ${fmt(r.treasuryFee)}, locked ${fmt(r.locked)}. VRF word ${r.randomWord.toString().slice(0, 12)}…</li>`);
        el.lastWinners.innerHTML = items.join("");
        shown = true;
        break;
      }
      if (Number(r.status) === 4) {
        // Keep looking for the last draw; refund controls for cancelled rounds live in the refund list above.
        el.lastWinners.innerHTML = `<li class="muted">Round #${id} was cancelled. Participants can refund their tickets${state.account ? " (see above)" : " once connected"}.</li>`;
        shown = true;
        continue;
      }
    }
    if (!shown) el.lastWinners.innerHTML = '<li class="muted">No finished round yet.</li>';
  }

  const now = () => Math.floor(Date.now() / 1000);

  function renderStatus() {
    const s = state.status;
    el.status.className = "pill " + (s === 1 ? (state.endTime > now() ? "live" : "ended") : s === 2 ? "drawing" : "");
    el.status.textContent = s === 0 ? "Waiting for first ticket" : s === 1 ? (state.endTime > now() ? "Live" : "Ended — ready to finalize") : s === 2 ? "Drawing (Chainlink VRF)" : STATUS[s];
    el.finalize.classList.toggle("hidden", !(s === 1 && state.endTime <= now()) && s !== 2);
    el.finalizeHint.classList.toggle("hidden", s !== 2 && !(s === 1 && state.endTime <= now()));
    if (s === 2) {
      const requestedAt = Number(state.round.randomnessRequestedAt);
      const requests = Number(state.round.requestCount);
      const retryAt = requestedAt + state.retryDelay;
      // A round can only be cancelled 24 h after both its end and its latest randomness request.
      const cancelAt = Math.max(state.endTime, requestedAt) + state.cancelDelay;
      const canRetry = requests < state.maxRequests;
      el.finalize.textContent = now() >= retryAt && canRetry ? `Add randomness request (${requests}/${state.maxRequests})` : "Waiting for Chainlink VRF…";
      el.finalize.disabled = now() < retryAt || !canRetry || state.busy;
      el.finalizeHint.textContent = now() >= cancelAt
        ? "Randomness never arrived: anyone can cancel the round for refunds."
        : canRetry
          ? "The random word usually arrives within a few blocks. Settlement happens automatically when it does; every request made for this round stays valid."
          : `All ${state.maxRequests} requests for this round are out. If none is fulfilled, the round can be cancelled for refunds at ${new Date(cancelAt * 1000).toLocaleString()}.`;
      if (now() >= cancelAt) { el.finalize.textContent = "Cancel round (refunds)"; el.finalize.disabled = state.busy; }
    } else if (s === 1 && state.endTime <= now()) {
      el.finalize.textContent = "Finalize round & draw winners";
      el.finalize.disabled = state.busy || !state.account;
      el.finalizeHint.textContent = state.account ? "Anyone may finalize. This requests the random word from Chainlink VRF." : "Connect a wallet to finalize.";
    }
  }

  function tick() {
    const s = state.status;
    if (s === 1) {
      const left = Math.max(0, state.endTime - now());
      el.timer.textContent = `${String(Math.floor(left / 60)).padStart(2, "0")}:${String(left % 60).padStart(2, "0")}`;
      el.timer.className = "timer" + (left === 0 ? " ended" : "");
      el.timerHint.textContent = left === 0 ? "Time is up. Anyone can finalize the round." : "Tickets close exactly when the timer hits zero.";
      if (left === 0 && el.finalize.classList.contains("hidden")) renderStatus();
    } else if (s === 2) {
      el.timer.textContent = "DRAW";
      el.timer.className = "timer ended";
      el.timerHint.textContent = "Waiting for the Chainlink VRF random word.";
    } else {
      el.timer.textContent = "15:00";
      el.timer.className = "timer idle";
      el.timerHint.textContent = "The timer starts with the first ticket of the round.";
    }
  }

  function updateCost() {
    const q = BigInt(Math.max(1, Math.floor(Number(el.qty.value) || 1)));
    el.cost.textContent = `${fmt(state.ticketPrice * q)} ${state.symbol}`;
  }

  // ------------------------------------------------------------------ transactions
  async function tx(fn, msgNode, okText) {
    if (!state.signer) { setMsg(msgNode, "Connect a wallet first.", "err"); return; }
    state.busy = true;
    setMsg(msgNode, "Confirm in your wallet…");
    try {
      const response = await fn();
      setMsg(msgNode, "Pending: " + short(response.hash));
      await response.wait();
      setMsg(msgNode, okText + " ✓", "ok");
    } catch (e) {
      setMsg(msgNode, explain(e), "err");
    } finally {
      state.busy = false;
      await refresh();
    }
  }

  async function buy() {
    const q = BigInt(Math.max(1, Math.floor(Number(el.qty.value) || 1)));
    const cost = state.ticketPrice * q;
    if (!state.token) { setMsg(el.buyMsg, "Token not configured yet.", "err"); return; }
    const allowance = await state.token.allowance(state.account, cfg.contractAddress);
    if (allowance < cost) {
      // Approve exactly what this purchase needs: no infinite approvals.
      await tx(() => state.token.approve(cfg.contractAddress, cost), el.buyMsg, `Approved ${fmt(cost)} ${state.symbol}`);
      if (el.buyMsg.classList.contains("err")) return;
    }
    await tx(() => state.pot.buyTickets(q), el.buyMsg, `Bought ${q} ticket${q === 1n ? "" : "s"}`);
  }

  async function finalizeOrRetry() {
    const s = state.status;
    if (s === 1) return tx(() => state.pot.finalizeRound(), el.finalizeHint, "Randomness requested");
    const cancelAt = Math.max(state.endTime, Number(state.round.randomnessRequestedAt)) + state.cancelDelay;
    if (now() >= cancelAt) return tx(() => state.pot.cancelRound(), el.finalizeHint, "Round cancelled");
    return tx(() => state.pot.retryRandomness(), el.finalizeHint, "Randomness request added");
  }

  // ------------------------------------------------------------------ boot
  function boot() {
    if (!ethers) { banner("ethers.js failed to load."); return; }
    if (!cfg.contractAddress) {
      banner("Frontend not configured: set contractAddress in frontend/config.js to the deployed IMDPot address.");
      el.addresses.textContent = "Contract address not configured.";
    } else {
      state.readProvider = buildReadProvider();
      if (state.readProvider) {
        attachContracts(state.readProvider);
        loadToken().then(refresh).catch((e) => banner(explain(e)));
        state.pot.TREASURY().then((t) => state.pot.DEAD_ADDRESS().then((d) => {
          el.addresses.innerHTML = `Contract ${link(cfg.contractAddress)} · Treasury ${link(t)} · Burn ${link(d)}`;
        })).catch(() => {});
      } else {
        banner("No wallet detected and no readRpcUrl configured. Connect a wallet to load the game.");
      }
    }
    discoverWallets();
    el.connect.onclick = () => el.menu.classList.toggle("hidden");
    el.qty.oninput = updateCost;
    document.querySelectorAll(".qty").forEach((b) => (b.onclick = () => { el.qty.value = b.dataset.qty; updateCost(); }));
    el.buy.onclick = buy;
    el.claim.onclick = () => tx(() => state.pot.claim(), el.claimMsg, "Prize claimed");
    el.redeem.onclick = () => tx(() => state.pot.redeemMultiplier(), el.redeemMsg, "Multiplier redeemed");
    el.finalize.onclick = finalizeOrRetry;
    setInterval(tick, 500);
    setInterval(() => { if (!state.busy) refresh(); }, 12000);
    tick();
  }

  document.addEventListener("DOMContentLoaded", boot);
})();
