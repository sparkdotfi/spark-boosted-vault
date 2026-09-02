// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { SparkBoostedVault } from "../../../src/SparkBoostedVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract AdminHandler is HandlerBase {

    address public admin;
    address public setter;
    address public taker;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE         = keccak256("TAKER_ROLE");

    // Ghost variable tracking assets taken out of the vault by the taker.
    uint256 public ghostTotalTaken;

    // Spare implementations to exercise UUPS upgrades against identical bytecode.
    SparkBoostedVault[2] internal spareImplementations;

    constructor(address vault_) HandlerBase(vault_) {
        admin  = vault.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        setter = vault.getRoleMember(SETTER_ROLE,        0);
        taker  = vault.getRoleMember(TAKER_ROLE,         0);

        spareImplementations[0] = new SparkBoostedVault();
        spareImplementations[1] = new SparkBoostedVault();
    }

    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_)
        public
        vaultTotalAmountsNeverChange
        chiNeverDecreases
    {
        minVsr_ = _bound(minVsr_, RAY,     vault.MAX_VSR());
        maxVsr_ = _bound(maxVsr_, minVsr_, vault.MAX_VSR());

        vm.prank(admin);
        vault.setVsrBounds(minVsr_, maxVsr_);

        assertEq(vault.minVsr(), minVsr_, "setVsrBounds: minVsr not set");
        assertEq(vault.maxVsr(), maxVsr_, "setVsrBounds: maxVsr not set");
    }

    function setVsr(uint256 vsr_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        vsr_ = _bound(vsr_, vault.minVsr(), vault.maxVsr());

        vm.prank(setter);
        vault.setVsr(vsr_);

        assertEq(vault.vsr(),          vsr_,            "setVsr: vsr not set");
        assertEq(vault.rho(),          block.timestamp, "setVsr: rho not updated by drip");
        assertEq(uint256(vault.chi()), vault.nowChi(),  "setVsr: chi not updated by drip");
    }

    function setMaxLiabilityCap(uint256 cap_)
        public
        vaultTotalAmountsNeverChange
        chiNeverDecreases
    {
        // Allow caps below the current liability to exercise the maxDeposit() == 0 paths.
        cap_ = _bound(cap_, 0, vault.maxLiability() + MAX_AMOUNT);

        vm.prank(admin);
        vault.setMaxLiabilityCap(cap_);

        assertEq(vault.maxLiabilityCap(), cap_, "setMaxLiabilityCap: cap not set");
    }

    function setCliff(uint64 cliff_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        cliff_ = uint64(_bound(cliff_, 0, uint256(vault.term())));

        vm.prank(admin);
        vault.setCliff(cliff_);

        assertEq(vault.cliff(), cliff_, "setCliff: cliff not set");
    }

    function setTerm(uint64 term_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        term_ = uint64(_bound(term_, vault.cliff(), 100 * 365 days));

        vm.prank(admin);
        vault.setTerm(term_);

        assertEq(vault.term(), term_, "setTerm: term not set");
    }

    function take(uint256 amount_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        amount_ = _bound(amount_, 0, asset.balanceOf(address(vault)));

        uint256 vaultBalanceBefore_ = asset.balanceOf(address(vault));
        uint256 takerBalanceBefore_ = asset.balanceOf(taker);

        vm.startPrank(taker);
        vault.take(amount_);
        vm.stopPrank();

        ghostTotalTaken += amount_;

        assertEq(
            asset.balanceOf(address(vault)), vaultBalanceBefore_ - amount_,
            "take: vault balance delta mismatch"
        );
        assertEq(
            asset.balanceOf(taker), takerBalanceBefore_ + amount_,
            "take: taker balance delta mismatch"
        );
    }

    function upgrade(uint256 seed_) public vaultTotalAmountsNeverChange chiNeverDecreases {
        address implementation_ = address(spareImplementations[seed_ % 2]);

        address asset_           = vault.asset();
        uint256 vsrBefore_       = vault.vsr();
        uint256 minVsrBefore_    = vault.minVsr();
        uint256 maxVsrBefore_    = vault.maxVsr();
        uint256 capBefore_       = vault.maxLiabilityCap();
        uint64  rhoBefore_       = vault.rho();
        uint64  termBefore_      = vault.term();
        uint64  cliffBefore_     = vault.cliff();

        vm.prank(admin);
        vault.upgradeToAndCall(implementation_, "");

        assertEq(vault.VERSION(), "1.0.0",       "upgrade: VERSION changed");
        assertEq(vault.asset(),   asset_,        "upgrade: asset changed");
        assertEq(vault.vsr(),     vsrBefore_,    "upgrade: vsr changed");
        assertEq(vault.minVsr(),  minVsrBefore_, "upgrade: minVsr changed");
        assertEq(vault.maxVsr(),  maxVsrBefore_, "upgrade: maxVsr changed");
        assertEq(vault.rho(),     rhoBefore_,    "upgrade: rho changed");
        assertEq(vault.term(),    termBefore_,   "upgrade: term changed");
        assertEq(vault.cliff(),   cliffBefore_,  "upgrade: cliff changed");

        assertEq(vault.maxLiabilityCap(), capBefore_, "upgrade: maxLiabilityCap changed");

        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "upgrade: admin role lost");
    }

}
