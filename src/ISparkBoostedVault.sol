// SPDX-License-Identifier: AGPL-3.0-or-later

// Copyright (C) 2021 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.35;

import {
    IAccessControlEnumerable
} from "../lib/oz/contracts/access/extensions/IAccessControlEnumerable.sol";

interface ISparkBoostedVault is IAccessControlEnumerable {

    /**********************************************************************************************/
    /*** Structs                                                                                ***/
    /**********************************************************************************************/

    /**
     * @notice Represents a user's deposit position in the vault.
     * @param  principal   Asset amount the account has put in, minus any withdrawn principal.
     * @param  shares      Raw rate-based shares; raw assets = shares * chi / RAY.
     * @param  depositTime Effective deposit time.
     */
    struct Position {
        uint256 principal;
        uint256 shares;
        uint64  depositTime;
    }

    /**********************************************************************************************/
    /*** Events                                                                                 ***/
    /**********************************************************************************************/

    /**
     * @notice The deposit event.
     * @param  account    The address depositing the assets.
     * @param  positionId The unique identifier of the position.
     * @param  assets     The amount of underlying assets deposited.
     * @param  shares     The raw rate-based shares credited to the position.
     * @param  referral   The 16-bit referral identifier.
     */
    event Deposit(
        address indexed account,
        uint256 indexed positionId,
        uint256         assets,
        uint256         shares,
        uint16  indexed referral
    );

    /**
     * @notice Emitted when the maximum liability cap is updated.
     * @param  cap New cap [asset units].
     */
    event MaxLiabilityCapSet(uint256 cap);

    /**
     * @notice Emitted when the vesting cliff is updated.
     * @param  cliff New cliff [seconds].
     */
    event CliffSet(uint64 cliff);

    /**
     * @notice Emitted every time drip() is called at a new rho.
     * @param  chi  The new rate accumulator value after the drip [ray].
     * @param  diff The approximate change in aggregate raw total assets [asset units].
     */
    event Drip(uint256 chi, uint256 diff);

    /**
     * @notice Emitted when an account with TAKER_ROLE withdraws assets.
     * @param  to     The TAKER_ROLE recipient.
     * @param  assets The amount taken [asset units]
     */
    event Take(address indexed to, uint256 assets);

    /**
     * @notice Emitted when the vesting term is updated.
     * @param  term New term [seconds].
     */
    event TermSet(uint64 term);

    /**
     * @notice Emitted when the VSR bounds are updated.
     * @param  minVsr New minimum [ray].
     * @param  maxVsr New maximum [ray].
     */
    event VsrBoundsSet(uint256 minVsr, uint256 maxVsr);

    /**
     * @notice Emitted when the VSR is updated.
     * @param  vsr The new VSR [ray].
     */
    event VsrSet(uint256 vsr);

    /**
     * @notice Emitted when a withdraw occurs.
     * @param  account    The position owner whose state was reduced.
     * @param  positionId The unique identifier of the position.
     * @param  recipient  The address to withdraw assets to.
     * @param  assets     The amount of underlying assets sent to receiver.
     * @param  shares     The raw rate-based shares burned from the position.
     */
    event Withdraw(
        address indexed account,
        uint256 indexed positionId,
        address indexed recipient,
        uint256         assets,
        uint256         shares
    );

    /**********************************************************************************************/
    /*** Custom Errors                                                                          ***/
    /**********************************************************************************************/

    /**
     * @notice Thrown when the vesting cliff duration is greater than the total vault term.
     * @param  cliff The vesting cliff duration [seconds].
     * @param  term  The total vesting term [seconds].
     */
    error CliffGreaterThanTerm(uint64 cliff, uint64 term);

    /**
     * @notice Thrown when the contract lacks sufficient liquidity to execute a transfer.
     * @param  amount    The requested transfer amount [asset units].
     * @param  liquidity The available contract balance [asset units].
     */
    error InsufficientLiquidity(uint256 amount, uint256 liquidity);

    /**
     * @notice Thrown when withdrawing more assets than are currently withdrawable from the
     *         position.
     * @param  assets       The requested withdrawal amount [asset units].
     * @param  withdrawable The maximum assets currently withdrawable [asset units].
     */
    error InsufficientWithdrawable(uint256 assets, uint256 withdrawable);

