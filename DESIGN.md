# IMDPot interface

## Overview

IMDPot is a compact Ethereum game dashboard for buying IMD tickets, following a round and claiming prizes. The visual direction is a quiet casino table: deep pine surfaces, warm light text and a lime ticket action. The chip illustration is original SVG artwork; it is decorative and never represents a real balance. “No crying in the casino” is the single brand signature.

The current round and ticket form lead the page. Economics, permissionless finalization, personal stats, prizes, history and rules follow in that order. Unavailable data uses a dash or an explicit loading/error message. There are no sample players, fabricated pools or seeded activity.

## Colors

The canonical system is in `frontend/src/styles.css`. Primitive hex values feed semantic custom properties; components use semantic names.

| Role | Token | Value |
| --- | --- | --- |
| Page | `--color-page` → `--pine-950` | `#111612` |
| Sidebar | `--color-sidebar` → `--pine-975` | `#0d120f` |
| Panels | `--color-surface` → `--pine-900` | `#18201a` |
| Jackpot table | `--color-table` → `--pine-875` | `#1b281e` |
| Hover / selected neutral surface | `--color-hover` → `--pine-850` | `#222d25` |
| Dividers | `--color-border` → `--pine-800` | `#2f3c32` |
| Control outlines | `--color-control-border` → `--pine-700` | `#455649` |
| Primary text / focus | `--color-text`, `--color-focus` → `--cream-50` | `#f1f4eb` |
| Secondary text | `--color-secondary` → `--sage-300` | `#a8b5a7` |
| Quiet decoration | `--color-muted` → `--sage-400` | `#8e9d8d` |
| Primary action | `--color-accent` → `--lime-400` | `#d3f36a` |
| Primary hover | `--color-accent-hover` → `--lime-300` | `#dff88e` |
| Primary label | `--color-on-accent` | `#172015` |
| Success | `--color-success` → `--green-300` | `#8bd9a5` |
| Burn category | `--color-burn` → `--orange-300` | `#efb28a` |
| Error | `--color-error` → `--red-300` | `#ffb3ad` |

Podium markers use muted gold, silver and copper fills with explicit place numbers. Wallet marks retain their vendor colors. Status always includes words; color alone never communicates readiness. The primary filled action is ticket purchase, or its confirmation inside a modal. Other page actions use neutral outlined buttons. This is one dark theme; no unimplemented light palette is implied. Rendered contrast results and coverage limits are in `artifacts/validation.md`.

## Typography

Geist Variable is bundled locally from `@fontsource-variable/geist`, using the Latin normal WOFF2 file. The fallback stack is `-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif`. The supplied file supports weights 100–900; the interface uses only 400, 500 and 600.

| Token | Size | Use |
| --- | --- | --- |
| `--text-caption` | 13px / `.8125rem` | Dense dashboard labels, hints, secondary prose |
| `--text-body` | 16px / `1rem` | Body, ticket action, smaller headings and inputs |
| `--text-heading` | 20px / `1.25rem` | Section headings and amount units |
| `--text-title` | 28px / `1.75rem` | Desktop page title, timer and personal stats |
| `--text-stat` | 40px / `2.5rem` | Claimable amount and narrow pool value |
| `--text-pool` | 64px / `4rem` | Wide desktop pool value |

Body line height is 1.5; longer rules use 1.6. Headings use 1.2–1.4, pool numbers 1.15 and claim numbers 1.3. Larger numeric values use slight negative tracking; normal UI text has natural spacing. Changing numbers use tabular figures. Headings balance, prose uses pretty wrapping. Addresses and exact amounts can wrap and remain selectable; approximate numeric displays expose exact values through `title`, and the purchase review always shows the full exact cost. Inputs stay at least 16px on phones to avoid iOS focus zoom. Small prose is intentional for a dense dashboard rather than an editorial reading page.

## Layout

`App.tsx` owns the one-page section order and hash navigation. Content uses a maximum width of 1344px, including 40px desktop gutters. The fixed sidebar is 216px wide. Grids use `minmax(0, ...)` to allow reflow. The main play and dashboard grids use a 1.45:1 ratio with 20px gaps; history uses 1:1.2. Panels have 26px padding at full width. Spacing is primarily 4/8/12/16/20/24/28/36/40px.

The implemented breakpoints are content driven:

- **1190px:** sidebar 192px, gutters 28px, panels 22px, pool value 40px, tighter grid and timer details.
- **980px:** sidebar collapses to an 82px icon rail. Decorative chips disappear to protect content width.
- **760px:** rail becomes a mobile brand header and normal-flow section navigation. Gutters become 24px; economics becomes three columns.
- **620px:** play, dashboard and history stack in DOM order. Gutters become 16px, panels 20px, the title becomes 20px and a small chip illustration returns. Ticket presets are 44px tall. Dialogs become bottom sheets with safe-area padding. Rules become one column.
- **360px:** decorative jackpot chips disappear, and the refund controls wrap.
- **1600px and wider:** the main top padding increases to 48px; content remains bounded.

