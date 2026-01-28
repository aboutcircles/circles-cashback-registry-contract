// SPDX-License-Identifier: AGPL3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CashbackRegistry} from "../src/CashbackRegistry.sol";

contract CashbackRegistryTest is Test {
    CashbackRegistry public registry;
    uint96 startTimestampAtPeriod0 = uint96(block.timestamp);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address chris = makeAddr("chris");
    address zeal = makeAddr("zeal");
    address gApp = makeAddr("gApp");
    address gPay = makeAddr("gPay");
    address admin = makeAddr("admin");
    uint96 initialDuration = 7;
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;

    function setUp() public {
        registry = new CashbackRegistry(startTimestampAtPeriod0, initialDuration, admin);
    }

    // Test add partner, view partner at the correct period
    // user: alice, bob
    // partner: Zeal,Gapp,GPay

    function testPeriod(uint96 timestamp, uint8 newDuration) public {
        assertEq(block.timestamp, 1);
        // timestamp has to be larger than the next start timestamp
        vm.assume(
            timestamp > block.timestamp + registry.duration() + registry.startTimestamp()
                && timestamp < type(uint96).max - newDuration
        );
        vm.assume(newDuration > 1 && newDuration != registry.duration());
        (uint256 startTimestamp, uint256 endTimestamp) = registry.getCurrentPeriod();
        assertEq(startTimestamp, registry.startTimestamp());
        assertEq(endTimestamp, registry.startTimestamp() + registry.duration() - 1);

        (startTimestamp, endTimestamp) = registry.getPeriodAtTimestamp(timestamp / 2);
        vm.warp(timestamp / 2);

        (uint256 newStartTimestamp, uint256 newEndTimestamp) = registry.getCurrentPeriod();
        assertEq(newStartTimestamp, startTimestamp);
        assertEq(newEndTimestamp, endTimestamp);

        // Test the period is changed

        vm.prank(admin);
        registry.setDuration(newDuration);
        assertEq(registry.duration(), newDuration);

        (startTimestamp, endTimestamp) = registry.getPeriodAtTimestamp(timestamp);

        vm.warp(timestamp);

        (, uint256 r) = _getQuotientResidue(timestamp - registry.startTimestamp(), newDuration);
        if (r == 0) {
            assertEq(startTimestamp, timestamp);
            assertEq(endTimestamp, timestamp + newDuration - 1);
        } else {
            assertEq(startTimestamp, timestamp - r);
            assertEq(endTimestamp, startTimestamp + newDuration - 1);
        }
    }

    // Test partner and period is correctly calculated
    // Test scenarios where duration is changed

    function testAddViewPartner(uint64 startTsX, uint64 startTsY, uint64 startTsZ, uint64 newDuration) public {
        assertEq(block.timestamp, 1);
        vm.assume(startTsX > 1);
        vm.assume(startTsX < startTsY);
        vm.assume(startTsY < startTsZ);
        vm.assume(newDuration > 1);
        (, uint256 endTimestampY) = registry.getPeriodAtTimestamp(startTsY);
        vm.assume(startTsZ > endTimestampY);

        vm.startPrank(admin);
        registry.registerPartner(zeal);
        registry.registerPartner(gApp);
        registry.registerPartner(gPay);
        vm.stopPrank();
        assertTrue(registry.isPartnerRegistered(zeal));
        assertTrue(registry.isPartnerRegistered(gApp));
        assertTrue(registry.isPartnerRegistered(gPay));

        // The start and end timestamp of the first period
        (uint256 startTs, uint256 endTs) = registry.getCurrentPeriod();
        // At period 0, alice add zeal as partner
        assertEq(registry.getPartnerAtTimestamp(alice, uint96(startTs - 1)), address(0)); // return default partner if not set
        vm.prank(alice);
        uint256 nextStartTimestamp = registry.setPartnerForNextPeriod(alice, zeal);
        assertEq(nextStartTimestamp, block.timestamp + initialDuration);

        assertEq(registry.getPartnerAtTimestamp(alice, uint96(endTs + 1)), zeal);

        // registry assumes the future partner is the same
        assertEq(registry.getPartnerAtTimestamp(alice, 100000), zeal);

        // alice -> {zeal, 8}

        // ===================== startTsX=====================
        vm.warp(startTsX);

        vm.prank(alice);
        nextStartTimestamp = registry.setPartnerForNextPeriod(alice, gPay);
        // if startTsX less than first period
        if (startTsX <= endTs) {
            //only change the head, because alice has already add zeal for the next period
            assertEq(registry.getPartnerAtTimestamp(alice, startTsX), address(0));
            assertEq(registry.getPartnerAtTimestamp(alice, startTsX + registry.duration()), gPay);
            assertEq(nextStartTimestamp, endTs + 1);
        } else {
            // if startTsX > first period
            (, uint256 endTimestampX) = registry.getPeriodAtTimestamp(startTsX);
            assertEq(registry.getPartnerAtTimestamp(alice, 1), address(0));
            assertEq(registry.getPartnerAtTimestamp(alice, 8), zeal);
            assertEq(registry.getPartnerAtTimestamp(alice, uint96(endTimestampX)), zeal);
            assertEq(registry.getPartnerAtTimestamp(alice, uint96(endTimestampX + 1)), gPay);
            assertEq(nextStartTimestamp, uint96(endTimestampX + 1));
        }

        // alice -> [{zeal, 8}, {gPay, endTimestampX + 1}]

        // ===================== startTsY=====================

        vm.warp(startTsY);

        vm.prank(bob);
        nextStartTimestamp = registry.setPartnerForNextPeriod(bob, gApp);
        assertEq(nextStartTimestamp, endTimestampY + 1);
        assertEq(registry.getPartnerAtTimestamp(bob, uint96(endTimestampY)), address(0)); // will return address(0) when user don't set the partner
        assertEq(registry.getPartnerAtTimestamp(bob, uint96(endTimestampY) + 1), gApp);

        vm.prank(alice);
        nextStartTimestamp = registry.setPartnerForNextPeriod(alice, gApp);
        assertEq(registry.getPartnerAtTimestamp(alice, uint96(endTimestampY) + 1), gApp);

        vm.prank(chris);
        nextStartTimestamp = registry.setPartnerForNextPeriod(chris, gApp);
        assertEq(registry.getPartnerAtTimestamp(chris, uint96(endTimestampY) + 1), gApp);

        // bob, chris -> [{gApp,endTimestampY + 1}}]
        // alice -> [{zeal, 1}, {gPay, endTimestampX + 1}}, {gApp, endTimestampY + 1}}]

        // Check the user that is eligible for partner gApp at period 10
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = chris;
        address[] memory usersForGApp = registry.getUsersAtTimestampForPartner(users, gApp, uint96(endTimestampY) + 1);

        assertEq(usersForGApp[0], alice);
        assertEq(usersForGApp[1], bob);
        assertEq(usersForGApp[2], chris);
        assertEq(usersForGApp.length, 3);

        assertEq(usersForGApp.length, 3);

        // test duration is changed
        vm.prank(admin);
        registry.setDuration(newDuration);

        vm.warp(startTsZ);
        (, uint256 endTimestampZ) = registry.getPeriodAtTimestamp(startTsZ);

        vm.prank(alice);
        nextStartTimestamp = registry.setPartnerForNextPeriod(alice, gPay);

        assertEq(nextStartTimestamp, endTimestampZ + 1);
        assertEq(registry.getPartnerAtTimestamp(alice, uint96(nextStartTimestamp)), gPay);

        vm.warp(nextStartTimestamp);
        (startTs, endTs) = registry.getCurrentPeriod();
        assertEq(startTs, nextStartTimestamp);
        assertEq(endTs, startTs + newDuration - 1);

        users[0] = alice;
        users[1] = bob;
        users[2] = chris;
        usersForGApp = registry.getUsersAtTimestampForPartner(users, gApp, uint96(endTimestampZ) + 1);

        assertEq(usersForGApp[0], bob);
        assertEq(usersForGApp[1], chris);
        assertEq(usersForGApp.length, 2);
    }

    function testRegisterPartner() public {
        vm.prank(admin);
        registry.registerPartner(zeal);
        assertTrue(registry.isPartnerRegistered(zeal));

        vm.prank(admin);
        registry.registerPartner(gApp);
        assertTrue(registry.isPartnerRegistered(gApp));

        vm.prank(admin);
        registry.unregisterPartner(zeal);
        assertFalse(registry.isPartnerRegistered(zeal));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CashbackRegistry.PartnerIsNotRegistered.selector, zeal));
        registry.unregisterPartner(zeal);
    }

    function testAdmin(address partner1, address partner2, uint96 newDuration, uint64 timestampDiff) public {
        vm.assume(
            partner1 != address(0) && partner2 != address(0) && partner1 != SENTINEL_20 && partner2 != SENTINEL_20
        );
        vm.assume(newDuration > 1 && newDuration != registry.duration() && newDuration < type(uint64).max);

        vm.assume(registry.startTimestamp() + timestampDiff < type(uint64).max);

        vm.prank(admin);
        registry.registerPartner(partner1);

        assertTrue(registry.isPartnerRegistered(partner1));
        if (partner1 == partner2) {
            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(CashbackRegistry.PartnerAlreadyRegistered.selector, partner1));
            registry.registerPartner(partner2);
        } else {
            vm.prank(admin);
            registry.registerPartner(partner2);
            assertTrue(registry.isPartnerRegistered(partner2));
        }

        // unregister partner1

        vm.prank(alice);
        vm.expectRevert(CashbackRegistry.OnlyAdmin.selector);
        registry.unregisterPartner(partner1);

        // only admin can bootstrap user's partner list
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CashbackRegistry.InvalidCaller.selector, alice));
        registry.setPartnerForNextPeriod(bob, partner1);

        vm.prank(admin);
        registry.setPartnerForNextPeriod(bob, partner1);
        assertEq(partner1, registry.getPartnerAtTimestamp(bob, uint96(block.timestamp) + registry.duration()));

        // Test set new duration

        uint96 originalDuration = registry.duration();
        uint256 originalStartTimestamp = registry.startTimestamp();

        vm.prank(admin);
        registry.setDuration(newDuration);

        assertEq(registry.lastDurationBeforeDurationChange(), originalDuration);
        assertEq(registry.lastStartTimestampBeforeDurationChange(), originalStartTimestamp);
        assertEq(registry.duration(), newDuration);

        vm.warp(registry.startTimestamp() - 1); // at the endTimestamp of the previous period

        (uint256 startTimestamp, uint256 endTimestamp) = registry.getPeriodAtTimestamp(uint96(block.timestamp));
        assertEq(endTimestamp, registry.startTimestamp() - 1);
        assertEq(startTimestamp, endTimestamp - registry.lastDurationBeforeDurationChange() + 1);

        // Warp to timestamp where new duration is used
        vm.warp(registry.startTimestamp() + timestampDiff);

        (startTimestamp, endTimestamp) = registry.getCurrentPeriod();

        // calculate the start,end timestamp
        (, uint256 r) = _getQuotientResidue((block.timestamp - registry.startTimestamp()), registry.duration());

        if (r == 0) {
            // when timestamp is at divisible, then it is at startTimestamp
            assertEq(startTimestamp, block.timestamp);
            assertEq(endTimestamp, block.timestamp + registry.duration() - 1);
        } else {
            // if not divisible, timestamp is can either 1) be in the middle, or 2) at the end timestamp
            assertEq(startTimestamp, block.timestamp - r);
            assertEq(endTimestamp, startTimestamp + registry.duration() - 1);
        }
    }

    // Helper function
    function _getQuotientResidue(uint256 number, uint256 d)
        internal
        pure
        returns (uint256 quotient, uint256 remainder)
    {
        quotient = number / d;
        remainder = number == (quotient * d) ? 0 : number - (quotient * d);
    }
}
