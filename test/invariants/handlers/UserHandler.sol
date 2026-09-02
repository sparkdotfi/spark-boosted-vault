// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { Math } from "../../../lib/oz/contracts/utils/math/Math.sol";

import { ISparkBoostedVault } from "../../../src/ISparkBoostedVault.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    uint256 public numUsers;

    address[] public users;

    uint256[] internal _positionIds;

    mapping(uint256 positionId => address owner) public positionOwner;

    // Ghost variables tracking every asset flow and structural change driven by users.
    uint256 public ghostTotalDeposited;        // Assets pulled into the vault via deposits.
    uint256 public ghostTotalWithdrawn;        // Assets paid out of the vault via withdrawals.
    uint256 public ghostDepositCount;          // Successful deposits (mirrors vault positionCount).
    uint256 public ghostPartialWithdrawCount;  // Successful partial withdrawals.

    constructor(address vault_, uint256 numUsers_) HandlerBase(vault_) {
        numUsers = numUsers_;

        for (uint256 i = 0; i < numUsers_; i++) {
            users.push(makeAddr(string(abi.encodePacked("user", i))));
        }
    }

    function numPositionIds() external view returns (uint256) {
        return _positionIds.length;
    }

    function positionIds(uint256 index_) external view returns (uint256) {
        return _positionIds[index_];
    }

    /**********************************************************************************************/
    /*** Fuzzed Actions                                                                         ***/
    /**********************************************************************************************/

    function deposit(uint256 assetAmount_, uint32 userIndex_) public chiNeverDecreases {
        uint256 maxDeposit_ = vault.maxDeposit();
        if (maxDeposit_ == 0) return;

        assetAmount_ = _bound(assetAmount_, 1, _min(maxDeposit_, MAX_AMOUNT));

        _deposit(_randomUser(userIndex_), assetAmount_, 0, false);
    }

    function depositWithReferral(
        uint256 assetAmount_,
        uint16  referral_,
        uint32  userIndex_
    ) public chiNeverDecreases {
        uint256 maxDeposit_ = vault.maxDeposit();
        if (maxDeposit_ == 0) return;

        assetAmount_ = _bound(assetAmount_, 1, _min(maxDeposit_, MAX_AMOUNT));

        _deposit(_randomUser(userIndex_), assetAmount_, referral_, true);
    }

    // Regression for SC-1611: depositing exactly `maxDeposit()` must never revert.
    function depositMax(uint32 userIndex_, uint16 referral_) public chiNeverDecreases {
        uint256 maxDeposit_ = vault.maxDeposit();
        if (maxDeposit_ == 0) return;

        if (maxDeposit_ > MAX_AMOUNT) maxDeposit_ = MAX_AMOUNT;

        _deposit(_randomUser(userIndex_), maxDeposit_, referral_, referral_ % 2 == 0);
    }

    function withdraw(uint256 indexSeed_, uint32 recipientIndex_) public chiNeverDecreases {
        uint256 positionId_ = _randomOpenPositionId(indexSeed_);
        if (positionId_ == 0) return;

        uint256 withdrawable_ = vault.withdrawableOf(positionId_);

        // Open positions always have principal > 0, so withdrawable is never zero.
        assertGt(withdrawable_, 0, "withdraw: open position with zero withdrawable");

        if (withdrawable_ > asset.balanceOf(address(vault))) return;

        address owner_     = positionOwner[positionId_];
        address recipient_ = _randomUser(recipientIndex_);

        ISparkBoostedVault.Position memory position_ = vault.getPosition(positionId_);

        uint256 totalSharesBefore_    = vault.totalShares();
        uint256 totalPrincipalBefore_ = vault.totalPrincipal();
        uint256 vaultBalanceBefore_   = asset.balanceOf(address(vault));
        uint256 recipientBalance_     = asset.balanceOf(recipient_);

        vm.prank(owner_);
        vault.withdraw(positionId_, recipient_);

        ghostTotalWithdrawn += withdrawable_;

        assertEq(
            vault.getPosition(positionId_).depositTime, 0,
            "withdraw: position not closed after full withdraw"
        );
        assertEq(
            vault.totalShares(), totalSharesBefore_ - position_.shares,
            "withdraw: totalShares delta mismatch"
        );
        assertEq(
            vault.totalPrincipal(), totalPrincipalBefore_ - position_.principal,
            "withdraw: totalPrincipal delta mismatch"
        );
        assertEq(
            asset.balanceOf(address(vault)), vaultBalanceBefore_ - withdrawable_,
            "withdraw: vault balance delta mismatch"
        );
        assertEq(
            asset.balanceOf(recipient_), recipientBalance_ + withdrawable_,
            "withdraw: recipient balance delta mismatch"
        );
        assertFalse(
            _ownerHasPosition(owner_, positionId_),
            "withdraw: position id not removed from owner set"
        );
    }

    struct PartialWithdrawState {
        address owner;
        address recipient;
        uint256 expectedSharePortion;
        uint256 expectedPrincipalPortion;
        uint256 totalSharesBefore;
        uint256 totalPrincipalBefore;
        uint256 vaultBalanceBefore;
        uint256 recipientBalanceBefore;
        bool    expectClose;
    }

    function partialWithdraw(
        uint256 indexSeed_,
        uint256 assets_,
        uint32  recipientIndex_
    ) public chiNeverDecreases {
        uint256 positionId_ = _randomOpenPositionId(indexSeed_);
        if (positionId_ == 0) return;

        uint256 maxWithdraw_ = vault.maxWithdrawOf(positionId_);
        if (maxWithdraw_ == 0) return;

        assets_ = _bound(assets_, 1, maxWithdraw_);

        uint256 withdrawable_ = vault.withdrawableOf(positionId_);

        ISparkBoostedVault.Position memory position_ = vault.getPosition(positionId_);

        PartialWithdrawState memory s_;

        s_.owner     = positionOwner[positionId_];
        s_.recipient = _randomUser(recipientIndex_);

        s_.expectedSharePortion     = Math.ceilDiv(position_.shares * assets_,    withdrawable_);
        s_.expectedPrincipalPortion = Math.ceilDiv(position_.principal * assets_, withdrawable_);

        s_.expectClose =
            s_.expectedSharePortion >= position_.shares ||
            s_.expectedPrincipalPortion >= position_.principal;

        s_.totalSharesBefore      = vault.totalShares();
        s_.totalPrincipalBefore   = vault.totalPrincipal();
        s_.vaultBalanceBefore     = asset.balanceOf(address(vault));
        s_.recipientBalanceBefore = asset.balanceOf(s_.recipient);

        vm.prank(s_.owner);
        vault.withdraw(positionId_, assets_, s_.recipient);

        ghostTotalWithdrawn += assets_;
        ghostPartialWithdrawCount++;

        if (s_.expectClose) {
            assertEq(
                vault.getPosition(positionId_).depositTime, 0,
                "partialWithdraw: position not closed"
            );
            assertEq(
                vault.totalShares(), s_.totalSharesBefore - position_.shares,
                "partialWithdraw: totalShares delta mismatch on close"
            );
            assertEq(
                vault.totalPrincipal(), s_.totalPrincipalBefore - position_.principal,
                "partialWithdraw: totalPrincipal delta mismatch on close"
            );
            assertFalse(
                _ownerHasPosition(s_.owner, positionId_),
                "partialWithdraw: position id not removed from owner set on close"
            );
        } else {
            ISparkBoostedVault.Position memory after_ = vault.getPosition(positionId_);

            assertEq(
                after_.shares, position_.shares - s_.expectedSharePortion,
                "partialWithdraw: position shares mismatch"
            );
            assertEq(
                after_.principal, position_.principal - s_.expectedPrincipalPortion,
                "partialWithdraw: position principal mismatch"
            );
            assertEq(after_.depositTime, position_.depositTime, "partialWithdraw: depositTime changed");
            assertEq(
                vault.totalShares(), s_.totalSharesBefore - s_.expectedSharePortion,
                "partialWithdraw: totalShares delta mismatch"
            );
            assertEq(
                vault.totalPrincipal(), s_.totalPrincipalBefore - s_.expectedPrincipalPortion,
                "partialWithdraw: totalPrincipal delta mismatch"
            );
            assertTrue(
                _ownerHasPosition(s_.owner, positionId_),
                "partialWithdraw: open position id missing from owner set"
            );
        }

        assertEq(
            asset.balanceOf(address(vault)), s_.vaultBalanceBefore - assets_,
            "partialWithdraw: vault balance delta mismatch"
        );
        assertEq(
            asset.balanceOf(s_.recipient), s_.recipientBalanceBefore + assets_,
            "partialWithdraw: recipient balance delta mismatch"
        );
    }

    /**********************************************************************************************/
    /*** Recording Hooks (test-driven flows, never fuzz targets)                                ***/
    /**********************************************************************************************/

    function noteExternalWithdraw(uint256 assets_) external {
        ghostTotalWithdrawn += assets_;
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _deposit(address user_, uint256 assetAmount_, uint16 referral_, bool useReferral_)
        internal
    {
        uint256 chiNow_         = vault.nowChi();
        uint256 expectedShares_ = assetAmount_ * RAY / chiNow_;

        if (expectedShares_ == 0) return;

        uint256 totalSharesBefore_    = vault.totalShares();
        uint256 totalPrincipalBefore_ = vault.totalPrincipal();
        uint256 vaultBalanceBefore_   = asset.balanceOf(address(vault));

        deal(address(asset), user_, assetAmount_);

        vm.startPrank(user_);

        asset.approve(address(vault), assetAmount_);

        uint256 positionId_ = useReferral_
            ? vault.deposit(assetAmount_, referral_)
            : vault.deposit(assetAmount_);

        vm.stopPrank();

        ghostDepositCount++;
        ghostTotalDeposited += assetAmount_;

        _positionIds.push(positionId_);

        positionOwner[positionId_] = user_;

        assertEq(positionId_, ghostDepositCount, "deposit: positionId not sequential");

        ISparkBoostedVault.Position memory position_ = vault.getPosition(positionId_);

        assertEq(position_.principal,   assetAmount_,    "deposit: position principal mismatch");
        assertEq(position_.shares,      expectedShares_, "deposit: position shares mismatch");
        assertEq(position_.depositTime, block.timestamp, "deposit: position depositTime mismatch");

        assertEq(
            vault.totalShares(), totalSharesBefore_ + expectedShares_,
            "deposit: totalShares delta mismatch"
        );
        assertEq(
            vault.totalPrincipal(), totalPrincipalBefore_ + assetAmount_,
            "deposit: totalPrincipal delta mismatch"
        );
        assertEq(
            asset.balanceOf(address(vault)), vaultBalanceBefore_ + assetAmount_,
            "deposit: vault balance delta mismatch"
        );

        uint256[] memory ids_ = vault.getPositionIdsOf(user_);

        assertEq(ids_[ids_.length - 1], positionId_, "deposit: position id not appended to owner set");
    }

    function _ownerHasPosition(address owner_, uint256 positionId_) internal view returns (bool) {
        uint256[] memory ids_ = vault.getPositionIdsOf(owner_);

        for (uint256 i = 0; i < ids_.length; i++) {
            if (ids_[i] == positionId_) return true;
        }

        return false;
    }

    function _randomOpenPositionId(uint256 seed_) internal view returns (uint256) {
        if (_positionIds.length == 0) return 0;

        uint256 positionId_ = _positionIds[_bound(seed_, 0, _positionIds.length - 1)];

        return vault.getPosition(positionId_).depositTime == 0 ? 0 : positionId_;
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

}
