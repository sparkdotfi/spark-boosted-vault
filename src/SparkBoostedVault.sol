// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { IERC20 }    from "../lib/oz/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "../lib/oz/contracts/token/ERC20/utils/SafeERC20.sol";

import { EnumerableSet } from "../lib/oz/contracts/utils/structs/EnumerableSet.sol";
import { Math }          from "../lib/oz/contracts/utils/math/Math.sol";

import {
    AccessControlEnumerableUpgradeable
} from "../lib/oz-upgradeable/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";

import { UUPSUpgradeable } from "../lib/oz-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";

import { ISparkBoostedVault } from "./ISparkBoostedVault.sol";

/*

  ███████╗██████╗  █████╗ ██████╗ ██╗  ██╗
  ██╔════╝██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝
  ███████╗██████╔╝███████║██████╔╝█████╔╝
  ╚════██║██╔═══╝ ██╔══██║██╔══██╗██╔═██╗
  ███████║██║     ██║  ██║██║  ██║██║  ██╗
  ╚══════╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝

  ██████╗  ██████╗  ██████╗ ███████╗████████╗███████╗██████╗
  ██╔══██╗██╔═══██╗██╔═══██╗██╔════╝╚══██╔══╝██╔════╝██╔══██╗
  ██████╔╝██║   ██║██║   ██║███████╗   ██║   █████╗  ██║  ██║
  ██╔══██╗██║   ██║██║   ██║╚════██║   ██║   ██╔══╝  ██║  ██║
  ██████╔╝╚██████╔╝╚██████╔╝███████║   ██║   ███████╗██████╔╝
  ╚═════╝  ╚═════╝  ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝╚═════╝

  ██╗   ██╗ █████╗ ██╗   ██╗██╗  ████████╗
  ██║   ██║██╔══██╗██║   ██║██║  ╚══██╔══╝
  ██║   ██║███████║██║   ██║██║     ██║
  ╚██╗ ██╔╝██╔══██║██║   ██║██║     ██║
   ╚████╔╝ ██║  ██║╚██████╔╝███████╗██║
    ╚═══╝  ╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝

*/

