// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { HandlerBase } from "./HandlerBase.sol";

contract AdminHandler is HandlerBase {

    address public admin;
    address public setter;
    address public taker;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE         = keccak256("TAKER_ROLE");

    uint256 constant FOUR_PCT_VSR  = 1.000000001243680656318820312e27;
    uint256 constant FORTY_PCT_VSR = 1.000000010669464688489416886e27;

    constructor(address vault_) HandlerBase(vault_) {
        admin  = vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        setter = vault.getRoleMember(SETTER_ROLE,        0);
        taker  = vault.getRoleMember(TAKER_ROLE,         0);
    }

    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        minVsr_ = _bound(minVsr_, RAY,     FOUR_PCT_VSR);
        maxVsr_ = _bound(maxVsr_, minVsr_, FORTY_PCT_VSR);

        vm.prank(admin);
        vault.setVsrBounds(minVsr_, maxVsr_);
    }

    function setVsr(uint256 vsr_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        vsr_ = _bound(vsr_, vault.minVsr(), vault.maxVsr());

        vm.prank(setter);
        vault.setVsr(vsr_);
    }

    function setMaxLiabilityCap(uint256 cap_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        uint256 currentLiability = vault.maxLiability();

        cap_ = _bound(cap_, currentLiability, currentLiability + MAX_AMOUNT);

        vm.prank(admin);
        vault.setMaxLiabilityCap(cap_);
    }

    function setCliff(uint64 cliff_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        cliff_ = uint64(_bound(cliff_, 0, uint256(vault.term())));

        vm.prank(admin);
        vault.setCliff(cliff_);
    }

    function setTerm(uint64 term_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        term_ = uint64(_bound(term_, vault.cliff(), 100 * 365 days));

        vm.prank(admin);
        vault.setTerm(term_);
    }

    function take(uint256 amount_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        amount_ = _bound(amount_, 0, asset.balanceOf(address(vault)));

        vm.startPrank(taker);
        vault.take(amount_);
        vm.stopPrank();
    }

}