    /**
     * @notice Thrown when a deposit would exceed the maximum deposit amount.
     * @param  assets     The attempted deposit amount [asset units].
     * @param  maxDeposit The maximum deposit amount [asset units].
     */
    error MaxDepositExceeded(uint256 assets, uint256 maxDeposit);

    /**
     * @notice Thrown when the VSR bounds are set such that the minimum is greater than the maximum.
     * @param  minVsr The proposed minimum Vault Savings Rate [ray].
     * @param  maxVsr The proposed maximum Vault Savings Rate [ray].
     */
    error MinVsrGreaterThanMaxVsr(uint256 minVsr, uint256 maxVsr);

    /**
     * @notice Thrown when the caller is not the owner of the specified position.
     */
    error NotPositionOwner();

    /**
     * @notice Thrown when the VSR is above the maximum allowed bound.
     * @param  vsr    The attempted Vault Savings Rate [ray].
     * @param  maxVsr The maximum allowed Vault Savings Rate [ray].
     */
    error VsrTooHigh(uint256 vsr, uint256 maxVsr);

    /**
     * @notice Thrown when the VSR is below the minimum allowed bound.
     * @param  vsr    The attempted Vault Savings Rate [ray].
     * @param  minVsr The minimum allowed Vault Savings Rate [ray].
     */
    error VsrTooLow(uint256 vsr, uint256 minVsr);

    /// @notice Thrown when the admin address is address(0).
    error ZeroAdmin();

    /// @notice Thrown when the underlying asset is address(0).
    error ZeroAsset();

    /// @notice Thrown when the deposit amount or resulting shares is zero.
    error ZeroDeposit();

    /**
     * @notice Thrown when trying to withdraw from a position that does not exist or has zero
     *         withdrawable assets.
     */
    error ZeroPosition();

    /// @notice Thrown when a withdrawal would result in zero shares or zero assets withdrawn.
    error ZeroWithdrawal();

    /**********************************************************************************************/
    /*** Interactive Functions                                                                  ***/
    /**********************************************************************************************/

    /**
     * @notice Deposits specified assets into the vault with a referral tracker, creating a new
     *         position.
     * @dev    Updates the rate accumulator (drips) before depositing.
     *         Reverts if total assets exceeds max liability cap.
     * @param  assets_     The amount of underlying assets to deposit.
     * @param  referral_   The 16-bit referral identifier for tracking user acquisition.
     * @return positionId_ The unique identifier of the newly created position.
     */
    function deposit(uint256 assets_, uint16 referral_) external returns (uint256 positionId_);

    /**
     * @notice Deposits specified assets into the vault, creating a new position.
     * @dev    Updates the rate accumulator (drips) before depositing.
     *         Reverts if total assets exceeds max liability cap.
     * @param  assets_     The amount of underlying assets to deposit.
     * @return positionId_ The unique identifier of the newly created position.
     */
    function deposit(uint256 assets_) external returns (uint256 positionId_);

    /**
     * @notice Updates the rate accumulator (chi) based on the elapsed time and current Vault
     *         Savings Rate (VSR).
     * @dev    Calculates the new chi value based on: new_chi = old_chi * (vsr)^delta_t / RAY.
     *         Updates the last update timestamp (rho) to the current block timestamp.
     */
    function drip() external;

    /**
     * @notice Initializes the boosted vault implementation with core configuration.
     * @dev    Can only be called once. Sets initial storage parameters, sets chi/vsr/minVsr/maxVsr
     *         to RAY, sets rho to block.timestamp, and grants DEFAULT_ADMIN_ROLE to `admin_`.
     * @param  asset_ The address of the underlying asset.
     * @param  admin_ The address to be granted the admin role.
     * @param  term_  The total vesting duration [seconds].
     * @param  cliff_ The vesting cliff duration [seconds], must be less than or equal to `term_`.
     */
    function initialize(address asset_, address admin_, uint64 term_, uint64 cliff_) external;

