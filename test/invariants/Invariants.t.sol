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

        // Foundry calls all external functions on targeted contracts.
        targetContract(address(adminHandler));
        targetContract(address(externalHandler));

        bytes4[] memory selectors_ = new bytes4[](4);
        selectors_[0] = UserHandler.deposit.selector;
        selectors_[1] = UserHandler.depositWithReferral.selector;
        selectors_[2] = UserHandler.withdraw.selector;
        selectors_[3] = UserHandler.partialWithdraw.selector;

        targetSelector(FuzzSelector({ addr: address(userHandler), selectors: selectors_ }));
    }

    /**********************************************************************************************/
    /*** Invariants                                                                             ***/
    /**********************************************************************************************/

    function invariant_vaultInvariants() public {
        this.vaultInvariant_A_sumPositionSharesEqTotalShares();
        this.vaultInvariant_B_sumPositionPrincipalsEqTotalPrincipal();
        this.vaultInvariant_C_maxDepositFormula();
        this.vaultInvariant_D_vsr();
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

        uint256 gap = vault.maxLiability();
        if (gap > asset.balanceOf(address(vault))) {
            _give(gap - asset.balanceOf(address(vault)));
        }

        this.simulateBankRun();
        _checkInvariantsOverTime();

        assertEq(vault.totalShares(),    0, "afterInvariant: totalShares != 0 after full exit");
        assertEq(vault.totalPrincipal(), 0, "afterInvariant: totalPrincipal != 0 after full exit");
        assertEq(vault.maxLiability(),   0, "afterInvariant: maxLiability != 0 after full exit");
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        this.invariant_vaultInvariants();
        this.invariant_positionInvariants();

        skip(30 minutes);

        this.invariant_vaultInvariants();
        this.invariant_positionInvariants();
    }

}
