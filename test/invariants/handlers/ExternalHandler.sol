// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { HandlerBase } from "./HandlerBase.sol";

contract ExternalHandler is HandlerBase {

    // Cap cumulative warping so extreme-depth campaigns cannot push chi towards overflow.
    uint256 public constant MAX_TOTAL_WARP = 20 * 365 days;

    // Ghost variables tracking donations and elapsed fuzzed time.
    uint256 public ghostTotalGiven;
    uint256 public ghostTotalWarped;

    constructor(address vault_) HandlerBase(vault_) {}

    function warp(uint256 secs_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        secs_ = _bound(secs_, 0, _min(10 days, MAX_TOTAL_WARP - ghostTotalWarped));

        ghostTotalWarped += secs_;

        uint256 timestampBefore_ = block.timestamp;

        vm.warp(block.timestamp + secs_);

        assertEq(block.timestamp, timestampBefore_ + secs_, "warp: timestamp mismatch");
    }

    function drip() public vaultTotalAmountsNeverChange chiNeverDecreases {
        vault.drip();

        assertEq(vault.rho(), block.timestamp,         "drip: rho not updated");
        assertEq(uint256(vault.chi()), vault.nowChi(), "drip: chi not synced to nowChi");

        uint192 chiAfter_ = vault.chi();

        // Drip is idempotent within the same block.
        vault.drip();

        assertEq(vault.chi(), chiAfter_,        "drip: second drip changed chi");
        assertEq(vault.rho(), block.timestamp,  "drip: second drip changed rho");
    }

    function give(uint256 amount_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        amount_ = _bound(amount_, 0, MAX_AMOUNT);

        _give(amount_);
    }

    /**********************************************************************************************/
    /*** Recording Hooks (test-driven flows, never fuzz targets)                                ***/
    /**********************************************************************************************/

    function giveExact(uint256 amount_) external {
        _give(amount_);
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _give(uint256 amount_) internal {
        deal(address(asset), address(this), amount_);

        uint256 vaultBalanceBefore_ = asset.balanceOf(address(vault));

        assertTrue(asset.transfer(address(vault), amount_), "give: transfer failed");

        ghostTotalGiven += amount_;

        assertEq(
            asset.balanceOf(address(vault)), vaultBalanceBefore_ + amount_,
            "give: vault balance delta mismatch"
        );
    }

}
