// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CashbackRegistry} from "../src/CashbackRegistry.sol";

contract CashbackRegistryTest is Test {
    CashbackRegistry public registry;
    uint96 startTimestamp = uint96(block.timestamp);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address zeal = makeAddr("zeal");
    address gApp = makeAddr("gApp");
    address gPay = makeAddr("gPay");
    uint96 duration = 7;
    bytes32 constant SENTINEL_32 = 0x0000000000000000000000000000000000000000000000000000000000000001;
    address constant SENTINEL_20 = 0x0000000000000000000000000000000000000001;

    function setUp() public {
        registry = new CashbackRegistry(startTimestamp, duration);
    }

    // Test add partner, view partner at the correct period
    // user: alice, bob
    // partner: Zeal,Gapp,GPay

    function testPeriod() public {
        assertEq(registry.getCurrentPeriod(), 0);

        vm.warp(block.timestamp + duration);

        assertEq(registry.getCurrentPeriod(), 1);
    }

    function testAddViewPartner() public {
        // At period 0, alice add zeal as partner
        assertEq(registry.getPartnerAtPeriod(alice, 1), address(0)); // return default partner if not set

        vm.prank(alice);

        registry.setPartnerForNextPeriod(zeal);

        assertEq(
            registry.partnerChangeLog(alice, SENTINEL_32),
            0x31ceba94fd56465661dc3be65664883013967e46000000000000000000000001
        );

        assertEq(registry.getPartnerAtPeriod(alice, 1), zeal);

        assertEq(registry.getPartnerAtPeriod(alice, 10), zeal);

        // alice -> {zeal, 1}

        vm.warp(block.timestamp + 8 * duration); // at period
        assertEq(registry.getCurrentPeriod(), 8);
        vm.prank(alice);
        registry.setPartnerForNextPeriod(gPay);

        assertEq(registry.getPartnerAtPeriod(alice, 1), zeal);
        assertEq(registry.getPartnerAtPeriod(alice, 8), zeal);
        assertEq(registry.getPartnerAtPeriod(alice, 9), gPay);

        // alice -> [{zeal, 1}, {gPay,9}]
        vm.prank(alice);
        // alice changes partner again
        registry.setPartnerForNextPeriod(gApp);
        assertEq(registry.getPartnerAtPeriod(alice, 9), gApp);
        // alice -> [{zeal, 1}, {gApp,9}]

        // bob

        vm.warp(block.timestamp + duration);
        assertEq(registry.getCurrentPeriod(), 9);
        vm.prank(bob);
        registry.setPartnerForNextPeriod(gApp);
        assertEq(registry.getPartnerAtPeriod(bob, 2), address(0)); // will return address(0) when user don't set the partner
        assertEq(registry.getPartnerAtPeriod(bob, 10), gApp);

        // bob -> [{gApp,10}]

        // Check the user that is eligible for partner gApp at period 10
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = bob;
        address[] memory usersForGApp = registry.getUsersAtPeriodForPartner(users, gApp, 10);

        assertEq(usersForGApp[0], alice);
        assertEq(usersForGApp[1], bob);
        assertEq(usersForGApp.length, 2);
    }

    function testRegisterPartner() public {
        vm.prank(zeal);
        registry.registerPartner(zeal);

        assertTrue(registry.isPartnerRegistered(zeal));

        vm.prank(gApp);
        registry.registerPartner(gApp);
        assertTrue(registry.isPartnerRegistered(gApp));
        assertFalse(registry.isPartnerRegistered(gPay));

        vm.prank(zeal);
        vm.expectRevert();
        registry.unregisterPartner(gApp);

        vm.prank(zeal);
        registry.unregisterPartner(zeal);
        assertFalse(registry.isPartnerRegistered(zeal));
    }
}
