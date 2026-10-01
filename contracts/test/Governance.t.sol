// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Fixture} from "./utils/Fixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {DmdSwapFactory} from "../src/core/DmdSwapFactory.sol";
import {DmdSwapPair} from "../src/core/DmdSwapPair.sol";
import {DmdSwapRouter} from "../src/periphery/DmdSwapRouter.sol";
import {DmdNameResolver} from "../src/names/DmdNameResolver.sol";
import {DmdNameRouter} from "../src/names/DmdNameRouter.sol";
import {WDMD} from "../src/token/WDMD.sol";
import {IDmdSwapPair} from "../src/interfaces/IDmdSwapPair.sol";
import {DmdSwapPairV2, DmdSwapFactoryV2} from "./mocks/Mocks.sol";

contract GovernanceTest is Fixture {
    function _owned() internal view returns (address[6] memory c) {
        c = [address(factory), address(router), address(nameResolver), address(nameRouter), address(wdmd), address(beacon)];
    }

    function test_everythingOwnedByTimelock_noDeployerPowers() public view {
        address[6] memory c = _owned();
        for (uint256 i; i < c.length; ++i) assertEq(Ownable(c[i]).owner(), address(timelock));
        assertEq(timelock.getMinDelay(), 24 hours);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), admin));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), admin));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock))); // self-administered
        assertEq(factory.guardian(), admin);
    }

    function test_adminCannotBypassTimelock() public {
        address newImpl = address(new DmdSwapFactoryV2());
        address newPairImpl = address(new DmdSwapPairV2());
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        UUPSUpgradeable(address(factory)).upgradeToAndCall(newImpl, "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        factory.setSwapFee(50);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        beacon.upgradeTo(newPairImpl);
        vm.stopPrank();
    }

    function test_nonAdminCannotSchedule() public {
        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(address(factory), 0, abi.encodeCall(DmdSwapFactory.setSwapFee, (50)), bytes32(0), bytes32(0), DELAY);
    }

    function test_upgradeBefore24h_reverts_after24h_succeeds_statePreserved() public {
        _addLiq(alice, address(tokA), address(tokB), 1e20, 1e20);
        address newImpl = address(new DmdSwapFactoryV2());
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        vm.prank(admin);
        timelock.schedule(address(factory), 0, data, bytes32(0), bytes32(0), DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(admin);
        vm.expectRevert(); // TimelockUnexpectedOperationState: not ready
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
        assertEq(DmdSwapFactoryV2(address(factory)).version(), 2);
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.swapFeeBps(), FEE_BPS);
        assertEq(factory.pairBeacon(), address(beacon));
    }

    function test_scheduledChangeCanBeCancelled() public {
        bytes memory data = abi.encodeCall(DmdSwapFactory.setSwapFee, (uint16(50)));
        vm.prank(admin);
        timelock.schedule(address(factory), 0, data, bytes32(0), bytes32(0), DELAY);
        bytes32 id = timelock.hashOperation(address(factory), 0, data, bytes32(0), bytes32(0));
        vm.prank(admin);
        timelock.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, bytes32(0), bytes32(0));
    }

    function test_beaconUpgrade_upgradesAllPairs_keepsReserves() public {
        address p1 = _addLiq(alice, address(tokA), address(tokB), 1e20, 2e20);
        address p2 = _addLiq(alice, address(tokB), address(tokC), 1e20, 1e9);
        (uint112 r0, uint112 r1,) = IDmdSwapPair(p1).getReserves();
        uint256 lp = DmdSwapPair(p1).balanceOf(alice);
        _govern(address(beacon), abi.encodeCall(UpgradeableBeacon.upgradeTo, (address(new DmdSwapPairV2()))));
        assertEq(DmdSwapPairV2(p1).version(), 2);
        assertEq(DmdSwapPairV2(p2).version(), 2);
        (uint112 n0, uint112 n1,) = IDmdSwapPair(p1).getReserves();
        assertEq(n0, r0);
        assertEq(n1, r1);
        assertEq(DmdSwapPair(p1).balanceOf(alice), lp);
        vm.prank(bob); // still fully functional
        router.swapExactTokensForTokens(1e18, 1, _path(address(tokA), address(tokB)), bob, block.timestamp);
    }

    function test_implementationsAndProxies_cannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        factory.initialize(attacker, attacker, address(beacon), 30, attacker, 5000);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(attacker, address(factory), address(wdmd));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        nameResolver.initialize(attacker, address(dmdController));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        nameRouter.initialize(attacker, address(factory), address(wdmd), address(nameResolver));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wdmd.initialize(attacker);
        // bare implementations are locked too
        DmdSwapFactory fImpl = new DmdSwapFactory();
        DmdSwapPair pImpl = new DmdSwapPair();
        WDMD wImpl = new WDMD();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fImpl.initialize(attacker, attacker, address(beacon), 30, attacker, 5000);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        pImpl.initialize(address(1), address(2));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wImpl.initialize(attacker);
    }

    function test_upgradeToNonContract_reverts() public {
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (alice, ""));
        vm.prank(admin);
        timelock.schedule(address(router), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(address(router), 0, data, bytes32(0), bytes32(0));
    }

    function test_erc7201Slots() public pure {
        string[6] memory ns = ["Factory", "Pair", "Router", "NameRouter", "NameResolver", "WDMD"];
        bytes32[5] memory expected = [
            bytes32(0x3a9518a2f0d6955e0f2574a2e06808bbe57f7b09b934d012dc3902a872d6f700),
            0x4653e66ab3b57af2ecbd66d149139e39ba5c31d263d1c45b0dccc0ec2deb0b00,
            0x8391502ab74cf48132fc1c67aeec9fe1e371612ea9a17433afe2b769d84a0000,
            0x9d82d1be8be96b3e8b5e98809a8055fd847ffcfb0269f18f9aa03f7e12041500,
            0x90f5aa5c8216b654c54d09f0c0445f3f59592e6155722f77b3d986c137b47000
        ];
        for (uint256 i; i < 5; ++i) {
            bytes32 slot = keccak256(abi.encode(uint256(keccak256(bytes(string.concat("dmdswap.storage.", ns[i])))) - 1))
                & ~bytes32(uint256(0xff));
            assertEq(slot, expected[i]);
        }
    }

    function test_wdmd_wrapUnwrap() public {
        vm.startPrank(bob);
        wdmd.deposit{value: 5 ether}();
        (bool ok,) = address(wdmd).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(wdmd.balanceOf(bob), 6 ether);
        uint256 d0 = bob.balance;
        wdmd.withdraw(6 ether);
        assertEq(bob.balance - d0, 6 ether);
        vm.expectRevert();
        wdmd.withdraw(1);
        vm.stopPrank();
        assertEq(address(wdmd).balance, wdmd.totalSupply());
    }
}
