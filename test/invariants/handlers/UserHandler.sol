// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { IERC20Metadata } from "../../../lib/oz/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { HandlerBase } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    uint256 public numUsers;

    address[] public users;

    uint256[] internal _positionIds;

    mapping(uint256 positionId => address owner) public positionOwner;

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

    function deposit(uint256 assetAmount_, uint32 userIndex_) public {
        uint256 maxDeposit = vault.maxDeposit();
        if (maxDeposit < 1 * 10 ** IERC20Metadata(address(asset)).decimals()) return;

        address user = _randomUser(userIndex_);
        assetAmount_ = _bound(assetAmount_, 1 * 10 ** IERC20Metadata(address(asset)).decimals(), _min(maxDeposit, MAX_AMOUNT));

        uint256 shares = assetAmount_ * RAY / vault.chi();
        if (shares == 0) return;

        deal(address(asset), user, assetAmount_);

        vm.startPrank(user);

        asset.approve(address(vault), assetAmount_);

        uint256 positionId_ = vault.deposit(assetAmount_);

        _positionIds.push(positionId_);

        positionOwner[positionId_] = user;

        vm.stopPrank();
    }

    function depositWithReferral(
        uint256 assetAmount_,
        uint16  referral_,
        uint32  userIndex_
    ) public {
        uint256 maxDeposit = vault.maxDeposit();
        if (maxDeposit < 1 * 10 ** IERC20Metadata(address(asset)).decimals()) return;

        address user = _randomUser(userIndex_);
        assetAmount_ = _bound(assetAmount_, 1 * 10 ** IERC20Metadata(address(asset)).decimals(), _min(maxDeposit, MAX_AMOUNT));

        uint256 shares = assetAmount_ * RAY / vault.chi();
        if (shares == 0) return;

        deal(address(asset), user, assetAmount_);

        vm.startPrank(user);

        asset.approve(address(vault), assetAmount_);

        uint256 positionId_ = vault.deposit(assetAmount_, referral_);

        _positionIds.push(positionId_);

        positionOwner[positionId_] = user;

        vm.stopPrank();
    }

    function withdraw(uint256 positionId_) public {
        if (vault.getPosition(positionId_).depositTime == 0) return;

        if (vault.withdrawableOf(positionId_) > asset.balanceOf(address(vault))) return;

        address owner = positionOwner[positionId_];

        vm.prank(owner);
        vault.withdraw(positionId_, owner);
    }

    function partialWithdraw(uint256 positionId_, uint256 assets_) public {
        if (vault.getPosition(positionId_).depositTime == 0) return;

        uint256 maxWithdrawable = vault.maxWithdrawOf(positionId_);
        if (maxWithdrawable == 0) return;

        assets_ = _bound(assets_, 1, maxWithdrawable);

        address owner = positionOwner[positionId_];

        vm.prank(owner);
        vault.withdraw(positionId_, assets_, owner);
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

}
