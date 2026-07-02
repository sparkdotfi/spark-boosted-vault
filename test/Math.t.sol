// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.35;

import { Test } from "../lib/forge-std/src/Test.sol";

import { SparkBoostedVault } from "../src/SparkBoostedVault.sol";

contract SparkBoostedVaultHarness is SparkBoostedVault {

    function rpow(uint256 x, uint256 n) public pure returns (uint256) {
        return super._rpow(x, n);
    }

}

contract RpowTests is Test {

    struct ApyVsrTestCase {
        uint256 apy;
        uint256 vsr;
    }

    struct TestCase {
        uint256 x;
        uint256 n;
        uint256 expected;
    }

    SparkBoostedVaultHarness internal harness;

    function setUp() external {
        harness = new SparkBoostedVaultHarness();
    }

    function fixtureRpow() public pure returns (TestCase[] memory testCases) {
        testCases = new TestCase[](10);

        // Boundary and identity cases.
        testCases[0] = TestCase({ x: 0,    n: 1, expected: 0    });  // 0^1   = 0
        testCases[1] = TestCase({ x: 1e27, n: 0, expected: 1e27 });  // 1.0^0 = 1.0
        testCases[2] = TestCase({ x: 1e27, n: 1, expected: 1e27 });  // 1.0^1 = 1.0
        testCases[3] = TestCase({ x: 1e27, n: 2, expected: 1e27 });  // 1.0^2 = 1.0

        // Exact ray powers (bases > 1 and < 1).
        testCases[4] = TestCase({ x: 2e27,   n: 3, expected: 8e27    });  // 2.0^3 = 8.0
        testCases[5] = TestCase({ x: 1.5e27, n: 2, expected: 2.25e27 });  // 1.5^2 = 2.25
        testCases[6] = TestCase({ x: 0.5e27, n: 2, expected: 0.25e27 });  // 0.5^2 = 0.25
        testCases[7] = TestCase({ x: 0.1e27, n: 3, expected: 1e24    });  // 0.1^3 = 0.001

        testCases[8] = TestCase({ x: 1000000001547125957863212449, n: 365 days, expected: 1049999999999999999994184102 });
        testCases[9] = TestCase({ x: 1000000021979553151239153027, n: 365 days, expected: 1999999999999999999947093656 });

        return testCases;
    }

    function table_rpow(TestCase memory rpow) public view {
        assertEq(harness.rpow(rpow.x, rpow.n), rpow.expected);
    }

    function fixtureApyVsr() public view returns (ApyVsrTestCase[] memory testCases) {
        string memory csv = vm.readFile("test/tables/rpow-apy.csv");
        string[] memory rows = vm.split(csv, "\n");
        testCases = new ApyVsrTestCase[](rows.length);
        for (uint256 i = 0; i < rows.length; i++) {
            testCases[i] = ApyVsrTestCase({
                apy: vm.parseUint(vm.split(rows[i], ",")[0]),
                vsr: vm.parseUint(vm.split(rows[i], ",")[1])
            });
        }
    }

    function table_rpow_apyVsr18Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e18;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 150_000);  // 1.5e-13 difference maximum on 1m
    }

    function table_rpow_apyVsr6Decimals(ApyVsrTestCase memory apyVsr) public view {
        uint256 deposit = 1_000_000e6;

        uint256 depositWithYieldApy = deposit * (10000 + apyVsr.apy) / 10000;
        uint256 depositWithYieldVsr = deposit * harness.rpow(apyVsr.vsr, 365 days) / 1e27;

        assertApproxEqAbs(depositWithYieldApy, depositWithYieldVsr, 1);  // 1 unit of rounding error for 6 decimals
    }

    // Adding this test to demonstrate the upper bound values of rpow instead of failure mode testing.
    // MAX_VSR is 100% APY.
    function test_rpow_upperBoundValues() public {
        uint256 maxVsr = harness.MAX_VSR();

        // Reverts between 75 and 80 years
        vm.expectRevert();
        harness.rpow(maxVsr, 80 * 365 days);

        uint256 maxVsrChi = harness.rpow(maxVsr, 75 * 365 days);

        // 37,778,931,862,957,161,634,615,052,296,000,273,248,252,349,772,281% accrued over 75 years at 100% APY
        // without drip getting called.
        assertEq(maxVsrChi, 3.7778931862957161634615052296000273248252349772281e49);
    }

    function test_rpow_lowerBoundValues() public view {
        uint256 minVsr = 1e27;

        uint256 minVsrChi = harness.rpow(minVsr, 1000 * 365 days);

        assertEq(minVsrChi, 1e27);
    }

}
