# SparkBoostedVault — Design Notes

## Overview

SparkBoostedVault is a per-user vesting variant of [SparkVault](https://github.com/sparkdotfi/spark-vaults-v2/blob/v1.0.1/src/SparkVault.sol). Each user's yield is gated by a vesting curve defined by two duration parameters: **`cliff`** and **`term`**. These parameters are initialized during setup but can be changed at any time after initialization by an account with default admin role privileges (`DEFAULT_ADMIN_ROLE`). While changing these values will not affect the total yield of an open position, it will affect the portion that is considered vested and unvested, either favorably or unfavorably for the position holder, depending on the change. Principal is always withdrawable; yield is multiplied by a curve that is 0 before `cliff` and then a **quadratic ease-in** `(elapsed/term)²` from 0 to 1 over the `[0, term]` window (with the pre-cliff portion zeroed out — a jump at cliff). Because the ramp is quadratic and slow at the start, early exits forfeit disproportionately more yield than they would under a linear curve.

**Positions have unique IDs and are tracked per user:**

- Each deposit creates a new, independent position with a unique incrementing `positionId`.
- An address can hold multiple positions. The active positions for a user are enumerable.
- Users can withdraw a specific position fully (closing the position) or partially (pro-ratably reducing principal and shares).
- `deposit(assets)` creates a new position for the msg.sender. `withdraw(...)` requires the position owner to be the caller (`msg.sender`) but accepts a `recipient` parameter to specify where the withdrawn assets are sent.

There is no ERC20 surface, and no allowance or transfer system.

## Per-user state

```solidity
struct Position {
    uint256 principal;   // asset units the user paid in, minus any withdrawn principal
    uint256 shares;      // raw rate-based shares; raw_assets = shares * chi / RAY
    uint64  depositTime; // deposit timestamp (T0)
}
```

The contract maintains the following storage structures to track these positions:

- `positionCount`: Incremented on each deposit to assign a unique ID.
- `positions`: Mapping from `positionId` to `Position` struct.
- `positionIdSets`: Mapping from user address to their set of `positionIds` (enumerable via OpenZeppelin's `EnumerableSet`).

Enumerable access is exposed via the following read methods:

- `getPositionIdsOf(address account)` returns an array of active position IDs for the account.
- `getPositionsOf(address account)` returns an array of `Position` structs for the account.
- `getPosition(uint256 positionId)` retrieves details of a specific position.

The core mathematical machinery for the rate accumulator (`chi` / `rho` / `vsr`) operates on the same principles as [SparkVault](https://github.com/sparkdotfi/spark-vaults-v2/blob/dev/src/SparkVault.sol) — `chi` grows continuously at the Vault Savings Rate (`vsr`) per second.

However, `SparkBoostedVault` differs significantly from the original `SparkVault` in terms of tokenization, positions, and vesting:

- **No Tokenization**: `SparkVault` is a standard ERC20-tokenized vault. `SparkBoostedVault` does not implement the ERC20 or ERC4626 standard and has no transferable share tokens or allowances.
- **Multi-Position Tracking**: While `SparkVault` pools assets into a single share balance per user, `SparkBoostedVault` tracks independent deposits as discrete positions identified by unique `positionId`s.
- **Vesting Curves**: Deposits in `SparkVault` are redeemable instantly with accrued yield. In `SparkBoostedVault`, accrued yield is locked under a quadratic vesting curve with a `cliff` and `term` based on the position's individual `depositTime`.

## The vesting curve

Let `elapsed = block.timestamp - depositTime`. Then:

```
m(elapsed) = 0                        if elapsed <  cliff
m(elapsed) = (elapsed / term)²        if elapsed >= cliff and elapsed < term
m(elapsed) = 1                        if elapsed >= term
```

Geometrically: take the parabola `y = (elapsed/term)²`, clamp at 1 past term, and **zero it out before cliff**. The result is discontinuous — at `elapsed == cliff`, m jumps from 0 to `(cliff/term)²`. After that, m grows quadratically until elapsed reaches term.

Key intuition: at half-term, only **25%** of yield is vested (vs. 50% under linear). At three-quarter term, ~56% is vested (vs. 75% linear). The bulk of the boost is concentrated in the tail near `term`, which makes the curve materially more punishing on early exits than the linear shape.

### Mutability of Cliff and Term

An account with `DEFAULT_ADMIN_ROLE` can change the vault's active `cliff` and `term` parameters at any time after initialization via `setCliff` and `setTerm` respectively.

- **Total Yield Unaffected**: Changing these parameters has absolutely no impact on the overall interest/yield accumulated by a position (which is driven purely by the position's shares and the growth of the global accumulator `chi`).
- **Vesting Portion Impacted**: Since the vesting multiplier `m(elapsed)` is evaluated dynamically using the _current_ `cliff` and `term` state of the vault, updating these parameters immediately recalculates the ratio of vested (`vested_yield`) to unvested (`unvested_yield`) yield for all open positions, based on their outstanding principal.
- **Favorable / Unfavorable Outcomes**:
    - Decreasing `cliff` or `term` shifts the curve to vest yield faster, increasing `vested_yield` (favorable for the position holder).
    - Increasing `cliff` or `term` shifts the curve to vest yield slower or reset elapsed duration to be pre-cliff, decreasing `vested_yield` (unfavorable for the position holder).

## Derived quantities

```
raw_assets     = shares * chi / RAY
raw_yield      = max(0, raw_assets - principal)
vested_yield   = raw_yield * m / RAY
unvested_yield = raw_yield - vested_yield
withdrawable   = principal + vested_yield
```

Principal is always claimable, even before cliff. Only yield is gated.

## Mint (deposit)

```
1. drip()                                     // refresh chi
2. Check: maxLiability() + assets <= maxLiabilityCap
3. positionId = ++positionCount
4. shares = assets * RAY / chi (require assets and shares > 0)
5. positions[positionId] = Position({
       principal:   assets,
       shares:      shares,
       depositTime: uint64(block.timestamp)
   })
6. Add positionId to msg.sender's position set
7. totalShares    += shares
   totalPrincipal += assets
8. Pull `assets` from msg.sender via safeTransferFrom
```

## Burn (withdraw)

The contract supports both full and partial withdraws for a specific position, directing the withdrawn assets to a specified recipient address:

- `withdraw(positionId, recipient)`: Full withdraw. Withdraws all assets (principal + vested yield), deleting the position.
- `withdraw(positionId, assets, recipient)`: Partial withdraw. Withdraws a specific amount of assets, reducing the position's principal and shares proportionally.

Both external methods delegate to the internal `_withdraw(positionId, assets, recipient)` function, which follows this flow:

```
1. drip()                                     // refresh chi
2. withdrawable = withdrawableOf(positionId)  // principal + vested_yield
3. Require withdrawable > 0
4. Require msg.sender is the owner of positionId (exists in positionIdSets[msg.sender])
5. Calculate portions (using ceilDiv):
   sharePortion     = ceilDiv(position.shares * assets, withdrawable)
   principalPortion = ceilDiv(position.principal * assets, withdrawable)
6. If sharePortion == position.shares or principalPortion == position.principal (full exit boundary):
   - Remove positionId from msg.sender's position set
   - Delete positions[positionId]
   - Set sharePortion     = position.shares
   - Set principalPortion = position.principal
7. Else (true partial exit):
   - Reduce position.shares    -= sharePortion
   - Reduce position.principal -= principalPortion
   - (Note: depositTime remains unchanged, continuing to vest remaining portions using the original timestamp)
8. Require assets != 0 and sharePortion != 0
9. totalShares    -= sharePortion
   totalPrincipal -= principalPortion
10. Push `assets` to recipient via safeTransfer
```

The user receives the requested `assets`. Any forfeited unvested yield corresponding to the burned shares remains in the vault as surplus.

---

## Take (Balance Withdrawal)

Authorized accounts with the `TAKER_ROLE` can withdraw assets from the vault using the `take(assets)` function.

While the primary design intent is for takers to harvest accrued surplus and forfeited yield, the `take` function is implemented as an **unrestricted balance withdrawal** of the underlying asset up to the contract's total current balance.

Consequently, the contract relies on a trust assumption: the `TAKER` is trusted to withdraw the vault's assets, invest/deploy them productively, and return liquidity to the vault as needed to satisfy user withdrawals.

---

## Worked example — single position through the curve

`term = 365 days`, `cliff = 90 days`, ~10% APY (treated linearly for arithmetic clarity).

Deposit 100 at t=0. Position: P=100, S=100, T0=0.

| t (days) | raw    | raw_yield | m      | vested | withdrawable | If user withdraws at t     |
| -------- | ------ | --------- | ------ | ------ | ------------ | -------------------------- |
| 30       | 100.82 | 0.82      | 0      | 0      | 100.00       | gets 100, forfeits 0.82    |
| 89       | 102.44 | 2.44      | 0      | 0      | 100.00       | gets 100, forfeits 2.44    |
| **90**   | 102.47 | 2.47      | 0.0608 | 0.150  | **100.15**   | gets 100.15, forfeits 2.32 |
| 180      | 104.93 | 4.93      | 0.2432 | 1.200  | 101.20       | gets 101.20, forfeits 3.73 |
| 270      | 107.40 | 7.40      | 0.5472 | 4.048  | 104.05       | gets 104.05, forfeits 3.35 |
| 365      | 110.00 | 10.00     | 1.0000 | 10.00  | 110.00       | gets 110, forfeits 0       |
| 730      | 120.00 | 20.00     | 1.0000 | 20.00  | 120.00       | gets 120, forfeits 0       |

Compare with the linear curve at the same times:

| t (days) | m_linear | vested_linear | m_quad | vested_quad | quad / linear |
| -------- | -------- | ------------- | ------ | ----------- | ------------- |
| 90       | 0.2466   | 0.609         | 0.0608 | 0.150       | 25%           |
| 180      | 0.4932   | 2.432         | 0.2432 | 1.200       | 49%           |
| 270      | 0.7397   | 5.473         | 0.5472 | 4.048       | 74%           |
| 365      | 1.0000   | 10.00         | 1.0000 | 10.00       | 100%          |

A user who exits at t=180 under the quadratic curve receives roughly **half** of what they'd receive under linear — most of the boost is back-loaded into the final stretch before term. The cliff jump at t=90 is also much smaller (0.15 vs 0.61), so even crossing cliff is a relatively modest milestone; the meaningful vesting happens later.

After term the multiplier saturates at 1, and further yield is fully claimable as it accrues. Forfeited yield stays in the vault and becomes TAKER-claimable surplus.

---

## Depositing More / "Re-staking"

Because the contract uses a multi-position model, there is no "top-up" or re-staking of existing positions:

1. Users who want to deposit more assets can simply call `deposit(assets)` again. This creates a new, independent position with its own unique `positionId` and a fresh `depositTime = block.timestamp`. The new position starts vesting from `m = 0`.
2. Existing positions continue to vest independently according to their respective `depositTime`s.

---

## Positions and Partial Exit Semantics

Since the contract implements a multi-position model (multiple position IDs per address) and supports partial withdraws, users have native control over their exits. A user can:

- Deposit in separate batches to have distinct vesting timelines (separate positions).
- Partially withdraw from a specific position to access some liquidity while leaving the rest of the position to continue vesting under its original `depositTime`.

---

## Properties summary

| Property               | Mechanism                                                                                                                                                                                                                                                                                                                |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Per-user vesting curve | `m = 0` if `elapsed < cliff` else `(elapsed/term)²` if `elapsed < term` else `1` (quadratic ease-in with a discontinuous jump at `cliff` from `0` to `(cliff/term)²`). The `cliff` and `term` are mutable by the admin, dynamically changing the vested/unvested portion of accrued yield without affecting total yield. |
| Position model         | Multiple positions per address (tracked by positionId), supports partial withdraws                                                                                                                                                                                                                                       |
| Principal              | Always paid out on `withdraw()` (even before cliff)                                                                                                                                                                                                                                                                      |
| Forfeited yield        | Stays in vault, increasing surplus; `TAKER_ROLE` can withdraw assets via unrestricted `take()` balance withdrawal                                                                                                                                                                                                        |
| Identity binding       | Position owner must call `withdraw` (as `msg.sender`), but can specify any `recipient` address; `deposit` always creates a position for `msg.sender`                                                                                                                                                                     |
| Non-fungible           | No ERC20 surface; no allowance; no transfer                                                                                                                                                                                                                                                                              |
| Upgradeability         | Upgradeable — implementation uses UUPS proxy pattern; admin can upgrade                                                                                                                                                                                                                                                  |
