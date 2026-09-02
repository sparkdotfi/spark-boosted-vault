// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { SparkBoostedVaultInvariantTestBase } from "./InvariantsBase.t.sol";

import { AdminHandler }    from "./handlers/AdminHandler.sol";
import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

contract SparkBoostedVaultInvariantTest is SparkBoostedVaultInvariantTestBase {

    function setUp() public override {
        super.setUp();

        adminHandler    = new AdminHandler(address(vault));
        externalHandler = new ExternalHandler(address(vault));
        userHandler     = new UserHandler(address(vault), 25);

        // Explicit selectors for every handler so recording hooks are never fuzzed.
        targetContract(address(adminHandler));
        targetContract(address(externalHandler));
        targetContract(address(userHandler));

        bytes4[] memory adminSelectors_ = new bytes4[](7);
        adminSelectors_[0] = AdminHandler.setVsrBounds.selector;
        adminSelectors_[1] = AdminHandler.setVsr.selector;
        adminSelectors_[2] = AdminHandler.setMaxLiabilityCap.selector;
        adminSelectors_[3] = AdminHandler.setCliff.selector;
        adminSelectors_[4] = AdminHandler.setTerm.selector;
        adminSelectors_[5] = AdminHandler.take.selector;
        adminSelectors_[6] = AdminHandler.upgrade.selector;

        targetSelector(FuzzSelector({ addr: address(adminHandler), selectors: adminSelectors_ }));

        bytes4[] memory externalSelectors_ = new bytes4[](3);
        externalSelectors_[0] = ExternalHandler.warp.selector;
        externalSelectors_[1] = ExternalHandler.drip.selector;
        externalSelectors_[2] = ExternalHandler.give.selector;

        targetSelector(FuzzSelector({ addr: address(externalHandler), selectors: externalSelectors_ }));

        bytes4[] memory userSelectors_ = new bytes4[](5);
        userSelectors_[0] = UserHandler.deposit.selector;
        userSelectors_[1] = UserHandler.depositWithReferral.selector;
        userSelectors_[2] = UserHandler.depositMax.selector;
        userSelectors_[3] = UserHandler.withdraw.selector;
        userSelectors_[4] = UserHandler.partialWithdraw.selector;

        targetSelector(FuzzSelector({ addr: address(userHandler), selectors: userSelectors_ }));
    }

    /**********************************************************************************************/
    /*** Invariants                                                                             ***/
    /**********************************************************************************************/

    function invariant_vaultInvariants() public {
        this.vaultInvariant_A_sumPositionSharesEqTotalShares();
        this.vaultInvariant_B_sumPositionPrincipalsEqTotalPrincipal();
        this.vaultInvariant_C_maxDepositFormula();
        this.vaultInvariant_D_vsr();
        this.vaultInvariant_E_assetAccounting();
        this.vaultInvariant_F_liabilityCoversWithdrawable();
        this.vaultInvariant_G_roles();
        this.vaultInvariant_H_chiRhoSanity();
        this.vaultInvariant_I_sequentialPositionIds();
    }

    function invariant_positionInvariants() public {
        uint256 n = userHandler.numPositionIds();

        for (uint256 i = 0; i < n; i++) {
            uint256 positionId_ = userHandler.positionIds(i);
            if (vault.getPosition(positionId_).depositTime == 0) continue;

            this.positionInvariant_A_yield(positionId_);
            this.positionInvariant_B_vestedYieldLeYield(positionId_);
            this.positionInvariant_C_vestingMultiplierBounds(positionId_);
            this.positionInvariant_D_maxWithdrawBounds(positionId_);
            this.positionInvariant_E_postCliffMultiplierGtZero(positionId_);
            this.positionInvariant_F_postTermMultiplierEqRay(positionId_);
            this.positionInvariant_G_openPositionSanity(positionId_);
        }
    }

    /**********************************************************************************************/
    /*** Post-Invariant                                                                         ***/
    /**********************************************************************************************/

    function afterInvariant() public {
        this.simulateBankRun();
        _checkInvariantsOverTime();

        skip(TERM);

        _give(vault.maxLiability());
        _checkInvariantsOverTime();

        adminHandler.setVsrBounds(RAY, RAY);
        adminHandler.setVsr(RAY);

        // `maxLiability + totalPrincipal` always covers the sum of withdrawables, including
        // vesting growth during the bank run, so every position can fully exit.
        uint256 needed_  = vault.maxLiability() + vault.totalPrincipal();
        uint256 balance_ = asset.balanceOf(address(vault));

        if (needed_ > balance_) {
            _give(needed_ - balance_);
        }

        this.simulateBankRun();
        _checkInvariantsOverTime();

        assertEq(vault.totalShares(),    0, "afterInvariant: totalShares != 0 after full exit");
        assertEq(vault.totalPrincipal(), 0, "afterInvariant: totalPrincipal != 0 after full exit");
        assertEq(vault.maxLiability(),   0, "afterInvariant: maxLiability != 0 after full exit");

        for (uint256 i = 0; i < userHandler.numUsers(); i++) {
            assertEq(
                vault.getPositionIdsOf(userHandler.users(i)).length,
                0,
                "afterInvariant: user still owns positions after full exit"
            );
        }
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        this.invariant_vaultInvariants();
        this.invariant_positionInvariants();

        uint256 sumWithdrawableBefore_ = _sumWithdrawable();

        skip(30 minutes);

        // With no interactions, withdrawable amounts can only grow over time.
        assertGe(
            _sumWithdrawable(),
            sumWithdrawableBefore_,
            "checkInvariantsOverTime: withdrawable sum decreased over time"
        );

        this.invariant_vaultInvariants();
        this.invariant_positionInvariants();
    }

}