The first 390×844 screen includes the product, the pool, the timer, ticket input and the buy action. There is no sticky bottom control covering content. The site was checked at 320, 390, 620, 760, 980 and 1440 CSS pixels; see validation for actual evidence and unperformed zoom/device checks.

## Elevation & depth

The interface is flat. Tonal surfaces group the pool and forms; separators explain internal sections and economics. Panels have no decorative border plus shadow combination. Only dialogs use elevation: `0 24px 80px #0008`, over a `#050906bd` backdrop. Native modal dialogs provide the top layer and make background content inert. Decorative rings on the chip illustration have no interactive role.

## Shapes

Panels use a 20px radius, reduced to 16px on phones. Controls use a 10px radius. Small presets and filters use 7px, and quantity stepper buttons 6px. Circular shapes are reserved for icon holders and chips. Dialogs use 24px corners; the bottom sheet squares its bottom corners. Structural dividers are 1px. Critical text is never clipped to force a shape.

## Components

| Component / source | Use and behavior |
| --- | --- |
| `Chip`, `Icon` in `frontend/src/Icons.tsx` | Original chip SVG and one coherent outline icon set. Icons inherit color and are decorative when the text already names the action. |
| `.button` in `styles.css` | `primary`, `secondary`, `wallet-button`, `full` variants. Disabled state is native, with contextual explanation. Hover, pressed and keyboard focus states are distinct. |
| Ticket form in `App.tsx` | Whole-ticket input, stepper and presets. Inline submit validation focuses the field. Cost uses bigint arithmetic. Review explains allowance, purchase, irreversible entry and gas. |
| `Modal` in `frontend/src/Modal.tsx` | Native `dialog.showModal()`. Close button, Escape and backdrop dismissal. Browser focus containment, background inertness and focus return; transaction dismissal returns to its status banner. |
| `WalletProvider`, `WalletButton` in `frontend/src/Wallet.tsx` | One picker for named EIP-6963 wallets, browser fallback, mobile app browsers, Coinbase and configured Privy. Per-row pending and recoverable errors. Connected address and disconnect; wrong-network switch with add-chain fallback. |
| `PrivySession` in `frontend/src/PrivySession.tsx` | Lazy SDK boundary using the owner's public app ID. Email/Google authentication and an Ethereum embedded wallet feed the same injected-provider transaction path. The row explains its unavailable default state. SDK errors leave the dashboard usable. |
| Transaction flow in `frontend/src/transactions.ts` | Verifies code/network/account, simulates calls, waits for successful receipts and refreshes state. Exact approval precedes purchase. A second fresh check rejects a closed or changed round. Pending, success, declined/reverted and replacement states keep transaction links. |
| `Fees`, `Winners` in `frontend/src/History.tsx` | Real event filters, explicit block window and earlier-page navigation. Deferred fees are distinguished from sent transfers. Winners come from recent settled contract rounds. Empty/error/loading states are explicit. |
| `RoundTools` in `frontend/src/RoundTools.tsx` | Native disclosure for delayed randomness, cancellation, pending fees and an explicit cancelled-round refund lookup. Contract timing gates control availability; claims and refunds remain available while paused. |

No entrance animation or perpetual decorative motion is used. Under `prefers-reduced-motion: no-preference`, button state transitions take 150ms with `cubic-bezier(.2, 0, 0, 1)` for transforms; presses scale to `.96`. Reduced motion removes these transitions. Focus uses a 2px foreground outline with a 4px offset; forced colors use `Highlight`.

## Do's and don'ts

- Start additional sections with the existing grid, `.panel` and `.section-head` patterns. Keep costly actions near their amount and explanation.
- Use the existing six type tokens and three weights. Reserve lime fill for the current primary action.
- Keep unknown values unknown, and pair failed reads with retry. Derive game state and token identity from the verified contract.
- Keep addresses and money accessible in full. Use exact bigint values for all decisions and transaction review.
- Add wallet options to the existing picker. Retain native button, link, form and dialog semantics.
- Recheck 320px reflow and the 390px opening screen after a layout change. Document real observed behavior, not assumed device support.

Design guidance: Jakub Krehel's Better Interface (MIT) and Paul Bakaus's Impeccable documentation method (Apache-2.0), pinned versions supplied with this assignment. Their retained combined license is `docs/licenses/Better-Interface-LICENSE.txt`. Font and wallet mark licenses are alongside it.
