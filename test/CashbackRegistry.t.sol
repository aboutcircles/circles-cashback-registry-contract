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
    uint96 duration = 7;
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;

    function setUp() public {
        registry = new CashbackRegistry(startTimestampAtPeriod0, duration, admin);
    }

    // Test add partner, view partner at the correct period
    // user: alice, bob
    // partner: Zeal,Gapp,GPay

    function testPeriod(uint96 timestamp) public {
        assertEq(block.timestamp, 1);

        vm.assume(timestamp > block.timestamp && timestamp < type(uint96).max);
        assertEq(registry.getCurrentPeriod(), 0);

        uint96 period = registry.getPeriodAtTimestamp(timestamp);
        vm.warp(timestamp);

        assertEq(registry.getCurrentPeriod(), period);
        vm.warp(type(uint256).max);
        assertGt(registry.getCurrentPeriod(), 1);
    }

    function testAddViewPartner(uint96 periodX, uint96 periodY, uint96 periodZ) public {
        assertEq(block.timestamp, 1);
        vm.assume(periodZ <= registry.getPeriodAtTimestamp(type(uint256).max));
        vm.assume(periodX != 0);
        vm.assume(periodX < periodY);
        vm.assume(periodY < periodZ);

        vm.startPrank(admin);
        registry.registerPartner(zeal);
        registry.registerPartner(gApp);
        registry.registerPartner(gPay);
        vm.stopPrank();
        assertTrue(registry.isPartnerRegistered(zeal));
        assertTrue(registry.isPartnerRegistered(gApp));
        assertTrue(registry.isPartnerRegistered(gPay));

        //  vm.assume(periodZ * registry.DURATION() < type(uint96).max);
        uint96 currentPeriod = registry.getCurrentPeriod();
        // At period 0, alice add zeal as partner
        assertEq(registry.getPartnerAtPeriod(alice, currentPeriod), address(0)); // return default partner if not set
        vm.prank(alice);
        uint256 nextStartTimestamp = registry.setPartnerForNextPeriod(alice, zeal);
        assertEq(nextStartTimestamp, block.timestamp + duration);

        assertEq(registry.getPartnerAtPeriod(alice, currentPeriod + 1), zeal);

        // registry assumes the future partner is the same
        assertEq(registry.getPartnerAtPeriod(alice, 100000), zeal);

        // alice -> {zeal, 1}

        // ===================== periodX=====================
        vm.warp(periodX * duration);
        currentPeriod = registry.getCurrentPeriod();
        uint96 correctCurrentPeriod = (periodX * duration - registry.START_TIMESTAMP()) / registry.DURATION();
        assertEq(currentPeriod, correctCurrentPeriod);
        vm.prank(alice);
        nextStartTimestamp = registry.setPartnerForNextPeriod(alice, gPay);
        if (periodX == 1) {
            assertEq(registry.getPartnerAtPeriod(alice, 1), gPay);
            assertEq(registry.getPartnerAtPeriod(alice, currentPeriod + 1), gPay);
        } else {
            assertEq(registry.getPartnerAtPeriod(alice, 1), zeal);
            assertEq(registry.getPartnerAtPeriod(alice, currentPeriod), zeal);
            assertEq(registry.getPartnerAtPeriod(alice, currentPeriod + 1), gPay);
        }
        assertEq(nextStartTimestamp, startTimestampAtPeriod0 + periodX * duration);

        // alice -> [{zeal, 1}, {gPay, periodX}]

        // bob
        // ===================== periodY=====================

        vm.warp(periodY * duration);
        currentPeriod = registry.getCurrentPeriod();
        correctCurrentPeriod = (periodY * duration - registry.START_TIMESTAMP()) / registry.DURATION();
        assertEq(currentPeriod, correctCurrentPeriod);

        vm.prank(bob);
        nextStartTimestamp = registry.setPartnerForNextPeriod(bob, gApp);
        assertEq(registry.getPartnerAtPeriod(bob, periodX), address(0)); // will return address(0) when user don't set the partner
        assertEq(registry.getPartnerAtPeriod(bob, periodY), gApp);
        assertEq(nextStartTimestamp, startTimestampAtPeriod0 + periodY * duration);

        vm.prank(alice);
        nextStartTimestamp = registry.setPartnerForNextPeriod(alice, gApp);
        assertEq(registry.getPartnerAtPeriod(alice, periodY), gApp);
        assertEq(nextStartTimestamp, startTimestampAtPeriod0 + periodY * duration);

        vm.prank(chris);
        nextStartTimestamp = registry.setPartnerForNextPeriod(chris, gApp);
        assertEq(registry.getPartnerAtPeriod(chris, periodY), gApp);
        assertEq(nextStartTimestamp, startTimestampAtPeriod0 + periodY * duration);

        // bob -> [{gApp,periodY}]
        // alice -> [{zeal, 1}, {gPay, periodX}, {gApp, periodY}]

        // Check the user that is eligible for partner gApp at period 10
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = chris;
        address[] memory usersForGApp = registry.getUsersAtPeriodForPartner(users, gApp, currentPeriod + 1);

        assertEq(usersForGApp[0], alice);
        assertEq(usersForGApp[1], bob);
        assertEq(usersForGApp[2], chris);
        assertEq(usersForGApp.length, 3);

        usersForGApp = registry.getUsersAtPeriodForPartner(users, gApp, currentPeriod);

        assertEq(usersForGApp.length, 0);
    }

    function testRegisterPartner() public {
        vm.prank(admin);
        registry.registerPartner(zeal);
        assertTrue(registry.isPartnerRegistered(zeal));

        vm.prank(admin);
        registry.registerPartner(gApp);
        assertTrue(registry.isPartnerRegistered(gApp));
        assertFalse(registry.isPartnerRegistered(gPay));

        vm.prank(zeal);
        vm.expectRevert();
        registry.unregisterPartner(zeal);

        vm.prank(admin);
        registry.unregisterPartner(zeal);
        assertFalse(registry.isPartnerRegistered(zeal));
    }

    function testAdmin(address partner1, address partner2) public {
        // only admin can register or unregister partner
        vm.assume(
            partner1 != address(0) && partner2 != address(0) && partner1 != SENTINEL_20 && partner2 != SENTINEL_20
        );
        vm.prank(admin);
        registry.registerPartner(partner1);

        assertTrue(registry.isPartnerRegistered(partner1));
        if (partner1 == partner2) {
            vm.prank(admin);
            vm.expectRevert();
            registry.registerPartner(partner2);
        } else {
            vm.prank(admin);

            registry.registerPartner(partner2);
            assertTrue(registry.isPartnerRegistered(partner2));
        }

        // unregister partner1

        vm.prank(alice);
        vm.expectRevert();
        registry.unregisterPartner(partner1);

        vm.prank(admin);
        registry.unregisterPartner(partner1);
        assertFalse(registry.isPartnerRegistered(partner1));

        vm.prank(admin);
        registry.registerPartner(zeal);
        assertTrue(registry.isPartnerRegistered(zeal));

        // admin can bootstrap user's partner list
        vm.prank(alice);
        vm.expectRevert();
        registry.setPartnerForNextPeriod(bob, zeal);

        vm.prank(admin);
        registry.setPartnerForNextPeriod(bob, zeal);

        assertEq(registry.getPartnerAtPeriod(bob, registry.getCurrentPeriod()), zeal);
    }

    function testGetPeriodTimestamp(uint96 period) public {
        vm.assume(period < (type(uint96).max - startTimestampAtPeriod0) / duration);

        (uint256 startTimestamp, uint256 endTimestamp) = registry.getStartEndTimestampForPeriod(period);

        assertEq(startTimestamp, startTimestampAtPeriod0 + period * duration);
        assertEq(endTimestamp, startTimestampAtPeriod0 + (period + 1) * duration);

        vm.warp(startTimestampAtPeriod0 + period * duration);
        assertEq(registry.getPeriodAtTimestamp(startTimestampAtPeriod0 - 1), 0);
        assertEq(registry.getPeriodAtTimestamp(block.timestamp), period);
    }
}
