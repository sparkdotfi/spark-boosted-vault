// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC20Mock }    from "../../lib/oz/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { ISparkBoostedVault } from "../../src/ISparkBoostedVault.sol";
import { SparkBoostedVault }  from "../../src/SparkBoostedVault.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

contract SparkBoostedVaultInvariantTestBase is Test {

    uint256 public constant RAY   = 1e27;
    uint64  public constant TERM  = 365 days;
    uint64  public constant CLIFF = 90 days;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE         = keccak256("TAKER_ROLE");

    address internal admin  = makeAddr("admin");
    address internal setter = makeAddr("setter");
    address internal taker  = makeAddr("taker");

    ERC20Mock         internal asset;
    SparkBoostedVault internal vault;

    AdminHandler    internal adminHandler;
    ExternalHandler internal externalHandler;
    UserHandler     internal userHandler;

    function setUp() public virtual {
        asset = new ERC20Mock();

        vault = SparkBoostedVault(
            address(new ERC1967Proxy(
                address(new SparkBoostedVault()),
                abi.encodeCall(SparkBoostedVault.initialize, (address(asset), admin, TERM, CLIFF))
            ))
        );

        vm.startPrank(admin);

        vault.grantRole(SETTER_ROLE, setter);
        vault.grantRole(TAKER_ROLE,  taker);

        vault.setMaxLiabilityCap(type(uint256).max);

        vm.stopPrank();
    }

    /**********************************************************************************************/
    /*** Vault Invariant Helpers                                                                ***/
    /**********************************************************************************************/

    function vaultInvariant_A_sumPositionSharesEqTotalShares() public view {
        uint256 sum;
        uint256 n = userHandler.numPositionIds();

        for (uint256 i = 0; i < n; i++) {
            ISparkBoostedVault.Position memory pos = vault.getPosition(userHandler.positionIds(i));

            if (pos.depositTime != 0) sum += pos.shares;
        }

        assertEq(sum, vault.totalShares(), "invariant A: sum(position.shares) != totalShares");
    }

    function vaultInvariant_B_sumPositionPrincipalsEqTotalPrincipal() public view {
        uint256 sum;
        uint256 n = userHandler.numPositionIds();

        for (uint256 i = 0; i < n; i++) {
            ISparkBoostedVault.Position memory pos = vault.getPosition(userHandler.positionIds(i));

            if (pos.depositTime != 0) sum += pos.principal;
        }

        assertEq(
            sum,
            vault.totalPrincipal(),
            "invariant B: sum(position.principal) != totalPrincipal"
        );
    }

    function vaultInvariant_C_maxDepositFormula() public view {
        uint256 cap_       = vault.maxLiabilityCap();
        uint256 liability_ = vault.maxLiability();
        uint256 expected_  = cap_ > liability_ ? cap_ - liability_ : 0;

        assertEq(vault.maxDeposit(), expected_, "invariant C: maxDeposit formula mismatch");
    }

    function vaultInvariant_D_vsr() public view {
        assertGe(vault.vsr(),    RAY,             "invariant D: vsr < RAY");
        assertGe(vault.minVsr(), RAY,             "invariant D: minVsr < RAY");
        assertLe(vault.maxVsr(), vault.MAX_VSR(), "invariant D: maxVsr > MAX_VSR");
        assertLe(vault.minVsr(), vault.maxVsr(),  "invariant D: minVsr > maxVsr");
    }

    /**********************************************************************************************/
    /*** Position Invariant Helpers                                                             ***/
    /**********************************************************************************************/

    function positionInvariant_A_yield(uint256 positionId_) public view {
        ISparkBoostedVault.Position memory pos = vault.getPosition(positionId_);

        uint256 rawAssets_ = pos.shares * vault.nowChi() / RAY;
        uint256 expected_  = rawAssets_ > pos.principal ? rawAssets_ - pos.principal : 0;

        assertEq(
            vault.yieldOf(positionId_),
            expected_,
            string(abi.encodePacked("invariant pos-A: yieldOf mismatch for id ", vm.toString(positionId_)))
        );
    }

    function positionInvariant_B_vestedYieldLeYield(uint256 positionId_) public view {
        assertLe(
            vault.vestedYieldOf(positionId_),
            vault.yieldOf(positionId_),
            string(abi.encodePacked("invariant pos-B: vestedYield > yield for id ", vm.toString(positionId_)))
        );
    }

    function positionInvariant_C_vestingMultiplierBounds(uint256 positionId_) public view {
        uint256 multiplier_ = vault.vestingMultiplierOf(positionId_);

        assertLe(multiplier_, RAY,
            string(abi.encodePacked("invariant pos-C: vestingMultiplier > RAY for id ", vm.toString(positionId_)))
        );
    }

    function positionInvariant_D_maxWithdrawBounds(uint256 positionId_) public view {
        assertLe(
            vault.maxWithdrawOf(positionId_),
            vault.withdrawableOf(positionId_),
            string(abi.encodePacked("invariant pos-D: maxWithdraw > withdrawable for id ", vm.toString(positionId_)))
        );
        assertLe(
            vault.maxWithdrawOf(positionId_),
            asset.balanceOf(address(vault)),
            string(abi.encodePacked("invariant pos-D: maxWithdraw > vault balance for id ", vm.toString(positionId_)))
        );
    }

    function positionInvariant_E_postCliffMultiplierGtZero(uint256 positionId_) public view {
        ISparkBoostedVault.Position memory pos = vault.getPosition(positionId_);

        if (block.timestamp - pos.depositTime >= vault.cliff()) {
            assertGt(
                vault.vestingMultiplierOf(positionId_),
                0,
                string(abi.encodePacked("invariant pos-E: multiplier == 0 after cliff for id ", vm.toString(positionId_)))
            );
        }
    }

    function positionInvariant_F_postTermMultiplierEqRay(uint256 positionId_) public view {
        ISparkBoostedVault.Position memory pos = vault.getPosition(positionId_);

        if (block.timestamp - pos.depositTime >= vault.term()) {
            assertEq(
                vault.vestingMultiplierOf(positionId_),
                RAY,
                string(abi.encodePacked("invariant pos-F: multiplier != RAY after term for id ", vm.toString(positionId_)))
            );
        }
    }

    /**********************************************************************************************/
    /*** Bank Run Simulation                                                                    ***/
    /**********************************************************************************************/

    function simulateBankRun() public {
        uint256 n = userHandler.numPositionIds();

        for (uint256 i = 0; i < n; i++) {
            skip(2 minutes);

            uint256 positionId_ = userHandler.positionIds(i);
            if (vault.getPosition(positionId_).depositTime == 0) continue;

            address owner_       = userHandler.positionOwner(positionId_);
            uint256 withdrawable = vault.withdrawableOf(positionId_);
            uint256 liquidity    = asset.balanceOf(address(vault));

            if (withdrawable == 0) continue;

            vm.startPrank(owner_);

            if (liquidity >= withdrawable) {
                vault.withdraw(positionId_, owner_);

                assertEq(vault.getPosition(positionId_).depositTime, 0, "position not closed after full withdraw");
            } else if (liquidity > 0) {
                vault.withdraw(positionId_, liquidity, owner_);

                assertEq(asset.balanceOf(address(vault)), 0, "vault not drained after partial withdraw");
            }

            vm.stopPrank();
        }
    }

    /**********************************************************************************************/
    /*** Helper Function                                                                        ***/
    /**********************************************************************************************/

    function _give(uint256 amount_) internal {
        address taker_ = adminHandler.taker();

        deal(address(asset), taker_, amount_);

        vm.prank(taker_);
        asset.transfer(address(vault), amount_);
    }

}
