// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { HandlerBase } from "./HandlerBase.sol";

contract ExternalHandler is HandlerBase {

    constructor(address vault_) HandlerBase(vault_) {}

    function warp(uint256 secs_) public {
        secs_ = _bound(secs_, 0, 10 days);

        vm.warp(block.timestamp + secs_);
    }

    function drip() public {
        vault.drip();
    }

    function give(uint256 amount_) public {
        amount_ = _bound(amount_, 0, MAX_AMOUNT);

        deal(address(asset), address(this), amount_);

        asset.transfer(address(vault), amount_);
    }

}