    /**
     * @notice Sets the vesting cliff duration for the vault.
     * @dev    Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The cliff must be less than or equal to the term.
     * @param  cliff_ The new vesting cliff duration [seconds].
     */
    function setCliff(uint64 cliff_) external;

    /**
     * @notice Sets the maximum liability cap for the vault.
     * @dev    Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         Deposits are disabled if they would cause the total liability to exceed this cap.
     * @param  cap_ The new maximum liability cap [asset units].
     */
    function setMaxLiabilityCap(uint256 cap_) external;

    /**
     * @notice Sets the total vault term.
     * @dev    Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         The term must be greater than or equal to the cliff.
     * @param  term_ The new total vault term [seconds].
     */
    function setTerm(uint64 term_) external;

    /**
     * @notice Sets the Vault Savings Rate (VSR).
     * @dev    Can only be called by accounts with SETTER_ROLE.
     *         Triggers a drip update before updating the rate.
     *         The rate must be within the configured min/max bounds.
     * @param  vsr_ The new VSR value [ray].
     */
    function setVsr(uint256 vsr_) external;

    /**
     * @notice Sets the minimum and maximum bounds for the Vault Savings Rate (VSR).
     * @dev    Can only be called by accounts with DEFAULT_ADMIN_ROLE.
     *         Ensures minVsr_ is at least RAY, maxVsr_ is at most MAX_VSR, and minVsr_ <= maxVsr_.
     * @param  minVsr_ The new minimum allowed VSR value [ray].
     * @param  maxVsr_ The new maximum allowed VSR value [ray].
     */
    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_) external;

    /**
     * @notice Allows authorized accounts with TAKER_ROLE to withdraw assets from the vault.
     * @dev    Transfers the specified amount of underlying assets to the caller.
     * @param  assets_ The amount of assets to withdraw [asset units].
     */
    function take(uint256 assets_) external;

    /**
     * @notice Withdraws all assets from a specific position.
     * @dev    Updates the rate accumulator (drips) before executing.
     *         Zeros shares and principal.
     *         Reverts if caller is not the owner of the position, or if position does not exist.
     * @param  positionId_ The unique identifier of the position.
     * @param  recipient_  The address to withdraw assets to.
     */
    function withdraw(uint256 positionId_, address recipient_) external;

    /**
     * @notice Withdraws assets from a specific position.
     * @dev    Updates the rate accumulator (drips) before executing.
     *         Reduces shares and principal proportionally based on the withdrawable assets.
     *         Reverts if caller is not the owner of the position, or if position does not exist.
     * @param  positionId_ The unique identifier of the position.
     * @param  assets_     The amount of underlying assets to withdraw.
     * @param  recipient_  The address to withdraw assets to.
     */
    function withdraw(uint256 positionId_, uint256 assets_, address recipient_) external;

    /**********************************************************************************************/
    /*** Variables                                                                              ***/
    /**********************************************************************************************/

    /// @notice Returns the absolute maximum allowed Vault Savings Rate (VSR).
    function MAX_VSR() external view returns (uint256);

    /// @notice Returns the precision multiplier representing 1.0 (1e27).
    function RAY() external view returns (uint256);

    /// @notice Returns the identifier of the role that can set the VSR.
    function SETTER_ROLE() external view returns (bytes32);

    /// @notice Returns the identifier of the role that can take assets.
    function TAKER_ROLE() external view returns (bytes32);

    /// @notice Returns the implementation version string.
    function VERSION() external view returns (string memory);

    /// @notice Returns the address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Returns the rate accumulator (chi) as of the last drip.
    function chi() external view returns (uint192);

    /// @notice Returns the vesting cliff duration configured for positions.
    function cliff() external view returns (uint64);

    /**
     * @notice Returns the maximum amount of assets that can be currently deposited.
     * @dev    Calculated as the difference between the max liability cap and the current total
     *         liability.
     */
    function maxDeposit() external view returns (uint256);

    /**
     * @notice Returns the current total share-valued liability of the vault calculated up to the
     *         current block timestamp.
     * @dev    Since shares are rounded down on deposit while principal is stored in full, this can
     *         be below the sum of `withdrawableOf()` by up to `chi / RAY + 1` units per position.
     */
    function maxLiability() external view returns (uint256);

    /**
     * @notice Returns the maximum liability cap of the vault.
     * @dev    Gates new deposits only. `maxLiability()` grows with `chi` and can exceed this cap.
     */
    function maxLiabilityCap() external view returns (uint256);

    /// @notice Returns the maximum allowed VSR value.
    function maxVsr() external view returns (uint256);

    /// @notice Returns the minimum allowed VSR value.
    function minVsr() external view returns (uint256);

    /// @notice Returns the rate accumulator (chi) calculated up to the current block timestamp.
    function nowChi() external view returns (uint256);

    /// @notice Returns the timestamp of the last drip operation.
    function rho() external view returns (uint64);

    /// @notice Returns the total vesting duration configured for positions.
    function term() external view returns (uint64);

    /// @notice Returns the total principal deposited across all active positions.
    function totalPrincipal() external view returns (uint256);

    /// @notice Returns the total shares issued across all active positions.
    function totalShares() external view returns (uint256);

    /// @notice Returns the current Vault Savings Rate (VSR).
    function vsr() external view returns (uint256);

    /**********************************************************************************************/
    /*** View/Pure Functions                                                                    ***/
    /**********************************************************************************************/

    /**
     * @notice Returns the details of a specific position.
     * @param  positionId_ The unique identifier of the position.
     * @return position_   The Position struct details.
     */
    function getPosition(uint256 positionId_) external view returns (Position memory position_);

    /**
     * @notice Returns all position identifiers owned by a specific account.
     * @param  account_     The address of the owner account.
     * @return positionIds_ An array of position identifiers.
     */
    function getPositionIdsOf(address account_)
        external
        view
        returns (uint256[] memory positionIds_);

    /**
     * @notice Returns all position details owned by a specific account.
     * @param  account_   The address of the owner account.
     * @return positions_ An array of Position structs.
     */
    function getPositionsOf(address account_) external view returns (Position[] memory positions_);

    /**
     * @notice Returns the maximum assets that can be withdrawn from a position, constrained by
     *         contract liquidity.
     * @param  positionId_  The unique identifier of the position.
     * @return maxWithdraw_ The maximum withdrawable amount [asset units].
     */
    function maxWithdrawOf(uint256 positionId_) external view returns (uint256 maxWithdraw_);

    /**
     * @notice Returns the unvested yield of a position.
     * @param  positionId_    The unique identifier of the position.
     * @return unvestedYield_ The amount of unvested yield [asset units].
     */
    function unvestedYieldOf(uint256 positionId_) external view returns (uint256 unvestedYield_);

    /**
     * @notice Returns the vested yield of a position.
     * @param  positionId_  The unique identifier of the position.
     * @return vestedYield_ The amount of vested yield [asset units].
     */
    function vestedYieldOf(uint256 positionId_) external view returns (uint256 vestedYield_);

    /**
     * @notice Returns the vesting multiplier [ray] for the user's `positionId_`.
     *         A return of 0 means none of the yield has vested.
     *         A return of RAY means yield is fully vested.
     * @param  positionId_ The unique identifier of the position.
     * @return multiplier_ The vesting multiplier [ray].
     */
    function vestingMultiplierOf(uint256 positionId_) external view returns (uint256 multiplier_);

    /**
     * @notice Returns the total withdrawable assets of a position (principal + vested yield).
     * @param  positionId_   The unique identifier of the position.
     * @return withdrawable_ The amount of withdrawable assets [asset units].
     */
    function withdrawableOf(uint256 positionId_) external view returns (uint256 withdrawable_);

    /**
     * @notice Returns the total yield (both vested and unvested) accrued by a position.
     * @param  positionId_ The unique identifier of the position.
     * @return yield_      The total yield [asset units].
     */
    function yieldOf(uint256 positionId_) external view returns (uint256 yield_);

    /**
     * @notice Checks if the contract supports a specific interface.
     * @param  interfaceId_ The interface identifier, as specified in ERC-165.
     * @return isSupported_ True if the contract supports the interface, false otherwise.
     */
    function supportsInterface(bytes4 interfaceId_) external view returns (bool isSupported_);

}
