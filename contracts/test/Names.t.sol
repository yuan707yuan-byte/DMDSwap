// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Fixture, IDMDNamesNFT} from "./utils/Fixture.sol";
import {DmdNameRouter} from "../src/names/DmdNameRouter.sol";
import {DmdNameResolver} from "../src/names/DmdNameResolver.sol";
import {DmdSwapRouterBase} from "../src/periphery/DmdSwapRouterBase.sol";
import {RejectDMD} from "./mocks/Mocks.sol";

interface IAddrView {
    function addr(bytes32 node) external view returns (address);
}

/// @notice Integration tests against the OFFICIAL DMD Naming System bytecode.
contract NamesTest is Fixture {
    bytes32 internal constant DMD_NODE = 0x9904bf4b5751e3b6a8b75d14c49424160de1a8fa8a90fd5c9fccdeac0503e612;

    function setUp() public override {
        super.setUp();
        _addLiq(carol, address(tokA), address(tokB), 1e24, 1e24);
        _addLiqDMD(carol, address(tokA), 1e24, 1e5 ether);
        _registerName(alice, "alice"); // first registration auto-activates
    }

    // ───────────────────────────── resolution semantics

    function test_resolve_activeName() public view {
        assertEq(nameResolver.resolve("alice"), alice);
        assertEq(nameRouter.resolveName("alice"), alice);
        assertEq(nameResolver.activeNameOf(alice), "alice");
    }

    function test_resolve_rejectsInvalidUnknownAndUppercase() public view {
        assertEq(nameResolver.resolve("nobody"), address(0));
        assertEq(nameResolver.resolve("Alice"), address(0)); // DMD names are lowercase-only
        assertEq(nameResolver.resolve("alice.dmd"), address(0)); // label only, no TLD
        assertEq(nameResolver.resolve(""), address(0));
        assertEq(nameResolver.activeNameOf(bob), "");
    }

    function test_resolve_ownedButInactiveName_doesNotResolve() public {
        _registerName(alice, "alice2"); // alice already has an active name => alice2 stays inactive
        assertEq(nameResolver.resolve("alice2"), address(0));
        assertEq(nameResolver.resolve("alice"), alice);
    }

    function test_resolve_afterNftTransfer_followsNewOwnerOnlyAfterActivation() public {
        uint256 tokenId = uint256(keccak256("alice"));
        uint256 fee = dmdNames.transferFee();
        vm.prank(alice);
        dmdNames.transferFrom{value: fee}(alice, bob, tokenId);
        assertEq(nameResolver.resolve("alice"), address(0)); // DMD wipes records on transfer
        uint256 actFee = dmdController.getActivationFee(bob);
        vm.prank(bob);
        dmdController.activate{value: actFee}("alice");
        assertEq(nameResolver.resolve("alice"), bob);
    }

    /// DMD does NOT clear records when a name expires. Raw resolver still returns the old owner —
    /// our adapter must refuse it.
    function test_resolve_expiredName_failsClosed_despiteStaleRecord() public {
        vm.warp(block.timestamp + 3660 days);
        bytes32 node = keccak256(abi.encodePacked(DMD_NODE, keccak256("alice")));
        assertEq(IAddrView(dmdResolver).addr(node), alice, "raw DMD record is stale but still set");
        assertEq(nameResolver.resolve("alice"), address(0), "adapter must reject expired names");
        assertEq(nameResolver.activeNameOf(alice), "");
    }

    function test_resolve_moderatedName_failsClosed() public {
        vm.prank(dmdDao);
        dmdController.moderateName(alice, "alice", "spam", "");
        assertEq(nameResolver.resolve("alice"), address(0));
    }

    function test_resolve_disabledByGovernance() public {
        _govern(address(nameResolver), abi.encodeCall(DmdNameResolver.setEnabled, (false)));
        assertEq(nameResolver.resolve("alice"), address(0));
    }

    /// Validation is byte-for-byte equivalent to the official DMDRegistrarController.valid().
    function testFuzz_isValidName_matchesOfficialController(bytes memory raw) public view {
        bytes memory alphabet = "abcz09-A.-_ -";
        uint256 len = raw.length % 70;
        bytes memory s = new bytes(len);
        for (uint256 i; i < len; ++i) s[i] = alphabet[uint8(raw[i % (raw.length == 0 ? 1 : raw.length)]) % alphabet.length];
        string memory name = string(s);
        assertEq(nameResolver.isValidName(name), dmdController.valid(name));
    }

    function test_isValidName_edgeCases() public view {
        string[10] memory ok_ = ["ab", "a1", "a-b", "a-b-c", "0x", "123", "a2-z9", "zz", "x-1", "9-9"];
        string[10] memory bad = ["a", "-ab", "ab-", "a--b", "Ab", "a_b", "a.b", "a b", "", unicode"äb"];
        for (uint256 i; i < 10; ++i) {
            assertTrue(nameResolver.isValidName(ok_[i]));
            assertTrue(dmdController.valid(ok_[i]));
            assertFalse(nameResolver.isValidName(bad[i]));
        }
    }

    // ───────────────────────────── name-bound payments

    function test_swapExactTokensToName() public {
        uint256 q = router.getAmountsOut(1e18, _path(address(tokA), address(tokB)))[1];
        uint256 b0 = tokB.balanceOf(alice);
        vm.prank(bob);
        nameRouter.swapExactTokensForTokensToName(1e18, q, _path(address(tokA), address(tokB)), "alice", alice, block.timestamp);
        assertEq(tokB.balanceOf(alice) - b0, q);
    }

    function test_swapDMDAndTokensToDMD_toName() public {
        uint256 a0 = tokA.balanceOf(alice);
        vm.prank(bob);
        nameRouter.swapExactDMDForTokensToName{value: 1 ether}(1, _path(address(wdmd), address(tokA)), "alice", alice, block.timestamp);
        assertGt(tokA.balanceOf(alice), a0);

        uint256 d0 = alice.balance;
        vm.prank(bob);
        nameRouter.swapExactTokensForDMDToName(1e20, 1, _path(address(tokA), address(wdmd)), "alice", alice, block.timestamp);
        assertGt(alice.balance, d0);
        assertEq(address(nameRouter).balance, 0);
        assertEq(wdmd.balanceOf(address(nameRouter)), 0);
    }

    function test_exactOutputToName_allThree() public {
        vm.startPrank(bob);
        uint256 b0 = tokB.balanceOf(alice);
        nameRouter.swapTokensForExactTokensToName(1e18, 2e18, _path(address(tokA), address(tokB)), "alice", alice, block.timestamp);
        assertEq(tokB.balanceOf(alice) - b0, 1e18);

        uint256 a0 = tokA.balanceOf(alice);
        uint256 bobDmd = bob.balance;
        uint256 need = router.getAmountsIn(1e18, _path(address(wdmd), address(tokA)))[0];
        nameRouter.swapDMDForExactTokensToName{value: need + 3 ether}(1e18, _path(address(wdmd), address(tokA)), "alice", alice, block.timestamp);
        assertEq(tokA.balanceOf(alice) - a0, 1e18);
        assertEq(bobDmd - bob.balance, need, "excess refunded to payer, not recipient");

        uint256 d0 = alice.balance;
        nameRouter.swapTokensForExactDMDToName(1 ether, 1e22, _path(address(tokA), address(wdmd)), "alice", alice, block.timestamp);
        assertEq(alice.balance - d0, 1 ether);
        vm.stopPrank();
    }

    function test_plainSendsToName() public {
        uint256 d0 = alice.balance;
        vm.prank(bob);
        nameRouter.sendDMDToName{value: 7 ether}("alice", alice);
        assertEq(alice.balance - d0, 7 ether);

        uint256 t0 = tokC.balanceOf(alice);
        vm.prank(bob);
        nameRouter.sendTokenToName(address(tokC), 123e6, "alice", alice);
        assertEq(tokC.balanceOf(alice) - t0, 123e6);
    }

    // ───────────────────────────── name-binding attacks

    function test_recipientMismatch_reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdNameRouter.RecipientMismatch.selector, "alice", alice, attacker));
        nameRouter.sendDMDToName{value: 1 ether}("alice", attacker);
    }

    /// The name changes hands between the user's confirmation and execution: funds must NOT follow.
    function test_nameTransferredAfterConfirmation_paymentReverts() public {
        address confirmed = nameResolver.resolve("alice"); // what the UI showed bob
        uint256 tokenId = uint256(keccak256("alice"));
        uint256 fee = dmdNames.transferFee();
        vm.prank(alice);
        dmdNames.transferFrom{value: fee}(alice, attacker, tokenId);
        uint256 actFee = dmdController.getActivationFee(attacker);
        vm.prank(attacker);
        dmdController.activate{value: actFee}("alice");
        assertEq(nameResolver.resolve("alice"), attacker);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdNameRouter.RecipientMismatch.selector, "alice", attacker, confirmed));
        nameRouter.swapExactTokensForTokensToName(1e18, 1, _path(address(tokA), address(tokB)), "alice", confirmed, block.timestamp);
    }

    function test_unresolvableName_reverts() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdNameRouter.NameNotResolvable.selector, "ghost"));
        nameRouter.sendDMDToName{value: 1 ether}("ghost", alice);
        vm.expectRevert(abi.encodeWithSelector(DmdNameRouter.NameNotResolvable.selector, "Alice"));
        nameRouter.sendDMDToName{value: 1 ether}("Alice", alice);
        vm.expectRevert(DmdSwapRouterBase.ZeroAddress.selector);
        nameRouter.sendDMDToName{value: 1 ether}("alice", address(0));
        vm.stopPrank();
    }

    function test_expiredName_paymentReverts() public {
        vm.warp(block.timestamp + 3660 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdNameRouter.NameNotResolvable.selector, "alice"));
        nameRouter.sendDMDToName{value: 1 ether}("alice", alice);
    }

    function test_nameRouter_slippageAndDeadlineEnforced() public {
        vm.startPrank(bob);
        vm.expectRevert(DmdSwapRouterBase.ZeroSlippageProtection.selector);
        nameRouter.swapExactTokensForTokensToName(1e18, 0, _path(address(tokA), address(tokB)), "alice", alice, block.timestamp);
        vm.expectRevert();
        nameRouter.swapExactTokensForTokensToName(1e18, 1, _path(address(tokA), address(tokB)), "alice", alice, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_nameRouter_honoursEmergencyPause() public {
        vm.prank(admin);
        factory.pause();
        vm.prank(bob);
        vm.expectRevert(DmdNameRouter.Paused.selector);
        nameRouter.sendDMDToName{value: 1 ether}("alice", alice);
    }

    function test_nameRouter_rejectsStrayDMD() public {
        vm.prank(bob);
        (bool ok,) = address(nameRouter).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_resolverConfig_rejectsInconsistentSystem() public {
        // a contract that is not the live .dmd registrar must be refused
        RejectDMD notController = new RejectDMD();
        bytes memory data = abi.encodeCall(DmdNameResolver.setController, (address(notController)));
        bytes32 salt = keccak256("bad");
        vm.prank(admin);
        timelock.schedule(address(nameResolver), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vm.expectRevert(DmdNameResolver.InconsistentNamesSystem.selector);
        timelock.execute(address(nameResolver), 0, data, bytes32(0), salt);
    }
}
