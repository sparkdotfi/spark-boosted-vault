# Spark Boosted Vault

![Foundry CI](https://github.com/sparkdotfi/spark-boosted-vault/actions/workflows/merge.yml/badge.svg)
[![Foundry][foundry-badge]][foundry]
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

[foundry]: https://getfoundry.sh/
[foundry-badge]: https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg

## Overview

Spark Boosted Vault is a multi-position, per-user vesting vault. Each user's yield is gated by a custom vesting curve defined by two duration parameters: a **cliff** and a **term**.

While deposited principal is always fully withdrawable, accrued yield is multiplied by a **quadratic ease-in curve** `(elapsed / term)²` ranging from `0` to `1` over the `[0, term]` duration. Any exit before the cliff forfeits 100% of the accrued yield, and early exits before the term forfeit a quadratic portion of the yield. The forfeited yield remains in the vault, increasing the surplus. The authorized `TAKER_ROLE` can withdraw assets from the vault (up to the total contract balance) via the `take` function. Importantly, the `take` function is implemented as an unrestricted balance withdrawal of the underlying asset rather than a restricted harvest of surplus. This design requires trusting the `TAKER` to manage the withdrawn assets and return them to the vault as needed to satisfy user withdrawals.

Unlike typical ERC4626 yield vaults, the Spark Boosted Vault **does not have an ERC20 or ERC4626 interface**. There is no token representation, no transfer system, and no allowances. Instead, each deposit creates a distinct, independent position tracked by a unique `positionId`.

## Features

- **Multi-Position Tracking**: Users can maintain multiple distinct deposits (positions), each vesting on its own timeline.
- **Continuous Rate Accumulation**: Vault yield accumulates continuously per second based on the Vault Savings Rate (`vsr`), updating the rate accumulator (`chi`) dynamically on interaction via `drip()`.
- **Quadratic Vesting Curve**: Restricts yield payout based on a quadratic ramp, concentrating vesting rewards near the end of the term and discouraging early withdrawals.
- **Partial & Full Withdrawals**: Position owners can withdraw their positions either partially (reducing principal and shares proportionally) or fully to any specified recipient address.
- **Unrestricted Balance Withdrawal**: Authorized takers (`TAKER_ROLE`) can withdraw assets from the vault (up to the total current contract balance) to deploy/invest elsewhere, with the expectation to return liquidity as needed to satisfy user withdrawals.
- **Upgradeable**: UUPS upgradeable contract architecture.
- **Role-Based Access Control**: Standardized AccessControl for administrative actions, VSR setters, and takers.
- **Referral System**: Native tracking of referrals during deposits.

## Architecture

### Vesting Multiplier Formula

Let `elapsed = block.timestamp - depositTime`. The vesting multiplier `m(elapsed)` is calculated as:

- `m(elapsed) = 0` if `elapsed < cliff`
- `m(elapsed) = (elapsed / term)²` if `elapsed >= cliff` and `elapsed < term`
- `m(elapsed) = 1` if `elapsed >= term`

### Core Derived Quantities

- `raw_assets = shares * chi / RAY`
- `raw_yield = max(0, raw_assets - principal)`
- `vested_yield = raw_yield * m(elapsed)`
- `withdrawable = principal + vested_yield`

### Contract Structure

```
SparkBoostedVault
├── AccessControlEnumerableUpgradeable
├── UUPSUpgradeable
└── ISparkBoostedVault
```

## Roles & Permissions

- **`DEFAULT_ADMIN_ROLE`**: Can upgrade the implementation, set the maximum liability cap, and update the VSR bounds (`minVsr` / `maxVsr`).
- **`SETTER_ROLE`**: Can update the active Vault Savings Rate (`vsr`) within the allowed bounds.
- **`TAKER_ROLE`**: Can withdraw any amount of assets from the vault (up to the current balance) using `take()`, with the expectation to manage/invest them and return liquidity as needed to satisfy withdrawals.

## Installation & Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Solidity ^0.8.35

### Build

```bash
forge build
```

### Test

```bash
forge test
```
