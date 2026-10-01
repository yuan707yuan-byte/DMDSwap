// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Fixture} from "./utils/Fixture.sol";
import {DmdSwapPair} from "../src/core/DmdSwapPair.sol";
import {DmdSwapRouterBase} from "../src/periphery/DmdSwapRouterBase.sol";
import {DmdSwapRouter} from "../src/periphery/DmdSwapRouter.sol";
import {DmdSwapLibrary} from "../src/libraries/DmdSwapLibrary.sol";
import {FeeOnTransferToken, ReentrantToken, RejectDMD} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RouterTest is Fixture {
    function setUp() public override {
        super.setUp();
        _addLiq(alice, address(tokA), address(tokB), 1e24, 1e24);
        _addLiq(alice, address(tokB), address(tokC), 1e24, 1e12);
        _addLiqDMD(alice, address(tokA), 1e24, 1e5 ether);
    }

    // ───────────────────────────── liquidity

    function test_addLiquidityDMD_refundsExcess() public {
        uint256 before = bob.balance;
        vm.prank(bob);
        (, uint256 amountDMD,) =
            router.addLiquidityDMD{value: 50 ether}(address(tokA), 1e20, 0, 0, bob, block.timestamp);
        assertEq(amountDMD, 10 ether); // pool ratio is 1e24 tokA : 1e5 DMD
        assertEq(before - bob.balance, 10 ether);
        assertEq(address(router).balance, 0);
    }

    function test_removeLiquidityDMD() public {
        address pair = factory.getPair(address(tokA), address(wdmd));
        uint256 lp = DmdSwapPair(pair).balanceOf(alice) / 2;
        uint256 dmdBefore = alice.balance;
        vm.startPrank(alice);
        DmdSwapPair(pair).approve(address(router), lp);
        router.removeLiquidityDMD(address(tokA), lp, 1, 1, alice, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(alice.balance - dmdBefore, 0.5e5 ether, 1e12);
        assertEq(wdmd.balanceOf(address(router)), 0);
    }

    function test_removeLiquidityWithPermit_survivesPermitFrontRun() public {
        (address user, uint256 pk) = makeAddrAndKey("lpUser");
        tokA.mint(user, 1e21);
        tokB.mint(user, 1e21);
        vm.startPrank(user);
        tokA.approve(address(router), type(uint256).max);
        tokB.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tokA), address(tokB), 1e21, 1e21, 0, 0, user, block.timestamp);
        vm.stopPrank();
        DmdSwapPair pair = DmdSwapPair(factory.getPair(address(tokA), address(tokB)));
        uint256 lp = pair.balanceOf(user);
        uint256 deadline = block.timestamp + 600;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                pair.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user, address(router), lp, 0, deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        // attacker sees the signature in the mempool and submits the permit first (griefing attempt)
        vm.prank(attacker);
        pair.permit(user, address(router), lp, deadline, v, r, s);
        // user's tx still succeeds thanks to the allowance fallback
        vm.prank(user);
        router.removeLiquidityWithPermit(address(tokA), address(tokB), lp, 1, 1, user, deadline, false, v, r, s);
        assertEq(pair.balanceOf(user), 0);
    }

    // ───────────────────────────── swaps

    function test_allSixSwapKinds() public {
        address[] memory ab = _path(address(tokA), address(tokB));
        address[] memory dA = _path(address(wdmd), address(tokA));
        address[] memory aD = _path(address(tokA), address(wdmd));
        vm.startPrank(bob);

        uint256 b0 = tokB.balanceOf(bob);
        uint256[] memory q = router.getAmountsOut(1e18, ab);
        router.swapExactTokensForTokens(1e18, q[1], ab, bob, block.timestamp);
        assertEq(tokB.balanceOf(bob) - b0, q[1]);

        q = router.getAmountsIn(5e17, ab);
        uint256 a0 = tokA.balanceOf(bob);
        router.swapTokensForExactTokens(5e17, q[0], ab, bob, block.timestamp);
        assertEq(a0 - tokA.balanceOf(bob), q[0]);

        a0 = tokA.balanceOf(bob);
        q = router.getAmountsOut(1 ether, dA);
        router.swapExactDMDForTokens{value: 1 ether}(q[1], dA, bob, block.timestamp);
        assertEq(tokA.balanceOf(bob) - a0, q[1]);

        uint256 d0 = bob.balance;
        q = router.getAmountsIn(1 ether, aD);
        router.swapTokensForExactDMD(1 ether, q[0], aD, bob, block.timestamp);
        assertEq(bob.balance - d0, 1 ether);

        d0 = bob.balance;
        q = router.getAmountsOut(1e19, aD);
        router.swapExactTokensForDMD(1e19, q[1], aD, bob, block.timestamp);
        assertEq(bob.balance - d0, q[1]);

        d0 = bob.balance;
        q = router.getAmountsIn(1e18, dA);
        router.swapDMDForExactTokens{value: q[0] + 5 ether}(1e18, dA, bob, block.timestamp);
        assertEq(d0 - bob.balance, q[0]); // excess refunded
        vm.stopPrank();

        assertEq(address(router).balance, 0);
        assertEq(wdmd.balanceOf(address(router)), 0);
    }

    function test_multiHop_AtoC() public {
        address[] memory p = _path3(address(tokA), address(tokB), address(tokC));
        uint256[] memory q = router.getAmountsOut(1e20, p);
        uint256 c0 = tokC.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(1e20, q[2], p, bob, block.timestamp);
        assertEq(tokC.balanceOf(bob) - c0, q[2]);
    }

    // ───────────────────────────── front-running protections

    function test_zeroSlippageProtection_isRejected() public {
        vm.startPrank(bob);
        vm.expectRevert(DmdSwapRouterBase.ZeroSlippageProtection.selector);
        router.swapExactTokensForTokens(1e18, 0, _path(address(tokA), address(tokB)), bob, block.timestamp);
        vm.expectRevert(DmdSwapRouterBase.ZeroSlippageProtection.selector);
        router.swapExactDMDForTokens{value: 1 ether}(0, _path(address(wdmd), address(tokA)), bob, block.timestamp);
        vm.expectRevert(DmdSwapRouterBase.ZeroSlippageProtection.selector);
        router.swapExactTokensForDMD(1e18, 0, _path(address(tokA), address(wdmd)), bob, block.timestamp);
        vm.stopPrank();
    }

    function test_expiredDeadline_reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdSwapRouterBase.Expired.selector, block.timestamp - 1, block.timestamp));
        router.swapExactTokensForTokens(1e18, 1, _path(address(tokA), address(tokB)), bob, block.timestamp - 1);
    }

    /// Sandwich simulation: attacker front-runs a victim's swap. Victim's on-chain minOut (0.5 %)
    /// makes the victim tx revert, so the sandwich yields nothing but the attacker's own fees.
    function test_sandwichAttack_isBlockedBySlippageGuard() public {
        address[] memory ab = _path(address(tokA), address(tokB));
        uint256 victimIn = 1e22;
        uint256 quoted = router.getAmountsOut(victimIn, ab)[1];
        uint256 minOut = quoted * 9950 / 10_000; // UI default 0.5 % slippage

        // front-run: attacker buys B first
        vm.prank(attacker);
        router.swapExactTokensForTokens(5e22, 1, ab, attacker, block.timestamp);

        // victim tx executes after the front-run => reverts instead of being exploited
        vm.prank(bob);
        vm.expectRevert();
        router.swapExactTokensForTokens(victimIn, minOut, ab, bob, block.timestamp);
    }

    function test_slippage_exactOutput_bounded() public {
        address[] memory ab = _path(address(tokA), address(tokB));
        uint256 need = router.getAmountsIn(1e20, ab)[0];
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdSwapRouterBase.ExcessiveInputAmount.selector, need, need - 1));
        router.swapTokensForExactTokens(1e20, need - 1, ab, bob, block.timestamp);
    }

    function test_invalidRecipients_andPaths() public {
        address[] memory ab = _path(address(tokA), address(tokB));
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(DmdSwapRouterBase.InvalidRecipient.selector, address(0)));
        router.swapExactTokensForTokens(1e18, 1, ab, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(DmdSwapRouterBase.InvalidRecipient.selector, address(router)));
        router.swapExactTokensForTokens(1e18, 1, ab, address(router), block.timestamp);
        address[] memory longPath = new address[](6);
        vm.expectRevert(DmdSwapLibrary.InvalidPath.selector);
        router.swapExactTokensForTokens(1e18, 1, longPath, bob, block.timestamp);
        vm.expectRevert(DmdSwapRouterBase.InvalidPath.selector);
        router.swapExactDMDForTokens{value: 1 ether}(1, ab, bob, block.timestamp); // path[0] != WDMD
        vm.stopPrank();
    }

    function test_receive_onlyFromWDMD() public {
        vm.prank(bob);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_dmdToRejectingRecipient_reverts() public {
        RejectDMD r = new RejectDMD();
        vm.prank(bob);
        vm.expectRevert(DmdSwapRouterBase.DMDTransferFailed.selector);
        router.swapExactTokensForDMD(1e18, 1, _path(address(tokA), address(wdmd)), address(r), block.timestamp);
    }

    // ───────────────────────────── fee-on-transfer tokens

    function test_feeOnTransfer_allThreeVariants() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 1e24);
        fot.mint(bob, 1e24);
        vm.prank(alice);
        fot.approve(address(router), type(uint256).max);
        vm.prank(bob);
        fot.approve(address(router), type(uint256).max);
        _addLiq(alice, address(fot), address(tokA), 1e23, 1e23);
        _addLiqDMD(alice, address(fot), 1e23, 1e4 ether);

        vm.startPrank(bob);
        // standard function cannot handle FOT input (K check fails) ...
        vm.expectRevert();
        router.swapExactTokensForTokens(1e20, 1, _path(address(fot), address(tokA)), bob, block.timestamp);
        // ... FOT variants work and enforce minOut on the amount actually received
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1e20, 1, _path(address(fot), address(tokA)), bob, block.timestamp);
        router.swapExactDMDForTokensSupportingFeeOnTransferTokens{value: 1 ether}(1, _path(address(wdmd), address(fot)), bob, block.timestamp);
        router.swapExactTokensForDMDSupportingFeeOnTransferTokens(1e20, 1, _path(address(fot), address(wdmd)), bob, block.timestamp);
        vm.expectRevert();
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1e20, 1e21, _path(address(fot), address(tokA)), bob, block.timestamp);
        vm.stopPrank();
        assertEq(address(router).balance, 0);
        assertEq(wdmd.balanceOf(address(router)), 0);
    }

    // ───────────────────────────── reentrancy

    function test_reentrantToken_cannotReenterRouter() public {
        ReentrantToken rt = new ReentrantToken();
        rt.mint(alice, 1e24);
        rt.mint(bob, 1e24);
        vm.prank(alice);
        rt.approve(address(router), type(uint256).max);
        vm.prank(bob);
        rt.approve(address(router), type(uint256).max);
        _addLiq(alice, address(rt), address(tokA), 1e22, 1e22);
        rt.arm(
            address(router),
            abi.encodeCall(
                DmdSwapRouter.swapExactTokensForTokens,
                (1e18, 1, _path(address(rt), address(tokA)), bob, block.timestamp)
            )
        );
        vm.prank(bob);
        router.swapExactTokensForTokens(1e18, 1, _path(address(rt), address(tokA)), bob, block.timestamp);
        assertTrue(rt.attempted());
        assertFalse(rt.reentrySucceeded(), "router must block re-entry");
    }

    // ───────────────────────────── quote consistency (fuzz)

    function testFuzz_quote_matchesExecution(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e6, 1e23));
        address[] memory p = _path3(address(tokA), address(tokB), address(tokC));
        uint256[] memory q = router.getAmountsOut(amountIn, p);
        vm.assume(q[2] > 0);
        uint256 c0 = tokC.balanceOf(bob);
        vm.prank(bob);
        router.swapExactTokensForTokens(amountIn, q[2], p, bob, block.timestamp);
        assertEq(tokC.balanceOf(bob) - c0, q[2]);
    }
}