contract SparkBoostedVault is ISparkBoostedVault, UUPSUpgradeable, AccessControlEnumerableUpgradeable {

    using EnumerableSet for EnumerableSet.UintSet;

    /**********************************************************************************************/
    /*** Vault Storage                                                                          ***/
    /**********************************************************************************************/

    /// @custom:storage-location erc7201:spark.storage.SparkBoostedVault.v1
    struct VaultStorage {
        address asset;
        uint192 chi;
        uint256 maxLiabilityCap;
        uint256 maxVsr;
        uint256 minVsr;
        uint256 positionCount;
        uint256 totalPrincipal;
        uint256 totalShares;
        uint256 vsr;
        uint64  cliff;
        uint64  rho;
        uint64  term;
        mapping (address account    => EnumerableSet.UintSet positionIdSet) positionIdSets;
        mapping (uint256 positionId => Position position)                   positions;
    }

    // keccak256(abi.encode(uint256(keccak256("spark.storage.SparkBoostedVault.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant VAULT_STORAGE_LOCATION =
        0x2172e6ff7d5a8d9d53591d5f3f1d2be5b532667b6d54094ee3cc625fe343d900;

    function _getVaultStorage() internal pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VAULT_STORAGE_LOCATION
        }
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    // This corresponds to a 100% APY, verify here:
    // bc -l <<< 'scale=27; e( l(2)/(60 * 60 * 24 * 365) )'
    /// @inheritdoc ISparkBoostedVault
    uint256 public constant override MAX_VSR = 1.000000021979553151239153027e27;

    /// @inheritdoc ISparkBoostedVault
    uint256 public constant override RAY = 1e27;

    /// @inheritdoc ISparkBoostedVault
    bytes32 public constant override SETTER_ROLE = keccak256("SETTER_ROLE");

    /// @inheritdoc ISparkBoostedVault
    bytes32 public constant override TAKER_ROLE  = keccak256("TAKER_ROLE");

    /// @inheritdoc ISparkBoostedVault
    string public constant override VERSION = "1.0.0";

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        _disableInitializers();  // Avoid initializing in the context of the implementation.
    }

    /**********************************************************************************************/
    /*** Initializer                                                                            ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function initialize(address asset_, address admin_, uint64 term_, uint64 cliff_)
        external
        override
        initializer
    {
        require(asset_ != address(0), ZeroAsset());
        require(admin_ != address(0), ZeroAdmin());
        require(cliff_ <= term_,      CliffGreaterThanTerm(cliff_, term_));

        VaultStorage storage $ = _getVaultStorage();

        $.asset  = asset_;
        $.chi    = uint192(RAY);
        $.cliff  = cliff_;
        $.maxVsr = RAY;
        $.minVsr = RAY;
        $.rho    = uint64(block.timestamp);
        $.term   = term_;
        $.vsr    = RAY;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /**********************************************************************************************/
    /*** External Interactive Admin Functions                                                   ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function setMaxLiabilityCap(uint256 cap_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxLiabilityCapSet(_getVaultStorage().maxLiabilityCap = cap_);
    }

    /// @inheritdoc ISparkBoostedVault
    function setVsrBounds(uint256 minVsr_, uint256 maxVsr_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(minVsr_ >= RAY,     VsrTooLow(minVsr_, RAY));
        require(maxVsr_ <= MAX_VSR, VsrTooHigh(maxVsr_, MAX_VSR));
        require(minVsr_ <= maxVsr_, MinVsrGreaterThanMaxVsr(minVsr_, maxVsr_));

        VaultStorage storage $ = _getVaultStorage();

        emit VsrBoundsSet($.minVsr = minVsr_, $.maxVsr = maxVsr_);
    }

    /// @inheritdoc ISparkBoostedVault
    function setCliff(uint64 cliff_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _getVaultStorage();

        require(cliff_ <= $.term, CliffGreaterThanTerm(cliff_, $.term));

        emit CliffSet(msg.sender, $.cliff = cliff_);
    }

    /// @inheritdoc ISparkBoostedVault
    function setTerm(uint64 term_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        VaultStorage storage $ = _getVaultStorage();

        require(term_ >= $.cliff, CliffGreaterThanTerm($.cliff, term_));

        emit TermSet(msg.sender, $.term = term_);
    }

    /**********************************************************************************************/
    /*** External Interactive Setter Functions                                                  ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function setVsr(uint256 vsr_) external override onlyRole(SETTER_ROLE) {
        VaultStorage storage $ = _getVaultStorage();

        require(vsr_ >= $.minVsr, VsrTooLow(vsr_, $.minVsr));
        require(vsr_ <= $.maxVsr, VsrTooHigh(vsr_, $.maxVsr));

        drip();

        emit VsrSet(msg.sender, $.vsr = vsr_);
    }

    /**********************************************************************************************/
    /*** External Interactive Taker Functions                                                   ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function take(uint256 assets_) external override onlyRole(TAKER_ROLE) {
        emit Take(msg.sender, assets_);

        _pushAsset(msg.sender, assets_);
    }

    /**********************************************************************************************/
    /*** External Interactive Functions                                                         ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function drip() public override {
        VaultStorage storage $ = _getVaultStorage();

        uint256 rho_ = $.rho;

        if (block.timestamp <= rho_) return;

        uint256 chi_    = $.chi;
        uint256 nowChi_ = nowChi();

        // Safe as `nowChi_` is limited to `maxUint256/RAY`, which is less than `type(uint192).max`.
        $.chi = uint192(nowChi_);
        $.rho = uint64(block.timestamp);

        uint256 totalShares_ = $.totalShares;

        emit Drip(nowChi_, ((totalShares_ * nowChi_) / RAY) - ((totalShares_ * chi_) / RAY));
    }

    /// @inheritdoc ISparkBoostedVault
    function deposit(uint256 assets_) external override returns (uint256 positionId_) {
        return _deposit(assets_, 0);
    }

    /// @inheritdoc ISparkBoostedVault
    function deposit(uint256 assets_, uint16 referral_)
        external
        override
        returns (uint256 positionId_)
    {
        return _deposit(assets_, referral_);
    }

    /// @inheritdoc ISparkBoostedVault
    function withdraw(uint256 positionId_, address recipient_) external override {
        _withdraw(positionId_, withdrawableOf(positionId_), recipient_);
    }

    /// @inheritdoc ISparkBoostedVault
    function withdraw(uint256 positionId_, uint256 assets_, address recipient_) external override {
        _withdraw(positionId_, assets_, recipient_);
    }

    /**********************************************************************************************/
    /*** External Variable Getters                                                              ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function asset() external view override returns (address) {
        return _getVaultStorage().asset;
    }

    /// @inheritdoc ISparkBoostedVault
    function chi() external view override returns (uint192) {
        return _getVaultStorage().chi;
    }

    /// @inheritdoc ISparkBoostedVault
    function cliff() external view override returns (uint64) {
        return _getVaultStorage().cliff;
    }

    /// @inheritdoc ISparkBoostedVault
    function maxDeposit() external view override returns (uint256) {
        uint256 maxLiability_    = maxLiability();
        uint256 maxLiabilityCap_ = _getVaultStorage().maxLiabilityCap;

        if (maxLiability_ >= maxLiabilityCap_) return 0;

        uint256 remainingCapacity_ = maxLiabilityCap_ - maxLiability_;
        uint256 minDeposit_        = Math.ceilDiv(nowChi(), RAY);

        // require at least minDeposit to mint 1 share; otherwise return 0 if at capacity
        return remainingCapacity_ >= minDeposit_ ? remainingCapacity_ : 0;
    }

    /// @inheritdoc ISparkBoostedVault
    function maxLiability() public view override returns (uint256) {
        return _getVaultStorage().totalShares * nowChi() / RAY;
    }

    /// @inheritdoc ISparkBoostedVault
    function maxLiabilityCap() external view override returns (uint256) {
        return _getVaultStorage().maxLiabilityCap;
    }

    /// @inheritdoc ISparkBoostedVault
    function maxVsr() external view override returns (uint256) {
        return _getVaultStorage().maxVsr;
    }

    /// @inheritdoc ISparkBoostedVault
    function minVsr() external view override returns (uint256) {
        return _getVaultStorage().minVsr;
    }

    /// @inheritdoc ISparkBoostedVault
    function nowChi() public view override returns (uint256) {
        VaultStorage storage $ = _getVaultStorage();

        return (block.timestamp > $.rho)
            ? _rpow($.vsr, block.timestamp - $.rho) * $.chi / RAY
            : $.chi;
    }

    /// @inheritdoc ISparkBoostedVault
    function rho() external view override returns (uint64) {
        return _getVaultStorage().rho;
    }

    /// @inheritdoc ISparkBoostedVault
    function term() external view override returns (uint64) {
        return _getVaultStorage().term;
    }

    /// @inheritdoc ISparkBoostedVault
    function totalPrincipal() external view override  returns (uint256) {
        return _getVaultStorage().totalPrincipal;
    }

    /// @inheritdoc ISparkBoostedVault
    function totalShares() external view override returns (uint256) {
        return _getVaultStorage().totalShares;
    }

    /// @inheritdoc ISparkBoostedVault
    function vsr() external view override returns (uint256) {
        return _getVaultStorage().vsr;
    }

    /**********************************************************************************************/
    /*** External View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    /// @inheritdoc ISparkBoostedVault
    function getPosition(uint256 positionId_) external view override returns (Position memory) {
        return _getVaultStorage().positions[positionId_];
    }

    /// @inheritdoc ISparkBoostedVault
    function getPositionIdsOf(address account_) external view override returns (uint256[] memory) {
        return _getVaultStorage().positionIdSets[account_].values();
    }

    /// @inheritdoc ISparkBoostedVault
    function getPositionsOf(address account_)
        external
        view
        override
        returns (Position[] memory positions_)
    {
        VaultStorage storage $            = _getVaultStorage();
        uint256[]    memory  positionIds_ = $.positionIdSets[account_].values();

        positions_ = new Position[](positionIds_.length);

        for (uint256 i = 0; i < positionIds_.length; ++i) {
            positions_[i] = $.positions[positionIds_[i]];
        }
    }

    /// @inheritdoc ISparkBoostedVault
    function maxWithdrawOf(uint256 positionId_) external view override returns (uint256) {
        uint256 liquidity_    = IERC20(_getVaultStorage().asset).balanceOf(address(this));
        uint256 withdrawable_ = withdrawableOf(positionId_);

        return liquidity_ > withdrawable_ ? withdrawable_ : liquidity_;
    }

    /// @inheritdoc ISparkBoostedVault
    function unvestedYieldOf(uint256 positionId_) external view override returns (uint256) {
        return yieldOf(positionId_) - vestedYieldOf(positionId_);
    }

    /// @inheritdoc ISparkBoostedVault
    function vestedYieldOf(uint256 positionId_) public view override returns (uint256) {
        return (yieldOf(positionId_) * vestingMultiplierOf(positionId_)) / RAY;
    }

    /// @inheritdoc ISparkBoostedVault
    function vestingMultiplierOf(uint256 positionId_) public view override returns (uint256) {
        VaultStorage storage $         = _getVaultStorage();
        Position     storage position_ = $.positions[positionId_];

        uint64 depositTime_ = position_.depositTime;

        if (depositTime_ == 0) return 0;

        uint256 elapsed_ = block.timestamp - depositTime_;

        if (elapsed_ < $.cliff) return 0;

        uint256 term_ = $.term;

        if (elapsed_ >= term_) return RAY;

        // NOTE: `elapsed_` is gated by `elapsed_ < term_` and `term_` is `uint64`, so `elapsed_^2`
        // is at most 2^128. Multiplied by RAY (~2^90) the intermediate fits in `uint256`.
        return (elapsed_ * elapsed_) * RAY / (term_ * term_);
    }

    /// @inheritdoc ISparkBoostedVault
    function withdrawableOf(uint256 positionId_) public view override returns (uint256) {
        Position storage position = _getVaultStorage().positions[positionId_];

        return position.principal + vestedYieldOf(positionId_);
    }

    /// @inheritdoc ISparkBoostedVault
    function yieldOf(uint256 positionId_) public view override returns (uint256) {
        Position storage position_ = _getVaultStorage().positions[positionId_];

        uint256 assets_ = (position_.shares * nowChi()) / RAY;

        return assets_ > position_.principal ? (assets_ - position_.principal) : 0;
    }

    /// @inheritdoc ISparkBoostedVault
    function supportsInterface(bytes4 interfaceId_)
        public
        view
        override(ISparkBoostedVault, AccessControlEnumerableUpgradeable)
        returns (bool)
    {
        return
            interfaceId_ == type(ISparkBoostedVault).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    /**********************************************************************************************/
    /*** Internal Interactive Functions                                                         ***/
    /**********************************************************************************************/

    function _deposit(uint256 assets_, uint16 referral_) internal returns (uint256 positionId_) {
        drip();

        VaultStorage storage $ = _getVaultStorage();

        uint256 maxLiability_ = maxLiability();

        require(
            maxLiability_ + assets_ <= $.maxLiabilityCap,
            MaxLiabilityCapExceeded(maxLiability_ + assets_, $.maxLiabilityCap)
        );

        positionId_ = ++$.positionCount;

        uint256 shares_ = assets_ * RAY / $.chi;

        require(assets_ != 0 && shares_ != 0, ZeroDeposit());

        $.positions[positionId_] = Position({
            principal   : assets_,
            shares      : shares_,
            depositTime : uint64(block.timestamp)
        });

        $.positionIdSets[msg.sender].add(positionId_);

        $.totalShares    += shares_;
        $.totalPrincipal += assets_;

        emit Deposit(msg.sender, positionId_, assets_, shares_, referral_);

        SafeERC20.safeTransferFrom(IERC20($.asset), msg.sender, address(this), assets_);
    }

    function _pushAsset(address to_, uint256 amount_) internal {
        IERC20 asset_ = IERC20(_getVaultStorage().asset);

        uint256 balance = asset_.balanceOf(address(this));

        require(amount_ <= balance, InsufficientLiquidity(amount_, balance));

        SafeERC20.safeTransfer(asset_, to_, amount_);
    }

    function _withdraw(uint256 positionId_, uint256 assets_, address recipient_) internal {
        drip();

        uint256 withdrawable_ = withdrawableOf(positionId_);

        require(withdrawable_ > 0,        ZeroPosition());
        require(assets_ <= withdrawable_, InsufficientWithdrawable(assets_, withdrawable_));

        VaultStorage          storage $              = _getVaultStorage();
        EnumerableSet.UintSet storage positionIdSet_ = $.positionIdSets[msg.sender];

        require(positionIdSet_.contains(positionId_), NotPositionOwner());

        Position storage position_ = $.positions[positionId_];

        uint256 shares_           = position_.shares;
        uint256 principal_        = position_.principal;
        uint256 sharePortion_     = Math.ceilDiv(shares_ * assets_,    withdrawable_);
        uint256 principalPortion_ = Math.ceilDiv(principal_ * assets_, withdrawable_);

        require(assets_ != 0 && sharePortion_ != 0, ZeroWithdrawal());

        if (sharePortion_ >= shares_ || principalPortion_ >= principal_) {
            positionIdSet_.remove(positionId_);

            delete $.positions[positionId_];

            sharePortion_     = shares_;
            principalPortion_ = principal_;
        } else {
            position_.shares    = shares_ - sharePortion_;
            position_.principal = principal_ - principalPortion_;
        }

        $.totalShares    -= sharePortion_;
        $.totalPrincipal -= principalPortion_;

        emit Withdraw(msg.sender, positionId_, assets_, sharePortion_);

        _pushAsset(recipient_, assets_);
    }

    /**********************************************************************************************/
    /*** Internal View/Pure Functions                                                           ***/
    /**********************************************************************************************/

    // Only DEFAULT_ADMIN_ROLE can upgrade the implementation
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // See borrowed implementation:
    // https://github.com/sky-ecosystem/sdai/blob/e6f8cfa1d638b1ef1c6187a1d18f73b21d2754a2/src/SavingsDai.sol#L118
    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

}
