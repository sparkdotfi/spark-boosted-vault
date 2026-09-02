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
        uint256 nowChi_    = vault.nowChi();
        uint256 actual_    = vault.maxDeposit();

        // Exact mirror of the documented behavior: remaining capacity, zeroed when the vault is
        // at capacity or when the remaining capacity cannot mint at least one share.
        uint256 expected_;
        if (liability_ < cap_) {
            uint256 remaining_  = cap_ - liability_;
            uint256 minDeposit_ = (nowChi_ + RAY - 1) / RAY;

            expected_ = remaining_ >= minDeposit_ ? remaining_ : 0;
        }

        assertEq(actual_, expected_, "invariant C: maxDeposit mismatch");

        if (actual_ != 0) {
            assertLe(actual_, cap_ - liability_, "invariant C: maxDeposit exceeds capacity");

            // A non-zero maxDeposit must always mint at least one share (SC-1611).
            if (actual_ <= type(uint256).max / RAY) {
                assertGe(actual_ * RAY / nowChi_, 1, "invariant C: maxDeposit mints zero shares");
            }
        }
    }

    function vaultInvariant_D_vsr() public view {
        assertGe(vault.vsr(),    RAY,             "invariant D: vsr < RAY");
        assertLe(vault.vsr(),    vault.MAX_VSR(), "invariant D: vsr > MAX_VSR");
        assertGe(vault.minVsr(), RAY,             "invariant D: minVsr < RAY");
        assertLe(vault.maxVsr(), vault.MAX_VSR(), "invariant D: maxVsr > MAX_VSR");
        assertLe(vault.minVsr(), vault.maxVsr(),  "invariant D: minVsr > maxVsr");
    }

    function vaultInvariant_E_assetAccounting() public view {
        uint256 expected_ =
            userHandler.ghostTotalDeposited() +
            externalHandler.ghostTotalGiven() -
            userHandler.ghostTotalWithdrawn() -
            adminHandler.ghostTotalTaken();

        assertEq(
            asset.balanceOf(address(vault)),
            expected_,
            "invariant E: vault balance != net recorded flows"
        );
    }

    function vaultInvariant_F_liabilityCoversWithdrawable() public view {
        uint256 sum_ = _sumWithdrawable();

        // Each deposit and each partial withdrawal can leave at most ~(nowChi / RAY + 2) wei of
        // rounding slack where a position's principal exceeds its share value.
        uint256 ops_   = userHandler.ghostDepositCount() + userHandler.ghostPartialWithdrawCount();
        uint256 slack_ = ops_ * (vault.nowChi() / RAY + 2);

        assertLe(
            sum_,
            vault.maxLiability() + slack_,
            "invariant F: sum(withdrawableOf) > maxLiability + rounding slack"
        );
    }

    function vaultInvariant_G_roles() public view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin), "invariant G: admin role lost");
        assertTrue(vault.hasRole(SETTER_ROLE, setter),       "invariant G: setter role lost");
        assertTrue(vault.hasRole(TAKER_ROLE, taker),         "invariant G: taker role lost");

        assertEq(
            vault.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1,
            "invariant G: unexpected admin count"
        );
    }

    function vaultInvariant_H_chiRhoSanity() public view {
        assertGe(uint256(vault.chi()), RAY,                  "invariant H: chi < RAY");
        assertLe(vault.rho(),          block.timestamp,      "invariant H: rho in the future");
        assertGe(vault.nowChi(),       uint256(vault.chi()), "invariant H: nowChi < chi");
    }

    function vaultInvariant_I_sequentialPositionIds() public view {
        uint256 count_ = userHandler.ghostDepositCount();

        assertEq(
            userHandler.numPositionIds(), count_,
            "invariant I: tracked position ids != deposit count"
        );

        if (count_ > 0) {
            assertEq(
                userHandler.positionIds(count_ - 1), count_,
                "invariant I: position ids not sequential"
            );
        }
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

        assertEq(
            vault.unvestedYieldOf(positionId_),
            vault.yieldOf(positionId_) - vault.vestedYieldOf(positionId_),
            string(abi.encodePacked("invariant pos-B: unvested + vested != yield for id ", vm.toString(positionId_)))
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

        uint256 elapsed_ = block.timestamp - pos.depositTime;

        if (elapsed_ >= vault.cliff() && elapsed_ > 0) {
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

    function positionInvariant_G_openPositionSanity(uint256 positionId_) public view {
        ISparkBoostedVault.Position memory pos = vault.getPosition(positionId_);

        assertGt(pos.shares,    0, string(abi.encodePacked("invariant pos-G: open position with zero shares for id ", vm.toString(positionId_))));
        assertGt(pos.principal, 0, string(abi.encodePacked("invariant pos-G: open position with zero principal for id ", vm.toString(positionId_))));

        assertLe(
            pos.depositTime,
            block.timestamp,
            string(abi.encodePacked("invariant pos-G: depositTime in the future for id ", vm.toString(positionId_)))
        );

        assertEq(
            vault.withdrawableOf(positionId_),
            pos.principal + vault.vestedYieldOf(positionId_),
            string(abi.encodePacked("invariant pos-G: withdrawable != principal + vestedYield for id ", vm.toString(positionId_)))
        );
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

                userHandler.noteExternalWithdraw(withdrawable);

                assertEq(vault.getPosition(positionId_).depositTime, 0, "position not closed after full withdraw");
            } else if (liquidity > 0) {
                vault.withdraw(positionId_, liquidity, owner_);

                userHandler.noteExternalWithdraw(liquidity);

                assertEq(asset.balanceOf(address(vault)), 0, "vault not drained after partial withdraw");
            }

            vm.stopPrank();
        }
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _give(uint256 amount_) internal {
        externalHandler.giveExact(amount_);
    }

    function _sumWithdrawable() internal view returns (uint256 sum_) {
        uint256 n = userHandler.numPositionIds();

        for (uint256 i = 0; i < n; i++) {
            sum_ += vault.withdrawableOf(userHandler.positionIds(i));
        }
    }

}
