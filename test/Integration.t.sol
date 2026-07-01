// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { Test } from "../lib/forge-std/src/Test.sol";

import { ERC20Mock }    from "../lib/oz/contracts/mocks/token/ERC20Mock.sol";
import { ERC1967Proxy } from "../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkBoostedVault }  from "../src/SparkBoostedVault.sol";
import { ISparkBoostedVault } from "../src/ISparkBoostedVault.sol";

contract SparkBoostedVaultIntegrationTests is Test {

    uint256 internal constant RAY          = 1e27;
    uint256 internal constant ONE_PCT_VSR  = 1.000000000315522921573372069e27;
    uint256 internal constant FOUR_PCT_VSR = 1.000000001243680656318820312e27;
    uint256 internal constant TEN_PCT_VSR  = 1.000000003022265980097387650e27;
    uint256 internal constant MAX_VSR      = 1.000000021979553151239153027e27;

    uint64 internal constant TERM  = 365 days;
    uint64 internal constant CLIFF = 90 days;

    address internal admin  = makeAddr("admin");
    address internal setter = makeAddr("setter");
    address internal taker  = makeAddr("taker");
    address internal user1  = makeAddr("user1");
    address internal user2  = makeAddr("user2");

    bytes32 internal DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal SETTER_ROLE        = keccak256("SETTER_ROLE");
    bytes32 internal TAKER_ROLE         = keccak256("TAKER_ROLE");

    ERC20Mock         internal asset;
    SparkBoostedVault internal vault;

    function setUp() public virtual {
        asset = new ERC20Mock();

        vault = SparkBoostedVault(
            address(new ERC1967Proxy(
                address(new SparkBoostedVault()),
                abi.encodeCall(
                    SparkBoostedVault.initialize,
                    (address(asset), admin, TERM, CLIFF)
                )
            ))
        );

        vm.startPrank(admin);

        vault.grantRole(SETTER_ROLE, setter);
        vault.grantRole(TAKER_ROLE,  taker);

        vault.setMaxLiabilityCap(1_000_000e6);

        vm.stopPrank();
    }

    // Deposit assets into the vault.
    function _deposit(address user, uint256 amount) internal returns (uint256 positionId) {
        deal(address(asset), user, amount);

        vm.startPrank(user);

        asset.approve(address(vault), amount);

        positionId = vault.deposit(amount);

        vm.stopPrank();
    }

    // Enable yield: open VSR bounds to [RAY, vsrValue] and set VSR.
    function _setVsr(uint256 maxVsr) internal {
        vm.prank(admin);
        vault.setVsrBounds(RAY, maxVsr);

        vm.prank(setter);
        vault.setVsr(maxVsr);
    }

    // Deal the vault's asset balance up to its current maxLiability() so withdrawals succeed.
    function _fundVaultToTotalAssets() internal {
        deal(address(asset), address(vault), vault.maxLiability());
    }

    /**********************************************************************************************/
    /*** Single user e2e tests                                                                  ***/
    /**********************************************************************************************/

    function test_e2e_singleUser_withdrawFullTerm() external {
        uint256 principal = 100_000e6;

        _setVsr(FOUR_PCT_VSR);

        // Step 1: User 1 deposits
        uint256 positionId = _deposit(user1, principal);

        // Step 2: Wait full term
        skip(TERM);

        // Step 3: User withdraws receiving principal + full yield
        assertEq(vault.vestingMultiplierOf(positionId), RAY);
        assertEq(vault.unvestedYieldOf(positionId),     0);

        uint256 yield = vault.yieldOf(positionId);

        assertGt(yield,                          0);                 // shows yield accrued
        assertEq(vault.vestedYieldOf(positionId),  yield);             // shows its entirely vested
        assertEq(vault.withdrawableOf(positionId), principal + yield); // shows its entirely withdrawable

        _fundVaultToTotalAssets();

        vm.prank(user1);
        vault.withdraw(positionId, user1);

        assertEq(asset.balanceOf(user1),          principal + yield);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalShares(),             0);
        assertEq(vault.totalPrincipal(),          0);
        assertEq(vault.maxLiability(),            0);

        ISparkBoostedVault.Position memory position = vault.getPosition(positionId);

        assertEq(position.principal,   0);
        assertEq(position.shares,      0);
        assertEq(position.depositTime, 0);
    }

    function test_e2e_singleUser_exitsBeforeCliff() external {
        uint256 principal = 100_000e6;

        _setVsr(FOUR_PCT_VSR);

        // Step 1: User 1 deposits
        uint256 positionId = _deposit(user1, principal);

        // Step 2: Wait just before cliff
        skip(CLIFF - 1);

        // Step 3: User withdraws receiving only principal
        assertEq(vault.vestingMultiplierOf(positionId), 0);
        assertEq(vault.vestedYieldOf(positionId),       0);
        assertEq(vault.withdrawableOf(positionId),      principal);

        uint256 unvestedYield = vault.unvestedYieldOf(positionId);

        assertGt(unvestedYield, 0);

        _fundVaultToTotalAssets();

        assertEq(asset.balanceOf(address(vault)), principal + unvestedYield);

        vm.prank(user1);
        vault.withdraw(positionId, user1);

        assertEq(asset.balanceOf(user1),          principal);
        assertEq(asset.balanceOf(address(vault)), unvestedYield);
        assertEq(vault.totalShares(),             0);
        assertEq(vault.totalPrincipal(),          0);
        assertEq(vault.maxLiability(),            0);

        // Step 4: Taker claims the forfeited yield
        assertEq(asset.balanceOf(taker),          0);
        assertEq(asset.balanceOf(address(vault)), unvestedYield);

        vm.prank(taker);
        vault.take(unvestedYield);

        assertEq(asset.balanceOf(taker),          unvestedYield);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    function testFuzz_e2e_singleUser_exitsMidVesting(uint256 elapsed) external {
        elapsed = bound(elapsed, CLIFF + 1, TERM - 1);

        uint256 principal = 100_000e6;

        _setVsr(FOUR_PCT_VSR);

        // Step 1: User 1 deposits
        uint256 positionId = _deposit(user1, principal);

        // Step 2: Wait for elapsed time
        skip(elapsed);

        // Step 3: User withdraws receiving partial yield
        uint256 multiplier = vault.vestingMultiplierOf(positionId);
        uint256 yield      = vault.yieldOf(positionId);

        assertGt(multiplier, 0);
        assertLt(multiplier, RAY);

        uint256 expectedVested        = yield * multiplier / RAY;
        uint256 expectedUnvestedYield = yield - expectedVested;

        assertEq(vault.vestedYieldOf(positionId),   expectedVested);
        assertEq(vault.unvestedYieldOf(positionId), expectedUnvestedYield);
        assertEq(vault.withdrawableOf(positionId),  principal + expectedVested);

        _fundVaultToTotalAssets();

        assertEq(asset.balanceOf(user1),          0);
        assertEq(asset.balanceOf(address(vault)), principal + yield);
        assertEq(vault.maxLiability(),            principal + yield);

        vm.prank(user1);
        vault.withdraw(positionId, user1);

        assertEq(asset.balanceOf(user1),          principal + expectedVested);
        assertEq(asset.balanceOf(address(vault)), expectedUnvestedYield);
        assertEq(vault.maxLiability(),            0);
    }

    function test_e2e_singleUser_redepositsAfterFullExit() external {
        uint256 principal = 100_000e6;

        _setVsr(FOUR_PCT_VSR);

        // Step 1: User 1 deposits
        uint256 positionId1 = _deposit(user1, principal);

        // Step 2: Skip to term
        skip(TERM);

        // Step 3: User withdraws receiving principal + full yield
        _fundVaultToTotalAssets();

        uint256 withdrawal1 = vault.withdrawableOf(positionId1);

        assertEq(asset.balanceOf(user1),                   0);
        assertEq(vault.getPosition(positionId1).principal, principal);

        vm.prank(user1);
        vault.withdraw(positionId1, user1);

        assertEq(asset.balanceOf(user1),                   withdrawal1);
        assertEq(vault.getPosition(positionId1).principal, 0);

        // Step 4: User 1 re-deposits
        deal(address(asset), user1, withdrawal1);

        vm.startPrank(user1);
        asset.approve(address(vault), withdrawal1);
        uint256 positionId2 = vault.deposit(withdrawal1);
        vm.stopPrank();

        assertEq(vault.getPosition(positionId2).principal,   withdrawal1);
        assertEq(vault.getPosition(positionId2).depositTime, uint64(block.timestamp));

        skip(TERM);

        _fundVaultToTotalAssets();

        uint256 withdrawal2 = vault.withdrawableOf(positionId2);

        assertGt(withdrawal2, withdrawal1);

        assertEq(asset.balanceOf(user1), 0);
        assertEq(vault.maxLiability(),   withdrawal2);

        vm.prank(user1);
        vault.withdraw(positionId2, user1);

        assertEq(asset.balanceOf(user1), withdrawal2);
        assertEq(vault.maxLiability(),   0);
    }

    /**********************************************************************************************/
    /*** Multi-user tests                                                                       ***/
    /**********************************************************************************************/

    // Two users deposit simultaneously - user1 exits before cliff (forfeits yield),
    // user2 holds to full term and receives all yield.
    function test_e2e_twoUsers_differentExitTimings() external {
        uint256 principal1 = 100_000e6;
        uint256 principal2 = 200_000e6;

        uint256 positionId1 = _deposit(user1, principal1);
        uint256 positionId2 = _deposit(user2, principal2);

        _setVsr(FOUR_PCT_VSR);

        assertEq(vault.totalShares(),    principal1 + principal2);
        assertEq(vault.totalPrincipal(), principal1 + principal2);
        assertEq(vault.maxLiability(),   principal1 + principal2);

        // User1 exits before cliff: forfeits all yield.
        skip(CLIFF - 1);

        uint256 unvestedYield1 = vault.unvestedYieldOf(positionId1);
        uint256 unvestedYield2 = vault.unvestedYieldOf(positionId2);

        assertGt(unvestedYield1, 0);

        assertEq(unvestedYield1,                         vault.yieldOf(positionId1));
        assertEq(vault.vestedYieldOf(positionId1),       0);
        assertEq(vault.vestingMultiplierOf(positionId1), 0);
        assertEq(vault.withdrawableOf(positionId1),      principal1);

        assertGt(unvestedYield2, 0);

        assertEq(unvestedYield2,                         vault.yieldOf(positionId2));
        assertEq(vault.vestedYieldOf(positionId2),       0);
        assertEq(vault.vestingMultiplierOf(positionId2), 0);
        assertEq(vault.withdrawableOf(positionId2),      principal2);

        assertEq(vault.totalPrincipal(), principal1 + principal2);
        assertEq(vault.maxLiability(),   principal1 + unvestedYield1 + principal2 + unvestedYield2);

        assertEq(asset.balanceOf(address(vault)), principal1 + principal2);
        assertEq(asset.balanceOf(user1),          0);
        assertEq(asset.balanceOf(user2),          0);

        vm.prank(user1);
        vault.withdraw(positionId1, user1);
        assertEq(vault.totalPrincipal(), principal2);
        assertEq(vault.maxLiability(),   principal2 + unvestedYield2);

        assertEq(asset.balanceOf(address(vault)), principal2);
        assertEq(asset.balanceOf(user1),          principal1);
        assertEq(asset.balanceOf(user2),          0);

        // User2 holds until their full term (TERM elapsed since original deposit)
        skip(TERM - (CLIFF - 1));

        assertEq(vault.vestingMultiplierOf(positionId2), RAY);

        _fundVaultToTotalAssets();

        uint256 yield2 = vault.yieldOf(positionId2);

        assertGt(yield2, 0);

        assertEq(asset.balanceOf(address(vault)), principal2 + yield2);
        assertEq(asset.balanceOf(user2),          0);

        assertEq(vault.totalPrincipal(), principal2);
        assertEq(vault.maxLiability(),   principal2 + yield2);

        vm.prank(user2);
        vault.withdraw(positionId2, user2);

        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(asset.balanceOf(user2),          principal2 + yield2);

        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.maxLiability(),   0);
    }

}
