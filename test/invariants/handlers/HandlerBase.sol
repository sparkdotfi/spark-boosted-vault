// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { IERC20 }         from "../../../lib/oz/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "../../../lib/oz/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { SparkBoostedVault } from "../../../src/SparkBoostedVault.sol";

contract HandlerBase is Test {

    uint256 public constant RAY = 1e27;

    uint256 public MAX_AMOUNT;

    IERC20            internal asset;
    SparkBoostedVault internal vault;

    modifier chiNeverDecreases() {
        uint256 nowChiBefore = vault.nowChi();
        _;
        assertGe(vault.nowChi(), nowChiBefore, "invariant: nowChi decreased");
    }

    modifier vaultTotalAmountsNeverChange() {
        uint256 totalPrincipalBefore = vault.totalPrincipal();
        uint256 totalSharesBefore    = vault.totalShares();

        _;

        assertEq(vault.totalPrincipal(), totalPrincipalBefore, "invariant: totalPrincipal changed");
        assertEq(vault.totalShares(),    totalSharesBefore,    "invariant: totalShares changed");
    }

    constructor(address vault_) {
        vault      = SparkBoostedVault(vault_);
        asset      = IERC20(vault.asset());
        MAX_AMOUNT = 10_000_000_000 * 10 ** IERC20Metadata(vault.asset()).decimals();
    }

}
